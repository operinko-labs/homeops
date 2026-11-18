#!/bin/sh
# Idempotent setup of the edge LXC (Alpine + OpenRC): Traefik + lego, no Docker.
# Pushed and executed by `just forge apply-edge`; expects its files beside it.
set -eu

# The documented rollback puts npmplus (LXC 107) back on 192.168.0.5 with the
# same SSH host keys, so `just forge apply-edge` could silently land there.
[ "$(hostname)" = edge ] || {
	echo "apply-edge: not the edge LXC (hostname is $(hostname)); refusing" >&2
	exit 1
}

S="$(cd "$(dirname "$0")" && pwd)"
CHANGED=""
RESTART=""
. "$S/versions.env"

# install <src> <dst> <mode> <owner> [restart]
# Atomic: the temp copy lives in the staging dir, so nothing half-written ever
# appears in a directory Traefik watches.
install_file() {
	if ! cmp -s "$1" "$2" 2>/dev/null; then
		mkdir -p "$(dirname "$2")"
		cp "$1" "$S/.install.tmp"
		chmod "$3" "$S/.install.tmp"
		chown "$4" "$S/.install.tmp"
		mv -f "$S/.install.tmp" "$2"
		CHANGED="$CHANGED $(basename "$2")"
		[ "${5:-}" = restart ] && RESTART=1
	fi
	return 0
}

# fetch <tarball-url> <checksums-url> <binary-name>: verified binary to /usr/local/bin
fetch() {
	d="$(mktemp -d)"
	tarball="$(basename "$1")"
	curl -fsSL -o "$d/$tarball" "$1"
	curl -fsSL -o "$d/checksums.txt" "$2"
	(cd "$d" && grep " $tarball\$" checksums.txt | sha256sum -c -s -) || {
		echo "checksum mismatch for $tarball" >&2
		rm -rf "$d"
		exit 1
	}
	tar -xzf "$d/$tarball" -C "$d" "$3"
	install -m 0755 "$d/$3" "/usr/local/bin/$3"
	rm -rf "$d"
}

grep -q '^traefik:' /etc/group || addgroup -S traefik
id traefik >/dev/null 2>&1 || adduser -S -D -H -G traefik -s /sbin/nologin traefik

if ! /usr/local/bin/traefik version 2>/dev/null | grep -Eq "^Version: +${TRAEFIK_VERSION#v}\$"; then
	base="https://github.com/traefik/traefik/releases/download/$TRAEFIK_VERSION"
	fetch "$base/traefik_${TRAEFIK_VERSION}_linux_amd64.tar.gz" "$base/traefik_${TRAEFIK_VERSION}_checksums.txt" traefik
	CHANGED="$CHANGED traefik-$TRAEFIK_VERSION"
	RESTART=1
fi
# File capabilities are lost whenever the binary is replaced; re-apply every run.
setcap cap_net_bind_service=+ep /usr/local/bin/traefik

if ! /usr/local/bin/lego --version 2>/dev/null | grep -q "lego version ${LEGO_VERSION#v} "; then
	base="https://github.com/go-acme/lego/releases/download/$LEGO_VERSION"
	fetch "$base/lego_${LEGO_VERSION}_linux_amd64.tar.gz" "$base/lego_${LEGO_VERSION#v}_checksums.txt" lego
	CHANGED="$CHANGED lego-$LEGO_VERSION"
fi

# traefik-warp as a local plugin: fetched here, at apply time, so a Traefik
# restart never needs the network. Traefik reads ./plugins-local from its
# working directory (/var/lib/traefik, set in the init script).
# The vendored copy carries traefik-warp-failclosed.patch: upstream falls back
# to trusting 192.168/16, 10/8 and 172.16/12 when Cloudflare's list can't be
# fetched (e.g. booting before WAN is up), which lets LAN clients forge their IP.
WARP_DIR=/var/lib/traefik/plugins-local/src/github.com/l4rm4nd/traefik-warp
WARP_ID="$TRAEFIK_WARP_VERSION $(sha256sum "$S/traefik-warp-failclosed.patch" | cut -d' ' -f1)"
if [ "$(cat "$WARP_DIR/.homeops-version" 2>/dev/null)" != "$WARP_ID" ]; then
	apk info -e patch >/dev/null 2>&1 || apk add -q --no-cache patch
	mkdir -p "$(dirname "$WARP_DIR")"
	# Same filesystem as WARP_DIR, so the final mv is an atomic rename.
	d="$(mktemp -d "$(dirname "$WARP_DIR")/.warp.XXXXXX")"
	trap 'rm -rf "$d"' EXIT
	curl -fsSL -o "$d.tar.gz" "https://github.com/l4rm4nd/traefik-warp/archive/$TRAEFIK_WARP_VERSION.tar.gz"
	tar -xzf "$d.tar.gz" -C "$d" --strip-components=1
	rm -f "$d.tar.gz"
	[ -f "$d/go.mod" ] || { echo "traefik-warp archive has no go.mod" >&2; exit 1; }
	patch -s -p1 -d "$d" < "$S/traefik-warp-failclosed.patch" || {
		echo "traefik-warp-failclosed.patch no longer applies to $TRAEFIK_WARP_VERSION; rework it" >&2
		exit 1
	}
	chmod -R a+rX "$d"
	echo "$WARP_ID" > "$d/.homeops-version"
	rm -rf "$WARP_DIR.old"
	if [ -d "$WARP_DIR" ]; then mv "$WARP_DIR" "$WARP_DIR.old"; fi
	mv "$d" "$WARP_DIR"
	rm -rf "$WARP_DIR.old"
	trap - EXIT
	CHANGED="$CHANGED traefik-warp-$TRAEFIK_WARP_VERSION"
	RESTART=1
fi
chown traefik:traefik /var/lib/traefik

mkdir -p /etc/edge/certs /var/lib/lego
chown root:traefik /etc/edge/certs
chmod 0750 /etc/edge/certs

install_file "$S/traefik.yaml" /etc/traefik/traefik.yaml 0644 root:root restart
install_file "$S/edge.yaml" /etc/traefik/dynamic/edge.yaml 0640 root:traefik
install_file "$S/lego.env" /etc/edge/lego.env 0600 root:root
install_file "$S/traefik.initd" /etc/init.d/traefik 0755 root:root restart
install_file "$S/edge-cert-hook.sh" /usr/local/bin/edge-cert-hook 0755 root:root
install_file "$S/edge-cert-renew.sh" /usr/local/bin/edge-cert-renew 0755 root:root
install_file "$S/logrotate-traefik" /etc/logrotate.d/traefik 0644 root:root
install_file "$S/cert-export" /usr/local/bin/cert-export 0755 root:root
# busybox run-parts skips names containing a dot, so no .sh here
[ -L /etc/periodic/daily/edge-cert-renew ] || {
	ln -sf /usr/local/bin/edge-cert-renew /etc/periodic/daily/edge-cert-renew
	CHANGED="$CHANGED periodic:edge-cert-renew"
}
chown root:traefik /etc/traefik /etc/traefik/dynamic
chmod 0750 /etc/traefik/dynamic

rc-update -q add crond default 2>/dev/null || true
rc-service -q crond status >/dev/null 2>&1 || rc-service crond start

# First run only: issue both certificates before Traefik needs them.
if [ ! -s /etc/edge/certs/_.vaderrp.com/fullchain.pem ] || [ ! -s /etc/edge/certs/_.dns.vaderrp.com/fullchain.pem ]; then
	/usr/local/bin/edge-cert-renew all
	# lego only runs the deploy hook when it issues; if its state in
	# /var/lib/lego survived but /etc/edge/certs did not, nothing gets copied.
	for n in _.vaderrp.com _.dns.vaderrp.com; do
		[ -s "/etc/edge/certs/$n/fullchain.pem" ] || {
			echo "apply-edge: /etc/edge/certs/$n missing after lego run; try: edge-cert-renew all --renew-force" >&2
			exit 1
		}
	done
	CHANGED="$CHANGED certificates"
fi

# WireGuard to the VPS (the key npmplus used). Only on 192.168.0.5: a second
# host with the same key would steal the tunnel from npmplus before cutover.
if ip -4 addr show eth0 | grep -q 'inet 192\.168\.0\.5/'; then
	apk info -e wireguard-tools >/dev/null 2>&1 || {
		apk add -q --no-cache wireguard-tools
		CHANGED="$CHANGED packages:wireguard-tools"
	}
	WG_BEFORE="$CHANGED"
	install_file "$S/wg0.conf" /etc/wireguard/wg0.conf 0600 root:root
	[ -e /etc/init.d/wg-quick.wg0 ] || ln -s wg-quick /etc/init.d/wg-quick.wg0
	rc-update -q add wg-quick.wg0 default 2>/dev/null || true
	if [ "$CHANGED" != "$WG_BEFORE" ]; then
		rc-service wg-quick.wg0 restart 2>/dev/null || rc-service wg-quick.wg0 start
	else
		rc-service -q wg-quick.wg0 status >/dev/null 2>&1 || rc-service wg-quick.wg0 start
	fi
else
	echo "wg0: skipped (not on 192.168.0.5 yet)"
fi

rc-update -q add traefik default 2>/dev/null || true
if [ -n "$RESTART" ]; then
	rc-service traefik restart 2>/dev/null || rc-service traefik start
else
	rc-service -q traefik status >/dev/null 2>&1 || rc-service traefik start
fi

if [ -n "$CHANGED" ]; then echo "changed:$CHANGED"; else echo "no changes"; fi
rc-service traefik status
