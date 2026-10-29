# stalwart-users OIDC Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** stalwart-users signs users in through Stalwart's own OIDC login (authorization code + PKCE, first-party client) instead of checking passwords itself, and changes a user's own password through Stalwart's `x:AccountPassword`, which verifies the current main password (and TOTP).

**Architecture:** A small `internal/oidc` client handles discovery, the authorize URL, code exchange, refresh and userinfo. `GET /api/auth/login` sends the browser to Stalwart's login page; `GET /api/auth/callback` finishes the flow, resolves the userinfo email to a Stalwart User by exact canonical primary address, and issues the existing session cookie. The user's OAuth tokens stay server-side in an in-memory store keyed by the session id; self password changes call `x:AccountPassword/set` with them. Admin and domain-admin actions keep using the admin API key. The Basic-auth login (`POST /api/auth/login`, `StalwartAuthenticator`, `Client.Authenticate`, `Store.Authenticate`) is removed.

**Tech Stack:** Go 1.24 stdlib (`net/http`, `crypto/rand`, `crypto/sha256`, `crypto/hmac`), existing `golang-jwt/jwt/v5`, React frontend, Stalwart v1.0.0.

**Spec:** this plan; context in `2026-10-28-stalwart-drop-sql-directory.md` (Decisions, Rehearsal "Found") and the conversation decisions of 2026-10-28: first-party client, `email-users.erinko.fi` only with the other host redirecting, same PR (operinko-labs/stalwart-users#37).

## Global Constraints

- Repo `C:\Users\ollie\stalwart-users-internal-dir`, branch `feat/internal-directory` (PR #37). Commit locally; the controller pushes. No AI attribution.
- Stalwart discovery (`<issuer>/.well-known/openid-configuration`): issuer `https://mail.erinko.fi`, `authorization_endpoint` `/login`, `token_endpoint` `/auth/token`, `userinfo_endpoint` `/auth/userinfo`, `code_challenge_methods_supported` `["S256"]`, `token_endpoint_auth_methods_supported` includes `client_secret_basic`, scopes include `openid` and `offline_access`, userinfo claims `sub`, `name`, `preferred_username`, `email`, `email_verified`.
- Requested scope: `openid offline_access`. PKCE S256 always; `state` always; client auth `client_secret_basic`.
- New required env: `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URL` (production `https://email-users.erinko.fi/api/auth/callback`). Existing `STALWART_URL`, `STALWART_ADMIN_TOKEN`, `DATABASE_URL`, `JWT_SECRET` stay required.
- Identity = userinfo `email`, canonicalised with `auth.CanonicalName`, matched exactly to a Stalwart User's primary `Email` (the existing `GetAccount` path). No match → sign-in refused. Never trust a username from the browser.
- `x:AccountPassword/set` is called as the user (`Authorization: Bearer <user access token>`) with `{"update":{"singleton":{"secret":<new>,"currentSecret":<current>,"otpAuth":{"otpCode":<code or omitted>}}}}`. Stalwart answers forbidden "Current secret is incorrect." (wrong current), forbidden "Current OTP code is required to change the password or OTP auth." (2FA on, code missing/wrong), invalidProperties (weak password).
- Secrets (passwords, codes, tokens, client secret) never appear in logs, errors or responses.
- Browser-facing errors from the callback are a fixed code in `/login?error=<code>`, never Stalwart's text.

## Decisions taken (flag to the user at handoff)

1. **OAuth tokens live in memory.** After a backend restart existing sessions still work for everything except a self password change, which then answers 401 `reauth_required` and the UI sends the user through sign-in again. No token is ever put in a cookie.
2. **Sign-out only ends the stalwart-users session.** It doesn't call Stalwart's `end_session_endpoint`, so a still-valid Stalwart login session can sign the user straight back in.
3. **Full admins changing their own password** keep the existing behaviour (no current password, admin API). Only non-admins and domain admins changing their own password go through `x:AccountPassword`.

## Review Focus

- A callback with a missing or wrong `state`, a replayed state cookie, or a code from another flow must be refused (no session) → Task 2 `TestCallbackRejectsBadState`, `TestCallbackStateCookieSingleUse`.
- A userinfo email that matches only an alias, a Group, or a case/Unicode variant must not sign in → Task 2 `TestCallbackRejectsNonPrimaryIdentity`.
- An expired access token must be refreshed once before `x:AccountPassword`; a failed refresh must give 401 `reauth_required`, not 500 → Task 3 `TestChangeOwnPasswordRefreshesExpiredToken`, `TestChangeOwnPasswordReauthWhenRefreshFails`.
- Stalwart's OTP-required answer must reach the UI as a distinct 400 so it can ask for the code → Task 3 `TestChangeOwnPasswordOtpRequired`.
- Sign-in redirects must only go to the configured authorize endpoint and back to `/`; no open redirect via query parameters → Task 2 `TestLoginRedirectsOnlyToAuthorizeEndpoint`.

---

### Task 1: `internal/oidc` client

**Files:**
- Create: `internal/oidc/client.go`, `internal/oidc/client_test.go`

**Interfaces:**
- Produces:
  ```go
  type Config struct{ Issuer, ClientID, ClientSecret, RedirectURL string }
  type Tokens struct {
      AccessToken, RefreshToken string
      ExpiresAt time.Time // now + expires_in
  }
  type UserInfo struct{ Subject, Email, PreferredUsername string }
  func New(cfg Config, httpClient *http.Client) *Client
  func (c *Client) AuthCodeURL(ctx context.Context, state, codeChallenge string) (string, error) // discovery fetched once and cached
  func (c *Client) Exchange(ctx context.Context, code, codeVerifier string) (Tokens, error)
  func (c *Client) Refresh(ctx context.Context, refreshToken string) (Tokens, error) // keeps the old refresh token if none is returned
  func (c *Client) UserInfo(ctx context.Context, accessToken string) (UserInfo, error)
  func NewPKCE() (verifier, challenge string, err error) // 32 random bytes, base64url no padding; challenge = base64url(sha256(verifier))
  ```
  Discovery must reject a document whose `issuer` differs from `Config.Issuer`.

- [ ] **Step 1: Write failing tests** against an httptest server serving discovery, token and userinfo: `TestAuthCodeURLParameters` (response_type=code, client_id, redirect_uri, scope `openid offline_access`, state, code_challenge, code_challenge_method=S256, endpoint from discovery), `TestDiscoveryIssuerMismatch`, `TestExchangeSendsBasicAuthAndVerifier`, `TestExchangeError` (400 `{"error":"invalid_grant"}` → error that doesn't contain the code), `TestRefreshKeepsRefreshToken`, `TestUserInfo`, `TestNewPKCE` (RFC 7636 appendix B vector for the challenge function).
- [ ] **Step 2: Run** `go test ./internal/oidc/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./... && go vet ./...` → PASS.
- [ ] **Step 5: Commit** `feat(oidc): client for Stalwart's OIDC endpoints`.

### Task 2: Sign-in through Stalwart

**Files:**
- Create: `internal/auth/oidc_login.go`, `internal/auth/oidc_login_test.go`, `internal/auth/tokenstore.go`, `internal/auth/tokenstore_test.go`
- Modify: `internal/auth/jwt.go` (session id), `internal/auth/session.go` (logout deletes stored tokens), `cmd/server/main.go` (routes, config), `cmd/server/main_test.go`
- Delete: `internal/auth/login.go` + its tests (Basic login), `Client.Authenticate` and its tests, `Store.Authenticate` and its tests

**Interfaces:**
- Consumes: Task 1 `oidc.Client`, `NewPKCE`; `directory.Store.GetAccount`, `IsAdmin`.
- Produces:
  ```go
  // tokenstore.go
  type TokenStore struct{ /* mutex + map */ }
  func NewTokenStore() *TokenStore
  func (s *TokenStore) Put(sessionID string, t oidc.Tokens)
  func (s *TokenStore) Get(sessionID string) (oidc.Tokens, bool)
  func (s *TokenStore) Delete(sessionID string)
  // jwt.go: SessionClaims gains the JWT ID; Session gains ID string; GenerateToken returns (token, sessionID string, err error)
  // oidc_login.go
  func LoginStartHandler(oc oidcStarter, tokens *TokenManager) http.HandlerFunc     // GET /auth/login
  func CallbackHandler(oc oidcFinisher, accounts accountResolver, tokens *TokenManager, store *TokenStore) http.HandlerFunc // GET /auth/callback
  ```
  `LoginStartHandler`: new state (32 random bytes, base64url) + PKCE pair; sets cookie `su_oidc` = HMAC-signed `state|verifier|expiry` (key derived from the JWT secret, 10 minutes, HttpOnly, Secure as the session cookie, SameSite=Lax, Path=/api/auth); 302 to `AuthCodeURL`.
  `CallbackHandler`: always clears `su_oidc`; Stalwart `error` param → `/login?error=denied`; bad/missing/expired/mismatched state → `/login?error=state`; exchange/userinfo failure → `/login?error=signin`; userinfo email not a User's primary address → `/login?error=no_mailbox`; success → session cookie (existing) + `store.Put(sessionID, tokens)` + 302 `/`. Paths are relative to the app root (respect `PATH_PREFIX` the same way the API does).
  Routes: `GET /auth/login`, `GET /auth/callback`, `GET /auth/me` and `POST /auth/logout` unchanged; `POST /auth/login` removed.

- [ ] **Step 1: Write failing tests**: `TestLoginRedirectsOnlyToAuthorizeEndpoint` (Location host/path = discovery's authorize endpoint; extra query params on `/auth/login` are ignored), `TestLoginSetsSignedStateCookie` (Lax, HttpOnly, Path), `TestCallbackSuccess` (session cookie set, tokens stored under the session id, 302 `/`), `TestCallbackRejectsBadState` (missing cookie, tampered HMAC, expired, state mismatch → `/login?error=state`, no session), `TestCallbackStateCookieSingleUse` (cookie cleared on every outcome), `TestCallbackRejectsNonPrimaryIdentity` (alias address, group address, `ſam@…` variant → `no_mailbox`), `TestCallbackProviderError` (`?error=access_denied` → `denied`), `TestLogoutDeletesStoredTokens`, `TestTokenStore`, and a `main_test.go` case that each `OIDC_*` env var is required.
- [ ] **Step 2: Run** `go test ./...` → FAIL.
- [ ] **Step 3: Implement**; delete the Basic-login code and its tests.
- [ ] **Step 4: Run** `go test ./... && go vet ./... && gofmt -l .` → PASS, gofmt prints nothing.
- [ ] **Step 5: Commit** `feat(auth): sign in through Stalwart's OIDC login`.

### Task 3: Own password change through `x:AccountPassword`

**Files:**
- Modify: `internal/stalwart/jmap.go` (+ test), `internal/api/password.go` (+ test), `internal/model/account.go`, `cmd/server/main.go`

**Interfaces:**
- Consumes: Task 1 `oidc.Client.Refresh`; Task 2 `TokenStore`, `Session.ID` (available to handlers through the request context — add `auth.SessionIDFromContext` beside `UsernameFromContext`).
- Produces:
  ```go
  // stalwart
  var ErrCurrentPasswordIncorrect = errors.New("current password is incorrect")
  var ErrOTPRequired = errors.New("two-factor code required")
  func (c *Client) ChangeOwnPassword(ctx context.Context, userAccessToken, current, next, otpCode string) error // ErrInvalid for weak passwords
  // model
  type ChangePasswordRequest struct{ CurrentPassword, NewPassword, OTPCode string } // json: current_password, new_password, otp_code
  ```
  Handler: non-admin self (and domain admin self) → tokens from the store; if `ExpiresAt` is within 30 s, `Refresh` once and `Put` the result; then `ChangeOwnPassword`. Missing tokens or failed refresh → 401 `{"error":"reauth_required"}`. `ErrCurrentPasswordIncorrect` → 401 "invalid current password"; `ErrOTPRequired` → 400 `{"error":"otp_required"}`; `ErrInvalid` → 400 with its description. Full admin self, and anyone changing another account they may manage → existing admin `SetPassword` path.

- [ ] **Step 1: Write failing tests**: `TestChangeOwnPasswordPayload` (Bearer is the user token, not the admin key; exact singleton patch; `otpAuth` only when a code is given), `TestChangeOwnPasswordErrors` (the three Stalwart answers above map to the three errors), handler tests `TestChangeOwnPasswordUsesUserToken`, `TestChangeOwnPasswordRefreshesExpiredToken`, `TestChangeOwnPasswordReauthWhenRefreshFails`, `TestChangeOwnPasswordReauthWhenNoTokens`, `TestChangeOwnPasswordOtpRequired`, `TestAdminResetStillUsesAdminKey`.
- [ ] **Step 2: Run** `go test ./...` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./... && go vet ./... && gofmt -l .` → PASS.
- [ ] **Step 5: Commit** `feat: change your own password through Stalwart`.

### Task 4: Frontend and docs

**Files:**
- Modify: `frontend/src/pages/LoginPage.tsx`, `frontend/src/contexts/AuthContext.tsx`, `frontend/src/contexts/auth-context.ts`, `frontend/src/api/client.ts`, `frontend/src/pages/MyAccountPage.tsx`, `README.md`

**Interfaces:**
- Consumes: Task 2 routes (`/api/auth/login` navigation, `/api/auth/me`, `/api/auth/logout`), Task 3 password API (`otp_code`, `otp_required`, `reauth_required`).
- Produces: LoginPage shows one "Sign in" button that navigates (full page, not fetch) to `<api base>/auth/login`, and shows a message for `?error=` codes `denied` ("Sign-in was cancelled."), `state` ("Sign-in expired, please try again."), `signin` ("Sign-in failed, please try again."), `no_mailbox` ("This account has no mailbox here."). `api.auth.login` and the email/password form are removed. MyAccountPage's password form adds an optional "Two-factor code" field, shown after an `otp_required` answer, and sends the user to `/login` on `reauth_required`.

- [ ] **Step 1:** Implement; `npm --prefix frontend run build` and `npm --prefix frontend run lint` (if the script exists) pass.
- [ ] **Step 2:** README: sign-in via Stalwart OIDC (first-party client, redirect URL, the four `OIDC_*` env vars), tokens held in memory, password change via `x:AccountPassword`.
- [ ] **Step 3: Commit** `feat(frontend): sign in with Stalwart`.

### Task 5: Rehearsal against a throwaway Stalwart

Scratch files only (session scratchpad); nothing touches live data.

- [ ] **Step 1:** Throwaway pod as in the drop-SQL rehearsal (Stalwart v1.0.0 on RocksDB, no egress, throwaway recovery admin), sign-in on the internal directory. Create a domain, three users with known strong passwords (one full admin, one domain admin via a local Postgres `domain_admins` row or a local Postgres container, one regular user with an app password), an ops admin with an API key.
- [ ] **Step 2:** `x:OAuthClient/set` create `stalwart-users` with `firstParty: true`, a generated secret, `redirectUris` `{"http://127.0.0.1:13000/api/auth/callback": true}`, `grantTypes` authorizationCode + refreshToken. Confirm discovery's issuer for the port-forwarded host and set `OIDC_ISSUER` to it.
- [ ] **Step 3:** Run the branch server locally (port 13000) against the pod. Script the browser: `GET /api/auth/login` → follow to Stalwart `/login?…`; `POST /api/auth` `{"type":"authCode","accountName":…,"accountSecret":…,"query":<the login URL's query string>,"consent":true}` → follow the returned location to `/api/auth/callback` with the `su_oidc` cookie → expect 302 `/` and a session cookie; `/api/auth/me` shows the user and the right admin flag.
- [ ] **Step 4:** Negative paths: wrong password (Stalwart refuses, no code), app password as `accountSecret` (record whether Stalwart's login form accepts it), alias address as `accountName` (`no_mailbox` or refused), tampered `state` (`/login?error=state`).
- [ ] **Step 5:** Password change as the regular user: wrong current → 401; app password as current → 401; right current + weak new → 400; right current + strong new → 200 and Stalwart sign-in with the new one works; after restarting the server, the same request → 401 `reauth_required`. Refresh: if the access token lifetime can be shortened on the throwaway (`x:OidcProvider` `accessTokenExpiry`, min 10 min), skip live waiting and rely on the unit test.
- [ ] **Step 6:** Tear down; record results under "Rehearsal" in this plan; commit to homeops `main`.

### Task 7: Self-registration of the OAuth client (added 2026-10-29)

Replaces the manual client registration and the Vaultwarden field of Task 6. stalwart-users registers its own first-party client at startup with the admin key it already has, using a secret derived from its existing `JWT_SECRET`, the same way Bulwark's "Auto-configure OAuth" does it, but automatically and without storing anything.

**Files:**
- Modify: `internal/stalwart/jmap.go` (+ test), `internal/oidc/client.go` (+ test), `cmd/server/main.go` (+ test), `README.md`
- Create: `internal/auth/clientsecret.go` (+ test)

**Interfaces:**
- Produces:
  ```go
  // auth
  func DeriveOAuthClientSecret(jwtSecret string) string // hex(HMAC-SHA256(key=jwtSecret, msg="stalwart-users oauth client secret")), 64 lowercase hex chars
  // stalwart
  type OAuthClientSpec struct{ ClientID, Secret, RedirectURI, Description string }
  func (c *Client) EnsureOAuthClient(ctx context.Context, spec OAuthClientSpec) (created bool, err error)
  ```
  `EnsureOAuthClient` runs `x:OAuthClient/query` with `{"filter":{"clientId":<id>}}`. With no match it creates `{"clientId","description","contacts":{},"secret","redirectUris":{<uri>:true},"postLogoutRedirectUris":{},"logo":null,"firstParty":true,"scopes":{},"grantTypes":{"authorizationCode":true,"refreshToken":true}}`. With a match it updates that id with `secret`, `redirectUris` (exactly `{<uri>: true}`), `firstParty: true`, `grantTypes` and `description`. Errors never contain the secret.
- `main.go`: `OIDC_CLIENT_SECRET` is no longer required; when empty the secret is `DeriveOAuthClientSecret(JWT_SECRET)`. After the handler is built, a background goroutine calls `EnsureOAuthClient` (10 s timeout per attempt), retrying with backoff 5 s → 60 s cap until it succeeds, logging `OAuth client stalwart-users created|updated` once, and errors without the secret. The server starts listening without waiting; sign-ins that happen before registration succeeds simply fail at the token exchange (`/login?error=signin`).
- `internal/oidc`: the HTTP client refuses redirects to another host or from https to http (`CheckRedirect`); same-host redirects are followed, at most 3.

- [ ] **Step 1: Write failing tests:**
  - `TestDeriveOAuthClientSecret`: deterministic, 64 hex chars, differs for different JWT secrets, and differs from the cookie MAC key derivation in `jwt.go`.
  - `TestEnsureOAuthClientCreates`: the exact create payload.
  - `TestEnsureOAuthClientUpdatesExisting`: the exact update patch on the queried id.
  - `TestEnsureOAuthClientErrorHasNoSecret`.
  - `TestOIDCRefusesCrossHostRedirect`: discovery answering 302 to another host is an error.
  - `TestOIDCFollowsSameHostRedirect`.
  - `TestRefusesHTTPSDowngradeRedirect`.
  - main tests: `OIDC_CLIENT_SECRET` optional, the derived secret used when it's empty, and registration retried until a fake succeeds.
- [ ] **Step 2: Run** `go test ./...` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./... && go vet ./... && gofmt -l .` → PASS, gofmt prints nothing.
- [ ] **Step 5: README:** the client registers itself at startup; `OIDC_CLIENT_SECRET` is an optional override; rotating `JWT_SECRET` rotates the client secret on the next start and signs everyone out.
- [ ] **Step 6: Commit** `feat: register the OAuth client in Stalwart at startup`.

### Task 6: Cutover additions (fold into Task 9 of `2026-10-28-stalwart-drop-sql-directory.md`) — superseded in part by Task 7: no Vaultwarden field and no manual client registration

Live, with the user, at the drop-SQL cutover.

- [ ] User adds field `stalwart_users_oidc_secret` (a long random value) to the Vaultwarden item behind `stalwart-users-secret`. After the ExternalSecret syncs, the controller reads it only from the Kubernetes secret and pipes it straight into the `x:OAuthClient/set` request below, never printing it.
- [ ] `x:OAuthClient/set` create `stalwart-users`: `firstParty: true`, the same secret, `redirectUris` `{"https://email-users.erinko.fi/api/auth/callback": true}`, `grantTypes` authorizationCode + refreshToken, description "stalwart-users (account management)".
- [ ] homeops: `external-secret.yaml` adds `OIDC_CLIENT_SECRET`; `helmrelease.yaml` adds `OIDC_ISSUER=https://mail.erinko.fi`, `OIDC_CLIENT_ID=stalwart-users`, `OIDC_REDIRECT_URL=https://email-users.erinko.fi/api/auth/callback`, and `CORS_ORIGIN=https://email-users.erinko.fi`; `httproute.yaml` serves the app on `email-users.erinko.fi` only and adds a route that 301-redirects `email-users.vaderrp.com` to `email-users.erinko.fi` (same shape as `bulwark-webmail`); homepage `href` → `https://email-users.erinko.fi`; Gatus check unchanged (in-cluster URL).
- [ ] Verify: sign in through Stalwart's page with the `.env` account (right password only) and check `/api/auth/me`. Test the password change on a temporary account created and deleted through stalwart-users, never on the user's real account.

## Rehearsal (Task 5, done 2026-10-29)

Branch 8780a76, Linux build run inside a throwaway pod (Stalwart v1.0.0 on RocksDB + Postgres sidecar for `domain_admins`, no egress). Stalwart's issuer is `https://<defaultHostname>` (`localhost` is rejected as a hostname), so the pod used its own name `stalwart-dirtest` with a throwaway CA + certificate loaded as `x:Certificate`, and the server trusted that CA via `SSL_CERT_FILE`. First-party client `stalwart-users` with an alphanumeric secret; login scripted through Stalwart's `POST /api/auth` (`{"type":"authCode","accountName","accountSecret","query","consent":true}` → `{"type":"authenticated","location":…}`).

Worked:
- `/api/auth/login` → Stalwart `/login` with `client_id`, `redirect_uri`, `scope=openid offline_access`, `response_type=code`, S256 challenge, state; `su_oidc` set. Callback → 302 `/`, session cookie, `/auth/me` right for a regular user, the full admin (`isAdmin: true`) and the domain admin (`adminDomains: ["rb.example.com"]`). Client secret via HTTP Basic accepted.
- Wrong password: Stalwart answers `{"type":"failure"}`, no code. Tampered state and a callback without `su_oidc` → `/login?error=state`, no session.
- Own password change through `x:AccountPassword` with the user token (no `accountId` needed): wrong current → 401, **app password as current → 401**, weak new → 400 "Password must be at least 8 characters long.", right current → 200 and only the new password signs in. Domain admin self → same path, 200. Full admin self → admin path without current password, 200.
- A second own change in the same session → 401 `reauth_required` (Stalwart revokes the session's tokens when the password changes; the UI sends the user to sign in again).
- After a backend restart the old session still works (`/auth/me`, a domain admin listing only their domain), and an own password change answers 401 `reauth_required`.
- No secret-looking lines in the server log.

Found:
- **Stalwart's login page accepts an app password**, so an app password opens a stalwart-users session (with that user's role). It still can't change the main password. Same exposure as Basic auth had for sign-in; stalwart-users can't tell which credential was used.
- Signing in with an alias address works: Stalwart resolves it and userinfo returns the primary address, so the session is the primary account.

Not covered: a wrong TOTP code (no 2FA user in the rehearsal) and token refresh after expiry (minimum access-token lifetime is 10 minutes; covered by unit tests).
