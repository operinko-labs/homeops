# Learnings — Stalwart User Management

## [2026-05-12T21:37] Session Start
- Plan approved by Momus after 5 review rounds
- This is a NEW repository project (`operinko-labs/stalwart-users`)
- Tasks 1-11 work in the new repo
- Task 12 works in homeops repo (Kubernetes deployment)
- Task 13 is documentation only

## [2026-05-13T00:42] Task 1: Go Project Scaffolding Complete

### Project Structure
- Module: `github.com/operinko-labs/stalwart-users`
- Entry point: `cmd/server/main.go` with full env var parsing
- Internal packages: `internal/{api,auth,db,model}` (placeholders)
- UI directory: `ui/` for SPA files

### HTTP Routing Pattern
- Root mux with health endpoint `/healthz` (not prefixed)
- API subrouter mounted under `PATH_PREFIX` with `http.StripPrefix`
- UI file server at `/` with lowest priority (Go 1.22+ pattern matching)
- Default `PATH_PREFIX=/accounts` for dev mode

### Environment Variables
All 7 env vars parsed and logged:
- `DATABASE_URL`: Optional, logs "Database: configured"
- `STALWART_URL`: Optional, logs URL
- `ADMIN_USERS`: Optional, comma-separated list
- `PATH_PREFIX`: Default "/accounts"
- `PORT`: Default 3000
- `SERVE_UI`: Optional, serves static files
- `AUTH_BYPASS`: Optional, logged (dev/test only)

### Build & CI
- Binary builds cleanly: `go build ./cmd/server/` → 8.4MB executable
- Makefile with targets: build, test, clean, run
- GitHub Actions CI: checkout → setup Go 1.22 → build → test
- .gitignore covers Go binaries, test files, IDE, OS files

### Key Decisions
- No external HTTP router frameworks (using stdlib http.ServeMux)
- No ORM packages (will use database/sql + lib/pq)
- No frontend build tooling (SPA served as static files)
- Health endpoint always on root mux for Kubernetes probes
- API routes take precedence over UI routes via Go 1.22+ pattern matching

### Next Steps (Task 2+)
- Implement database connection pooling
- Add authentication middleware
- Implement user management API handlers
- Add SSHA512 password hashing
- Integrate with Stalwart JMAP session validation
