set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir() + '/kubernetes'

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f /dev/stdin

[doc('Browse a PVC')]
browse-pvc namespace claim:
    kubectl browse-pvc -n {{ namespace }} -i mirror.gcr.io/alpine:latest {{ claim }}

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f /dev/stdin

[doc('Switch the mariadb-ha primary to another pod index')]
mariadb-switchover index:
    kubectl -n database patch mariadb mariadb-ha --type merge -p '{"spec":{"replication":{"primary":{"podIndex":{{ index }}}}}}'
    kubectl -n database wait mariadb mariadb-ha --for=jsonpath='{.status.currentPrimaryPodIndex}'={{ index }} --timeout=5m
    kubectl -n database wait mariadb mariadb-ha --for=condition=Ready --timeout=5m

[doc('Open a shell on a node')]
node-shell node:
    kubectl debug node/{{ node }} -n default -it --image="mirror.gcr.io/alpine:latest" --profile sysadmin
    kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do \
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true; \
    done

[doc('Snapshot VolSync PVCs')]
snapshot:
    kubectl get replicationsources --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" patch replicationsources "$name" --type merge -p '{"spec":{"trigger":{"manual":"$(date +%s)"}}}'; \
    done

[doc('Suspend or resume Keda ScaledObjects')]
keda state:
    kubectl get scaledobjects --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite so "$name" autoscaling.keda.sh/paused{{ if state != "suspend" { "-" } else { "=true" } }}; \
    done

[doc('Suspend or resume VolSync')]
volsync state:
    flux -n volsync-system {{ state }} kustomization volsync
    flux -n volsync-system {{ state }} helmrelease volsync
    kubectl -n volsync-system scale deployment volsync --replicas {{ if state != "suspend" { "1" } else { "0" } }}

[doc('Restore VolSync app')]
volsync-restore ns app previous='0':
    #!/usr/bin/env bash
    set -e
    # Gather variables
    if kubectl --namespace {{ ns }} get replicationsources/{{ app }} -o jsonpath='{.spec.restic}' | grep -q "{"; then
        accessor="restic"
        template=".taskfiles/volsync/resources/replicationdestination.yaml.j2"
    else
        accessor="kopia"
        template=".taskfiles/volsync/resources/replicationdestination-kopia.yaml.j2"
    fi

    claim=$(kubectl --namespace {{ ns }} get replicationsources/{{ app }} --output=jsonpath='{.spec.sourcePVC}')
    access_modes=$(kubectl --namespace {{ ns }} get replicationsources/{{ app }} --output=jsonpath="{.spec.${accessor}.accessModes}")
    storage_class_name=$(kubectl --namespace {{ ns }} get replicationsources/{{ app }} --output=jsonpath="{.spec.${accessor}.storageClassName}")
    puid=$(kubectl --namespace {{ ns }} get replicationsources/{{ app }} --output=jsonpath="{.spec.${accessor}.moverSecurityContext.runAsUser}")
    pgid=$(kubectl --namespace {{ ns }} get replicationsources/{{ app }} --output=jsonpath="{.spec.${accessor}.moverSecurityContext.runAsGroup}")
    repo_root=$(git rev-parse --show-toplevel)

    # Suspend Flux reconcilation
    echo "Suspending Flux HelmRelease..."
    flux -n {{ ns }} suspend helmrelease {{ app }}

    # Scale down
    echo "Scaling down deployments..."
    kubectl -n {{ ns }} scale deployment --replicas 0 --selector="app.kubernetes.io/instance={{ app }}"
    # Wait for pods to terminate
    kubectl -n {{ ns }} wait pod --for=delete --selector="app.kubernetes.io/instance={{ app }}" --timeout=2m

    # Render and Apply Restore Object
    # We cd to repo_root so minijinja-cli finds .minijinja.toml (checking if needed, but safer)
    (cd "$repo_root" && minijinja-cli "$template" -D APP={{ app }} -D NS={{ ns }} -D CLAIM=$claim -D ACCESS_MODES=$access_modes -D STORAGE_CLASS_NAME=$storage_class_name -D PUID=$puid -D PGID=$pgid -D PREVIOUS={{ previous }} | kubectl apply --server-side --filename -)

    # Wait for restore job to start
    echo "Waiting for restore job to start..."
    until kubectl -n {{ ns }} get job/volsync-dst-{{ app }}-manual &>/dev/null; do
        sleep 1
        echo -n "."
    done
    echo "Job started."
    # Wait for restore job to complete
    kubectl -n {{ ns }} wait job/volsync-dst-{{ app }}-manual --for=condition=complete --timeout=120m

    # Cleanup
    kubectl -n {{ ns }} delete replicationdestination {{ app }}-manual

    # Resume Flux reconcilation (which will scale up)
    echo "Resuming Flux HelmRelease..."
    flux -n {{ ns }} resume helmrelease {{ app }}
    flux -n {{ ns }} reconcile helmrelease {{ app }} --force

[doc('Sync ExternalSecrets')]
sync-es:
    kubectl get es --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite es "$name" force-sync="$(date +%s)"; \
    done

[doc('Sync GitRepositories')]
sync-git:
    kubectl get gitrepo --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite gitrepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('Sync HelmReleases')]
sync-hr:
    kubectl get hr --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite hr "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)" reconcile.fluxcd.io/forceAt="$(date +%s)"; \
    done

[doc('Sync Kustomizations')]
sync-ks:
    kubectl get ks --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite ks "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('Sync OCIRepositories')]
sync-oci:
    kubectl get ocirepo --no-headers -A | while read -r ns name _; do \
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite ocirepo "$name" reconcile.fluxcd.io/requestedAt="$(date +%s)"; \
    done

[doc('View a secret')]
view-secret namespace secret:
    kubectl view-secret -n {{ namespace }} {{ secret }}

[private]
render-local-ks ns ks:
    flux-local build ks --namespace "{{ ns }}" --path "{{ kubernetes_dir }}/flux/cluster" "{{ ks }}"