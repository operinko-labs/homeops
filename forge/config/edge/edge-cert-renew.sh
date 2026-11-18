#!/bin/sh
# Obtain or renew the edge certificates (installed as /usr/local/bin/edge-cert-renew
# and linked from /etc/periodic/daily). lego v5's `run` does both: it is a no-op
# until a certificate is due.
#   edge-cert-renew [all|vaderrp|dns] [extra `lego run` flags, e.g. --renew-force]
#
# LAN :53 is DNAT'd to Technitium, whose internal zones (dns.vaderrp.com is one)
# hide the Cloudflare view lego needs to find the zone and check propagation.
# Quad9 also answers on 9953, which the DNAT does not touch, so zone lookup goes
# there. Propagation checks are replaced by a fixed wait (as NPMplus's certbot
# did): the authoritative check would hit Cloudflare's nameservers on :53
# (DNAT'd), and the recursive one sees Quad9's cached TXT set, which lags when
# the wildcard and apex share _acme-challenge.vaderrp.com.
set -eu

which="${1:-all}"
[ $# -gt 0 ] && shift

run() {
	lego --log.format text run \
		--path /var/lib/lego \
		--env-file /etc/edge/lego.env \
		--accept-tos \
		--dns cloudflare \
		--dns.resolvers 9.9.9.9:9953,149.112.112.112:9953 \
		--dns.propagation.wait 90s \
		--deploy-hook /usr/local/bin/edge-cert-hook \
		"$@"
}

case "$which" in
	all | vaderrp) run -d '*.vaderrp.com' -d vaderrp.com "$@" ;;
esac
case "$which" in
	all | dns) run -d '*.dns.vaderrp.com' -d dns.vaderrp.com -d technitium.vaderrp.com "$@" ;;
esac
