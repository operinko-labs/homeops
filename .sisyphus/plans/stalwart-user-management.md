# Stalwart User Management — Go API + SPA

## TL;DR

> **Quick Summary**: Build a Go API backend + vanilla SPA for managing Stalwart mail server's SQL directory (accounts, email aliases, group memberships). The API runs as a sidecar in the Stalwart pod; the SPA is served via Stalwart's Applications feature as a zip artifact.
>
> **Deliverables**:
> - Go API binary (container image in Harbor `operinko-labs` project)
> - Vanilla HTML/JS SPA (zip artifact on GitHub release)
> - Homeops Kubernetes manifests (sidecar + Stalwart Applications config)
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: Task 1 → Task 2 → Tasks 3-6 → Tasks 7-10 → Tasks 11-13 → F1-F4

---

## Context

### Original Request
Stalwart mail server uses a PostgreSQL SQL directory for user accounts but has no built-in UI for managing users/aliases. Build a user management solution: a static SPA mounted via Stalwart Applications and a Go API backend as a sidecar container handling PostgreSQL CRUD + SSHA512 hashing.

### Interview Summary
**Key Discussions**:
- **Stack**: Go for API (single binary, lightweight sidecar), vanilla HTML/JS for SPA (no build step)
- **Auth**: JMAP token forwarding — sidecar validates tokens by calling Stalwart's `/jmap/session` on localhost:8080
- **Deployment**: Sidecar container in existing Stalwart pod (bjw-s app-template pattern)
- **SPA delivery**: Stalwart Applications feature — zip with `index.html`, fetched via `resourceUrl` from GitHub release
- **Source code**: Dedicated repo under `operinko-labs` GitHub org
- **CI**: Org-runner (ARC), images pushed to Harbor (`operinko-labs` project, public)
- **Scope**: CRUD accounts + email aliases + group memberships, SSHA512 hashing, JMAP auth
- **Tests**: TDD approach for Go backend

**Research Findings**:
- SQL directory schema: `directory.accounts` (name PK, secret, description, type, quota, active), `directory.emails` (name+address PK, type), `directory.group_members` (name+member_of PK)
- SSHA512: `{SSHA512}` prefix + Base64(SHA512(password+salt) + salt), 16-byte salt
- JMAP session: GET `/jmap/session` with `Authorization: Bearer <token>` → 200 OK with account info (including admin flag) or 401
- Stalwart Applications: `[application."name"]` config with `resourceUrl`, `urlPrefix`, `unpackDirectory`
- Existing sidecar pattern: n8n's `tempest-mcp` container under `controllers.n8n.containers`
- DB: `postgres18-rw.database.svc.cluster.local:5432/stalwart`, user `stalwart`, password from Bitwarden ExternalSecret

### Metis Review
**Identified Gaps** (addressed):
- **Admin gating**: JMAP session response includes account capabilities — API must verify the authenticated user has admin role, not just a valid token. Default: check for admin account name match against env var `ADMIN_USERS` (comma-separated list)
- **Cascade deletes**: Deleting an account must clean up `directory.emails` and `directory.group_members` rows. Use SQL transaction.
- **Primary email protection**: Primary email (`type='primary'`) should only be removed when the account is deleted, not via alias CRUD
- **Port selection**: Sidecar listens on port 3000 (avoids all Stalwart ports: 25, 143, 443, 465, 587, 993, 995, 4190, 8080)
- **CORS**: Not needed in any environment. In production, SPA and API are on the same origin via HTTPRoute path-based routing (`/manage/users/*` → Stalwart, `/manage/api/*` → sidecar). In development, both SPA and API are served by the Go server on the same port (`SERVE_UI=./ui` serves SPA at `/`, API at `/accounts`).
- **Salt length**: 16 bytes (standard, compatible with Stalwart's verification)
- **Empty passwords**: Reject — return 400
- **No ORM**: Use `database/sql` + `lib/pq` directly
- **Health endpoint**: `/healthz` for liveness/readiness probes

---

## Work Objectives

### Core Objective
Create a complete user management solution for Stalwart's SQL directory — a Go REST API + vanilla SPA — deployed as a sidecar container and Stalwart Application in the existing homeops cluster.

### Concrete Deliverables
1. Go API binary with endpoints: accounts CRUD, email aliases CRUD, group memberships CRUD
2. Vanilla HTML/JS/CSS SPA zip artifact
3. GitHub Actions CI workflow (build Go → Harbor, build SPA zip → GitHub release)
4. Homeops Kubernetes manifests: sidecar container in Stalwart HelmRelease, Stalwart Applications config

### Definition of Done
- [ ] `curl -H "Authorization: Bearer <admin-token>" http://localhost:3000/accounts` returns JSON array
- [ ] Creating an account stores `{SSHA512}` hashed password in `directory.accounts`
- [ ] SPA loads at Stalwart's configured `urlPrefix` and can list/create/delete accounts
- [ ] Sidecar container runs alongside Stalwart without disrupting mail service
- [ ] All Go tests pass (`go test ./...`)

### Must Have
- CRUD for accounts (create with SSHA512, list, get, enable/disable, delete)
- CRUD for email aliases (list, add, remove per account)
- CRUD for group memberships (list, add, remove per account)
- JMAP token validation (admin-only access)
- Health endpoint (`/healthz`)
- TDD with Go tests
- CI pipeline building and pushing to Harbor + GitHub releases

### Must NOT Have (Guardrails)
- No email sending/receiving functionality — directory management only
- No custom auth system — JMAP token forwarding only
- No ORM — `database/sql` + `lib/pq` directly
- No frontend build system — vanilla HTML/JS/CSS, no bundler/transpiler
- No WebSocket, real-time updates, or polling in the SPA
- No password policy enforcement — accept any non-empty password
- No audit logging in v1
- No bulk/batch operations (no CSV import)
- No pagination/filtering/search in list endpoints in v1
- No management of Stalwart config, domains, TLS, mail queues, or any tables beyond `directory.*`
- No user roles/RBAC beyond "admin or not"
- No multi-arch Docker builds unless explicitly needed
- `AUTH_BYPASS` must NEVER be set in production Kubernetes manifests (ExternalSecret, HelmRelease) — it is for local development/testing only

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (new repo)
- **Automated tests**: TDD (tests first)
- **Framework**: Go standard `testing` package
- **TDD flow**: Each API task follows RED (failing test) → GREEN (minimal impl) → REFACTOR

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **API endpoints**: Use Bash (`curl`) — send requests, assert status + response fields
- **Go tests**: Use Bash (`go test ./...`) — run tests, assert pass
- **SPA**: Use Playwright — navigate, interact, assert DOM, screenshot
- **Kubernetes**: Use Bash (`kubectl`) — verify pod status, logs, service endpoints

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Foundation — repo scaffolding + types + DB):
├── Task 1: Go project scaffolding + CI skeleton [quick]
├── Task 2: Database layer + connection + health [deep]
└── Task 3: SSHA512 hashing module [quick]

Wave 2 (Core API — all CRUD endpoints, MAX PARALLEL):
├── Task 4: Accounts CRUD endpoints (depends: 2, 3) [deep]
├── Task 5: Email aliases CRUD endpoints (depends: 2) [deep]
├── Task 6: Group memberships CRUD endpoints (depends: 2) [deep]
└── Task 7: JMAP auth middleware (depends: 1) [unspecified-high]

Wave 3 (SPA + Integration):
├── Task 8: SPA — accounts management UI (depends: 4) [visual-engineering]
├── Task 9: SPA — aliases + groups UI (depends: 5, 6) [visual-engineering]
├── Task 10: Dockerfile + CI pipeline finalization (depends: 4, 5, 6, 7) [quick]
└── Task 11: SPA zip packaging + release workflow (depends: 8, 9) [quick]

Wave 4 (Homeops integration):
├── Task 12: Stalwart HelmRelease sidecar + ExternalSecret + HTTPRoute (depends: 10) [unspecified-high]
├── Task 13: Documentation for manual Stalwart Application registration (depends: 11, 12) [writing] (non-blocking)
└── (Task 12 blocks F1-F4; Task 13 is post-deployment docs, does not block verification)

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| 1 | - | 2, 3, 7 | 1 |
| 2 | 1 | 4, 5, 6 | 1 |
| 3 | 1 | 4 | 1 |
| 4 | 2, 3 | 8, 10 | 2 |
| 5 | 2 | 9, 10 | 2 |
| 6 | 2 | 9, 10 | 2 |
| 7 | 1 | 10 | 2 |
| 8 | 4 | 11 | 3 |
| 9 | 5, 6 | 11 | 3 |
| 10 | 4, 5, 6, 7 | 12 | 3 |
| 11 | 8, 9 | 13 | 3 |
| 12 | 10 | F1-F4 | 4 |
| 13 | 11, 12 | - (post-deploy docs) | 4 |

### Agent Dispatch Summary

- **Wave 1**: 3 tasks — T1 → `quick`, T2 → `deep`, T3 → `quick`
- **Wave 2**: 4 tasks — T4 → `deep`, T5 → `deep`, T6 → `deep`, T7 → `unspecified-high`
- **Wave 3**: 4 tasks — T8 → `visual-engineering`, T9 → `visual-engineering`, T10 → `quick`, T11 → `quick`
- **Wave 4**: 2 tasks — T12 → `unspecified-high`, T13 → `quick`
- **FINAL**: 4 tasks — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [x] 1. Go Project Scaffolding + CI Skeleton

  **What to do**:
  - Create new GitHub repository `operinko-labs/stalwart-users` (or confirm name with user)
  - Initialize Go module: `go mod init github.com/operinko-labs/stalwart-users`
  - Create project structure:
    ```
    ├── cmd/server/main.go        # Entry point, wire up router + DB + config
    ├── internal/
    │   ├── api/                   # HTTP handlers
    │   ├── auth/                  # JMAP auth middleware + SSHA512 hashing
    │   ├── db/                    # Database connection + queries
    │   └── model/                 # Data types/structs
    ├── ui/                        # SPA static files
    ├── Dockerfile                 # Placeholder
    ├── Makefile                   # Build targets
    ├── .github/workflows/ci.yml   # Skeleton CI
    └── .gitignore
    ```
  - `cmd/server/main.go`: Parse env vars (`DATABASE_URL`, `STALWART_URL`, `ADMIN_USERS`, `PATH_PREFIX`, `PORT`), start HTTP server on `PORT` (default 3000). Support `PATH_PREFIX` env var (default empty) for mounting API routes behind a reverse proxy prefix (e.g., `/manage/api`). Implementation: register `/healthz` directly on the root mux (always available at pod-local `/healthz` for probes). Then create an API subrouter with all `/accounts` routes and mount it under the prefix: `mux.Handle(pathPrefix+"/", http.StripPrefix(pathPrefix, apiRouter))`. When `PATH_PREFIX` is empty (local dev), API routes are at `/accounts`; when set to `/manage/api`, they're at `/manage/api/accounts`. Health probes always hit `/healthz` regardless of prefix.
  - Support `SERVE_UI` env var (default empty): when set to a directory path (e.g., `SERVE_UI=./ui`), serve static files from that directory at the root path `/`. The Go server registers the file server handler at `/` with lowest priority — API routes (`/accounts`, `/healthz`) take precedence via Go 1.22+ ServeMux pattern matching. This enables same-origin local development: the SPA loads from `http://localhost:3000/` and calls API endpoints at `/accounts`. In production, the SPA is served by Stalwart Applications (which rewrites `<base href>`), so `SERVE_UI` is not set.
  - Use Go standard library `net/http` for routing (no external router framework)
  - Add `.gitignore` for Go binaries
  - Skeleton CI workflow: checkout, `go build ./...`, `go test ./...`

  **Must NOT do**:
  - Do not add any external HTTP router framework (chi, gorilla, gin, etc.) — use `net/http` ServeMux
  - Do not add ORM packages
  - Do not add frontend build tooling

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Scaffolding is straightforward file creation
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (foundation task)
  - **Parallel Group**: Wave 1
  - **Blocks**: Tasks 2, 3, 7
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `kubernetes/apps/tools/n8n/app/helmrelease.yaml:109-150` — Sidecar container pattern (tempest-mcp) showing image, env, probes, securityContext, resources structure. Use this to understand what the final container config will look like so you design env vars accordingly.

  **External References**:
  - Go standard library `net/http` ServeMux: https://pkg.go.dev/net/http#ServeMux — use `http.NewServeMux()` for routing

  **WHY Each Reference Matters**:
  - The n8n sidecar pattern shows which env vars are injected via `envFrom: secretRef` — design your env var names to match what will be in the Kubernetes secret

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Go project builds successfully
    Tool: Bash
    Preconditions: Go installed, repo cloned
    Steps:
      1. Run `go build ./cmd/server/`
      2. Verify binary is created
      3. Run `./server --help` or just start and verify it exits cleanly when no DB is configured
    Expected Result: Binary compiles without errors
    Failure Indicators: Compilation errors, missing imports
    Evidence: .sisyphus/evidence/task-1-go-build.txt

  Scenario: CI workflow syntax is valid
    Tool: Bash
    Preconditions: .github/workflows/ci.yml exists
    Steps:
      1. Validate YAML syntax with `yq '.' .github/workflows/ci.yml`
      2. Check that `go build` and `go test` steps are present
    Expected Result: Valid YAML with build + test steps
    Failure Indicators: YAML parse errors, missing required fields
    Evidence: .sisyphus/evidence/task-1-ci-syntax.txt
  ```

  **Commit**: YES
  - Message: `feat(api): scaffold Go project with module and CI skeleton`
  - Files: `go.mod, cmd/server/main.go, internal/*, Makefile, .github/workflows/ci.yml, .gitignore`
  - Pre-commit: `go build ./...`

- [x] 2. Database Layer + Connection + Health Check

  **What to do**:
  - **RED**: Write tests first in `internal/db/db_test.go`:
    - Test `NewPool()` returns error on invalid connection string
    - Test `HealthCheck()` returns nil on valid connection (use test DB or mock)
    - Test `Close()` shuts down pool
  - **GREEN**: Implement `internal/db/db.go`:
    - `NewPool(databaseURL string) (*Pool, error)` — create `sql.DB` with `lib/pq` driver, set max connections (10), connection timeout
    - `Pool.HealthCheck() error` — `db.PingContext(ctx)`
    - `Pool.Close() error`
  - Add `GET /healthz` handler in `internal/api/health.go` — calls `pool.HealthCheck()`, returns `{"status":"ok"}` (200) or `{"status":"error","message":"..."}` (503)
  - Wire health endpoint in `cmd/server/main.go`
  - Add `lib/pq` dependency: `go get github.com/lib/pq`

  **Must NOT do**:
  - Do not add ORM (no GORM, no sqlx, no ent) — `database/sql` + `lib/pq` only
  - Do not add connection retry/backoff logic — simple fail-fast

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: TDD cycle requires careful test-first thinking and DB abstraction design
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 3 after Task 1 completes)
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Tasks 4, 5, 6
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `kubernetes/apps/mail/stalwart/app/external-secret.yaml` — DB connection string format: `postgresql://stalwart:<password>@postgres18-rw.database.svc.cluster.local:5432/stalwart`. The Go API should accept `DATABASE_URL` env var in this format.
  - `kubernetes/apps/mail/stalwart/app/configmap.yaml` — Full SQL directory schema (accounts, emails, group_members tables with exact column types)

  **External References**:
  - `lib/pq` driver: https://pkg.go.dev/github.com/lib/pq — PostgreSQL driver for `database/sql`

  **WHY Each Reference Matters**:
  - The ExternalSecret shows the exact connection string format the sidecar will receive as `DATABASE_URL`
  - The configmap shows the exact table schemas the DB layer will query against

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/db/db_test.go`
  - [ ] `go test ./internal/db/...` → PASS

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Health endpoint returns ok with valid DB
    Tool: Bash (curl)
    Preconditions: Server running with valid DATABASE_URL
    Steps:
      1. Start server: `DATABASE_URL=<test-db-url> go run ./cmd/server/ &`
      2. Wait 2s for startup
      3. Run `curl -s http://localhost:3000/healthz`
      4. Assert response contains `"status":"ok"`
      5. Assert HTTP status is 200
    Expected Result: `{"status":"ok"}` with 200
    Failure Indicators: 503 status, connection error message, server crash
    Evidence: .sisyphus/evidence/task-2-health-ok.txt

  Scenario: Health endpoint returns error with no DB
    Tool: Bash (curl)
    Preconditions: Server running with invalid DATABASE_URL
    Steps:
      1. Start server: `DATABASE_URL=postgresql://bad:bad@localhost:5432/bad go run ./cmd/server/ &`
      2. Wait 2s
      3. Run `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/healthz`
      4. Assert HTTP status is 503
    Expected Result: 503 status
    Failure Indicators: 200 status, server crash on startup
    Evidence: .sisyphus/evidence/task-2-health-error.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add database layer with connection pool and health check`
  - Files: `internal/db/db.go, internal/db/db_test.go, internal/api/health.go, go.sum`
  - Pre-commit: `go test ./...`

- [x] 3. SSHA512 Password Hashing Module

  **What to do**:
  - **RED**: Write tests first in `internal/auth/hash_test.go`:
    - Test `HashPassword("testpassword")` returns string starting with `{SSHA512}`
    - Test `VerifyPassword("testpassword", hashedValue)` returns true
    - Test `VerifyPassword("wrongpassword", hashedValue)` returns false
    - Test `HashPassword("")` returns error (empty password rejected)
    - Test that two calls to `HashPassword` with same input produce different hashes (random salt)
  - **GREEN**: Implement `internal/auth/hash.go`:
    - `HashPassword(password string) (string, error)` — generate 16-byte random salt, compute SHA512(password+salt), return `{SSHA512}` + base64(hash+salt)
    - `VerifyPassword(password, hash string) bool` — decode, extract salt (bytes after first 64), recompute, compare
  - Use `crypto/sha512`, `crypto/rand`, `encoding/base64` from Go stdlib only

  **Must NOT do**:
  - Do not use external hashing libraries (no bcrypt, no argon2 — Stalwart expects SSHA512)
  - Do not implement password policy validation (accept any non-empty string)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Small, self-contained crypto module with clear spec
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 2 after Task 1 completes)
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: Task 4
  - **Blocked By**: Task 1

  **References**:

  **External References**:
  - Stalwart SSHA512 verification source code: `crates/directory/src/core/secret.rs` — Base64 decode, first 64 bytes = hash, remaining = salt, verify SHA512(input+salt) == stored hash. This is the authoritative reference for hash format compatibility.

  **WHY Each Reference Matters**:
  - The Stalwart source code defines the exact format — our Go implementation must produce hashes that Stalwart can verify (users log in via Stalwart, not our API)

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/auth/hash_test.go`
  - [ ] `go test ./internal/auth/...` → PASS (5+ tests, 0 failures)

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Hash produces Stalwart-compatible format
    Tool: Bash
    Preconditions: Go module built
    Steps:
      1. Run test: `go test -v -run TestHashPassword ./internal/auth/`
      2. Verify output shows hash starts with `{SSHA512}`
      3. Run test: `go test -v -run TestVerifyPassword ./internal/auth/`
      4. Verify round-trip verification passes
    Expected Result: All tests PASS, hash format matches `{SSHA512}<base64>`
    Failure Indicators: Test failures, hash format mismatch
    Evidence: .sisyphus/evidence/task-3-hash-tests.txt

  Scenario: Empty password is rejected
    Tool: Bash
    Preconditions: Go module built
    Steps:
      1. Run test: `go test -v -run TestEmptyPassword ./internal/auth/`
      2. Verify test asserts error is returned
    Expected Result: Error returned for empty password
    Failure Indicators: No error returned, hash created for empty string
    Evidence: .sisyphus/evidence/task-3-empty-password.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add SSHA512 password hashing module`
  - Files: `internal/auth/hash.go, internal/auth/hash_test.go`
  - Pre-commit: `go test ./...`

- [x] 4. Accounts CRUD Endpoints with TDD

  **What to do**:
  - **RED**: Write tests first in `internal/api/accounts_test.go`:
    - Test `GET /accounts` returns JSON array of accounts (mock DB)
    - Test `GET /accounts/{name}` returns single account
    - Test `POST /accounts` with `{"name","password","description","type","quota"}` creates account, returns 201
    - Test `POST /accounts` with duplicate name returns 409
    - Test `POST /accounts` with empty password returns 400
    - Test `PATCH /accounts/{name}` with `{"active": false}` disables account, returns 200
    - Test `DELETE /accounts/{name}` removes account + cascades emails + group_members, returns 204
    - Test `DELETE /accounts/{nonexistent}` returns 404
  - **GREEN**: Implement `internal/api/accounts.go`:
    - `GET /accounts` — `SELECT name, description, type, quota, active FROM directory.accounts ORDER BY name`
    - `GET /accounts/{name}` — single account by name (never return `secret` field)
    - `POST /accounts` — insert into `directory.accounts` with SSHA512-hashed password; also insert primary email into `directory.emails` (if name contains `@`, use that as primary email address)
    - `PATCH /accounts/{name}` — update description, quota, active fields (partial update)
    - `DELETE /accounts/{name}` — within a transaction: delete from `directory.group_members WHERE name = $1 OR member_of = $1`, delete from `directory.emails WHERE name = $1`, delete from `directory.accounts WHERE name = $1`
  - Implement DB query functions in `internal/db/accounts.go`
  - Define `model.Account` struct in `internal/model/account.go`
  - **NEVER** return the `secret` column in any GET response

  **Must NOT do**:
  - Do not return password hashes in any API response
  - Do not add pagination, filtering, or sorting
  - Do not add bulk create/delete

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: TDD with DB queries, transaction handling, multiple edge cases
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 5, 6, 7)
  - **Parallel Group**: Wave 2
  - **Blocks**: Tasks 8, 10
  - **Blocked By**: Tasks 2, 3

  **References**:

  **Pattern References**:
  - `kubernetes/apps/mail/stalwart/app/configmap.yaml` — SQL directory schema: exact column names and types for `directory.accounts` table (name TEXT PK, secret TEXT, description TEXT, type TEXT DEFAULT 'individual', quota INTEGER DEFAULT 0, active BOOLEAN DEFAULT true)
  - `internal/db/db.go` (from Task 2) — DB pool interface to use for queries
  - `internal/auth/hash.go` (from Task 3) — `HashPassword()` function to call when creating accounts

  **WHY Each Reference Matters**:
  - The configmap schema is the ground truth for column names and defaults — queries must match exactly
  - The DB pool and hash modules are direct dependencies imported by this task

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/api/accounts_test.go`
  - [ ] `go test ./internal/api/...` → PASS (8+ tests, 0 failures)

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Create and list accounts
    Tool: Bash (curl)
    Preconditions: Server running with valid DATABASE_URL and AUTH_BYPASS=true (test mode, no Stalwart needed)
    Steps:
      1. Start server: `DATABASE_URL=<test-db-url> AUTH_BYPASS=true go run ./cmd/server/ &`
      2. Wait 2s for startup
      3. POST `curl -s -X POST -H "Content-Type: application/json" -d '{"name":"testuser@vaderrp.com","password":"Secret123","description":"Test User","type":"individual"}' http://localhost:3000/accounts`
      4. Assert HTTP 201
      5. GET `curl -s http://localhost:3000/accounts`
      6. Assert response is JSON array containing `testuser@vaderrp.com`
      7. Assert no `secret` field in response objects
    Expected Result: Account created with 201, listed without password hash
    Failure Indicators: 500 error, secret field present in response, duplicate entry
    Evidence: .sisyphus/evidence/task-4-create-list.txt

  Scenario: Delete account cascades to emails and groups
    Tool: Bash (curl + psql)
    Preconditions: Server running with AUTH_BYPASS=true, account `testuser@vaderrp.com` exists with aliases and group memberships
    Steps:
      1. DELETE `curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:3000/accounts/testuser@vaderrp.com`
      2. Assert HTTP 204
      3. GET `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/accounts/testuser@vaderrp.com`
      4. Assert HTTP 404
      5. Verify cascade in DB: `psql "$DATABASE_URL" -c "SELECT count(*) FROM directory.emails WHERE name='testuser@vaderrp.com'"` → 0
      6. Verify cascade in DB: `psql "$DATABASE_URL" -c "SELECT count(*) FROM directory.group_members WHERE name='testuser@vaderrp.com'"` → 0
    Expected Result: Account and all related rows deleted
    Failure Indicators: Orphaned email/group rows, 500 error, partial deletion
    Evidence: .sisyphus/evidence/task-4-delete-cascade.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add accounts CRUD endpoints with TDD`
  - Files: `internal/api/accounts.go, internal/api/accounts_test.go, internal/db/accounts.go, internal/model/account.go`
  - Pre-commit: `go test ./...`

- [x] 5. Email Aliases CRUD Endpoints with TDD

  **What to do**:
  - **RED**: Write tests first in `internal/api/aliases_test.go`:
    - Test `GET /accounts/{name}/emails` returns all emails for account
    - Test `POST /accounts/{name}/emails` with `{"address":"alias@vaderrp.com","type":"alias"}` creates alias, returns 201
    - Test `POST /accounts/{name}/emails` with duplicate address returns 409
    - Test `DELETE /accounts/{name}/emails/{address}` removes alias, returns 204
    - Test `DELETE /accounts/{name}/emails/{primary-address}` where type is `primary` returns 400 (cannot delete primary email)
    - Test operations on non-existent account return 404
  - **GREEN**: Implement `internal/api/aliases.go`:
    - `GET /accounts/{name}/emails` — `SELECT address, type FROM directory.emails WHERE name = $1 ORDER BY type DESC, address`
    - `POST /accounts/{name}/emails` — insert into `directory.emails`, verify account exists first
    - `DELETE /accounts/{name}/emails/{address}` — check type is not `primary` before deleting
  - Implement DB query functions in `internal/db/emails.go`
  - Define `model.Email` struct in `internal/model/email.go`

  **Must NOT do**:
  - Do not allow deleting primary email (only via account deletion)
  - Do not validate email format beyond basic non-empty check
  - Do not add MX record lookups

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: TDD with relational constraints (foreign key to accounts, primary protection)
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4, 6, 7)
  - **Parallel Group**: Wave 2
  - **Blocks**: Tasks 9, 10
  - **Blocked By**: Task 2

  **References**:

  **Pattern References**:
  - `kubernetes/apps/mail/stalwart/app/configmap.yaml` — SQL schema for `directory.emails` table (name TEXT NOT NULL, address TEXT NOT NULL, type TEXT DEFAULT 'primary', PK: name+address)
  - `internal/db/db.go` (from Task 2) — DB pool interface
  - `internal/api/accounts.go` (from Task 4) — Follow same handler structure and patterns

  **WHY Each Reference Matters**:
  - The emails table has a composite PK (name, address) — queries must use both columns for operations
  - Following the accounts handler pattern ensures consistent API style

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/api/aliases_test.go`
  - [ ] `go test ./internal/api/...` → PASS (6+ tests, 0 failures)

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Add and list email aliases
    Tool: Bash (curl)
    Preconditions: Server running with AUTH_BYPASS=true, account `testuser@vaderrp.com` exists
    Steps:
      1. POST `curl -s -X POST -H "Content-Type: application/json" -d '{"address":"alias@vaderrp.com","type":"alias"}' http://localhost:3000/accounts/testuser@vaderrp.com/emails`
      2. Assert HTTP 201
      3. GET `curl -s http://localhost:3000/accounts/testuser@vaderrp.com/emails`
      4. Assert response includes both primary and alias addresses
    Expected Result: Alias added, both primary and alias listed
    Failure Indicators: 500 error, duplicate key violation, missing primary
    Evidence: .sisyphus/evidence/task-5-add-list-alias.txt

  Scenario: Cannot delete primary email
    Tool: Bash (curl)
    Preconditions: Server running with AUTH_BYPASS=true, account exists with primary email
    Steps:
      1. DELETE `curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:3000/accounts/testuser@vaderrp.com/emails/testuser@vaderrp.com`
      2. Assert HTTP 400
    Expected Result: 400 Bad Request — primary email cannot be deleted
    Failure Indicators: 204 (deletion succeeded), 500 error
    Evidence: .sisyphus/evidence/task-5-primary-protection.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add email aliases CRUD endpoints with TDD`
  - Files: `internal/api/aliases.go, internal/api/aliases_test.go, internal/db/emails.go, internal/model/email.go`
  - Pre-commit: `go test ./...`

- [x] 6. Group Memberships CRUD Endpoints with TDD

  **What to do**:
  - **RED**: Write tests first in `internal/api/groups_test.go`:
    - Test `GET /accounts/{name}/groups` returns groups the account belongs to
    - Test `POST /accounts/{name}/groups` with `{"member_of":"admin-group"}` adds membership, returns 201
    - Test `POST /accounts/{name}/groups` with duplicate returns 409
    - Test `DELETE /accounts/{name}/groups/{group}` removes membership, returns 204
    - Test operations on non-existent account return 404
  - **GREEN**: Implement `internal/api/groups.go`:
    - `GET /accounts/{name}/groups` — `SELECT member_of FROM directory.group_members WHERE name = $1 ORDER BY member_of`
    - `POST /accounts/{name}/groups` — insert into `directory.group_members`, verify account exists first
    - `DELETE /accounts/{name}/groups/{group}` — delete from `directory.group_members WHERE name = $1 AND member_of = $2`
  - Implement DB query functions in `internal/db/groups.go`

  **Must NOT do**:
  - Do not add group creation/management (groups are just accounts with `type='group'`)
  - Do not add recursive group membership resolution

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: TDD with relational constraints
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4, 5, 7)
  - **Parallel Group**: Wave 2
  - **Blocks**: Tasks 9, 10
  - **Blocked By**: Task 2

  **References**:

  **Pattern References**:
  - `kubernetes/apps/mail/stalwart/app/configmap.yaml` — SQL schema for `directory.group_members` table (name TEXT NOT NULL, member_of TEXT NOT NULL, PK: name+member_of)
  - `internal/api/aliases.go` (from Task 5) — Follow same sub-resource handler pattern (nested under accounts)

  **WHY Each Reference Matters**:
  - Same composite PK pattern as emails table — follow same query approach

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/api/groups_test.go`
  - [ ] `go test ./internal/api/...` → PASS (5+ tests, 0 failures)

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Add and list group memberships
    Tool: Bash (curl)
    Preconditions: Server running with AUTH_BYPASS=true, account `testuser@vaderrp.com` exists, group account `admins` exists with type='group'
    Steps:
      1. POST `curl -s -X POST -H "Content-Type: application/json" -d '{"member_of":"admins"}' http://localhost:3000/accounts/testuser@vaderrp.com/groups`
      2. Assert HTTP 201
      3. GET `curl -s http://localhost:3000/accounts/testuser@vaderrp.com/groups`
      4. Assert response includes `admins`
    Expected Result: Group membership created and listed
    Failure Indicators: 500 error, missing membership
    Evidence: .sisyphus/evidence/task-6-add-list-group.txt

  Scenario: Remove group membership
    Tool: Bash (curl)
    Preconditions: Server running with AUTH_BYPASS=true, testuser is member of admins group
    Steps:
      1. DELETE `curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:3000/accounts/testuser@vaderrp.com/groups/admins`
      2. Assert HTTP 204
      3. GET `curl -s http://localhost:3000/accounts/testuser@vaderrp.com/groups`
      4. Assert `admins` is no longer listed
    Expected Result: Membership removed
    Failure Indicators: 500 error, membership still present
    Evidence: .sisyphus/evidence/task-6-remove-group.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add group memberships CRUD endpoints with TDD`
  - Files: `internal/api/groups.go, internal/api/groups_test.go, internal/db/groups.go`
  - Pre-commit: `go test ./...`

- [x] 7. JMAP Auth Middleware

  **What to do**:
  - **RED**: Write tests first in `internal/auth/jmap_test.go`:
    - Test middleware with no `Authorization` header returns 401
    - Test middleware with invalid token (mock Stalwart returning 401) returns 401
    - Test middleware with valid token but non-admin user returns 403
    - Test middleware with valid admin token passes through to handler
    - Use `httptest` to mock Stalwart's `/jmap/session` endpoint
  - **GREEN**: Implement `internal/auth/jmap.go`:
    - `JMAPAuthMiddleware(stalwartURL string, adminUsers []string) func(http.Handler) http.Handler`
    - Extract `Bearer <token>` from `Authorization` header
    - Forward token to `stalwartURL + "/jmap/session"` via HTTP GET
    - If Stalwart returns 401 → return 401 to client
    - Parse Stalwart's JSON response to extract username
    - Check if username is in `adminUsers` list → if not, return 403
    - If authorized, add username to request context and call next handler
  - `ADMIN_USERS` env var: comma-separated list of usernames allowed to use the management API
  - Skip auth for `GET /healthz` endpoint
  - Support `AUTH_BYPASS=true` env var for development/testing: when set, skip JMAP token validation entirely and treat all requests as admin. This is **never** set in production (not in ExternalSecret or HelmRelease env). QA scenarios use this to test endpoints without requiring a running Stalwart instance.

  **Must NOT do**:
  - Do not cache tokens (let Stalwart handle token lifecycle)
  - Do not implement custom token generation
  - Do not add role-based access beyond admin/non-admin check

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Auth middleware with external service integration, mocking in tests
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 4, 5, 6)
  - **Parallel Group**: Wave 2
  - **Blocks**: Task 10
  - **Blocked By**: Task 1

  **References**:

  **External References**:
  - Stalwart JMAP session endpoint: `GET /jmap/session` with `Authorization: Bearer <token>` returns JSON with `username`, `accounts`, `capabilities` on success (200) or 401 on failure. This is the endpoint the middleware validates tokens against.
  - Go `net/http/httptest` package: https://pkg.go.dev/net/http/httptest — for mocking Stalwart's endpoint in tests

  **WHY Each Reference Matters**:
  - The JMAP session response structure determines how we extract the username for admin check
  - httptest is essential for testing the middleware without a real Stalwart instance

  **Acceptance Criteria**:

  **If TDD:**
  - [ ] Test file created: `internal/auth/jmap_test.go`
  - [ ] `go test ./internal/auth/...` → PASS (4+ tests, 0 failures)

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Unauthenticated request rejected (no AUTH_BYPASS)
    Tool: Bash (curl)
    Preconditions: Server running WITHOUT AUTH_BYPASS (default), STALWART_URL pointing to mock or real Stalwart
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/accounts`
      2. Assert HTTP 401
    Expected Result: 401 Unauthorized
    Failure Indicators: 200 (auth bypassed), 500 error
    Evidence: .sisyphus/evidence/task-7-no-auth.txt

  Scenario: Health endpoint bypasses auth
    Tool: Bash (curl)
    Preconditions: Server running without AUTH_BYPASS
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/healthz`
      2. Assert HTTP 200 (no Authorization header needed)
    Expected Result: 200 OK without auth
    Failure Indicators: 401 on health endpoint
    Evidence: .sisyphus/evidence/task-7-health-no-auth.txt

  Scenario: AUTH_BYPASS=true skips validation
    Tool: Bash (curl)
    Preconditions: Server running with AUTH_BYPASS=true, valid DATABASE_URL
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/accounts`
      2. Assert HTTP 200 (no Authorization header, bypass active)
    Expected Result: 200 OK — auth bypassed for development/testing
    Failure Indicators: 401 (bypass not working)
    Evidence: .sisyphus/evidence/task-7-auth-bypass.txt
  ```

  **Commit**: YES
  - Message: `feat(api): add JMAP token auth middleware`
  - Files: `internal/auth/jmap.go, internal/auth/jmap_test.go`
  - Pre-commit: `go test ./...`

- [x] 8. SPA — Accounts Management UI

  **What to do**:
  - Create `ui/index.html` — single-page app shell with:
    - Login form: text input for Bearer token (stored in `localStorage`)
    - Accounts table: name, description, type, quota, active (status badge)
    - Create account form: name, password, description, type (dropdown: individual/group), quota
    - Enable/disable toggle button per account
    - Delete button per account (with confirmation dialog)
    - Navigation tabs/sections for Accounts, Aliases, Groups (Aliases and Groups populated in Task 9)
  - Create `ui/style.css` — clean, minimal admin UI:
    - Use CSS custom properties for theming (dark/light auto via prefers-color-scheme)
    - Table styling, form styling, status badges, buttons
    - Responsive layout (works on desktop and tablet)
  - Create `ui/app.js` — vanilla JavaScript:
    - `fetchAPI(path, options)` — wrapper that adds `Authorization: Bearer` header from localStorage. API base URL: configurable via a global variable (e.g., `window.API_BASE`). In production (Stalwart Applications at `/manage/users/`), set to `../api` which resolves to `/manage/api/`. In dev mode (SERVE_UI serves SPA at `/`), set to empty string `""` (same origin, root-relative). Auto-detect: if `window.location.pathname` starts with `/manage/users`, use `../api`; otherwise use `""` (dev mode). All SPA functions MUST use `fetchAPI` — no hardcoded paths.
    - `loadAccounts()` → GET `{API_BASE}/accounts` → render table
    - `createAccount(formData)` → POST `{API_BASE}/accounts`
    - `toggleAccount(name, active)` → PATCH `{API_BASE}/accounts/{name}`
    - `deleteAccount(name)` → DELETE `{API_BASE}/accounts/{name}`
    - Error handling: show error messages inline (toast or banner)
    - API base URL: auto-detected from `window.location` as described above

  **Must NOT do**:
  - Do not use any JavaScript framework (React, Vue, Svelte, etc.)
  - Do not use any CSS framework (Tailwind, Bootstrap, etc.)
  - Do not add bundler/transpiler (webpack, vite, esbuild, etc.)
  - Do not add WebSocket or polling
  - No inline styles — all CSS in `style.css`

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: Frontend UI work requiring clean design and UX
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 9)
  - **Parallel Group**: Wave 3
  - **Blocks**: Task 11
  - **Blocked By**: Task 4

  **References**:

  **Pattern References**:
  - `internal/api/accounts.go` (from Task 4) — API endpoint paths and request/response formats the SPA must call

  **External References**:
  - Stalwart Applications: zip must have `index.html` at root with `<base href="/">` tag. Stalwart rewrites the href to match the configured `urlPrefix`. All asset paths in HTML must be relative.

  **WHY Each Reference Matters**:
  - The API contract from Task 4 determines all fetch URLs and JSON shapes
  - The base href behavior affects how assets are loaded in the SPA

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: SPA loads and displays accounts table
    Tool: Playwright
    Preconditions: Server running with AUTH_BYPASS=true, SERVE_UI=./ui, valid DATABASE_URL, and test data (at least 2 accounts)
    Steps:
      1. Start server: `DATABASE_URL=<url> AUTH_BYPASS=true SERVE_UI=./ui go run ./cmd/server/ &`
      2. Navigate to `http://localhost:3000/`
      3. Wait for table to populate (selector: `table` or `.accounts-table`)
      4. Assert table has at least 2 rows
      5. Assert columns include: Name, Description, Type, Active
      6. Take screenshot
    Expected Result: Table renders with account data, no console errors, no CORS errors (same origin)
    Failure Indicators: Empty table, JavaScript errors, CORS errors
    Evidence: .sisyphus/evidence/task-8-spa-accounts.png

  Scenario: Create account via SPA form
    Tool: Playwright
    Preconditions: Server running with AUTH_BYPASS=true and SERVE_UI=./ui
    Steps:
      1. Navigate to `http://localhost:3000/`
      2. Click "Create Account" button (selector: `button.create-account` or `#create-account`)
      3. Fill name field: `newuser@vaderrp.com`
      4. Fill password field: `TestPass123`
      5. Fill description field: `New Test User`
      6. Select type: `individual`
      7. Click submit
      8. Wait for table to refresh
      9. Assert new row with `newuser@vaderrp.com` appears
    Expected Result: Account created, table updated
    Failure Indicators: Form validation error, API error, table not refreshed
    Evidence: .sisyphus/evidence/task-8-spa-create.png
  ```

  **Commit**: YES
  - Message: `feat(ui): add accounts management SPA page`
  - Files: `ui/index.html, ui/app.js, ui/style.css`
  - Pre-commit: N/A

- [x] 9. SPA — Aliases + Groups Management UI

  **What to do**:
  - Extend `ui/app.js` with aliases and groups functionality:
    - When clicking an account row (or expand button), show detail panel with:
      - **Emails section**: List of email addresses (primary badge, alias badges). Add alias form (address input). Delete button per alias (not on primary).
      - **Groups section**: List of group memberships. Add to group form (group name input). Remove button per membership.
    - `loadEmails(name)` → GET `{API_BASE}/accounts/{name}/emails`
    - `addAlias(name, address)` → POST `{API_BASE}/accounts/{name}/emails`
    - `removeAlias(name, address)` → DELETE `{API_BASE}/accounts/{name}/emails/{address}`
    - `loadGroups(name)` → GET `{API_BASE}/accounts/{name}/groups`
    - `addGroup(name, group)` → POST `{API_BASE}/accounts/{name}/groups`
    - `removeGroup(name, group)` → DELETE `{API_BASE}/accounts/{name}/groups/{group}`
  - Update `ui/style.css` with styles for detail panel, badges, sub-tables

  **Must NOT do**:
  - Do not use JavaScript frameworks
  - Do not allow deleting primary email in UI (disable/hide delete button for primary)

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: Frontend UI extension with detail panel UX
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 8 in late Wave 3 — depends on different API endpoints)
  - **Parallel Group**: Wave 3
  - **Blocks**: Task 11
  - **Blocked By**: Tasks 5, 6

  **References**:

  **Pattern References**:
  - `ui/app.js` (from Task 8) — Existing `fetchAPI()` wrapper and table rendering pattern
  - `internal/api/aliases.go` (from Task 5) — API endpoint paths and response format for emails
  - `internal/api/groups.go` (from Task 6) — API endpoint paths and response format for groups

  **WHY Each Reference Matters**:
  - Must follow same fetch pattern and error handling from Task 8
  - API contracts define exactly what the UI calls and what it receives

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: View and add email alias via SPA
    Tool: Playwright
    Preconditions: Server running with AUTH_BYPASS=true and SERVE_UI=./ui, account `testuser@vaderrp.com` exists
    Steps:
      1. Navigate to `http://localhost:3000/`
      2. Click on `testuser@vaderrp.com` row to expand detail panel
      3. Assert emails section shows primary email with "primary" badge
      4. Type `alias@vaderrp.com` in add-alias input
      5. Click "Add Alias" button
      6. Assert new alias appears in list with "alias" badge
      7. Assert primary email's delete button is disabled/hidden
    Expected Result: Alias added, primary email protected
    Failure Indicators: Alias not appearing, primary deletable, JS errors
    Evidence: .sisyphus/evidence/task-9-spa-alias.png

  Scenario: View and manage group membership via SPA
    Tool: Playwright
    Preconditions: Same server setup, group account `admins` exists
    Steps:
      1. Expand account detail panel
      2. Navigate to groups section
      3. Type `admins` in add-group input
      4. Click "Add to Group"
      5. Assert `admins` appears in group list
      6. Click remove button on `admins`
      7. Assert `admins` is removed from list
    Expected Result: Group membership added and removed
    Failure Indicators: Group not appearing, removal failing
    Evidence: .sisyphus/evidence/task-9-spa-groups.png
  ```

  **Commit**: YES
  - Message: `feat(ui): add aliases and groups management UI`
  - Files: `ui/app.js, ui/style.css`
  - Pre-commit: N/A

- [x] 10. Dockerfile + CI Pipeline Finalization

  **What to do**:
  - Create `Dockerfile`:
    - Multi-stage build: `golang:1.24-alpine` build stage → `gcr.io/distroless/static-debian12` runtime
    - Build: `CGO_ENABLED=0 GOOS=linux go build -o /server ./cmd/server/`
    - Runtime: copy binary, run as non-root user (UID 65534), expose port 3000
    - `ENTRYPOINT ["/server"]`
  - Finalize `.github/workflows/ci.yml`:
    - Trigger: push to `main`, pull requests
    - Jobs:
      1. `test`: Go test + vet
      2. `build-image`: Build Docker image, push to Harbor (`harbor.vaderrp.com/operinko-labs/stalwart-users:<tag>` — confirm hostname with user)
    - Use org-runner (`runs-on: self-hosted` or appropriate ARC label)
    - Tag strategy: `v*` tags for releases, `main` branch gets `latest`
  - Add `Makefile` targets: `build`, `test`, `docker-build`, `docker-push`

  **Must NOT do**:
  - No multi-arch builds
  - No Docker Compose
  - No Kubernetes manifests in this repo (those are in homeops)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Straightforward Dockerfile and CI config
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (needs all API tasks complete to test full build)
  - **Parallel Group**: Wave 3 (after Wave 2)
  - **Blocks**: Task 12
  - **Blocked By**: Tasks 4, 5, 6, 7

  **References**:

  **External References**:
  - Distroless images: `gcr.io/distroless/static-debian12` — minimal runtime for Go static binaries
  - Harbor registry: Push to `harbor.vaderrp.com/operinko-labs/stalwart-users` (confirm hostname)

  **WHY Each Reference Matters**:
  - Distroless ensures minimal attack surface for the sidecar
  - Harbor hostname must be correct for CI push and Kubernetes image pull

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Docker image builds successfully
    Tool: Bash
    Preconditions: Docker installed, all Go code committed
    Steps:
      1. Run `docker build -t stalwart-users:test .`
      2. Assert exit code 0
      3. Run `docker run --rm stalwart-users:test --help` or check it starts and exits (no DB)
      4. Check image size: `docker images stalwart-users:test --format "{{.Size}}"`
      5. Assert image size < 50MB (distroless + Go static binary)
    Expected Result: Image builds, runs, small footprint
    Failure Indicators: Build failure, large image (>100MB), runtime error
    Evidence: .sisyphus/evidence/task-10-docker-build.txt

  Scenario: CI workflow YAML is valid
    Tool: Bash
    Preconditions: .github/workflows/ci.yml exists
    Steps:
      1. Validate: `yq '.' .github/workflows/ci.yml`
      2. Verify `test` and `build-image` jobs exist
      3. Verify Harbor registry reference is correct
    Expected Result: Valid CI config with both jobs
    Failure Indicators: YAML errors, missing jobs
    Evidence: .sisyphus/evidence/task-10-ci-valid.txt
  ```

  **Commit**: YES
  - Message: `feat(ci): add Dockerfile and finalize CI pipeline`
  - Files: `Dockerfile, .github/workflows/ci.yml, Makefile`
  - Pre-commit: `docker build .`

- [x] 11. SPA Zip Packaging + Release Workflow

  **What to do**:
  - Add GitHub Actions release workflow `.github/workflows/release.yml`:
    - Trigger: push tag `v*`
    - Steps:
      1. Checkout
      2. Create zip from `ui/` directory: `cd ui && zip -r ../stalwart-users-ui.zip .`
      3. Create GitHub release with the zip as an artifact
      4. Also build and push Docker image (tagged with version)
  - Add `Makefile` target: `zip-ui` — creates `stalwart-users-ui.zip` from `ui/` contents
  - Ensure `ui/index.html` is at the root of the zip (not nested in `ui/` subdirectory)

  **Must NOT do**:
  - No minification or bundling
  - No build step for the SPA

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple CI workflow and zip command
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (needs SPA files from Tasks 8, 9)
  - **Parallel Group**: Wave 3 (after Tasks 8, 9)
  - **Blocks**: Task 13
  - **Blocked By**: Tasks 8, 9

  **References**:

  **External References**:
  - Stalwart Applications: The zip must have `index.html` at root level (not nested). Stalwart downloads from `resourceUrl` and unpacks.
  - GitHub Actions `softprops/action-gh-release`: Standard action for creating releases with artifacts.

  **WHY Each Reference Matters**:
  - Zip structure is critical — `index.html` must be at root or Stalwart won't find it

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Zip contains index.html at root
    Tool: Bash
    Preconditions: ui/ directory exists with index.html
    Steps:
      1. Run `make zip-ui` (or equivalent zip command)
      2. Run `unzip -l stalwart-users-ui.zip`
      3. Assert `index.html` is listed at root (not `ui/index.html`)
      4. Assert `app.js` and `style.css` are also at root
    Expected Result: All SPA files at zip root
    Failure Indicators: Files nested under subdirectory
    Evidence: .sisyphus/evidence/task-11-zip-structure.txt

  Scenario: Release workflow YAML is valid
    Tool: Bash
    Preconditions: .github/workflows/release.yml exists
    Steps:
      1. Validate: `yq '.' .github/workflows/release.yml`
      2. Verify trigger is `push tags v*`
      3. Verify zip and release steps exist
    Expected Result: Valid workflow targeting tag pushes
    Failure Indicators: YAML errors, wrong trigger
    Evidence: .sisyphus/evidence/task-11-release-valid.txt
  ```

  **Commit**: YES
  - Message: `feat(ci): add SPA zip packaging and release workflow`
  - Files: `.github/workflows/release.yml, Makefile`
  - Pre-commit: N/A

- [x] 12. Stalwart HelmRelease Sidecar + ExternalSecret Updates (homeops)

  **What to do**:
  - Edit `kubernetes/apps/mail/stalwart/app/helmrelease.yaml`:
    - Add new container `user-mgmt-api` under `controllers.stalwart.containers` (alongside existing `app` container):
      ```yaml
      user-mgmt-api:
        image:
          repository: harbor.vaderrp.com/operinko-labs/stalwart-users
          tag: <initial-version>  # e.g. 0.1.0@sha256:...
        env:
          TZ: Europe/Helsinki
          PORT: "3000"
          STALWART_URL: "http://localhost:8080"
          ADMIN_USERS: "admin"
          PATH_PREFIX: "/manage/api"
        envFrom:
          - secretRef:
              name: "{{ .Release.Name }}-secret"
        probes:
          liveness: &api-probes
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /healthz
                port: &api-port 3000
              initialDelaySeconds: 10
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
          readiness: *api-probes
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: ["ALL"]}
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
      ```
  - Edit `kubernetes/apps/mail/stalwart/app/external-secret.yaml`:
    - Add `DATABASE_URL` to the template data: `DATABASE_URL: "postgresql://stalwart:{{ .db_password }}@postgres18-rw.database.svc.cluster.local:5432/stalwart?search_path=directory"`
    - The sidecar gets this env var via the same `stalwart-secret` secretRef
  - Add a service for the sidecar API in `helmrelease.yaml` under `service`:
    ```yaml
    api:
      controller: stalwart
      ports:
        http:
          port: 3000
    ```
  - Update `kubernetes/apps/mail/stalwart/app/httproute.yaml` to add a path-based rule routing `/manage/api` to the sidecar service:
    ```yaml
    - matches:
        - path:
            type: PathPrefix
            value: /manage/api
      backendRefs:
        - name: stalwart-api
          port: 3000
    ```
    This rule must appear **before** the existing catch-all `path: /` rule so it takes priority. The SPA at `/manage/users/` calls `../api/accounts` which resolves to `/manage/api/accounts`, routed to the sidecar.
  - The Go API strips the `/manage/api` prefix for API routes only (via `PATH_PREFIX=/manage/api` env var, as designed in Task 1). Health probes (`/healthz`) are registered on the root mux and remain accessible without the prefix.

  **Must NOT do**:
  - Do not modify the existing `app` container configuration
  - Do not change the init-db container
  - Do not add new init containers
  - Do not change existing env vars or secrets beyond adding `DATABASE_URL`

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Modifying production Kubernetes manifests requires care
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4
  - **Blocks**: Task 13
  - **Blocked By**: Task 10

  **References**:

  **Pattern References**:
  - `kubernetes/apps/mail/stalwart/app/helmrelease.yaml` — Existing Stalwart HelmRelease. The sidecar container goes under `controllers.stalwart.containers` alongside the existing `app` container. Follow the exact same structure (image, env, envFrom, probes, securityContext, resources).
  - `kubernetes/apps/tools/n8n/app/helmrelease.yaml:109-150` — The `tempest-mcp` sidecar pattern: image, env, envFrom, probes (liveness/readiness with httpGet), securityContext, resources. Copy this exact pattern for the user-mgmt-api container.
  - `kubernetes/apps/mail/stalwart/app/external-secret.yaml` — Current ExternalSecret template. Add `DATABASE_URL` to the `template.data` section using the existing `{{ .db_password }}` variable.
  - `kubernetes/apps/mail/stalwart/app/httproute.yaml` — Current HTTPRoute with single catch-all rule routing `/ → stalwart-app:8080`. Add a new path-based rule for `/manage/api` → `stalwart-api:3000` **before** the existing catch-all rule.

  **WHY Each Reference Matters**:
  - The existing HelmRelease structure must be preserved — only additive changes
  - The n8n sidecar is the proven pattern in this repo for adding containers
  - The ExternalSecret already has the db_password variable — reuse it for DATABASE_URL

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: HelmRelease YAML is valid
    Tool: Bash
    Preconditions: helmrelease.yaml modified
    Steps:
      1. Run `yamllint kubernetes/apps/mail/stalwart/app/helmrelease.yaml`
      2. Run `kubeconform -strict -ignore-missing-schemas kubernetes/apps/mail/stalwart/app/helmrelease.yaml`
      3. Assert no errors
    Expected Result: Valid YAML, valid Kubernetes manifest
    Failure Indicators: YAML lint errors, kubeconform violations
    Evidence: .sisyphus/evidence/task-12-helmrelease-valid.txt

  Scenario: Existing Stalwart config not broken + HTTPRoute updated
    Tool: Bash
    Preconditions: Modified manifests
    Steps:
      1. Verify `controllers.stalwart.containers.app` section is unchanged (diff against main)
      2. Verify `controllers.stalwart.initContainers.init-db` is unchanged
      3. Verify new `user-mgmt-api` container exists under `controllers.stalwart.containers`
      4. Verify `DATABASE_URL` added to ExternalSecret template
      5. Verify `httproute.yaml` has new rule matching `/manage/api` → `stalwart-api:3000`
      6. Verify new `/manage/api` rule appears **before** the catch-all `/` rule
      7. Run `yamllint kubernetes/apps/mail/stalwart/app/httproute.yaml` — assert no errors
    Expected Result: Only additive changes, existing config intact, HTTPRoute routes API traffic to sidecar
    Failure Indicators: Modified existing container config, missing HTTPRoute rule, wrong rule order
    Evidence: .sisyphus/evidence/task-12-no-regression.txt
  ```

  **Commit**: YES
  - Message: `feat(k8s): add user-management API sidecar to Stalwart pod`
  - Files: `kubernetes/apps/mail/stalwart/app/helmrelease.yaml, kubernetes/apps/mail/stalwart/app/external-secret.yaml, kubernetes/apps/mail/stalwart/app/httproute.yaml`
  - Pre-commit: `yamllint kubernetes/apps/mail/stalwart/app/`

- [x] 13. Stalwart Application Registration (manual via WebUI)

  **What to do**:
  - This is a **manual one-time step** performed by the user via Stalwart's WebUI after the SPA zip is published as a GitHub release and the sidecar is deployed.
  - The executing agent's job is to create a documentation file `docs/stalwart-app-registration.md` in the `operinko-labs/stalwart-users` repo with clear instructions for the user:
    1. Navigate to **Stalwart Admin → Settings → Web Applications** (`https://stalwart-admin.vaderrp.com`)
    2. Click **Create Application** (or equivalent)
    3. Fill in the following fields:
       - **Description**: `Mail User Management`
       - **Resource URL**: `https://github.com/operinko-labs/stalwart-users/releases/latest/download/stalwart-users-ui.zip`
       - **URL Prefix**: `/manage/users`
       - **Enabled**: `true`
       - **Auto Update Frequency**: `1d` (optional, checks for new zip daily)
       - **Unpack Directory**: `user-management` (subdirectory within Stalwart data dir)
    4. Save. Stalwart will fetch the zip, unpack it, and serve the SPA at `/manage/users/`.
  - Include a note that Stalwart persists this configuration in its database — it survives pod restarts.
  - Include a verification section: after saving, navigate to `https://stalwart-admin.vaderrp.com/manage/users/` and confirm the SPA loads.

  **Must NOT do**:
  - Do not automate this via scripts or API calls — user adds it manually through the WebUI
  - Do not modify Stalwart's config files or Kubernetes manifests for this step
  - Do not modify any homeops files for this task

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: Documentation task — clear instructions for manual setup
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (after Task 12)
  - **Blocks**: None (post-deployment documentation, does not block final verification)
  - **Blocked By**: Tasks 11, 12

  **References**:

  **External References**:
  - Stalwart Application Object Reference: https://stalw.art/docs/ref/object/application/ — defines all fields (description, resourceUrl, urlPrefix, enabled, autoUpdateFrequency, unpackDirectory)
  - Stalwart Management WebUI: Settings → Web Applications page allows creating Application objects via the UI

  **WHY Each Reference Matters**:
  - The Application object docs define the exact field names and types the user will see in the WebUI form
  - The WebUI is the documented, supported way to create hosted applications in Stalwart v0.16.x

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Documentation file exists and is complete
    Tool: Bash
    Preconditions: Task completed
    Steps:
      1. Run `cat docs/stalwart-app-registration.md`
      2. Assert file contains the Resource URL: `https://github.com/operinko-labs/stalwart-users/releases/latest/download/stalwart-users-ui.zip`
      3. Assert file contains URL Prefix: `/manage/users`
      4. Assert file contains step-by-step instructions for WebUI navigation
      5. Assert file contains a verification step (navigate to the SPA URL)
    Expected Result: Complete documentation with all required fields and instructions
    Failure Indicators: Missing fields, wrong URL, no verification step
    Evidence: .sisyphus/evidence/task-13-docs-complete.txt

  Scenario: SPA is accessible after manual registration
    Tool: Bash (curl)
    Preconditions: User has registered the application via WebUI, SPA zip published
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" https://stalwart-admin.vaderrp.com/manage/users/`
      2. Assert HTTP 200
      3. Run `curl -s https://stalwart-admin.vaderrp.com/manage/users/ | grep -q '<html'`
      4. Assert HTML content returned
    Expected Result: SPA served by Stalwart at /manage/users/
    Failure Indicators: 404 (app not registered or zip not fetched), empty response
    Evidence: .sisyphus/evidence/task-13-spa-accessible.txt
  ```

  **Commit**: YES
  - Message: `docs: add Stalwart application registration instructions`
  - Files: `docs/stalwart-app-registration.md`
  - Pre-commit: N/A

---

## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [x] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, curl endpoint, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Code Quality Review** — `unspecified-high`
  Run `go vet ./...` + `go test ./...`. Review all Go files for: empty error handling, unused imports, hardcoded credentials, `fmt.Println` in production code. Check SPA for inline styles vs CSS, console.log in production. Verify Dockerfile uses multi-stage build and non-root user.
  Output: `Build [PASS/FAIL] | Vet [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [x] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state. Execute EVERY QA scenario from Tasks 1-12 (skip Task 13 — it is post-deployment documentation requiring manual user action via Stalwart WebUI, excluded from automated verification). Test cross-task integration (create account → add alias → add to group → list → delete account cascades). Test edge cases: empty state, invalid input, unauthorized access. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [x] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance. Detect cross-task contamination. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

| Task | Commit Message | Files | Pre-commit |
|------|---------------|-------|------------|
| 1 | `feat(api): scaffold Go project with module and CI skeleton` | go.mod, main.go, .github/workflows/ci.yml | `go build ./...` |
| 2 | `feat(api): add database layer with connection pool and health check` | internal/db/*.go, internal/db/*_test.go | `go test ./...` |
| 3 | `feat(api): add SSHA512 password hashing module` | internal/auth/hash*.go, internal/auth/hash*_test.go | `go test ./...` |
| 4 | `feat(api): add accounts CRUD endpoints with TDD` | internal/api/accounts*.go, *_test.go | `go test ./...` |
| 5 | `feat(api): add email aliases CRUD endpoints with TDD` | internal/api/aliases*.go, *_test.go | `go test ./...` |
| 6 | `feat(api): add group memberships CRUD endpoints with TDD` | internal/api/groups*.go, *_test.go | `go test ./...` |
| 7 | `feat(api): add JMAP token auth middleware` | internal/auth/jmap*.go, *_test.go | `go test ./...` |
| 8 | `feat(ui): add accounts management SPA page` | ui/index.html, ui/app.js, ui/style.css | N/A |
| 9 | `feat(ui): add aliases and groups management UI` | ui/app.js, ui/style.css | N/A |
| 10 | `feat(ci): add Dockerfile and finalize CI pipeline` | Dockerfile, .github/workflows/ci.yml | `docker build .` |
| 11 | `feat(ci): add SPA zip packaging and release workflow` | .github/workflows/release.yml, Makefile | N/A |
| 12 | `feat(k8s): add user-management API sidecar to Stalwart pod` | helmrelease.yaml, external-secret.yaml, httproute.yaml | `yamllint` |
| 13 | `docs: add Stalwart application registration instructions` | docs/stalwart-app-registration.md | N/A |

---

## Success Criteria

### Verification Commands
```bash
# Go API tests pass
go test ./... -v  # Expected: PASS, 0 failures

# API responds to health check
curl -s http://localhost:3000/healthz  # Expected: {"status":"ok"}

# API rejects unauthenticated requests
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/accounts  # Expected: 401

# API lists accounts with valid admin token
curl -s -H "Authorization: Bearer <token>" http://localhost:3000/accounts  # Expected: 200, JSON array

# Stalwart pod has both containers running
kubectl -n mail get pods -l app.kubernetes.io/name=stalwart -o jsonpath='{.items[0].status.containerStatuses[*].name}'
# Expected: app user-mgmt-api (or similar)

# SPA loads via Stalwart
curl -s -o /dev/null -w "%{http_code}" https://stalwart-admin.vaderrp.com/manage/users/
# Expected: 200
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All Go tests pass
- [ ] SPA renders and can CRUD accounts/aliases/groups
- [ ] Sidecar healthy in Stalwart pod
- [ ] CI builds and pushes to Harbor
- [ ] SPA zip published as GitHub release
