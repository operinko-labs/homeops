# `vps/` Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the wg-haproxy mail-relay VPS (haproxy + Postfix + WireGuard + fail2ban + unattended-upgrades) declaratively from this repo via `just vps apply`.

**Architecture:** Config files live in `vps/config/`, the WireGuard private key in SOPS-encrypted `vps/secrets.sops.yaml`. `just vps apply` scps the configs plus an idempotent `apply.sh` to a root-only staging dir on the VPS, streams the rendered `wg0.conf` (sops + minijinja, key never touches local disk), and runs the script, which diff-installs each file and reloads only changed services.

**Tech Stack:** just, sops (age), minijinja-cli, bash, ssh/scp.

**Spec:** `docs/superpowers/specs/2026-07-03-vps-declarative-management-design.md`

## Global Constraints

- Run `just`/`sops`/`minijinja-cli` via WSL: `wsl -e bash -lc "cd /mnt/c/Users/ollie/homeops && <cmd>"`. Plain `just`, never `mise x --` (WSL `just` wraps mise itself). Windows-side mise is broken.
- VPS access: `ssh -p 2222 root@212.147.241.182`. **Read-only** ssh commands are fine to run directly; any command that **mutates the VPS or cluster is run by the user** (the auto-mode permission classifier denies them).
- The decrypted WireGuard private key must never be written to local disk, printed to the terminal, or pasted into chat. Render pipelines stream to the VPS or into `grep -c`.
- Repo `.gitattributes` already forces `eol=lf` on all text files — do not add CRLF-sensitive handling.
- Commits: conventional style (`feat(vps): …`), no AI attribution, no `Co-Authored-By` trailers.
- Age recipient for SOPS: `age18hklnzlqlz0y7tf8gzeh2slv8vxnlyvjcn7e38xsd744s3t9hf0su4lwpx`.

---

### Task 1: SOPS rule and WireGuard secret

**Files:**
- Modify: `.sops.yaml`
- Create: `vps/secrets.sops.yaml` (user-assisted — the secret value comes off the VPS)

**Interfaces:**
- Produces: `vps/secrets.sops.yaml` containing key `vps_wg_private_key` (string), decryptable with the repo age key. Task 3's render and Task 5's `apply` recipe consume it.

- [ ] **Step 1: Add the creation rule**

In `.sops.yaml`, insert after the two `talos/` rules (before the `(bootstrap|kubernetes)` rule):

```yaml
  - path_regex: vps/.*\.sops\.ya?ml
    age: "age18hklnzlqlz0y7tf8gzeh2slv8vxnlyvjcn7e38xsd744s3t9hf0su4lwpx"
```

- [ ] **Step 2: USER STEP — create the secret file**

The user runs (key goes straight from the VPS into the encrypted file):

```bash
# In WSL, from /mnt/c/Users/ollie/homeops:
ssh -p 2222 root@212.147.241.182 "grep '^PrivateKey' /etc/wireguard/wg0.conf | sed 's/PrivateKey = /vps_wg_private_key: /'" > vps/secrets.sops.yaml
sops -e -i vps/secrets.sops.yaml
```

(Plaintext exists on local disk only for the instant between the two commands; acceptable for a user-run bootstrap, same trust level as `age.key` itself.)

- [ ] **Step 3: Verify encryption and round-trip**

```bash
grep -c 'ENC\[AES256_GCM' vps/secrets.sops.yaml          # expect: 1
sops -d vps/secrets.sops.yaml | grep -c '^vps_wg_private_key: .\+'   # expect: 1
```

- [ ] **Step 4: Commit**

```bash
git add .sops.yaml vps/secrets.sops.yaml
git commit -m "feat(vps): add sops rule and wireguard key secret"
```

---

### Task 2: Static config files (current VPS state, captured)

**Files:**
- Create: `vps/config/haproxy.cfg`
- Create: `vps/config/postfix-main.cf`
- Create: `vps/config/fail2ban-jail.local`
- Create: `vps/config/fail2ban-filter-haproxy-http-auth.conf`
- Create: `vps/config/sshd-hardening.conf`

**Interfaces:**
- Produces: staged file names exactly as listed (Task 4's `apply.sh` maps them to targets; Task 5 scps `vps/config/.` wholesale).

- [ ] **Step 1: Write `vps/config/haproxy.cfg`** — byte-identical to the live `/etc/haproxy/haproxy.cfg` so the first apply is a no-op for haproxy:

```
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 10s
    timeout client  300s
    timeout server  300s

# HTTPS / JMAP (port 443)
#frontend ft_https
#    bind :::443
#    default_backend bk_https

#backend bk_https
#    server stalwart 172.16.8.10:443

frontend ft_https
    bind :::443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    # Route webmail.erinko.fi to Traefik (TLS terminated there)
    use_backend bk_traefik if { req_ssl_sni -i webmail.erinko.fi }
    # Everything else goes to Stalwart (mail.erinko.fi, JMAP, etc.)
    default_backend bk_https

backend bk_https
    server stalwart 172.16.8.10:443

backend bk_traefik
    server traefik 172.16.8.11:443

# Submission (port 587)
frontend ft_submission
    bind :::587
    default_backend bk_submission

backend bk_submission
    server stalwart 172.16.8.10:587

# Submissions/SMTPS (port 465)
frontend ft_submissions
    bind :::465
    default_backend bk_submissions

backend bk_submissions
    server stalwart 172.16.8.10:465

# IMAP (port 143)
frontend ft_imap
    bind :::143
    default_backend bk_imap

backend bk_imap
    server stalwart 172.16.8.10:143

# IMAPS (port 993)
frontend ft_imaps
    bind :::993
    default_backend bk_imaps

backend bk_imaps
    server stalwart 172.16.8.10:993

# ManageSieve (port 4190)
frontend ft_sieve
    bind :::4190
    default_backend bk_sieve

backend bk_sieve
    server stalwart 172.16.8.10:4190

# SMTP inbound (port 25) - with PROXY protocol for real client IP
frontend ft_smtp
    bind :::25
    default_backend bk_smtp

backend bk_smtp
    server stalwart 172.16.8.10:25 send-proxy-v2

# POP3S (port 995)
frontend ft_pop3s
    bind :::995
    default_backend bk_pop3s

backend bk_pop3s
    server stalwart 172.16.8.10:995
```

- [ ] **Step 2: Write `vps/config/postfix-main.cf`** — current live `main.cf` **minus** the dead `transport_maps = hash:/etc/postfix/transport` line (the file it references does not exist):

```
# Relay Postfix config for Stalwart mail
compatibility_level = 3.9

# Hostname and origin
myhostname = wg-haproxy.vaderrp.com
myorigin = $myhostname

smtpd_banner = $myhostname ESMTP

# Listen on WireGuard + public interfaces
inet_interfaces = 172.16.8.2
inet_protocols = ipv4

# Trust Stalwart on WireGuard network
mynetworks = 172.16.8.0/24

# No local delivery - relay only
mydestination =
local_transport = error:no local delivery
local_recipient_maps =

# Relay inbound mail for vaderrp.com to Stalwart
relay_domains =

# No relay host for outbound - deliver directly
relayhost =

# TLS for outbound
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_security_level = may
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

# No inbound TLS on WG, optional on public
smtpd_tls_security_level = none

# Relay restrictions
smtpd_relay_restrictions = permit_mynetworks reject_unauth_destination

# Limits
mailbox_size_limit = 0
message_size_limit = 52428800

# Disable local aliases
alias_maps =
alias_database =
smtp_helo_name = mail.vaderrp.com
```

- [ ] **Step 3: Write `vps/config/fail2ban-jail.local`** — byte-identical to live `/etc/fail2ban/jail.local`:

```
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport
ignoreip = 127.0.0.1/8 ::1 80.223.184.52 192.168.0.0/16 172.16.8.0/24 10.42.0.0/16

[sshd]
enabled = true
port = 22,2222
mode = aggressive
maxretry = 3
bantime = 24h

[haproxy-http-auth]
enabled = true
port = 443,587,465,993,143,25,4190
filter = haproxy-http-auth
logpath = /var/log/haproxy.log
maxretry = 5
bantime = 1h
findtime = 5m

[postfix]
enabled = true
port = 25
filter = postfix[mode=aggressive]
logpath = /var/log/mail.log
maxretry = 3
bantime = 1h
findtime = 10m
backend = auto

[postfix-sasl]
enabled = true
port = 25
filter = postfix[mode=auth]
logpath = /var/log/mail.log
maxretry = 3
bantime = 24h
findtime = 10m
backend = auto
```

- [ ] **Step 4: Write `vps/config/fail2ban-filter-haproxy-http-auth.conf`** — byte-identical to live `/etc/fail2ban/filter.d/haproxy-http-auth.conf`:

```
[Definition]
# Ban clients that cause too many connection errors or TLS failures
failregex = ^.* <HOST>:\d+ .* (503|502|408|400) \d+.*$
ignoreregex =
```

- [ ] **Step 5: Write `vps/config/sshd-hardening.conf`** — new drop-in (target `/etc/ssh/sshd_config.d/60-homeops.conf`). Ubuntu includes `sshd_config.d` at the top of `sshd_config`, so these win for first-match keywords; `apply.sh` comments out the duplicate `Port` in the main config (Port is additive, not first-match):

```
# Managed by homeops vps/ module - do not edit on the host
Port 2222
PasswordAuthentication no
PermitRootLogin prohibit-password
```

- [ ] **Step 6: Verify repo copies match the live host (read-only ssh)**

```bash
# In WSL from the repo root; expect: no output from the first three diffs
ssh -p 2222 root@212.147.241.182 'cat /etc/haproxy/haproxy.cfg' | diff - vps/config/haproxy.cfg
ssh -p 2222 root@212.147.241.182 'cat /etc/fail2ban/jail.local' | diff - vps/config/fail2ban-jail.local
ssh -p 2222 root@212.147.241.182 'cat /etc/fail2ban/filter.d/haproxy-http-auth.conf' | diff - vps/config/fail2ban-filter-haproxy-http-auth.conf
# Expect exactly two removed lines (the transport comment is kept, the setting removed):
ssh -p 2222 root@212.147.241.182 'cat /etc/postfix/main.cf' | diff - vps/config/postfix-main.cf
```

Expected postfix diff: only `< transport_maps = hash:/etc/postfix/transport` (and its adjacency). If any other file differs, the live host changed since capture — update the repo copy to match and re-verify.

- [ ] **Step 7: Commit**

```bash
git add vps/config/
git commit -m "feat(vps): capture haproxy, postfix, fail2ban and sshd configs"
```

---

### Task 3: WireGuard template and update-automation configs

**Files:**
- Create: `vps/config/wg0.conf.j2`
- Create: `vps/config/apt-20auto-upgrades`
- Create: `vps/config/apt-52-auto-reboot.conf`
- Create: `vps/config/needrestart-50-auto.conf`

**Interfaces:**
- Consumes: `vps_wg_private_key` from Task 1's `vps/secrets.sops.yaml`.
- Produces: staged names consumed by Task 4 (`wg0.conf` arrives rendered — the `.j2` itself is never installed).

- [ ] **Step 1: Write `vps/config/wg0.conf.j2`** — live `/etc/wireguard/wg0.conf` with the key templated (peer `zFEcLX…` is talos7's public key, rotated 2026-07-03):

```
[Interface]
PrivateKey = {{ vps_wg_private_key }}
Address = 172.16.8.2/32
MTU = 1420
Table = off
PostUp = ip route add 172.16.8.0/24 dev wg0; ip route add 10.96.0.0/16 dev wg0; ip route add 10.42.0.0/16 dev wg0
PostDown = ip route del 172.16.8.0/24 dev wg0; ip route del 10.96.0.0/16 dev wg0; ip route del 10.42.0.0/16 dev wg0

[Peer]
PublicKey = zFEcLX+tpfWVbgelxPQz0ljctGTskPTKmxZ7rh308Bg=
AllowedIPs = 172.16.8.0/24, 10.96.0.0/16, 10.42.0.0/16
PersistentKeepalive = 25
Endpoint = 80.223.184.52:51820
```

- [ ] **Step 2: Write `vps/config/apt-20auto-upgrades`** (target `/etc/apt/apt.conf.d/20auto-upgrades`, matches live):

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

- [ ] **Step 3: Write `vps/config/apt-52-auto-reboot.conf`** (target `/etc/apt/apt.conf.d/52-homeops-auto-reboot.conf`, new file; `apply.sh` sets the host timezone to Europe/Helsinki so 04:30 is local — the box currently runs Etc/UTC):

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
```

- [ ] **Step 4: Write `vps/config/needrestart-50-auto.conf`** (target `/etc/needrestart/conf.d/50-homeops.conf`, new file — restart services automatically after library upgrades instead of prompting):

```perl
# Managed by homeops vps/ module
$nrconf{restart} = 'a';
```

- [ ] **Step 5: Verify the render (key stays out of the terminal)**

```bash
# In WSL from the repo root
sops -d vps/secrets.sops.yaml | minijinja-cli vps/config/wg0.conf.j2 --format yaml - | grep -c '^PrivateKey = .\+='
# expect: 1
sops -d vps/secrets.sops.yaml | minijinja-cli vps/config/wg0.conf.j2 --format yaml - | grep -c '{{'
# expect: 0
```

Also verify the render matches the live file except nothing (the live file already has the real key), by comparing everything but the key line:

```bash
diff <(sops -d vps/secrets.sops.yaml | minijinja-cli vps/config/wg0.conf.j2 --format yaml - | grep -v '^PrivateKey') \
     <(ssh -p 2222 root@212.147.241.182 "grep -v '^PrivateKey' /etc/wireguard/wg0.conf")
# expect: no output
```

- [ ] **Step 6: Commit**

```bash
git add vps/config/
git commit -m "feat(vps): add wireguard template and unattended-upgrade configs"
```

---

### Task 4: `apply.sh`

**Files:**
- Create: `vps/apply.sh`

**Interfaces:**
- Consumes: staged files from Tasks 2–3 in the same directory as the script (`/root/.homeops-staging/` at runtime), including rendered `wg0.conf`.
- Produces: idempotent convergence; prints `changed: <item>` lines or `no changes`. Task 5 invokes it as `bash /root/.homeops-staging/apply.sh`.

- [ ] **Step 1: Write `vps/apply.sh`**

```bash
#!/usr/bin/env bash
# Idempotent config apply for the wg-haproxy VPS.
# Pushed and executed by `just vps apply`; expects its config files beside it.
set -euo pipefail

STAGING="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
CHANGED=()

# --- packages ---------------------------------------------------------------
PACKAGES=(haproxy postfix wireguard fail2ban unattended-upgrades needrestart)
missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
done
if ((${#missing[@]})); then
  echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
  CHANGED+=("packages: ${missing[*]}")
fi

# --- timezone (Automatic-Reboot-Time is host-local) -------------------------
if [[ "$(timedatectl show -p Timezone --value)" != "Europe/Helsinki" ]]; then
  timedatectl set-timezone Europe/Helsinki
  CHANGED+=("timezone -> Europe/Helsinki")
fi

# install_file <staged-name> <target-path> <mode>; returns 0 iff file changed
install_file() {
  local src="$STAGING/$1" dst="$2" mode="$3"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -m "$mode" -D "$src" "$dst"
    CHANGED+=("$dst")
    return 0
  fi
  return 1
}

# --- haproxy -----------------------------------------------------------------
if install_file haproxy.cfg /etc/haproxy/haproxy.cfg 644; then
  haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl reload haproxy
fi

# --- postfix -----------------------------------------------------------------
if install_file postfix-main.cf /etc/postfix/main.cf 644; then
  postfix check
  systemctl reload postfix
fi

# --- wireguard ---------------------------------------------------------------
if install_file wg0.conf /etc/wireguard/wg0.conf 600; then
  systemctl restart wg-quick@wg0
fi

# --- sshd --------------------------------------------------------------------
if install_file sshd-hardening.conf /etc/ssh/sshd_config.d/60-homeops.conf 644; then
  # Port is additive across config files; the drop-in owns it now.
  sed -i 's|^Port 2222$|#Port 2222 (managed in sshd_config.d/60-homeops.conf)|' /etc/ssh/sshd_config
  sshd -t
  systemctl daemon-reload
  systemctl restart ssh
fi

# --- fail2ban ----------------------------------------------------------------
f2b_changed=0
if install_file fail2ban-jail.local /etc/fail2ban/jail.local 644; then f2b_changed=1; fi
if install_file fail2ban-filter-haproxy-http-auth.conf /etc/fail2ban/filter.d/haproxy-http-auth.conf 644; then f2b_changed=1; fi
if ((f2b_changed)); then systemctl reload fail2ban; fi

# --- unattended upgrades / needrestart (no reload needed) --------------------
install_file apt-20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades 644 || true
install_file apt-52-auto-reboot.conf /etc/apt/apt.conf.d/52-homeops-auto-reboot.conf 644 || true
install_file needrestart-50-auto.conf /etc/needrestart/conf.d/50-homeops.conf 644 || true

# --- ensure everything is enabled ---------------------------------------------
systemctl enable --quiet haproxy postfix fail2ban wg-quick@wg0 unattended-upgrades

# --- report -------------------------------------------------------------------
if ((${#CHANGED[@]})); then
  printf 'changed: %s\n' "${CHANGED[@]}"
else
  echo "no changes"
fi
```

- [ ] **Step 2: Syntax-check the script**

```bash
# In WSL from the repo root
bash -n vps/apply.sh && echo SYNTAX_OK    # expect: SYNTAX_OK
shellcheck vps/apply.sh || true           # advisory if shellcheck present; fix real findings
```

- [ ] **Step 3: Commit**

```bash
git add vps/apply.sh
git commit -m "feat(vps): add idempotent apply script"
```

---

### Task 5: `vps/mod.just` and root registration

**Files:**
- Create: `vps/mod.just`
- Modify: `.justfile` (root — add one `mod` line after `mod talos "talos"`)

**Interfaces:**
- Consumes: `vps/secrets.sops.yaml` (Task 1), `vps/config/*` (Tasks 2–3), `vps/apply.sh` (Task 4).
- Produces: `just vps apply [port]` and `just vps ssh`. `VPS_HOST` env var overrides the target for disaster-recovery runs.

- [ ] **Step 1: Write `vps/mod.just`**

```just
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

vps_dir := justfile_dir() + '/vps'
host := env('VPS_HOST', 'root@212.147.241.182')

[private]
default:
    just -l vps

[doc('Apply VPS configuration (pass port=22 for first run on a fresh box)')]
apply port='2222':
    ssh -p {{ port }} {{ host }} 'mkdir -p -m 700 /root/.homeops-staging'
    scp -P {{ port }} -q {{ vps_dir }}/config/haproxy.cfg {{ vps_dir }}/config/postfix-main.cf {{ vps_dir }}/config/sshd-hardening.conf {{ vps_dir }}/config/fail2ban-jail.local {{ vps_dir }}/config/fail2ban-filter-haproxy-http-auth.conf {{ vps_dir }}/config/apt-20auto-upgrades {{ vps_dir }}/config/apt-52-auto-reboot.conf {{ vps_dir }}/config/needrestart-50-auto.conf {{ vps_dir }}/apply.sh {{ host }}:/root/.homeops-staging/
    sops -d {{ vps_dir }}/secrets.sops.yaml | minijinja-cli {{ vps_dir }}/config/wg0.conf.j2 --format yaml - | ssh -p {{ port }} {{ host }} 'umask 077; cat > /root/.homeops-staging/wg0.conf'
    ssh -p {{ port }} {{ host }} 'bash /root/.homeops-staging/apply.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('SSH into the VPS')]
ssh:
    ssh -p 2222 {{ host }}
```

- [ ] **Step 2: Register the module in the root `.justfile`**

Add after `mod talos "talos"`:

```just
mod vps "vps"
```

- [ ] **Step 3: Verify recipe listing and a dry parse**

```bash
# In WSL from the repo root
just vps            # expect: lists apply and ssh recipes, no parse errors
just -n vps apply   # dry-run; expect: prints the ssh/scp/sops command lines without executing
```

- [ ] **Step 4: Commit**

```bash
git add vps/mod.just .justfile
git commit -m "feat(vps): add just module with push-based apply"
```

---

### Task 6: Live apply and verification (user-gated)

**Files:** none (execution only; fix-up commits if verification finds drift)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: USER STEP — first live apply**

```bash
# In WSL from the repo root
just vps apply
```

Expected `changed:` lines — exactly these and nothing else:
- `timezone -> Europe/Helsinki`
- `/etc/postfix/main.cf` (transport_maps removed)
- `/etc/ssh/sshd_config.d/60-homeops.conf` (new)
- `/etc/apt/apt.conf.d/52-homeops-auto-reboot.conf` (new)
- `/etc/needrestart/conf.d/50-homeops.conf` (new)
- possibly `/etc/apt/apt.conf.d/20auto-upgrades` (comment/whitespace variance)

`haproxy.cfg`, `wg0.conf`, and both fail2ban files must report **no change** (they were captured byte-identical — an unexpected change here means the WireGuard tunnel restarts; not fatal, but investigate before re-running). The ssh session must survive the sshd restart (port stays 2222).

- [ ] **Step 2: USER STEP — idempotence check**

```bash
just vps apply
```

Expected output ends with: `no changes`

- [ ] **Step 3: Verify mail path end-to-end (read-only, agent can run)**

```powershell
$c=New-Object Net.Sockets.TcpClient; $c.ConnectAsync('mail.erinko.fi',25).Wait(5000) | Out-Null; $s=$c.GetStream(); $s.ReadTimeout=8000; $b=New-Object byte[] 256; $n=$s.Read($b,0,256); [Text.Encoding]::ASCII.GetString($b,0,$n).Trim(); $c.Close()
```

Expected: `220 mail.erinko.fi Stalwart ESMTP at your service`

- [ ] **Step 4: Verify update automation (read-only)**

```bash
ssh -p 2222 root@212.147.241.182 "timedatectl show -p Timezone --value; apt-config dump | grep -E 'Automatic-Reboot |Automatic-Reboot-Time'; unattended-upgrade --dry-run 2>&1 | tail -2; echo rc=\$?"
```

Expected: `Europe/Helsinki`, `Automatic-Reboot "true"`, `Automatic-Reboot-Time "04:30"`, dry-run rc=0.

- [ ] **Step 5: Commit any fix-ups**

If verification required config corrections, commit them:

```bash
git add vps/
git commit -m "fix(vps): reconcile captured configs with live host"
```

---

### Task 7 (optional, fulfils spec success criterion 2): disaster-recovery rehearsal

**Files:** none

Run when convenient — costs a few cents of hourly billing:

- [ ] **Step 1: USER STEP** — create a throwaway UpCloud VM (smallest plan, Ubuntu 26.04, your SSH key), note its IP.
- [ ] **Step 2: USER STEP** — `VPS_HOST=root@<new-ip> just vps apply port=22`
- [ ] **Step 3: Verify** — `ssh -p 2222 root@<new-ip> 'wg show wg0; systemctl is-active haproxy postfix fail2ban'`. Expected: wg0 up with peer `zFEcLX…` and a recent handshake (the VPS initiates toward home, so no talos-side change is needed — same WG identity from sops), all three services `active`. Full inbound traffic would additionally need the `mail.erinko.fi` A record repointed — do **not** do that in a rehearsal.
- [ ] **Step 4: USER STEP** — destroy the throwaway VM.

---

## Self-review notes

- Spec §1 (layout) → Tasks 1–5; §2 (apply flow) → Tasks 4–5; §3 (updates/reboots) → Task 3 configs + Task 4 timezone/enable + Task 6 verification; §4 (key rotation) already completed pre-plan; §5 (allowed-ips) intentionally absent (deferred by spec). Success criteria 1/3/4 → Task 6; criterion 2 → Task 7.
- `wg0.conf` is rendered and streamed, never written locally; `secrets.sops.yaml` plaintext exists only momentarily during the user-run Task 1 bootstrap.
- Staged filenames in Task 5's scp list match Task 2/3 creations and Task 4's `install_file` calls one-to-one (`wg0.conf` arrives via the render pipe, `wg0.conf.j2` is deliberately not pushed).
