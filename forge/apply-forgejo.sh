#!/usr/bin/env bash
# Idempotent config apply for the forgejo LXC.
# Pushed and executed by `just forge apply-forgejo`; expects app.ini and
# sshd-forgejo.conf beside it.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
UNIT=/etc/systemd/system/forgejo.service
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/60-forgejo.conf
CHANGED=()
RESTART_FORGEJO=0

# --- run user: enforce 'git' so remotes are git@forgejo.vaderrp.com ---------
if ! id git &>/dev/null; then
  if id forgejo &>/dev/null; then
    systemctl stop forgejo
    usermod -l git -d /home/git -m forgejo
    groupmod -n git forgejo 2>/dev/null || true
    sed -i 's/User=forgejo/User=git/; s/Group=forgejo/Group=git/' "$UNIT"
    systemctl daemon-reload
    CHANGED+=("run user forgejo -> git")
    RESTART_FORGEJO=1
  else
    echo "ERROR: neither 'git' nor 'forgejo' user exists" >&2
    exit 1
  fi
fi
grep -q '^User=git$' "$UNIT" || { echo "ERROR: $UNIT does not run as git" >&2; exit 1; }

# --- app.ini -----------------------------------------------------------------
if ! cmp -s "$STAGING/app.ini" /etc/forgejo/app.ini; then
  install -m 640 -o root -g git "$STAGING/app.ini" /etc/forgejo/app.ini
  CHANGED+=("/etc/forgejo/app.ini")
  RESTART_FORGEJO=1
fi

# --- instance signing key ----------------------------------------------------
# Forgejo signs the commits it authors itself with this key. Only the private
# half is in sops; the .pub is derived here so the two halves cannot drift.
# Rotation is not supported by Forgejo, so this key is effectively permanent.
if ! cmp -s "$STAGING/signing.key" /etc/forgejo/signing.key; then
  install -m 600 -o git -g git "$STAGING/signing.key" /etc/forgejo/signing.key
  CHANGED+=("/etc/forgejo/signing.key")
  RESTART_FORGEJO=1
fi
if ! cmp -s <(ssh-keygen -y -f /etc/forgejo/signing.key) /etc/forgejo/signing.key.pub; then
  ssh-keygen -y -f /etc/forgejo/signing.key > /etc/forgejo/signing.key.pub
  chown root:git /etc/forgejo/signing.key.pub
  chmod 644 /etc/forgejo/signing.key.pub
  CHANGED+=("/etc/forgejo/signing.key.pub")
  RESTART_FORGEJO=1
fi

chown -R git:git /var/lib/forgejo

# Settle Forgejo before the sshd work below, so a failure there can never strand
# a pending restart (the next run would see app.ini already in place and skip it).
if ((RESTART_FORGEJO)); then
  systemctl restart forgejo
fi

# --- sshd: connections via the edge proxy (192.168.0.5) are git-only ---------
# Both mutations are staged first, then validated together, then applied.
SSHD_DIRTY=0
DROPIN_WRITTEN=0
if ! grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' "$SSHD_CONFIG"; then
  cp -a "$SSHD_CONFIG" "$SSHD_CONFIG.bak"
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
  CHANGED+=("$SSHD_CONFIG Include")
  SSHD_DIRTY=1
fi
if ! cmp -s "$STAGING/sshd-forgejo.conf" "$SSHD_DROPIN"; then
  if [[ -e "$SSHD_DROPIN" ]]; then cp -a "$SSHD_DROPIN" "$SSHD_DROPIN.bak"; fi
  install -D -m 644 -o root -g root "$STAGING/sshd-forgejo.conf" "$SSHD_DROPIN"
  CHANGED+=("$SSHD_DROPIN")
  SSHD_DIRTY=1
  DROPIN_WRITTEN=1
fi
if ((SSHD_DIRTY)); then
  if ! /usr/sbin/sshd -t; then
    if [[ -e "$SSHD_CONFIG.bak" ]]; then mv "$SSHD_CONFIG.bak" "$SSHD_CONFIG"; fi
    # Only undo the drop-in if THIS run wrote it. When just the Include line was
    # added, the existing drop-in is already correct and must be left alone.
    if ((DROPIN_WRITTEN)); then
      if [[ -e "$SSHD_DROPIN.bak" ]]; then mv "$SSHD_DROPIN.bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    fi
    echo "ERROR: sshd -t rejected the new config; reverted, service untouched" >&2
    exit 1
  fi
  rm -f "$SSHD_CONFIG.bak" "$SSHD_DROPIN.bak"
  # restart, not reload: ssh.service is socket-activated here, and SIGHUP makes
  # the listener re-exec without its systemd-passed FDs and die. KillMode=process
  # keeps established sessions alive across the restart.
  systemctl restart ssh
  systemctl is-active --quiet ssh || { echo "ssh failed to start" >&2; exit 1; }
fi

if ((${#CHANGED[@]})); then
  printf 'changed: %s\n' "${CHANGED[@]}"
else
  echo "no changes"
fi
systemctl is-active --quiet forgejo || { echo "forgejo failed to start" >&2; exit 1; }
