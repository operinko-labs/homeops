#!/usr/bin/env bash
# Smoke test for the edge proxy: bash forge/edge-smoke.sh <lan-ip> [--wan]
#
# Checks every route in forge/config/edge/routes.yaml through <lan-ip>:443, the
# dashboard (401 without credentials), the :22 git-SSH stream (must present
# Forgejo's own host key) and the technitium certificate SANs. --wan adds the
# public VPS path, where only forgejo.vaderrp.com may answer.
# Run from WSL (needs curl, yq, ssh-keyscan, openssl). Exits non-zero on any FAIL.
set -uo pipefail

ip="${1:?usage: edge-smoke.sh <lan-ip> [--wan]}"
wan="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
routes="${EDGE_ROUTES:-$here/config/edge/routes.yaml}"
vps_ip="212.147.241.182"
vps_ssh_port="2222"
edge_wg_ip="172.16.8.20"
forgejo_ip="192.168.7.30"
fails=0

check() { # name got expected
  if [[ "$2" == "$3" ]]; then echo "OK   $1 $2"; else echo "FAIL $1 got=$2 expected=$3"; fails=$((fails + 1)); fi
}

code() { # host ip [extra curl args...]
  local host="$1" addr="$2"; shift 2
  curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "$host:443:$addr" "$@" "https://$host/" 2>/dev/null || true
}

read_count=0
while IFS=$'\t' read -r host expect; do
  check "$host" "$(code "$host" "$ip")" "$expect"
  read_count=$((read_count + 1))
done < <(yq -r '.edge_routes[] | [.host, .expect] | @tsv' < "$routes" 2>/dev/null)
# A missing or failing yq would otherwise skip every route check and pass.
want_count=$(grep -c '^  - name:' "$routes")
check routes-read "$read_count" "${want_count:-?}"
[[ "$read_count" -gt 0 ]] || check routes-read 0 ">0"

# routes.yaml promises only forgejo is published on the VPS entrypoint.
wan_routes=$(yq -r '[.edge_routes[] | select(.wan) | .name] | join(",")' < "$routes" 2>/dev/null)
check wan-only-forgejo "${wan_routes:-none}" forgejo

dash=$(curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "edge.vaderrp.com:443:$ip" https://edge.vaderrp.com/dashboard/ 2>/dev/null || true)
check dashboard "$dash" 401

want_key=$(ssh-keyscan -T 8 -p 22 -t ed25519 "$forgejo_ip" 2>/dev/null | awk '{print $3}')
got_key=$(ssh-keyscan -T 8 -p 22 -t ed25519 "$ip" 2>/dev/null | awk '{print $3}')
check ssh-stream "${got_key:-none}" "${want_key:-forgejo-unreachable}"

# technitium.vaderrp.com may get either the wildcard or the *.dns cert (both are
# valid for it); what matters is that the cert verifies for the name, and that the
# *.dns cert (the one Technitium's cert-sync exports) is loaded at all.
verify=$(openssl s_client -connect "$ip:443" -servername technitium.vaderrp.com \
  -verify_hostname technitium.vaderrp.com -verify_return_error </dev/null 2>/dev/null \
  | grep -q 'Verify return code: 0 (ok)' && echo 1 || echo 0)
check technitium-cert-valid "$verify" 1
dnscert=$(openssl s_client -connect "$ip:443" -servername ns1.dns.vaderrp.com </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -c 'DNS:technitium.vaderrp.com')
check dns-cert-loaded "$dnscert" 1

if [[ "$wan" == "--wan" ]]; then
  check wan-forgejo "$(code forgejo.vaderrp.com "$vps_ip")" 303
  for h in pbs.vaderrp.com vaultwarden.vaderrp.com hass.vaderrp.com; do
    # The wan entrypoint has no router for these hosts: Traefik's own 404.
    check "wan-spoof-$h" "$(code forgejo.vaderrp.com "$vps_ip" -H "Host: $h")" 404
  done
  # From the VPS (172.16.8.2, outside the LAN range) straight at the LAN
  # entrypoint over WireGuard: the lan-only allowlist must answer 403.
  lan=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$vps_ssh_port" "root@$vps_ip" \
    "curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve hass.vaderrp.com:443:$edge_wg_ip https://hass.vaderrp.com/" 2>/dev/null || true)
  check lan-only-from-vps "${lan:-none}" 403
fi

echo "---- $fails failure(s)"
exit $((fails > 0))
