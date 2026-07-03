set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := justfile_dir() + '/scripts'
talos_dir := justfile_dir() + '/talos'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -e "{{ node }}" -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Generate schematic ID from Talos schematic')]
gen-schematic-id:
    curl -sX POST --data-binary @<(just template "{{ talos_dir }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -e {{ node }} -n {{ node }} reboot -m powercycle || exit 0

[doc('Render Talos config for a node')]
render-config node:
    @if [[ "{{ node }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then \
        export HOSTNAME=$(grep -l "{{ node }}" {{ talos_dir }}/nodes/*.yaml.j2 | head -n1 | xargs basename -s .yaml.j2); \
    else \
        export HOSTNAME="{{ node }}"; \
    fi; \
    if [ -z "$HOSTNAME" ] || [ ! -f "{{ talos_dir }}/nodes/${HOSTNAME}.yaml.j2" ]; then \
        echo "Error: Node {{ node }} not found in talos/nodes/*.yaml.j2" >&2; exit 1; \
    fi; \
    export IS_CONTROLLER=$(grep -q "type: controlplane" "{{ talos_dir }}/nodes/${HOSTNAME}.yaml.j2" && echo "true" || echo "false"); \
    sops -d "{{ talos_dir }}/secrets.sops.yaml" | minijinja-cli "{{ talos_dir }}/machineconfig.yaml.j2" --format yaml - -D IS_CONTROLLER="${IS_CONTROLLER}" | \
        talosctl machineconfig patch /dev/stdin -p @<(sops -d "{{ talos_dir }}/secrets.sops.yaml" | minijinja-cli "{{ talos_dir }}/nodes/${HOSTNAME}.yaml.j2" --format yaml -)

[doc('Reset a node')]
reset-node node *args:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        talosctl -e "{{ node }}" -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe u-local-hostpath --graceful=false {{ args }} || exit 0

[doc('Shutdown a node')]
shutdown-node node *args:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -e "{{ node }}" -n "{{ node }}" shutdown --force {{ args }} || exit 0

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -e "{{ controller }}" -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -e "{{ node }}" -n "{{ node }}" upgrade -i "$(just talos machine-image)" -m powercycle --timeout=10m {{ args }}

[private]
machine-controller node:
    minijinja-cli "{{ talos_dir }}/nodes/{{ node }}.yaml.j2" | yq 'select(.machine) | (.machine.type == "controlplane")'

[private]
machine-image:
    @sops -d "{{ talos_dir }}/secrets.sops.yaml" | minijinja-cli "{{ talos_dir }}/machineconfig.yaml.j2" --format yaml - -D IS_CONTROLLER=true | yq 'select(.machine.install.image) | .machine.install.image'