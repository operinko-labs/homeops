# Stalwart PROXY Protocol Rollout Plan

> **For agentic workers:** this is a live-operations runbook, executed inline by the controller with the user (superpowers:executing-plans). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stalwart sees the real client address on every protocol the VPS haproxy relays, so its auth bans hit attackers instead of nobody.

**Architecture:** The VPS haproxy (172.16.8.2) relays 443, 465, 587, 993, 995 and 4190 to Stalwart's LoadBalancer IP 172.16.8.10 as plain TCP, so Stalwart sees every internet client as 172.16.8.2, which `x:AllowedIp` exempts (172.16.8.0/24). Port 25 already uses PROXY v2 (`send-proxy-v2` + the smtp listener trusting 172.16.8.0/24). This change does the same for the other relayed listeners and keeps `Http.clientIpSource` at `peer`.

**Tech Stack:** haproxy on the wg-haproxy VPS (`vps/config/haproxy.cfg`, applied with `just vps apply`), Stalwart v1.0.0 registry API (`x:NetworkListener`, `x:Security`), Flux.

**Spec:** the throwaway-pod test of 2026-10-28, recorded in memory `project_stalwart_1_0_migration.md` ("PROXY protocol finding").

## Global Constraints

- `overrideProxyTrustedNetworks` takes effect only after a Stalwart restart.
- From a trusted source the PROXY header is mandatory: a connection without one gets no response. So haproxy must send PROXY exactly from the moment the restarted Stalwart starts listening.
- Untrusted sources are unaffected; a PROXY header from them gets 400. Pods, Traefik and LAN clients keep working unchanged.
- Bans land on the PROXY-reported address; other clients through the same proxy are not affected.
- Trust only `172.16.8.2/32` on the changed listeners. Leave the smtp listener's existing `172.16.8.0/24` alone.
- Do not touch `Http.clientIpSource` (stays `peer`): it's global and would let 443 clients forge X-Forwarded-For.
- Stalwart's Deployment is `Recreate` with one replica; start to Ready took ~33 s on 2026-10-27.
- homeops changes commit straight to `main`; no AI attribution.

## Scope

| haproxy backend | Port | Stalwart listener | Change |
|---|---|---|---|
| `bk_https` | 443 | `https` | send-proxy-v2 + trust |
| `bk_submissions` | 465 | `submissions` | send-proxy-v2 + trust |
| `bk_submission` | 587 | `submission` | send-proxy-v2 + trust |
| `bk_imaps` | 993 | `imaps` | send-proxy-v2 + trust |
| `bk_pop3s` | 995 | `pop3s` | send-proxy-v2 + trust |
| `bk_sieve` | 4190 | `sieve` | send-proxy-v2 + trust |
| `bk_imap` | 143 | none (no plain IMAP listener in 1.0) | remove frontend + backend: it only refuses connections |
| `bk_smtp` | 25 | `smtp` | unchanged |
| `bk_traefik`, `bk_forgejo_web`, `bk_rtc_tcp`, `bk_forgejo_ssh` | | not Stalwart | unchanged |

Not in scope: the Traefik → `stalwart-app:8080` path (admin UI, LAN `mail.erinko.fi`, Bulwark, stalwart-users) keeps showing pod addresses.

## Decisions taken (flag to the user at handoff)

1. **`authBanPeriod` becomes 1 day** (it's `null` today, which makes bans permanent). Once bans hit real addresses, a phone with a stale password on a shared mobile IP could otherwise lock that address out for good. Repeat offenders get banned again each day. `authBanRate` stays 100 per 24 h.
2. **Port 143 is dropped from haproxy.** Stalwart 1.0 has no listener there, so it fails today anyway.

---

### Task 1: Pre-flight

- [ ] **Step 1: Confirm the only 172.16.8.x source on the six listeners is .2.** Run:
  ```bash
  kubectl -n mail logs deploy/stalwart --since=24h | sed 's/\x1b\[[0-9;]*m//g' > "$SCRATCH/stalwart24h.log"
  ```
  (`$SCRATCH` = the session scratchpad; delete the file afterwards.) Tally `listenerId` × `remoteIp` blocks as on 2026-10-28. Expected: for https/submissions/submission/imaps/pop3s/sieve, every 172.16.8.x address is 172.16.8.2. Anything else (e.g. 172.16.8.1) would lose access under PROXY trust: stop and add it to the trust list or find its path.
- [ ] **Step 2: Baseline from outside.** From the user's PC (public internet via the VPS, not the LAN path):
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' --resolve mail.erinko.fi:443:212.147.241.182 https://mail.erinko.fi/healthz/live
  ```
  Expected `200`. Plus `openssl s_client -connect 212.147.241.182:993 -servername mail.erinko.fi -quiet` shows the IMAP greeting, and the same on 465 (SMTP banner), 587 (STARTTLS banner), 995 and 4190.
- [ ] **Step 3: Record the listener ids** with `x:NetworkListener/get` (`name`, `overrideProxyTrustedNetworks`), and save the current `x:Security` singleton for rollback.

### Task 2: Prepare both sides (no effect yet)

**Files:** `vps/config/haproxy.cfg`

- [ ] **Step 1: haproxy config.** Append ` send-proxy-v2` to the `server stalwart` lines of the six backends in the Scope table. Delete the `ft_imap`/`bk_imap` block. Update the `# SMTP inbound` style comments so each changed backend says it sends PROXY v2. Don't apply yet. Check syntax on the VPS:
  ```bash
  scp -P 2222 vps/config/haproxy.cfg root@212.147.241.182:/tmp/haproxy.cfg.new && ssh -p 2222 root@212.147.241.182 'haproxy -c -f /tmp/haproxy.cfg.new && rm /tmp/haproxy.cfg.new'
  ```
  Expected: `Configuration file is valid`.
- [ ] **Step 2: Commit** (don't push yet, so Flux and the VPS stay unchanged): `feat(vps): send PROXY v2 to every Stalwart listener`.
- [ ] **Step 3: Stalwart side.** With the recovery admin, `x:NetworkListener/set` updates the six listener ids with `{"overrideProxyTrustedNetworks": {"172.16.8.2/32": true}}`, and `x:Security/set` updates `singleton` with `{"authBanPeriod": "1d"}` (check the accepted Duration format against the `x:Security/get` output from Task 1; if it wants milliseconds use `86400000`). Read back with `/get`: the six listeners show the new map. This has no effect until the restart.
- [ ] **Step 4: Confirm nothing changed yet:** re-run the Task 1 Step 2 checks; all still succeed.

### Task 3: Switch (one window, ~1 minute of mail-client errors)

- [ ] **Step 1: Restart Stalwart:** `kubectl -n mail rollout restart deploy/stalwart`.
- [ ] **Step 2: While the old pod is terminating and the new one is starting**, push and apply haproxy:
  ```bash
  git push origin HEAD:main && just vps apply
  ```
  (`apply.sh` runs `haproxy -c` and `systemctl reload haproxy` only when the file changed.) Both sides are down or switching at this point, so this adds no outage of its own.
- [ ] **Step 3: Wait for Ready:** `kubectl -n mail rollout status deploy/stalwart --timeout=180s`.

### Task 4: Verify

- [ ] **Step 1: Outside checks** (Task 1 Step 2 commands): all succeed again.
- [ ] **Step 2: Real addresses in the logs.** After a few minutes, tally `listenerId` × `remoteIp` for the last 10 minutes. Expected: the six listeners show public client addresses (including the user's home IP from the Step 1 checks) and no 172.16.8.2.
- [ ] **Step 3: A real sign-in from outside.** The user opens their phone's mail app on mobile data (IMAP + SMTP submission) and sends a message to themselves; it arrives. Logs show the phone carrier's address on `imaps` and `submissions`/`submission`.
- [ ] **Step 4: Inside paths unaffected.** Bulwark sign-in at webmail.erinko.fi works, the admin UI at stalwart-admin.vaderrp.com loads, and inbound mail on 25 still arrives (send from an outside account).
- [ ] **Step 5: Bans attribute correctly.** From the user's PC, three bad IMAP logins with a non-existent user (`openssl s_client` to 993, `a LOGIN nobody@erinko.fi wrong`): `x:BlockedIp` doesn't list 172.16.8.2. (Don't reach the limit of 100; this only checks attribution in the auth-failure log lines, which should show the home IP.)

### Task 5: Record

- [ ] **Step 1:** Add a "Done" note with times and results to this plan; update memory `project_stalwart_1_0_migration.md` (PROXY live, authBanPeriod 1d, 143 removed); commit and push homeops.

**Rollback** (any time): `git revert` the haproxy commit + `just vps apply`; `x:NetworkListener/set` the six listeners back to `{}` and `x:Security/set` `authBanPeriod` back to `null`; `kubectl -n mail rollout restart deploy/stalwart`, applying haproxy while the old pod is down, as in Task 3.

## Done (2026-10-28, 21:22–21:23 UTC)

- Pre-flight: over 24 h the only 172.16.8.x source on the six listeners was 172.16.8.2 (plus one in-cluster pod on imaps). Outside baseline OK on 443/993/995/465/587/4190. Rollback values saved: the six listeners had `{}`, smtp `{"172.16.8.0/24": true}`, `x:Security.authBanPeriod` `null`.
- haproxy aa0b3979c: `send-proxy-v2` on the six backends, port 143 relay removed; `haproxy -c` passed on the VPS. Applied by copying the file and `systemctl reload haproxy` (same steps as `apply.sh`) so the timing could be controlled; the VPS file equals the committed one.
- Stalwart: listeners https, submissions, submission, imaps, pop3s, sieve → `{"172.16.8.2/32": true}`; `authBanPeriod` = 86400000 (1 day; the API takes milliseconds).
- Switch: `rollout restart` at 21:22:36, old pod gone 21:22:40, haproxy reloaded 21:22:42, new pod Ready 21:23:13 — ~37 s of downtime.
- Verified: all six ports answer from outside; Stalwart logs real client addresses (home IPv4 on submission, the user's phone on https, an IPv6 client on pop3s) and no 172.16.8.2; no PROXY errors; admin API/UI, webmail + its SSO start, stalwart-users (vaderrp host) unaffected; ban list unchanged (89). Phone on mobile data synced and delivered a self-sent message.
- Not verified directly: failed IMAP logins aren't logged at INFO, so ban attribution relies on the throwaway-pod test.
