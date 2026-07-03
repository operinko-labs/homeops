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
