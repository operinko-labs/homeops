#!/bin/sh
# lego --deploy-hook (installed as /usr/local/bin/edge-cert-hook). Copies a new
# or renewed certificate to /etc/edge/certs/<name>/{fullchain,privkey}.pem,
# where Traefik and the Technitium cert-export read it.
set -eu

dir="/etc/edge/certs/${LEGO_HOOK_CERT_NAME_SANITIZED:?}"
tmp="/etc/edge/.hook.$$"
mkdir -p "$dir"
cp "${LEGO_HOOK_CERT_PATH:?}" "$tmp.crt"
cp "${LEGO_HOOK_CERT_KEY_PATH:?}" "$tmp.key"
chown root:traefik "$tmp.crt" "$tmp.key"
chmod 0644 "$tmp.crt"
chmod 0640 "$tmp.key"
mv -f "$tmp.crt" "$dir/fullchain.pem"
mv -f "$tmp.key" "$dir/privkey.pem"

# Traefik's file provider watches /etc/traefik/dynamic, not the certificate
# files it references. Replacing edge.yaml (same content, atomic rename from
# outside the watched directory) triggers a reload that re-reads the certs.
if [ -f /etc/traefik/dynamic/edge.yaml ]; then
	cp -p /etc/traefik/dynamic/edge.yaml /etc/traefik/.edge.yaml.reload
	mv -f /etc/traefik/.edge.yaml.reload /etc/traefik/dynamic/edge.yaml
fi
echo "edge-cert-hook: installed $dir"
