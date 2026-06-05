# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a GitOps homelab Kubernetes cluster running on [Talos Linux](https://github.com/siderolabs/talos) with [Flux CD](https://github.com/fluxcd/flux2) for continuous delivery. The cluster is 7 nodes (talos1–talos7, `192.168.7.21–27`), control-plane endpoint at `cluster.vaderrp.com`. Secrets are managed with [SOPS](https://github.com/getsops/sops) (age key). Dev tooling is managed with [mise](https://mise.jdx.dev/).

## Commands

The task runner is **`just`** (not `task`). Submodules are `talos`, `kube`, and `bootstrap`.

### Talos

```sh
just talos render-config <node-ip-or-hostname>   # Render merged machine config for a node
just talos apply-node <node-ip-or-hostname>       # Apply config to a node
just talos reboot-node <node>
just talos reset-node <node>
just talos shutdown-node <node>
just talos upgrade-node <node>                    # Upgrade Talos on a node
just talos upgrade-k8s <version>                  # Upgrade Kubernetes cluster-wide
just talos gen-schematic-id                       # Generate Talos factory schematic ID
just talos download-image <version> <schematic>
```

### Kubernetes

```sh
just kube apply-ks <ns> <ks>       # Apply a local Flux Kustomization
just kube delete-ks <ns> <ks>
just kube sync-hr                  # Force-reconcile all HelmReleases
just kube sync-ks                  # Force-reconcile all Kustomizations
just kube sync-es                  # Force-sync all ExternalSecrets
just kube sync-git                 # Force-sync all GitRepositories
just kube sync-oci                 # Force-sync all OCIRepositories
just kube view-secret <ns> <secret>
just kube browse-pvc <ns> <claim>
just kube node-shell <node>
just kube prune-pods
just kube snapshot                 # Trigger VolSync snapshots on all PVCs
just kube volsync-restore <ns> <app> [previous]
just kube volsync <suspend|resume>
just kube keda <suspend|resume>
```

### Bootstrap (initial cluster setup only)

```sh
just bootstrap   # Runs all stages: talos → kube → kubeconfig → namespaces → resources → crds → apps
```

### Useful kubectl / flux one-liners

```sh
flux get ks -A            # Check Kustomization status
flux get hr -A            # Check HelmRelease status
flux reconcile ks <name> -n flux-system --with-source
kubectl -n <ns> get events --sort-by='.metadata.creationTimestamp'
```

## Architecture

### Directory structure

```
.
├── bootstrap/         # One-time cluster bootstrap: Helmfile for cilium, coredns, cert-manager, flux
├── kubernetes/
│   ├── apps/          # All workloads, one subdirectory per namespace
│   ├── components/    # Reusable Kustomize components (volsync-kopia, traefik-warp, alerts, etc.)
│   └── flux/          # Flux entry point (cluster/ks.yaml → meta → apps)
├── talos/
│   ├── machineconfig.yaml.j2   # Base machine config template (minijinja)
│   ├── nodes/*.yaml.j2         # Per-node config patches
│   ├── secrets.sops.yaml       # SOPS-encrypted cluster secrets
│   └── talenv.yaml             # Talos + Kubernetes version pins (Renovate-managed)
└── apps/              # Custom applications built in this repo (Python)
    ├── log-aggregator/
    ├── tempest-mcp/
    └── n8n-workflows/
```

### Flux GitOps flow

`kubernetes/flux/cluster/ks.yaml` is the root — it creates two top-level `Kustomization`s:
- `cluster-meta`: loads Helm repositories from `kubernetes/flux/meta/`
- `cluster-apps`: recursively applies everything under `kubernetes/apps/`

Each app lives at `kubernetes/apps/<namespace>/<app>/`:
- `ks.yaml` — Flux `Kustomization` (dependency ordering, VolSync component inclusion, postBuild substitutions)
- `app/` — actual Kubernetes manifests: `helmrelease.yaml`, `ocirepository.yaml`, `external-secret.yaml`, `httproute.yaml`, PVCs, etc.

### Talos config generation

Machine configs are assembled by `just talos render-config <node>`:
1. `talos/secrets.sops.yaml` is decrypted with SOPS
2. `talos/machineconfig.yaml.j2` is rendered via minijinja (with `IS_CONTROLLER` set)
3. The per-node patch from `talos/nodes/<hostname>.yaml.j2` is applied on top

The resulting YAML is piped directly to `talosctl apply-config` — there are no committed rendered configs (the `talos/clusterconfig/` directory contains reference copies only).

### Secrets

- SOPS encrypts with age key at `age.key` (path set by `SOPS_AGE_KEY_FILE` in `.mise.toml`)
- Rules in `.sops.yaml`:
  - `talos/secrets.sops.yaml`: fully encrypted
  - `talos/*.sops.yaml`: MAC-only encrypted
  - `(bootstrap|kubernetes)/*.sops.yaml`: only `data`/`stringData` fields encrypted
- Kubernetes secrets are typically managed via `ExternalSecret` resources pulling from 1Password (external-secrets operator)

### Networking

- **CNI**: Cilium (with BGP for load-balancer IPs)
- **Ingress**: Traefik (`internal` class for LAN, `external` class via cloudflared for internet)
- **DNS**: k8s_gateway + external-dns (Cloudflare) + internal CoreDNS
- **Tunnel**: cloudflared for public exposure

### Storage

- **PVC backups**: VolSync with kopia (`kubernetes/components/volsync-kopia/`) — referenced as a Kustomize component in each app's `ks.yaml`
- **NFS**: media and download mounts from `192.168.0.221` (NAS)
- **Databases**: CloudNative-PG (Postgres), Dragonfly (Redis-compatible)

### Container registry

All public registries are mirrored through Harbor at `harbor.vaderrp.com`. The mirror configuration is in `talos/machineconfig.yaml.j2`. Image pulls in-cluster hit Harbor rather than DockerHub/GHCR/etc. directly.

### App namespaces

`actions-runner-system`, `cert-manager`, `database`, `default`, `external-secrets`, `flux-system`, `gpro`, `kube-system`, `mail`, `media`, `network`, `observability`, `security`, `storage`, `tools`

### Tooling versions

Managed in `.mise.toml` and `talos/talenv.yaml`. Renovate opens PRs for version bumps on Helm charts, container images, and CLI tools.
