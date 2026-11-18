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
routes="$here/config/edge/routes.yaml"
vps_ip="212.147.241.182"
forgejo_ip="192.168.7.30"
fails=0

check() { # name got expected
  if [[ "$2" == "$3" ]]; then echo "OK   $1 $2"; else echo "FAIL $1 got=$2 expected=$3"; fails=$((fails + 1)); fi
}

code() { # host ip [extra curl args...]
  local host="$1" addr="$2"; shift 2
  curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "$host:443:$addr" "$@" "https://$host/" 2>/dev/null || true
}

while IFS=$'\t' read -r host expect; do
  check "$host" "$(code "$host" "$ip")" "$expect"
done < <(yq -r '.edge_routes[] | [.host, .expect] | @tsv' < "$routes")

dash=$(curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "edge.vaderrp.com:443:$ip" https://edge.vaderrp.com/dashboard/ 2>/dev/null || true)
check dashboard "$dash" 401

want_key=$(ssh-keyscan -T 8 -p 22 -t ed25519 "$forgejo_ip" 2>/dev/null | awk '{print $3}')
got_key=$(ssh-keyscan -T 8 -p 22 -t ed25519 "$ip" 2>/dev/null | awk '{print $3}')
check ssh-stream "${got_key:-none}" "${want_key:-forgejo-unreachable}"

sans=$(openssl s_client -connect "$ip:443" -servername technitium.vaderrp.com </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -c 'DNS:technitium.vaderrp.com')
check technitium-cert "$sans" 1

if [[ "$wan" == "--wan" ]]; then
  check wan-forgejo "$(code forgejo.vaderrp.com "$vps_ip")" 303
  for h in pbs.vaderrp.com vaultwarden.vaderrp.com hass.vaderrp.com; do
    got=$(code forgejo.vaderrp.com "$vps_ip" -H "Host: $h")
    # Anything but a 2xx/3xx means the spoofed host was refused.
    if [[ "$got" =~ ^[23] ]]; then check "wan-spoof-$h" "$got" "4xx"; else check "wan-spoof-$h" refused refused; fi
  done
fi

echo "---- $fails failure(s)"
exit $((fails > 0))
