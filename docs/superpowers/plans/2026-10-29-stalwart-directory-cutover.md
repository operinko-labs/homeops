# Stalwart Internal Directory + stalwart-users OIDC Cutover Runbook

> **For agentic workers:** live-operations runbook, executed inline by the controller with the user (superpowers:executing-plans). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stalwart authenticates every mailbox from its internal directory (the 41 SSHA512 hashes copied verbatim), and stalwart-users v0.5.0 runs on `email-users.erinko.fi`, signing in through Stalwart's OIDC as a first-party client.

**Architecture:** One live window. Before it: release v0.5.0, add the OAuth client secret, register the client. In the window:
1. Freeze stalwart-users.
2. Back up Postgres.
3. Copy the SQL directory into the internal accounts with `migrate-directory`.
4. Switch `x:Authentication.directoryId` to internal and restart Stalwart.
5. Deploy v0.5.0 with OIDC and the host consolidation.

The SQL tables stay untouched as the rollback source for two weeks.

**Tech Stack:** Flux, Stalwart v1.0.0 registry API, CNPG, Forgejo Actions release.

**Spec:** `2026-10-28-stalwart-drop-sql-directory.md` (Task 9 and Task 10, Rehearsal) and `2026-10-28-stalwart-users-oidc-login.md` (Task 6, Task 7, Rehearsal). This runbook replaces their Task 9 / Task 6 as the steps to run; their rollback notes still hold.

## Global Constraints

- Right-password checks only on the live server, with `stalwart_username`/`stalwart_password` from homeops `.env` (`olli@erinko.fi`, 4-byte salt). Failed sign-ins count towards the ban threshold (100 per 24 h, now per real client IP).
- Never print or log secrets; temporary test passwords live only in the scratchpad and are deleted afterwards.
- `x:Authentication.directoryId` changes and `overrideProxyTrustedNetworks`-style settings take effect only after a Stalwart restart (Recreate, ~35–40 s to Ready).
- OAuth client: v0.5.0 registers `stalwart-users` itself at startup (OIDC plan Task 7): `firstParty: true`, `redirectUris` exactly `{"https://email-users.erinko.fi/api/auth/callback": true}`, `grantTypes` authorizationCode + refreshToken, secret derived from `JWT_SECRET`. No Vaultwarden field, no manual registration. Re-checked on Stalwart 1.0.0 on 2026-10-29: created on first start, corrected after tampering on the next start, sign-in works with the derived secret, SIGTERM exits in ~1 s.
- stalwart-users v0.5.0 env: `OIDC_ISSUER=https://mail.erinko.fi`, `OIDC_CLIENT_ID=stalwart-users`, `OIDC_REDIRECT_URL=https://email-users.erinko.fi/api/auth/callback`, `CORS_ORIGIN=https://email-users.erinko.fi`; existing `STALWART_URL`, `STALWART_ADMIN_TOKEN`, `DATABASE_URL`, `JWT_SECRET` stay. No `OIDC_CLIENT_SECRET`.
- SQL directory id `iqlf1mnmaaqc` is the rollback target.
- homeops commits go straight to `main`; no AI attribution.

## Impact

| What | When | How long |
|---|---|---|
| stalwart-users unavailable | from the freeze (Task 3 Step 1) to the deploy (Task 4) | ~20–30 min |
| Mail sign-ins (IMAP/POP/SMTP AUTH/JMAP/webmail) fail | during the Stalwart restart (Task 3 Step 5) | ~40–60 s |
| Mail delivery | queued by the VPS relay / senders during the restart | no loss |
| Bulwark sessions | the Stalwart restart; account ids don't change, so tokens should survive, but expect at most one fresh sign-in | — |
| stalwart-users sessions | v0.5.0 deploy (old sessions are SQL-era; everyone signs in once through Stalwart) | — |

---

### Task 1: Precondition (user)

- [ ] **Step 1:** User reviews and merges [operinko-labs/stalwart-users#37](https://forgejo.vaderrp.com/operinko-labs/stalwart-users/pulls/37) on Forgejo. Nothing else is needed from the user before the window.

### Task 2: Prepare (no user-visible change)

- [ ] **Step 1: Release v0.5.0.** On the merged `main` of `C:\Users\ollie\stalwart-users`: `git fetch forgejo && git tag v0.5.0 forgejo/main && git push forgejo v0.5.0`. Wait for the Release workflow. Verify in Harbor, for `stalwart-users` and `stalwart-users-frontend`: tags `v0.5.0`, `sha-<commit>`, `latest`; scan `Success`; `signature.cosign`. Confirm the backend image contains `/migrate-directory`, either by running `docker run --rm --entrypoint /migrate-directory harbor.vaderrp.com/operinko-labs/stalwart-users:v0.5.0 --help` or from the build log.
- [ ] **Step 2: Admin key may manage OAuth clients.** With the key from `stalwart-users-secret` (read inside a script, never printed), `x:OAuthClient/query` `{}` must answer a list, not a forbidden error. Otherwise self-registration would retry forever and every sign-in would fail.
- [ ] **Step 3: Discovery from inside the cluster.** From the Bulwark pod, `node -e` a fetch of `https://mail.erinko.fi/.well-known/openid-configuration` and print only `issuer` and `token_endpoint`. Expected `https://mail.erinko.fi` and `https://mail.erinko.fi/auth/token`.
- [ ] **Step 4: Pre-flight on live.**
  - The `.env` account gets 200 on `/jmap/session`.
  - `x:Authentication/get` shows `directoryId` `iqlf1mnmaaqc`.
  - `x:Account/get` shows 41 Users.
  - Record these values for rollback.

### Task 3: Window — directory switch

- [ ] **Step 1: Freeze stalwart-users.**
  ```bash
  flux suspend hr stalwart-users -n mail
  kubectl -n mail scale deploy -l app.kubernetes.io/name=stalwart-users --replicas=0
  ```
- [ ] **Step 2: Backup.** CNPG on-demand `Backup` `postgres18-pre-drop-sql-directory` (method `plugin`, plugin `barman-cloud.cloudnative-pg.io`, as for `postgres18-pre-stalwart-1-0`). Wait with `kubectl -n database get backups.postgresql.cnpg.io postgres18-pre-drop-sql-directory -w` until `completed`.
- [ ] **Step 3: Migration dry run.** `kubectl apply` a one-shot Job (scratchpad manifest, not committed):
  - `mail/stalwart-users-migrate`, image `harbor.vaderrp.com/operinko-labs/stalwart-users:v0.5.0`, command `/migrate-directory`;
  - `envFrom` `stalwart-users-secret`, `STALWART_URL=http://stalwart-app.mail.svc.cluster.local:8080`;
  - restricted PodSecurity context: runAsNonRoot, drop ALL, seccomp RuntimeDefault, no privilege escalation;
  - `backoffLimit: 0`.

  Read the logs. Expected: 41 accounts, no errors; `admin@vaderrp.com` already Admin; no `roles` change for `olli@erinko.fi`; aliases only added where SQL has ones Stalwart lacks.
- [ ] **Step 4: Apply.** Delete the Job and re-apply it with `--apply`. Expected: every line `updated (…secret…)` or `unchanged`, then the "secret written again" note. Run it a third time with `--apply`: patch fields all `unchanged`.
- [ ] **Step 5: Switch.** `x:Authentication/set` `{"update":{"singleton":{"directoryId":null}}}`. Read back: `directoryId` `null`. Then `kubectl -n mail rollout restart deploy/stalwart` and `kubectl -n mail rollout status deploy/stalwart --timeout=240s`.
- [ ] **Step 6: Verify mail.**
  - The `.env` account gets 200 on `/jmap/session` through `stalwart-admin.vaderrp.com`.
  - IMAP LOGIN succeeds through the VPS: `openssl s_client -connect 212.147.241.182:993 -servername mail.erinko.fi -quiet`, then `a LOGIN …`.
  - SMTP AUTH succeeds on 465.
  - `x:Account/get` still shows that account as Admin.
  - The user checks their phone and Bulwark.
  - Over 15 minutes, the Stalwart log shows no rising `auth.failed` for real users.

  If anything fails: **Rollback A**.

### Task 4: Window — stalwart-users v0.5.0

- [ ] **Step 1: Commit homeops.**
  - `helmrelease.yaml`: both image tags → `v0.5.0`. Backend env gains `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_REDIRECT_URL` and changes `CORS_ORIGIN`, per Global Constraints.
  - `httproute.yaml`: route `stalwart-users` serves only `email-users.erinko.fi`. A new route `stalwart-users-redirect` sends `email-users.vaderrp.com` to `https://email-users.erinko.fi` with a 301, path kept, same shape as `bulwark-webmail`; keep `external-dns` and the `route.scope: external` label on both.
  - Homepage `href` → `https://email-users.erinko.fi`.

  Push.
- [ ] **Step 2: Deploy.**
  ```bash
  flux reconcile ks stalwart-users -n mail --with-source
  flux resume hr stalwart-users -n mail
  ```
  Then `kubectl -n mail scale deploy -l app.kubernetes.io/name=stalwart-users --replicas=1` (resume doesn't restore replicas) and wait for Ready. Backend log: `OIDC issuer: https://mail.erinko.fi`, `Listening` and `OAuth client stalwart-users created`, no errors. `x:OAuthClient/get` (properties `clientId`, `firstParty`, `redirectUris`, `grantTypes`) shows the expected client.
- [ ] **Step 3: Scripted checks** (browser User-Agent header, since Cloudflare blocks Python's):
  - `https://email-users.vaderrp.com/x` → 301 `https://email-users.erinko.fi/x`.
  - `https://email-users.erinko.fi/api/auth/login` → 302 to `https://mail.erinko.fi/login?…` with `client_id=stalwart-users`, the redirect URI above, `scope=openid offline_access` and S256.
- [ ] **Step 4: Temporary account round trip** (the controller, never on the user's account).
  1. Create `cutover-test@vaderrp.com` with a known strong password through the admin API.
  2. Run the scripted OIDC sign-in against live: `/api/auth/login` → `POST https://mail.erinko.fi/api/auth` → callback on `email-users.erinko.fi` → `/api/auth/me` shows the account, not admin.
  3. Change its own password with the right current password → 200; the new password signs in to Stalwart.
  4. Delete the account through the admin API and the scratch file.
- [ ] **Step 5: User checks.**
  - The user signs in at `https://email-users.erinko.fi` through Stalwart's page, sees 41 accounts, and opens their own account.
  - `GET /api/accounts/minna@medikabalans.fi/admin-domains` (or the UI) shows `medikabalans.fi`.
- [ ] **Step 6: Clean up.** Delete the Job and the scratch manifests.

  Record the results:
  - "Done" sections in this runbook and in both source plans;
  - memory `project_stalwart_1_0_migration.md`;
  - the `stalwart-users` release memory (v0.5.0, OIDC).

  Commit and push homeops.

### Task 5: After two weeks (≈ 2026-11-12)

- [ ] Drop-SQL plan Task 10: destroy the Sql directory `iqlf1mnmaaqc`, drop `directory.accounts`/`emails`/`group_members` (keep `domain_admins`), trim `init-directory.sql`, delete backup `postgres18-pre-drop-sql-directory`.
- [ ] 1.0 migration Phase 4 (pending since 2026-10-27): drop the old `stalwart` DB, remove `migrate.yaml` + its PVC and the 0.16 `config.json` from `stalwart-secret`, delete backup `postgres18-pre-stalwart-1-0`.

## Rollback

**Rollback A — mail sign-in broken after the switch** (Task 3 Step 6):
1. `x:Authentication/set` `directoryId` back to `iqlf1mnmaaqc`.
2. Restart Stalwart.
3. Check the `.env` account gets 200.
4. Leave stalwart-users on v0.4.2: `flux resume hr stalwart-users -n mail` and scale it back to 1.

**Rollback B — stalwart-users v0.5.0 broken, mail fine:** `git revert` the Task 4 Step 1 commit, push and reconcile, and v0.4.2 comes back. But v0.4.2 writes to SQL, which Stalwart no longer reads, so also suspend and scale it to 0 until it's fixed forward, rather than letting it change SQL.

**Full rollback within the soak:**
1. Rollback A.
2. Rollback B without the scale-down.
3. Passwords changed after the cutover revert to the SQL hashes.

The OAuth client can stay registered.

## Done (2026-10-29, UTC)

- v0.5.0 tagged at 27d9b9f (Release run success; both images signed, scans Success). Pre-flight clean: the only API key is `admin@vaderrp.com`'s (Admin role), discovery reachable in-cluster, 41 Users, dry run without errors (six empty descriptions to fill).
- Freeze 00:58, backup `postgres18-pre-drop-sql-directory` completed 01:01.
- **Order change:** the first `--apply` stopped at `fritzbox@erinko.fi` with "Cannot change credentials for accounts in an external directory". Without the enterprise edition every domain uses the default directory (`get_default_directory`), so while it is the SQL directory every credential change is refused. Accounts whose internal secret already matched SQL (synced by a recent login) were no-ops, which is why the rehearsal never hit this. With the user's OK: `directoryId: null` + restart first (down 01:11:39–01:12:16), then `--apply` at 01:12:20 wrote all 41 hashes; a second `--apply` was all `unchanged`. **For any re-run: switch first, migrate immediately after.**
- Verified: `.env` account JMAP 200, IMAP LOGIN and SMTP AUTH via the VPS, both admins intact, no auth failures. stalwart-users v0.5.0 deployed (392ba5366) and self-registered `stalwart-users`; `email-users.vaderrp.com` → 301 `email-users.erinko.fi`; temporary account round trip (OIDC sign-in, `/auth/me`, own password change) OK and the account deleted. User confirmed email-users, Bulwark and phone.
- Found afterwards: `erinko.fi/.well-known/jmap` redirected to chat.erinko.fi, breaking JMAP autodiscovery (Epistles) → fixed in the matrix `well-known` route (cafe568d4). Epistles works with an app password; its OAuth device flow still gets `invalid_client` (it sends a client ID Stalwart doesn't know and doesn't self-register; debug log shows no metadata-document fetch). `x:OidcProvider.clientMetadataDocuments` was set to `any` for that test and is still `any`; tracer level was raised to debug for the capture and is back at `info`.
- Epistles follow-up: its client ID is the fixed `epistles-jmap` (found in its WebView code cache, next to the hard-coded scope `openid email profile offline_access`). Registered it as public client `e` (grantTypes deviceCode + refreshToken; scopes mail, contacts, calendars). The device endpoint now answers `invalid_scope`: Stalwart accepts `openid`, `offline_access` and the `urn:ietf:params:oauth:scope:*` scopes but rejects `email` and `profile`, has no setting to allow them, and Epistles ignores `scopes_supported`. OAuth needs an Epistles fix; it stays on the app password. The client entry stays for when it does.
- `clientMetadataDocuments` back to `disabled` (+ ReloadSettings) on 2026-10-29; a metadata-URL `client_id` now gets `invalid_client`. Discovery still advertises `client_id_metadata_document_supported: true` regardless of the setting.
