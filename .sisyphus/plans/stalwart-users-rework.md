# Stalwart Users Rework — Standalone Deployment

## Summary
Rework stalwart-users from a Stalwart SPA + sidecar into a standalone user management system with React frontend + Go backend, deployed as separate pods on `email-users.vaderrp.com`.

## Architecture
- **Frontend**: React + Vite, served by Nginx container, port 80
- **Backend**: Go API, port 3000
- **Auth**: JWT in HTTP-only secure cookies, validated against `directory.accounts` (SSHA512 passwords)
- **Admin**: Determined by querying Stalwart's JMAP API (`Principal/get`) for the user's role after password validation. Admin role is managed in Stalwart's internal registry, not the SQL directory.
- **Non-admin**: Can only manage their own account (view/edit details, aliases, groups)
- **Domain**: `email-users.vaderrp.com` (external)
- **Registry**: `harbor.vaderrp.com/operinko-labs/stalwart-users` (backend), `harbor.vaderrp.com/operinko-labs/stalwart-users-frontend` (frontend)
- **Repo**: github.com/operinko-labs/stalwart-users (monorepo with `frontend/` directory)

## Database Schema (existing, no changes)
```sql
directory.accounts (name TEXT PK, secret TEXT, description TEXT, type TEXT, quota INTEGER, active BOOLEAN)
directory.emails (name TEXT, address TEXT, type TEXT, PK(name, address))
directory.group_members (name TEXT, member_of TEXT, PK(name, member_of))
```

## TODOs

### Phase 1: Cleanup
- [x] T1: Remove sidecar from stalwart HelmRelease — delete `user-mgmt-api` container, `api` service, and `/manage/api` HTTPRoute rule. Remove Stalwart app registration docs and SPA zip from release workflow. Clean up `ui/` directory.

### Phase 2: Backend Auth Rework
- [x] T2: Replace JMAP auth with JWT session auth — new `internal/auth/jwt.go` with login endpoint (`POST /api/auth/login`), logout (`POST /api/auth/logout`), session check (`GET /api/auth/me`). JWT stored in HTTP-only secure cookie. Validate credentials against `directory.accounts` (SSHA512). Check admin status by calling Stalwart JMAP API with admin token to query user's role (`UserRoles::Admin`). Include `isAdmin` flag in JWT. Backend needs `STALWART_ADMIN_TOKEN` env var. TDD.
- [x] T3: Add authorization middleware — admin users can access all endpoints. Non-admin users can only access `/api/accounts/{their-own-name}/*` endpoints. Return 403 for unauthorized access. TDD.
- [x] T4: Add password change endpoint — `PUT /api/accounts/{name}/password`. Users can change their own password, admins can change anyone's. Hash new password as SSHA512. TDD.

### Phase 3: React Frontend
- [x] T5: Initialize React + Vite + TypeScript project in `frontend/` — set up project structure, routing (react-router), API client with cookie-based auth, and build config. Add Dockerfile.frontend (multi-stage: node build + nginx serve).
- [x] T6: Build login page — email + password form, POST to `/api/auth/login`, redirect to dashboard on success. Show error on failure.
- [x] T7: Build accounts management page (admin view) — list all accounts in a table, create/edit/delete accounts, toggle active status. Only visible to admins.
- [x] T8: Build self-service account page (non-admin view) — view own account details, change password, manage own aliases.
- [x] T9: Build alias management — view/add/remove email aliases for an account. Admins can manage any account's aliases, non-admins only their own.
- [x] T10: Build group management — view/add/remove group memberships. Admin only.

### Phase 4: CI/CD Updates
- [x] T11: Update release workflow — build and push two images (backend + frontend). Remove SPA zip creation. Add frontend build step.
- [x] T12: Update CI workflow — add frontend lint/typecheck/test step alongside Go test.

### Phase 5: Homeops Deployment
- [x] T13: Create stalwart-users deployment in homeops — new app at `kubernetes/apps/mail/stalwart-users/` with HelmRelease (two containers or two controllers: backend + frontend), ExternalSecret, HTTPRoute (`email-users.vaderrp.com`, external, `/api/*` → backend, `/` → frontend), ks.yaml, DNS.

### Phase 6: Final Verification
- [x] F1: Oracle review — verify auth flow security (JWT, SSHA512, cookie flags, CORS)
- [x] F2: Oracle review — verify authorization logic (admin vs non-admin access control)
- [ ] F3: Hands-on QA — deploy and test login, account management, self-service, alias/group management via browser
- [x] F4: Code quality review — no TODOs, no hardcoded values, tests pass, builds clean

## Parallelization
- T2, T3, T4 are sequential (each builds on previous auth work)
- T5 can run in parallel with T2-T4 (frontend setup independent of backend auth)
- T6-T10 are sequential (each page builds on previous)
- T11-T12 can run in parallel
- T13 depends on T11 (needs image names/tags)
- F1-F4 run in parallel after all implementation tasks
