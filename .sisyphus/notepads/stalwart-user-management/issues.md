# Issues — Stalwart User Management

## Known Gotchas
- `AUTH_BYPASS=true` is for dev/test ONLY — never set in production K8s manifests
- Primary email (`type='primary'`) cannot be deleted via alias API
- Account deletion must cascade to `directory.emails` and `directory.group_members`
- Empty passwords must be rejected (400)
- SSHA512 format: `{SSHA512}` + Base64(SHA512(password+salt) + salt)
- Salt length: 16 bytes

## Path Routing
- `PATH_PREFIX` env var for production (`/manage/api`)
- Health endpoint `/healthz` registered on root mux (not prefixed)
- API subrouter mounted under prefix with `http.StripPrefix`
