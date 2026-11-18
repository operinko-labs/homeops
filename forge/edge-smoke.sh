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

# --- real client IPs (docs/superpowers/specs/2026-11-19-edge-real-client-ip-design.md)
# Each probe carries ?smoke=<token>; logged() reads that request's JSON
# access-log line on the edge LXC and prints one field.
token() { echo "$(date +%s)$RANDOM"; }
logged() { # token field
  sleep 1
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p 2222 "root@$ip" \
    "grep -F 'smoke=$1' /var/log/traefik/access.log | tail -1" 2>/dev/null \
    | python3 -c "import sys,json; l=sys.stdin.read().strip(); print(json.loads(l).get('$2','') if l else '')"
}

# A LAN client forging CF-Connecting-IP must keep its own address.
t=$(token)
curl -sk -o /dev/null -m 10 --resolve "photos.vaderrp.com:443:$ip" -H 'CF-Connecting-IP: 1.2.3.4' \
  "https://photos.vaderrp.com/?smoke=$t" || true
xr=$(logged "$t" request_X-Real-Ip)
if [[ "$xr" == 192.168.* ]]; then check real-ip-spoof "$xr" "$xr"; else check real-ip-spoof "${xr:-none}" "192.168.x"; fi

if [[ "$wan" == "--wan" ]]; then
  # Home WAN IP as the VPS sees it, and the real Cloudflare path (Quad9 :9953
  # escapes the LAN :53 DNAT, so this resolves to Cloudflare, not edge).
  wan_ip=$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p "$vps_ssh_port" "root@$vps_ip" 'echo ${SSH_CLIENT%% *}' 2>/dev/null)
  cf_ip=$(dig +short -p 9953 photos.vaderrp.com @9.9.9.9 | grep -E '^[0-9.]+$' | head -1)
  t=$(token)
  curl -sk -o /dev/null -m 15 --resolve "photos.vaderrp.com:443:$cf_ip" "https://photos.vaderrp.com/?smoke=$t" || true
  check real-ip-cloudflare "$(logged "$t" request_X-Real-Ip)" "${wan_ip:-unknown}"
  check cf-allowlist-nodered "$(curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "nodered.vaderrp.com:443:$cf_ip" https://nodered.vaderrp.com/)" 403
  # auth: oidc routes: a browser outside the LAN is sent to Authentik first,
  # even when it forges headers claiming a LAN address (warp rewrites them);
  # their LAN answer is the per-route check at the top.
  forged="-H 'X-Real-Ip: 192.168.0.10' -H 'X-Forwarded-For: 192.168.0.10' -H 'CF-Connecting-IP: 192.168.0.10'"
  while IFS= read -r host; do
    got=$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p "$vps_ssh_port" "root@$vps_ip"       "curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' -m 10 -H 'Accept: text/html' $forged --resolve $host:443:$edge_wg_ip https://$host/" 2>/dev/null || true)
    if [[ "$got" == "302 https://auth.vaderrp.com/"* ]]; then check "oidc-required-from-vps-$host" 302-auth 302-auth; else check "oidc-required-from-vps-$host" "${got:-none}" "302 https://auth.vaderrp.com/..."; fi
    # Non-browser clients (no text/html in Accept) get a flat 401, not a redirect.
    got=$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p "$vps_ssh_port" "root@$vps_ip"       "curl -sk -o /dev/null -w '%{http_code}' -m 10 $forged --resolve $host:443:$edge_wg_ip https://$host/" 2>/dev/null || true)
    check "oidc-api-401-from-vps-$host" "${got:-none}" 401
    # Cloudflare itself refuses a client-supplied CF-Connecting-IP (403), so the
    # Cloudflare probe forges only the headers it passes through.
    got=$(curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' -m 15 -H 'Accept: text/html'       -H 'X-Real-Ip: 192.168.0.10' -H 'X-Forwarded-For: 192.168.0.10' --resolve "$host:443:$cf_ip" "https://$host/" || true)
    if [[ "$got" == "302 https://auth.vaderrp.com/"* ]]; then check "oidc-required-cloudflare-$host" 302-auth 302-auth; else check "oidc-required-cloudflare-$host" "${got:-none}" "302 https://auth.vaderrp.com/..."; fi
  done < <(yq -r '.edge_routes[] | select(.auth == "oidc") | .host' < "$routes" 2>/dev/null)
  # VPS path: haproxy's PROXY v2 header must give Traefik the real client.
  t=$(token)
  curl -sk -o /dev/null -m 15 --resolve "forgejo.vaderrp.com:443:$vps_ip" "https://forgejo.vaderrp.com/?smoke=$t" || true
  check real-ip-vps "$(logged "$t" ClientHost)" "${wan_ip:-unknown}"
fi

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
  # Routes marked public: true (reached via Cloudflare -> UDM :443 forward)
  # must answer non-LAN clients normally.
  while IFS=$'\t' read -r host expect; do
    got=$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p "$vps_ssh_port" "root@$vps_ip" \
      "curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve $host:443:$edge_wg_ip https://$host/" 2>/dev/null || true)
    check "public-from-vps-$host" "${got:-none}" "$expect"
  done < <(yq -r '.edge_routes[] | select(.public) | [.host, .expect] | @tsv' < "$routes" 2>/dev/null)
fi

echo "---- $fails failure(s)"
exit $((fails > 0))
