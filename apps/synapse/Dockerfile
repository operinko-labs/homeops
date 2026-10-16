# Version comes from apps/synapse/VERSION via the build workflow
ARG SYNAPSE_VERSION
FROM oci.element.io/synapse:${SYNAPSE_VERSION}
# Bump by hand, together with a VERSION change: the image tag is VERSION
# and CI skips the build when that tag already exists in Harbor
ARG S3_PROVIDER_VERSION=1.7.0
RUN pip install --no-cache-dir "synapse-s3-storage-provider==${S3_PROVIDER_VERSION}" \
 && python3 -c "import s3_storage_provider" \
 && command -v s3_media_upload
