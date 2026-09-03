#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Apply essential CRDs needed before ArgoCD
function apply_crds() {
    log debug "Applying essential CRDs"

    local -r crds=(
        # Gateway API CRDs are required for ArgoCD HTTPRoute/GRPCRoute
        # renovate: datasource=github-tags depName=kubernetes-sigs/gateway-api extractVersion=^v(?<version>\d+\.\d+\.\d+)
        https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
        # ExternalDNS CRDs are required for ArgoCD external-dns
        https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/heads/master/config/crd/standard/dnsendpoints.externaldns.k8s.io.yaml
        # ExternalSecret CRDs are required for ArgoCD external-secrets
        https://raw.githubusercontent.com/external-secrets/external-secrets/refs/heads/main/deploy/crds/bundle.yaml
        # CertManager CRDs
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/cert-manager.io_issuers.yaml
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/cert-manager.io_clusterissuers.yaml
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/cert-manager.io_certificates.yaml
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/cert-manager.io_certificaterequests.yaml
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/acme.cert-manager.io_orders.yaml
        https://raw.githubusercontent.com/cert-manager/cert-manager/refs/heads/master/deploy/crds/acme.cert-manager.io_challenges.yaml
        # renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
        https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.86.1/stripped-down-crds.yaml
        # Traefik CRDs required for Middleware, IngressRoute, etc. Install at bootstrap time.
        # renovate: datasource=github-tags depName=traefik/traefik extractVersion=^v(?<version>\d+\.\d+)
        https://raw.githubusercontent.com/traefik/traefik/v2.10/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
    )

    for crd in "${crds[@]}"; do
        kubectl apply --server-side --filename "${crd}" &>/dev/null
        #if kubectl apply --server-side --filename "${crd}" &>/dev/null; then
        #    log info "CRDs applied" "crd=${crd}"
        #else
        #    log warn "Failed to apply CRDs (may already exist)" "crd=${crd}"
        #fi
    done

    # Wait for core Gateway API CRDs to be Established
    for gcrd in gatewayclasses gateways httproutes grpcroutes referencegrants; do
        crd_name="${gcrd}.gateway.networking.k8s.io"
        if kubectl get crd "${crd_name}" &>/dev/null; then
            kubectl wait --for=condition=Established --timeout=120s "crd/${crd_name}" || true
        fi
    done
}

# Clean up existing ArgoCD resources if they exist
function cleanup_existing_argocd() {
    log debug "Checking for existing ArgoCD resources"

    # Check if argocd namespace exists
    if kubectl get namespace argocd &>/dev/null; then
        log info "Found existing ArgoCD namespace, cleaning up"

        # Remove finalizers from all Applications
        kubectl get applications -n argocd -o name 2>/dev/null | while read -r app; do
            kubectl patch "${app}" -n argocd --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done

        # Delete the namespace
        kubectl delete namespace argocd --timeout=60s || true

        # If namespace is stuck, force remove finalizer
        if kubectl get namespace argocd &>/dev/null; then
            log warn "Namespace stuck terminating, forcing removal"
            kubectl patch namespace argocd -p '{"spec":{"finalizers":[]}}' --type=merge || true
            sleep 5
        fi

        # Wait for namespace to be gone
        for i in {1..30}; do
            if ! kubectl get namespace argocd &>/dev/null; then
                log info "ArgoCD namespace deleted successfully"
                break
            fi
            log debug "Waiting for namespace deletion..." "attempt=${i}"
            sleep 2
        done
    fi

    # Clean up cluster-scoped ArgoCD resources
    log debug "Cleaning up cluster-scoped ArgoCD resources"
    kubectl delete clusterrole -l app.kubernetes.io/part-of=argocd 2>/dev/null || true
    kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=argocd 2>/dev/null || true
}

# Install ArgoCD using Helm
function install_argocd() {
    log debug "Installing ArgoCD"

    # Add Argo Helm repository
    if ! helm repo list | grep -q "^argo"; then
        log info "Adding Argo Helm repository"
        helm repo add argo https://argoproj.github.io/argo-helm
    fi
    helm repo update argo

    # Extract Helm values from ArgoCD Application manifest
    local -r argocd_app="${ROOT_DIR}/kubernetes/argocd/applications/argocd/argocd.yaml"
    local -r values_file="/tmp/argocd-bootstrap-values.yaml"

    log info "Extracting Helm values from ArgoCD Application manifest"
    yq eval '.spec.sources[0].helm.values' "${argocd_app}" > "${values_file}"

    # Install or upgrade ArgoCD
    # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
    local -r argocd_chart_version=10.5.0

    log info "Installing ArgoCD with Helm"
    if helm upgrade --install argocd argo/argo-cd \
        --version "${argocd_chart_version}" \
        --namespace argocd \
        --create-namespace \
        --values "${values_file}" \
        --wait \
        --timeout 10m; then
        log info "ArgoCD installed successfully"
    else
        log error "Failed to install ArgoCD"
    fi

    # Clean up temporary values file
    rm -f "${values_file}"
}

# Wait for ArgoCD to be ready
function wait_for_argocd() {
    log debug "Waiting for ArgoCD to be ready"

    # Wait for ArgoCD server to be ready
    if kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s; then
        log info "ArgoCD server is ready"
    else
        log error "ArgoCD server failed to become ready"
    fi

    # Wait for ArgoCD application controller to be ready
    if kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=300s; then
        log info "ArgoCD application controller is ready"
    else
        log error "ArgoCD application controller failed to become ready"
    fi
}

# Apply ArgoCD AppProjects
function apply_argocd_projects() {
    log debug "Applying ArgoCD AppProjects"

    local -r projects_dir="${ROOT_DIR}/kubernetes/argocd/applications/projects"

    if [[ ! -d "${projects_dir}" ]]; then
        log error "Projects directory does not exist" "directory=${projects_dir}"
    fi

    # Apply all AppProject manifests
    if kubectl apply -f "${projects_dir}"; then
        log info "ArgoCD AppProjects applied successfully"
    else
        log error "Failed to apply ArgoCD AppProjects"
    fi
}

# Apply ArgoCD Application for self-management
function apply_argocd_application() {
    log debug "Applying ArgoCD Application for self-management"

    local -r argocd_app="${ROOT_DIR}/kubernetes/argocd/applications/argocd/argocd.yaml"

    if kubectl apply -f "${argocd_app}"; then
        log info "ArgoCD Application applied successfully"
    else
        log error "Failed to apply ArgoCD Application"
    fi
}

# Apply root Application to bootstrap all other applications
function apply_root_application() {
    log debug "Applying root Application"

    local -r root_app="${ROOT_DIR}/kubernetes/argocd/applications/root.yaml"

    if kubectl apply -f "${root_app}"; then
        log info "Root Application applied successfully"
    else
        log error "Failed to apply root Application"
    fi
}

function main() {
    check_cli helm kubectl yq

    # Bootstrap ArgoCD
    wait_for_nodes
    apply_crds
    cleanup_existing_argocd
    install_argocd
    wait_for_argocd
    apply_argocd_projects
    apply_argocd_application
    apply_root_application

    log info "Congrats! ArgoCD is bootstrapped and syncing the Git repository"
}

main "$@"

