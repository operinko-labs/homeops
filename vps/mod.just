set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

vps_dir := justfile_dir() + '/vps'
host := env('VPS_HOST', 'root@212.147.241.182')

[private]
default:
    just -l vps

[doc('Apply VPS configuration (pass port=22 for first run on a fresh box)')]
apply port='2222':
    ssh -p {{ port }} {{ host }} 'mkdir -p -m 700 /root/.homeops-staging'
    scp -P {{ port }} -q {{ vps_dir }}/config/haproxy.cfg {{ vps_dir }}/config/postfix-main.cf {{ vps_dir }}/config/sshd-hardening.conf {{ vps_dir }}/config/fail2ban-jail.local {{ vps_dir }}/config/fail2ban-filter-haproxy-http-auth.conf {{ vps_dir }}/config/apt-20auto-upgrades {{ vps_dir }}/config/apt-52-auto-reboot.conf {{ vps_dir }}/config/needrestart-50-auto.conf {{ vps_dir }}/apply.sh {{ host }}:/root/.homeops-staging/
    sops -d {{ vps_dir }}/secrets.sops.yaml | minijinja-cli {{ vps_dir }}/config/wg0.conf.j2 --format yaml - | ssh -p {{ port }} {{ host }} 'umask 077; cat > /root/.homeops-staging/wg0.conf'
    ssh -p {{ port }} {{ host }} 'bash /root/.homeops-staging/apply.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('SSH into the VPS')]
ssh:
    ssh -p 2222 {{ host }}
