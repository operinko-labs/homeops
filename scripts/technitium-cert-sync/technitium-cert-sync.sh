#!/usr/bin/env bash
# Pull the TLS bundle NPMplus holds and hand it to Technitium as PKCS#12.
#
# Runs on each Technitium LXC from a systemd timer. NPMplus is the only ACME
# client; the nodes never talk to Let's Encrypt or hold a Cloudflare token.
# The pull direction is deliberate — NPMplus holds no credential that can write
# to a DNS server, only the nodes hold a read-only one pointing back at it.
#
# Technitium reloads its bundle when the file's modification time changes, so
# the swap must be atomic and must only happen when the source actually changed.
set -Eeuo pipefail

# Host serving the bundle. Its authorized_keys pins this key to a forced command
# that tars the two PEMs to stdout, so there is nothing to request — whatever
# command is sent is ignored, and the key cannot do anything else.
readonly SRC_HOST="${SRC_HOST:-root@npmplus}"
# NPMplus's own sshd listens on 2222; its :22 is the NPM+ stream to Forgejo
# (forge/mod.just npmplus_ssh_port), which would answer with Forgejo's host key.
readonly SRC_PORT="${SRC_PORT:-2222}"
readonly SSH_KEY="${SSH_KEY:-/root/.ssh/technitium-cert-sync}"

# Where Technitium expects the bundle. Must match Settings -> Optional Protocols
# -> TLS Certificate File Path, and must be identical on every node: clustering
# replicates that setting, so a node-specific path would break the other node.
readonly OUT="${OUT:-/etc/dns/ssl.pfx}"
readonly WORK="${WORK:-/var/lib/technitium-cert}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >&2; }

main() {
    rm -rf "${WORK}/new"
    mkdir -p "${WORK}/new" "$(dirname "${OUT}")"

    # The forced command tars the two PEMs to stdout with -h, so the symlinks
    # into ../../archive/ are dereferenced server-side and we receive real
    # files. Nothing here chooses what to fetch; the far side decides.
    #
    # -T because the key is restricted and would refuse a PTY anyway, and
    # BatchMode so an unknown host key fails outright rather than hanging on a
    # prompt no one will answer — see the known_hosts note in the README.
    if ! ssh -T -o BatchMode=yes -p "${SRC_PORT}" -i "${SSH_KEY}" "${SRC_HOST}" \
        | tar -xzf - -C "${WORK}/new"; then
        log "ERROR: could not fetch bundle from ${SRC_HOST}; leaving ${OUT} untouched"
        exit 1
    fi

    for f in fullchain.pem privkey.pem; do
        if [[ ! -s "${WORK}/new/${f}" ]]; then
            log "ERROR: ${f} missing or empty in fetched bundle; leaving ${OUT} untouched"
            exit 1
        fi
    done

    # A timer fires on schedule, not on renewal. Without this check every tick
    # would rewrite the bundle and trigger a pointless certificate reload.
    if [[ -f "${OUT}" ]] \
        && cmp -s "${WORK}/new/fullchain.pem" "${WORK}/current/fullchain.pem" 2>/dev/null \
        && cmp -s "${WORK}/new/privkey.pem" "${WORK}/current/privkey.pem" 2>/dev/null; then
        exit 0
    fi

    # Technitium takes PKCS#12 only. The legacy algorithms mirror what the old
    # in-cluster initContainer used and are known to produce a bundle it
    # accepts; modern defaults may work but have not been verified here.
    openssl pkcs12 -export -legacy \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "${WORK}/new/privkey.pem" \
        -in "${WORK}/new/fullchain.pem" \
        -out "${OUT}.tmp" -passout pass:

    chmod 0600 "${OUT}.tmp"

    # Rename rather than write in place: Technitium watches mtime, and an
    # in-place write risks it reading a partially written bundle. The rename is
    # atomic and refreshes the timestamp in one step, triggering the reload.
    mv "${OUT}.tmp" "${OUT}"

    rm -rf "${WORK}/current"
    mv "${WORK}/new" "${WORK}/current"

    local expiry
    expiry="$(openssl x509 -in "${WORK}/current/fullchain.pem" -noout -enddate)"
    log "installed new bundle at ${OUT} (${expiry})"
}

main "$@"
