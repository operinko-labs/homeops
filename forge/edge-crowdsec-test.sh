#!/usr/bin/env bash
# CrowdSec test for edge: bash forge/edge-crowdsec-test.sh [edge-ip] [--live]
#
# Feeds the fixture access-log lines in forge/config/edge/crowdsec/tests/ to
# `cscli explain` on the edge LXC and checks which IP CrowdSec would act on:
#   cf.log   Cloudflare path: the visitor (X-Real-Ip), never the Cloudflare node
#   vps.log  VPS path: the PROXY-protocol client
#   lan.log  LAN client: whitelisted
# Run from WSL. Exits non-zero on any FAIL.
set -uo pipefail

ip="${1:-192.168.0.5}"
here="$(cd "$(dirname "$0")" && pwd)"
fails=0

check() { # name got expected
  if [[ "$2" == "$3" ]]; then echo "OK   $1 $2"; else echo "FAIL $1 got=$2 expected=$3"; fails=$((fails + 1)); fi
}

explain() { # fixture -> cscli explain output
  ssh -o BatchMode=yes -o ConnectTimeout=8 -p 2222 "root@$ip" \
    'f=$(mktemp); cat > "$f"; cscli explain --file "$f" --type traefik --verbose 2>&1; rm -f "$f"' \
    < "$here/config/edge/crowdsec/tests/$1"
}

# The last value explain shows for evt.Meta.source_ip, i.e. what scenarios bucket on.
source_ip() { grep -oE 'evt\.Meta\.source_ip : ([^ ]+ -> )?[0-9a-f.:]+' | tail -1 | awk '{print $NF}'; }
whitelisted() { grep -qiE 'whitelisted|ignored by whitelist' && echo yes || echo no; }

out=$(explain cf.log)
check cf-source-ip "$(source_ip <<<"$out")" 203.0.113.50
check cf-not-whitelisted "$(whitelisted <<<"$out")" no
check cf-reaches-scenarios "$(grep -c 'parser success' <<<"$out" | awk '{print ($1>0)?"yes":"no"}')" yes

out=$(explain vps.log)
check vps-source-ip "$(source_ip <<<"$out")" 198.51.100.7
check vps-not-whitelisted "$(whitelisted <<<"$out")" no

out=$(explain lan.log)
check lan-whitelisted "$(whitelisted <<<"$out")" yes

# --live: the bouncer on the real paths (takes ~5 minutes; briefly bans the
# VPS's public IP, which is the test client for both public entrypoints, and
# stops CrowdSec for the fail-open check).
if [[ "${2:-}" == "--live" ]]; then
  vps_ip="212.147.241.182"
  edge() { ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p 2222 "root@$ip" "$@" 2>/dev/null; }
  vps() { ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p 2222 "root@$vps_ip" "$@" 2>/dev/null; }
  cf_ip=$(dig +short -p 9953 photos.vaderrp.com @9.9.9.9 | grep -E '^[0-9.]+$' | head -1)
  # From the VPS: photos via Cloudflare (X-Real-Ip = VPS) and Forgejo via its
  # own haproxy (PROXY client = VPS).
  via_cf() { vps "curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve photos.vaderrp.com:443:$cf_ip https://photos.vaderrp.com/"; }
  via_vps() { vps "curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve forgejo.vaderrp.com:443:$vps_ip https://forgejo.vaderrp.com/"; }
  wait_for() { # want fn... : poll up to 90s until every fn prints want
    local want="$1" t; shift
    for t in $(seq 1 18); do
      local all=1 f; for f in "$@"; do [[ "$($f)" == "$want" ]] || all=0; done
      ((all)) && { echo "$want"; return; }
      sleep 5
    done
    echo "timeout:$(for f in "$@"; do printf '%s,' "$($f)"; done)"
  }

  check bouncer-before-cf "$(via_cf)" 200
  check bouncer-before-vps "$(via_vps)" 303

  edge "cscli decisions add -i $vps_ip -d 4m -R homeops-smoke-test" >/dev/null
  check crowdsec-ban "$(wait_for 403 via_cf via_vps)" 403
  edge "cscli decisions delete -i $vps_ip" >/dev/null
  check crowdsec-unban-cf "$(wait_for 200 via_cf)" 200
  check crowdsec-unban-vps "$(wait_for 303 via_vps)" 303

  # Fail open: with CrowdSec down for longer than the 60s stream interval,
  # the public paths keep answering.
  edge "rc-service crowdsec stop" >/dev/null
  sleep 75
  check crowdsec-fail-open-cf "$(via_cf)" 200
  check crowdsec-fail-open-vps "$(via_vps)" 303
  edge "rc-service crowdsec start" >/dev/null
  sleep 10

  # No self-ban: a burst of 404s from the LAN and via Cloudflare from home
  # (whose X-Real-Ip is the home WAN IP) must not produce a decision.
  wan_ip=$(vps 'echo ${SSH_CLIENT%% *}')
  for n in $(seq 1 30); do
    curl -sk -o /dev/null -m 5 --resolve "photos.vaderrp.com:443:$ip" "https://photos.vaderrp.com/.env-lan-$n" || true
    curl -sk -o /dev/null -m 5 --resolve "photos.vaderrp.com:443:$cf_ip" "https://photos.vaderrp.com/.env-cf-$n" || true
  done
  sleep 10
  lan_ip=$(edge "grep -F '.env-lan-30' /var/log/traefik/access.log | tail -1" \
    | python3 -c "import sys,json; l=sys.stdin.read().strip(); print(json.loads(l)['ClientHost'] if l else '')")
  check self-ban-lan "$(edge "cscli decisions list -i ${lan_ip:-192.168.0.84} -o raw" | grep -c ban)" 0
  check self-ban-wan "$(edge "cscli decisions list -i ${wan_ip:-0.0.0.0} -o raw" | grep -c ban)" 0
fi

echo "---- $fails failure(s)"
exit $((fails > 0))
