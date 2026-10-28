# Drop Stalwart's SQL Directory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stalwart 1.0 authenticates every mail user from its own internal directory, with the existing `{SSHA512}` hashes copied in verbatim, and stalwart-users manages accounts through Stalwart's admin API instead of the `directory` SQL tables.

**Architecture:** stalwart-users already talks to its data through small store interfaces (`accountsStore`, `aliasesStore`, `groupsStore`, `passwordsStore`, `auth.AccessStore`). A new `internal/directory.Store` implements them over Stalwart's JMAP admin API (`x:Account`, `x:Domain`), keeping only the app-owned `directory.domain_admins` table in Postgres. A one-shot `migrate-directory` command copies hashes, aliases, admin roles and quotas from SQL into the 41 internal accounts Stalwart already mirrors. At cutover, `Authentication.directoryId` switches from the SQL directory to the internal one; the SQL tables stay untouched as the rollback source until the soak ends.

**Tech Stack:** Go 1.24 (stalwart-users, stdlib `net/http`, `lib/pq`), Stalwart v1.0.0 JMAP registry API, CNPG Postgres 18, Flux.

**Spec:** this plan plus the test record in `docs/superpowers/plans/2026-10-27-stalwart-1.0-migration.md` ("Tested 2026-10-28 in a throwaway 1.0.0 pod…").

## Global Constraints

- Stalwart image stays `ghcr.io/stalwartlabs/stalwart:v1.0.0@sha256:baafeacd6cbde77acdd94af49972d41c6709e54a376df48e18a9fe3f445eb3d5`.
- SQL directory object id is `iqlf1mnmaaqc`; it is the current `x:Authentication` singleton `directoryId`.
- Existing hashes are copied byte-for-byte. Stalwart stores a Password secret as-is only when it starts with `{` or `$` and passes `is_password_hash`; anything else gets hashed as a plaintext password. Never send a value that fails the format check below.
- Hash format check (all 41 live rows pass it): case-insensitive prefix `{SSHA512}`, body matches `^[A-Za-z0-9+/]+={0,2}$`, base64-decoded length ≥ 65. Live salts are 4, 8 and 16 bytes.
- New and changed passwords go to Stalwart as plaintext; Stalwart hashes them with `passwordHashAlgorithm` = `argon2id` and enforces `minPasswordLength` 8 and `minPasswordStrength` "three".
- An account's name in stalwart-users is its full address (`local@domain`); in Stalwart it is `name` (local part) plus `domainId`.
- Full admin = `roles` `{"@type":"Admin"}`; everyone else `{"@type":"User"}`. Domain-admin assignments stay in Postgres `directory.domain_admins` (`stalwart_v1` DB).
- Quota maps to `quotas` key `maxDiskQuota` (bytes); 0 means no entry (unlimited). Confirm the JSON key in Task 7 before relying on it.
- stalwart-users changes go on a branch in `C:\Users\ollie\stalwart-users`, pushed to the `forgejo` remote, as a PR the user merges; release = `v*` tag. homeops changes commit straight to `main`.
- No AI attribution in commits or PR text.

## Decisions taken (flag to the user at handoff)

1. **No "inactive" accounts.** 1.0 accounts have no enable flag and every live account is active. `active` is always `true` in API output; a PATCH with `"active": false` returns 400 `accounts can't be disabled in Stalwart 1.0`. The frontend drops the Active toggle.
2. **Groups use Stalwart's own groups.** `/accounts/{name}/groups` reads and writes `memberGroupIds`, naming groups by their address. No groups exist today. Creating accounts of type `group` from stalwart-users returns 400; groups are made in Stalwart's admin UI.
3. **stalwart-users login goes through Stalwart.** It checks credentials with HTTP Basic on `/jmap/session` instead of reading hashes. Side effect: the 27 accounts with 4- or 8-byte salts can sign in to stalwart-users for the first time (today's `verifySsha512` rejects anything under 80 decoded bytes). Accounts with two-factor auth can't sign in this way; that matches today.

## Review Focus

- A secret that fails the hash format check (whitespace, URL-safe base64, empty) must make `migrate-directory` stop with that account named, never send it → Task 6 `TestMigrateRejectsMalformedHash`.
- Stalwart's password-policy rejection of a new password must reach the user as 400 with Stalwart's description, not 500 → Task 2 `TestSetPasswordInvalidProperties`, Task 5 `TestChangePasswordWeakPassword`.
- An alias on a domain Stalwart doesn't host, or one already used by another account, must give 400/409 → Task 4 `TestInsertEmailUnknownDomain`, `TestInsertEmailInUse`.
- Re-running `migrate-directory --apply` after a partial run must change nothing that's already right and finish the rest → Task 6 `TestMigrateIsIdempotent`.
- A user whose internal account has no Password credential yet (created after the last SQL sync) must get one created, not a patch to a missing key → Task 2 `TestSetPasswordCreatesCredential`.

---

### Task 1: JMAP client reads (accounts, domains, credential check)

**Files:**
- Modify: `internal/stalwart/jmap.go`
- Test: `internal/stalwart/jmap_test.go`

**Interfaces:**
- Produces:
  ```go
  type Alias struct{ Name, DomainID string }
  type Account struct {
      ID, Type, Name, DomainID, Email, Description string // Type: "User" | "Group"
      Aliases       map[string]Alias // keyed by Stalwart list key
      IsAdmin       bool             // roles["@type"] == "Admin"
      DiskQuota     int64            // quotas["maxDiskQuota"], 0 if absent
      MemberGroupIDs []string
      PasswordKey   string           // list key of the Password credential, "" if none
  }
  type Domain struct{ ID, Name string }
  func (c *Client) ListAccounts(ctx context.Context) ([]Account, error)   // x:Account/get ids:null
  func (c *Client) ListDomains(ctx context.Context) ([]Domain, error)     // x:Domain/get ids:null, properties [name]
  func (c *Client) Authenticate(ctx context.Context, username, password string) (bool, error) // GET /jmap/session, Basic; 200→true, 401→false, else error
  ```

- [ ] **Step 1: Write failing tests** `TestListAccountsMapsFields` (fixture with an Admin user that has two aliases, `quotas {"maxDiskQuota":1048576}`, credentials `{"0":{"@type":"Password"},"1":{"@type":"ApiKey"}}` → `IsAdmin` true, `DiskQuota` 1048576, `PasswordKey` "0", `Email` from `emailAddress`), `TestListAccountsNoPassword` (credentials `{}` → `PasswordKey` ""), `TestListDomains`, `TestAuthenticate` (200 → true, 401 → false, 500 → error; assert the `Authorization: Basic` header and that no Bearer token is sent).
- [ ] **Step 2: Run** `go test ./internal/stalwart/ -run 'ListAccounts|ListDomains|Authenticate'` → FAIL (undefined).
- [ ] **Step 3: Implement** the three methods; reuse `call` for the JMAP ones.
- [ ] **Step 4: Run** the same command → PASS; then `go test ./...` → PASS.
- [ ] **Step 5: Commit** `feat(stalwart): read accounts and domains, check credentials`.

### Task 2: JMAP client writes (create with password, update, set password)

**Files:**
- Modify: `internal/stalwart/jmap.go`
- Test: `internal/stalwart/jmap_test.go`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  ```go
  // ErrInvalid wraps Stalwart's notCreated/notUpdated "invalidProperties"/"invalidPatch";
  // its Error() is Stalwart's description so handlers can return it as 400.
  type ErrInvalid struct{ Description string }
  func (c *Client) CreateAccount(ctx context.Context, name, password, description string, diskQuota int64) error // password may be plaintext or a hash
  func (c *Client) UpdateAccount(ctx context.Context, id string, patch map[string]any) error
  func (c *Client) SetPassword(ctx context.Context, account Account, secret string) error
  ```
  `SetPassword` patches `credentials/<PasswordKey>/secret` when `PasswordKey != ""`, otherwise patches `credentials/0` with `{"@type":"Password","secret":secret}` — confirm that create-via-patch form in Task 7 and adjust here if Stalwart wants another key.

- [ ] **Step 1: Write failing tests** `TestCreateAccountWithPassword` (payload has `credentials {"0":{"@type":"Password","secret":"pw"}}` and `quotas {"maxDiskQuota":5}`; quota 0 → `quotas {}`), `TestUpdateAccountPatch`, `TestSetPasswordPatchesExisting` (patch key `credentials/0/secret`), `TestSetPasswordCreatesCredential`, `TestSetPasswordInvalidProperties` (`notUpdated` with `invalidProperties` + description "Password is too weak" → `errors.As(err, &ErrInvalid{})` and description preserved). Update `TestCreateAccountSuccess` for the new signature.
- [ ] **Step 2: Run** `go test ./internal/stalwart/` → FAIL.
- [ ] **Step 3: Implement**; `NotUpdated` is added to `jmapSetResponse`.
- [ ] **Step 4: Run** `go test ./...` → PASS.
- [ ] **Step 5: Commit** `feat(stalwart): create with password, update and set password`.

### Task 3: directory.Store — accounts and access

**Files:**
- Create: `internal/directory/store.go`, `internal/directory/store_test.go`
- Modify: `internal/db/accounts.go` (only `IsAdmin` callers move; SQL account functions are deleted in Task 5)

**Interfaces:**
- Consumes: Task 1–2 client methods; `db.Pool.ListAdminDomains`, `SetAdminDomains`.
- Produces:
  ```go
  type jmapClient interface { /* ListAccounts, ListDomains, CreateAccount, UpdateAccount, DeleteAccount, SetPassword, Authenticate */ }
  type adminDomainsDB interface {
      ListAdminDomains(name string) ([]string, error)
      SetAdminDomains(name string, domains []string) error
      DeleteAdminDomains(name string) error // new in internal/db/domain_admins.go
  }
  func New(client jmapClient, admins adminDomainsDB) *Store
  func (s *Store) ListAccounts() ([]model.Account, error)            // Users only; Type "individual", Active true, Quota = DiskQuota
  func (s *Store) GetAccount(name string) (*model.Account, error)    // nil, nil when absent
  func (s *Store) CreateAccount(name, password, description, accountType string, quota int) error // accountType "group" → ErrUnsupported
  func (s *Store) UpdateAccount(name string, description *string, quota *int, active *bool) error   // active=false → ErrUnsupported
  func (s *Store) DeleteAccount(name string) error                   // JMAP destroy + DeleteAdminDomains
  func (s *Store) IsAdmin(name string) (bool, error)
  func (s *Store) ListAdminDomains(name string) ([]string, error)    // delegates
  func (s *Store) SetAdminDomains(name string, domains []string) error // delegates
  var ErrUnsupported = errors.New(...)  // handlers map to 400 with its text
  ```
  Unknown accounts return `db.ErrAccountNotFound` so existing handler checks keep working; `db.ErrAccountNotFound` and `db.ErrGroupMembershipNotFound` stay when Task 5 deletes the SQL functions. Every method uses a 5 s context like `internal/db`.

- [ ] **Step 1: Write failing tests** against a fake `jmapClient`: `TestListAccountsMapsModel`, `TestGetAccountMissing`, `TestCreateAccountPassesPlaintext` (fake records password `"hunter2-Long!"` unchanged), `TestCreateGroupUnsupported`, `TestUpdateAccountQuotaPatch` (quota 0 → patch `quotas` `{}`), `TestUpdateAccountDeactivateUnsupported`, `TestDeleteAccountRemovesAdminDomains`, `TestIsAdminFromRoles`.
- [ ] **Step 2: Run** `go test ./internal/directory/` → FAIL.
- [ ] **Step 3: Implement**; add `DeleteAdminDomains` to `internal/db/domain_admins.go` with a test in `domain_admins_test.go` (sqlmock, like its neighbours).
- [ ] **Step 4: Run** `go test ./...` → PASS.
- [ ] **Step 5: Commit** `feat(directory): account store over Stalwart's admin API`.

### Task 4: directory.Store — addresses and groups

**Files:**
- Modify: `internal/directory/store.go`, `internal/directory/store_test.go`

**Interfaces:**
- Consumes: Task 3 `Store`.
- Produces:
  ```go
  func (s *Store) ListEmails(name string) ([]model.Email, error)   // primary (Type "primary") first, then aliases (Type "alias")
  func (s *Store) InsertEmail(name, address, emailType string) error // alias only; adds to aliases
  func (s *Store) GetEmailType(name, address string) (string, error) // "" when not on this account
  func (s *Store) DeleteEmail(name, address string) error
  func (s *Store) AddressInUse(address string) (bool, error)         // case-insensitive over every account's Email and aliases
  func (s *Store) ListGroups(name string) ([]string, error)          // group addresses from memberGroupIds
  func (s *Store) AddGroup(name, memberOf string) error              // memberOf must be an existing Group account
  func (s *Store) RemoveGroup(name, memberOf string) error           // db.ErrGroupMembershipNotFound when absent
  var ErrAddressInUse = errors.New("address already in use")       // handlers map to 409
  ```

- [ ] **Step 1: Write failing tests** `TestListEmailsPrimaryFirst`, `TestInsertEmailAddsAlias` (patch `aliases/<newkey>` with `{"enable":true,"name":"info","domainId":"j"}`), `TestInsertEmailUnknownDomain` (→ `ErrUnsupported`-style 400 error naming the domain), `TestInsertEmailInUse` (address on another account → `ErrAddressInUse`), `TestDeleteEmailRemovesAlias`, `TestAddressInUseCaseInsensitive`, `TestAddGroupUnknownGroup`, `TestRemoveGroupMissing`.
- [ ] **Step 2: Run** `go test ./internal/directory/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./...` → PASS.
- [ ] **Step 5: Commit** `feat(directory): addresses and group membership`.

### Task 5: Login, password change and wiring

**Files:**
- Modify: `internal/auth/login.go`, `internal/api/password.go`, `internal/api/accounts.go`, `cmd/server/main.go`, `README.md`, `frontend/src/pages/AccountsPage.tsx`
- Delete: `internal/auth/hash.go`, `internal/auth/hash_test.go`, the SQL account/email/group functions in `internal/db/accounts.go`, `emails.go`, `groups.go` (keep `domain_admins.go`, `db.go`)
- Test: `internal/auth/login_test.go`, `internal/api/password_test.go`, `internal/api/accounts_test.go`, `cmd/server/main_test.go`

**Interfaces:**
- Consumes: Task 1 `Authenticate`, Task 3–4 `Store`.
- Produces:
  ```go
  // internal/auth
  type StalwartAuthenticator struct{ /* checker, admins */ }
  func NewStalwartAuthenticator(checker interface{ Authenticate(ctx context.Context, u, p string) (bool, error) }, admins AccessStore) *StalwartAuthenticator
  // internal/api
  type passwordsStore interface {
      Authenticate(ctx context.Context, name, password string) (bool, error)
      SetPassword(name, password string) error
  }
  ```
  `newCreateAccountHandler` and `handleDeleteAccount` lose the `stalwartClient` parameter (the store now is Stalwart). `ErrUnsupported` / `stalwart.ErrInvalid` → 400 with the error text; `ErrAddressInUse` → 409. `main.go` requires `STALWART_URL`, `STALWART_ADMIN_TOKEN` and `DATABASE_URL` (domain_admins only) and fails fast if one is missing.

- [ ] **Step 1: Write failing tests** `TestStalwartAuthenticatorSuccess` (IsAdmin from `AccessStore.IsAdmin`), `TestStalwartAuthenticatorInvalid` (false → nil user, nil error), `TestChangePasswordSelfChecksCurrent` (fake `Authenticate` false → 401), `TestChangePasswordWeakPassword` (`stalwart.ErrInvalid{"Password is too weak"}` → 400 with that text), `TestCreateAccountWeakPassword`, `TestPatchAccountDeactivate400`, and a `main_test.go` case that missing `STALWART_ADMIN_TOKEN` fails config.
- [ ] **Step 2: Run** `go test ./...` → FAIL.
- [ ] **Step 3: Implement**; remove now-unused code and imports; frontend drops the Active toggle from the edit form (MyAccountPage keeps showing "Active").
- [ ] **Step 4: Run** `go test ./... && go vet ./...` and `npm --prefix frontend run build` → PASS.
- [ ] **Step 5: Commit** `feat: manage accounts through Stalwart's internal directory`.

### Task 6: `migrate-directory` command

**Files:**
- Create: `cmd/migrate-directory/main.go`, `cmd/migrate-directory/migrate.go`, `cmd/migrate-directory/migrate_test.go`
- Modify: `Dockerfile` (build and ship the second binary), `README.md`

**Interfaces:**
- Consumes: Task 1–2 client (`ListAccounts`, `ListDomains`, `UpdateAccount`, `SetPassword`).
- Produces: binary `/migrate-directory` in the backend image. Env: `DATABASE_URL`, `STALWART_URL`, `STALWART_ADMIN_TOKEN`. Flags: `--apply` (default is a dry run), `--only <address>` (repeatable).
  ```go
  type sqlAccount struct{ Name, Secret, Description string; Quota int64; IsAdmin bool; Aliases []string }
  func loadSQL(db *sql.DB) ([]sqlAccount, error) // accounts JOIN emails (type <> 'primary'), active = true only
  func validHash(secret string) bool              // the Global Constraints format check
  func plan(sqlAccts []sqlAccount, accts []stalwart.Account, domains []stalwart.Domain) ([]change, error)
  type change struct{ Address, AccountID string; Patch map[string]any; Secret string; Account stalwart.Account }
  ```
  Per account the patch sets `description`, `roles` (Admin iff `is_admin`), `quotas` (`maxDiskQuota` iff quota > 0), and `aliases` (exact set from SQL, existing keys reused); the secret goes through `SetPassword`. Output: one line per account, `address: unchanged|updated|would update (<fields>)`; secrets never printed. Exit non-zero if any SQL account has no internal account, any alias domain is unknown, or any hash fails `validHash` — before writing anything.

- [ ] **Step 1: Write failing tests** `TestValidHash` (the four live shapes pass; `{SSHA512}` + URL-safe body, trailing space, `{SSHA}`-only, empty fail), `TestMigrateRejectsMalformedHash` (whole run aborts, no client writes), `TestMigrateMissingInternalAccount`, `TestPlanAdminAndAliases`, `TestMigrateIsIdempotent` (second plan over the result of the first → all `unchanged`), `TestDryRunWritesNothing`.
- [ ] **Step 2: Run** `go test ./cmd/migrate-directory/` → FAIL.
- [ ] **Step 3: Implement.** "Unchanged" for the secret can't be read back (Stalwart masks it), so `--apply` always calls `SetPassword`; idempotence covers the patch fields.
- [ ] **Step 4: Run** `go test ./... && docker build -f Dockerfile .` → PASS, image contains `/migrate-directory`.
- [ ] **Step 5: Commit, push branch, open the PR** (`tea pr create`), then stop for the user to merge after Task 7.

### Task 7: Rehearsal in a throwaway pod

Runs the branch image against a disposable Stalwart 1.0 with its own Postgres; nothing touches live data. Scratch files go in the session scratchpad, not in git.

**Files (scratchpad):** `dirtest.yaml` (NetworkPolicy with no egress except pod-local; Pod with containers `postgres:18` on an emptyDir, `stalwart:v1.0.0` with a RocksDB config and a throwaway `STALWART_RECOVERY_ADMIN`, and the branch's stalwart-users backend image), `dirtest-seed.sql`, `dirtest.py`.

- [ ] **Step 1: Seed** Postgres with `init-directory.sql` from `kubernetes/apps/mail/stalwart/app/configmap.yaml`, `is_admin` and `domain_admins`, and five accounts with known passwords: salts 4, 8, 16, a lowercase `{ssha512}`, and one `is_admin` account with two aliases.
- [ ] **Step 2: Configure Stalwart** over the API: two domains, a Sql directory copied from live `iqlf1mnmaaqc` (same queries) pointing at the sidecar, `x:Authentication` `directoryId` set to it, restart. Sign in once per account so Stalwart creates the internal mirrors. Expected: 200 for each.
- [ ] **Step 3: Confirm the open schema points:** the `maxDiskQuota` JSON key, the `SetPassword` create-via-patch form for an account with no Password credential, and that patching an existing credential with a hash stores it as-is (sign-in with the known password → 200). Fix Task 1–2 code if any differ.
- [ ] **Step 4: Run** `/migrate-directory` (dry run, then `--apply`, then `--apply` again). Expected: second apply prints only `unchanged` apart from secrets.
- [ ] **Step 5: Switch** `x:Authentication` `directoryId` to `null` (internal) and restart Stalwart. Expected: all five sign in with their passwords (200) and fail with a wrong one (401); `x:Account/get` shows the admin account with `roles.@type` Admin and both aliases.
- [ ] **Step 6: Exercise stalwart-users** against the pod: login as the admin and as a 4-byte-salt user (200), create an account, change a password (then sign in to Stalwart with it → 200), add and remove an alias, set a quota, delete the account, weak password → 400.
- [ ] **Step 7: Rollback drill:** set `directoryId` back to the Sql directory, restart, the original passwords sign in → 200.
- [ ] **Step 8: Tear down** pod, NetworkPolicy and secret; record results under a "Rehearsal" heading at the end of this plan and commit to homeops `main`.

### Task 8: Release

- [ ] **Step 1:** User merges the PR on Forgejo. Tag `v0.5.0` on `main` and push to `forgejo`.
- [ ] **Step 2:** Verify both images in Harbor: tags `v0.5.0`, `sha-<commit>`, `latest`; scan Success; `signature.cosign` present.

### Task 9: Cutover (homeops, live)

Mail keeps flowing throughout; sign-ins fail only during the Stalwart restart (~1 min). stalwart-users is down from step 2 to step 9.

**Files:**
- Modify: `kubernetes/apps/mail/stalwart-users/app/helmrelease.yaml` (both tags → `v0.5.0`; `STALWART_URL`, `STALWART_ADMIN_TOKEN` and `DATABASE_URL` are already in the pod env)
- Create (cutover only, applied with `kubectl apply`, not committed): a one-shot Job manifest running `/migrate-directory` from the v0.5.0 backend image with `envFrom: stalwart-users-secret` and the HelmRelease's `STALWART_URL`

- [ ] **Step 1: Canary.** Insert `dircanary@vaderrp.com` into `directory.accounts` (+ primary email) with a known password hashed with an 8-byte salt; sign in once (200) so Stalwart mirrors it.
- [ ] **Step 2: Freeze.** `flux suspend hr stalwart-users -n mail`; `kubectl -n mail scale deploy -l app.kubernetes.io/name=stalwart-users --replicas=0`.
- [ ] **Step 3: Backup.** CNPG on-demand `Backup` of `postgres18` named `postgres18-pre-drop-sql-directory`; wait with `kubectl -n database get backups.postgresql.cnpg.io postgres18-pre-drop-sql-directory -w` until `completed`.
- [ ] **Step 4: Dry run.** Run the Job without `--apply`; the output lists 42 accounts (41 + canary) and no errors.
- [ ] **Step 5: Apply.** Run the Job with `--apply`; then again → only `unchanged` apart from secrets.
- [ ] **Step 6: Switch.** `x:Authentication/set` `{"update":{"singleton":{"directoryId":null}}}`; `kubectl -n mail rollout restart deploy/stalwart`; wait for Ready.
- [ ] **Step 7: Verify.** Canary: right password 200, wrong 401 on `/jmap/session`. IMAP and SMTP AUTH for the canary (`openssl s_client` to `mail.erinko.fi:993` / `:465`). User signs in to Bulwark and their mail client. Loki: no spike of `auth.failed` for real users over 15 min.
- [ ] **Step 8: Deploy** stalwart-users v0.5.0 (commit the helmrelease/external-secret change, reconcile, `flux resume hr stalwart-users -n mail`, scale to 1 if it stays at 0). Log in as the user: the account list shows 42 and `GET /accounts/minna@medikabalans.fi/admin-domains` still returns `medikabalans.fi`.
- [ ] **Step 9: Clean up** the canary (delete it in stalwart-users and from `directory.accounts`/`emails`), delete the Job, record the cutover in this plan.

**Rollback** (any time before the soak ends): `directoryId` back to `iqlf1mnmaaqc`, restart Stalwart, stalwart-users back to `v0.4.2`. Passwords changed after cutover revert to the SQL hash.

### Task 10: After a two-week soak

- [ ] Destroy the Sql directory object `iqlf1mnmaaqc` via `x:Directory/set`.
- [ ] Drop `directory.accounts`, `directory.emails`, `directory.group_members` in `stalwart_v1`; keep `directory.domain_admins`.
- [ ] Remove those tables from `init-directory.sql` in `kubernetes/apps/mail/stalwart/app/configmap.yaml`; keep the schema creation for `domain_admins`.
- [ ] Delete the backup `postgres18-pre-drop-sql-directory`; update the memory note and the 1.0 migration runbook.
