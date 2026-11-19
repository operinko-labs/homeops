#!/usr/bin/env bash
# CrowdSec parser test for edge: bash forge/edge-crowdsec-test.sh [edge-ip]
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

echo "---- $fails failure(s)"
exit $((fails > 0))
