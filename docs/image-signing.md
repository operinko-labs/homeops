# Image signing

Every image that operinko-labs Forgejo CI pushes to `harbor.vaderrp.com/operinko-labs` is signed with
cosign right after the push, by digest. Harbor shows the signature as a `signature.cosign` accessory on
the artifact.

## Key scheme

**Decision (2026-10-27): one cosign key pair (ECDSA P-256) for the whole org, no keyless signing and no
transparency log.**

- Keyless Sigstore needs an OIDC identity token Fulcio trusts. Forgejo Actions has no such issuer, and
  keyless signing would also mean reaching the public Fulcio and Rekor from the runners.
- Uploading to the public Rekor would publish every internal image name and digest, so nothing goes there.
  Verification therefore skips the tlog (`--insecure-ignore-tlog` / Kyverno `ignoreTlog: true`).

| What | Where |
| --- | --- |
| Private key (encrypted PEM) | Vaultwarden item `cosign operinko-labs image signing` (`d18d0a6b`), notes field |
| Key password | same item, password field |
| Public key | [`cosign.pub`](../cosign.pub) in this repo, also the item's `public_key` field |
| CI copies | Forgejo org Actions secrets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` on `operinko-labs` |

Every workflow in the org can read the org secrets, so anyone who can push a workflow to an operinko-labs
repo can sign. That is the same trust boundary as `HARBOR_USERNAME`/`HARBOR_PASSWORD`, which can already
push any image.

## How CI signs

Each workflow downloads the cosign v3.1.3 release binary and checks it against a pinned sha256.
`sigstore/cosign-installer` can't be used because it calls `envsubst`, which the runner image lacks. After
the push, the workflow runs:

```sh
cosign sign --yes --key env://COSIGN_PRIVATE_KEY \
  --use-signing-config=false --new-bundle-format=false --tlog-upload=false \
  "harbor.vaderrp.com/operinko-labs/<repo>@<digest>"
```

- `--new-bundle-format=false` keeps the legacy `sha256-<digest>.sig` tag. Harbor recognises that format
  as a cosign signature. cosign 3's default bundle format goes in as an OCI referrer that Harbor may not
  treat as a signature.
- `--use-signing-config=false --tlog-upload=false` turns off the Rekor upload. cosign 3 marks
  `--tlog-upload` as deprecated. When a release removes it, switch to `--signing-config` with a config
  that has no `rekorTlogUrls`, and check that Harbor still lists the result.
- The step retries for up to 5 minutes. cosign reads the image manifest before it signs, and Harbor
  answers that read with 412 while scan-on-push runs (`prevent_vul`). An image with a Critical CVE stays
  412, so its sign step fails after the retries. That image can't be pulled anyway.
- The digest comes from `docker/build-push-action`'s `digest` output. Workflows that push with plain
  `docker push` take it from the push output instead. All of an image's tags share that digest, so one
  signature covers them.
- Renovate doesn't track the cosign version. To bump it, change the URL and the sha256 (from the
  release's `cosign_checksums.txt`) in every workflow.
- Workflows that tag more than once push a single tag, sign, and then add the other tags with
  `docker buildx imagetools create`. Pushing several tags in one buildx push trips the same 412.

Signing workflows: homeops `build-{log-aggregator,synapse,tempest-mcp}.yaml`, lab-images
(`drupal-php-fpm`, `nginx-brotli`), the five Drupal site CIs (kyronautopalvelu, leo_cal, medikabalans,
ruoka-admin, ruskonkesateatteri), gpro (`ci.yml`, `manual-build.yml`), torn-tracker, torn_stats_tracker,
autoposter, stalwart-users (`.github/workflows/release.yml`), bitwarden-eso-provider (`bweso`) and
site-overview. The Helm chart pushes (`charts`, bitwarden-eso-provider `cd-helm-release.yml`) aren't
signed.

## Verifying

The operinko-labs project is public, so no login is needed:

```sh
cosign verify --key cosign.pub --insecure-ignore-tlog=true harbor.vaderrp.com/operinko-labs/log-aggregator:0.3.3
```

Images pushed before 2026-10-27 have no signature. They pick one up on their next build. The first
signed image was log-aggregator 0.3.3 (homeops Actions run 2196).

## Rotation

Rotate when the key may have leaked (a stray workflow log, a compromised repo with Actions enabled) and
otherwise once a year.

1. `cosign generate-key-pair` with a fresh random password (`COSIGN_PASSWORD` set in the environment).
2. Update the Vaultwarden item: notes, password and `public_key`.
3. Overwrite the org secrets, either with
   `PUT /api/v1/orgs/operinko-labs/actions/secrets/{COSIGN_PRIVATE_KEY,COSIGN_PASSWORD}` and body
   `{"data": "..."}`, or in the org's Actions settings.
4. If enforcement is on, add the new public key to the policy next to the old one first (two
   `attestors[].entries`, `count: 1`). Then replace `cosign.pub`.
5. Re-sign the digests that are deployed now with the new key (`cosign sign` by digest, same flags). A
   second signature is added to the existing `.sig` manifest.
6. Once nothing deployed depends on the old key alone, drop it from the policy.

## Enforcement: recommendation

Nothing is enforced yet. There are two candidates.

### Harbor: "Cosign: prevent unsigned images from being pulled" on operinko-labs

- Proxy-cache projects (`dockerhub`, `ghcr`, `gcr`, `k8s`, `quay`, `fluentbit`) are separate projects,
  so a per-project setting exempts them by construction.
- It covers every pull, CI and non-Kubernetes hosts included.
- Harbor only checks that *some* cosign signature exists. It doesn't check which key made it, so any
  account with push rights can satisfy it with a throwaway key.
- It blocks every unsigned digest the moment it's switched on. That includes rollbacks, older tags, and
  the `FROM drupal-php-fpm` base pulls in the site builds until the base image is rebuilt.
- Harbor applies the block to manifest reads, and cosign reads the manifest before signing. The sign step
  could then never succeed, as with the `prevent_vul` 412. That needs a test before relying on it.

### Kyverno `verifyImages` (Kyverno 1.16 from chart 3.6.2, in `security`)

- It verifies against our public key, not just "has a signature".
- Matching only `harbor.vaderrp.com/operinko-labs/*` leaves proxied images out. Cluster manifests name
  them by their upstream registry (`ghcr.io/...` and so on) and containerd mirrors them through Harbor.
- It can run in `Audit` first and produce PolicyReports without blocking anything, then switch to
  `Enforce` per rule.
- Rotation works by listing two keys.
- It only covers Pods, and it puts the Kyverno webhook in the admission path for those images.

**Recommendation: Kyverno, staged.** Harbor's check doesn't bind to our key, and it risks breaking the
signing step itself.

1. Add the policy below in `Audit` (for example as `kubernetes/apps/security/kyverno/policies/verify-images.yaml`)
   and watch `kubectl get policyreport -A` for a week.
2. Let every image get a signed build, or re-sign the deployed digests by hand.
3. Switch `failureAction` to `Enforce`.

`mutateDigest: false` stops Kyverno from rewriting image tags to digests, which would fight Flux/Helm.

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kyverno.io/clusterpolicy_v1.json
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-operinko-labs-images
  annotations:
    policies.kyverno.io/title: Verify operinko-labs image signatures
    policies.kyverno.io/description: >-
      Images from harbor.vaderrp.com/operinko-labs must carry a cosign signature
      made with the key in cosign.pub. Proxy-cache images are not matched.
spec:
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: operinko-labs-signed
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "harbor.vaderrp.com/operinko-labs/*"
          failureAction: Audit
          mutateDigest: false
          verifyDigest: false
          required: true
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEacG7diNtFSMNUD+A0dZKZJOXVZ22
                      pQUw77geH1ZFcUp5UC6mICQ6GjBxEBpFZ+iw5QP2vMPB90QDI2pdmTErOA==
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true
                    ctlog:
                      ignoreSCT: true
```
