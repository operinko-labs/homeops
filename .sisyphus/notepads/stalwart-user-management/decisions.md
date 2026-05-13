# Decisions — Stalwart User Management

## Architecture
- **Stack**: Go API + vanilla HTML/JS SPA
- **Auth**: JMAP token forwarding (validate via `/jmap/session`)
- **Admin gating**: `ADMIN_USERS` env var (comma-separated)
- **Port**: 3000 (sidecar)
- **DB**: PostgreSQL via `database/sql` + `lib/pq` (no ORM)
- **Hashing**: SSHA512 with 16-byte salt
- **SPA delivery**: Stalwart Applications (zip from GitHub release)
- **CI**: GitHub Actions on org-runner, images to Harbor `operinko-labs` project

## Routing
- Production: `/manage/users/*` → Stalwart (SPA), `/manage/api/*` → sidecar
- Dev: SPA at `/`, API at `/accounts` (same-origin via `SERVE_UI=./ui`)
- Health probes: `/healthz` (always available, not prefixed)

## Repository Structure
- New repo: `operinko-labs/stalwart-users` (tasks 1-11)
- Homeops repo: Kubernetes manifests (task 12)
