set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

forge_dir := justfile_dir() + '/forge'
forge_ip := '192.168.7.30'
# edge Traefik LXC (meanie VMID 120); took over npmplus's address on 2026-11-18.
# Its own sshd is on 2222 because Traefik's :22 stream belongs to Forgejo.
edge_ip := '192.168.0.5'
edge_ssh_port := '2222'
runner1_ip := '192.168.7.31'
runner2_ip := '192.168.7.32'

[private]
default:
    just -l forge

[doc('Apply Forgejo config to the forge LXC')]
apply-forgejo:
    ssh root@{{ forge_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/app.ini.j2 --format yaml - | ssh root@{{ forge_ip }} 'umask 077; cat > /root/.homeops-staging/app.ini'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/signing.key.j2 --format yaml - | ssh root@{{ forge_ip }} 'umask 077; cat > /root/.homeops-staging/signing.key'
    scp -q {{ forge_dir }}/config/sshd-forgejo.conf {{ forge_dir }}/config/forgejo-robots.txt {{ forge_dir }}/apply-forgejo.sh root@{{ forge_ip }}:/root/.homeops-staging/
    ssh root@{{ forge_ip }} 'bash /root/.homeops-staging/apply-forgejo.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('Apply runner config: just forge apply-runner 1|2 (set FORGEJO_RUNNER_TOKEN to (re)register)')]
apply-runner n:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$([ "{{ n }}" = "1" ] && echo "{{ runner1_ip }}" || echo "{{ runner2_ip }}")
    ssh root@$ip 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/runner-config.yaml.j2 --format yaml - | ssh root@$ip 'umask 077; cat > /root/.homeops-staging/config.yaml'
    scp -q {{ forge_dir }}/apply-runner.sh root@$ip:/root/.homeops-staging/
    ssh root@$ip "FORGEJO_RUNNER_TOKEN='${FORGEJO_RUNNER_TOKEN:-}' bash /root/.homeops-staging/apply-runner.sh; rc=\$?; rm -rf /root/.homeops-staging; exit \$rc"

[doc('Apply Traefik + lego config to the edge LXC')]
apply-edge:
    ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    { sops -d {{ forge_dir }}/secrets.sops.yaml; sed '/^---$/d' {{ forge_dir }}/config/edge/routes.yaml; } | minijinja-cli --config-file {{ forge_dir }}/../.minijinja.toml {{ forge_dir }}/config/edge/dynamic.yaml.j2 --format yaml - | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/edge.yaml'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli --config-file {{ forge_dir }}/../.minijinja.toml {{ forge_dir }}/config/edge/lego.env.j2 --format yaml - | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/lego.env'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli --config-file {{ forge_dir }}/../.minijinja.toml {{ forge_dir }}/config/edge/selfcheck.env.j2 --format yaml - | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/selfcheck.env'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli --config-file {{ forge_dir }}/../.minijinja.toml {{ forge_dir }}/config/edge/unifi-sync.env.j2 --format yaml - | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/unifi-sync.env'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli --config-file {{ forge_dir }}/../.minijinja.toml {{ forge_dir }}/config/wg0-npmplus.conf.j2 --format yaml - | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/wg0.conf'
    cd {{ forge_dir }} && scp -P {{ edge_ssh_port }} -q config/edge/versions.env config/edge/traefik.yaml config/edge/traefik.initd config/edge/edge-cert-hook.sh config/edge/edge-cert-renew.sh config/edge/logrotate-traefik config/edge/cert-export config/edge/traefik-warp-failclosed.patch config/edge/cf-unifi-sync config/edge/cf-unifi-sync.periodic config/edge/crowdsec.initd config/edge/crowdsec-hub-upgrade config/edge/edge-selfcheck config/edge/edge-selfcheck.periodic apply-edge.sh root@{{ edge_ip }}:/root/.homeops-staging/
    cd {{ forge_dir }} && scp -P {{ edge_ssh_port }} -q -r config/edge/crowdsec root@{{ edge_ip }}:/root/.homeops-staging/
    sops -d --extract '["edge_crowdsec_bouncer_key"]' {{ forge_dir }}/secrets.sops.yaml | ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'umask 077; cat > /root/.homeops-staging/bouncer.key'
    ssh -p {{ edge_ssh_port }} root@{{ edge_ip }} 'sh /root/.homeops-staging/apply-edge.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('One-time/idempotent Forgejo API-level state (org, mirrors, secrets)')]
setup:
    sops exec-env {{ forge_dir }}/secrets.sops.yaml 'bash {{ forge_dir }}/setup-forgejo.sh'

[doc('SSH into the forge LXC')]
ssh:
    ssh root@{{ forge_ip }}
