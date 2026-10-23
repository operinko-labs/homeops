# Version comes from apps/synapse/VERSION via the build workflow
ARG SYNAPSE_VERSION
# Static (musl) state compressor for the nightly CronJob; only the binary is copied
FROM ghcr.io/matrix-org/rust-synapse-compress-state:latest@sha256:bfddeb3421bdd7813f072002c1bf752624e98cb4132a691729aa7901a02564df AS compressor
FROM oci.element.io/synapse:${SYNAPSE_VERSION}
# Bump by hand, together with a VERSION change: the image tag is VERSION
# and CI skips the build when that tag already exists in Harbor
ARG S3_PROVIDER_VERSION=1.7.0
# Upstream ships 12.3.0, which has Critical CVEs; Synapse needs >=10.0.1 and its
# thumbnailer works on 13.x. Drop this once upstream ships a fixed Pillow.
ARG PILLOW_VERSION=13.0.0
# gosu only serves the stock start.py entrypoint; ESS starts Synapse directly as
# an unprivileged user, and gosu's Go runtime trips Harbor's critical-CVE block.
# (The base is distroless-style: apt can't upgrade it, Debian fixes come with
# new upstream images.)
RUN rm -f /usr/sbin/gosu
COPY --from=compressor /usr/local/bin/synapse_auto_compressor /usr/local/bin/synapse_auto_compressor
RUN pip install --no-cache-dir "synapse-s3-storage-provider==${S3_PROVIDER_VERSION}" "pillow==${PILLOW_VERSION}" \
 && pip check \
 && python3 -c "import s3_storage_provider" \
 && command -v s3_media_upload \
 && synapse_auto_compressor --version
