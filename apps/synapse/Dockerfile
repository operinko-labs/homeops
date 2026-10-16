# Version comes from apps/synapse/VERSION via the build workflow
ARG SYNAPSE_VERSION
FROM oci.element.io/synapse:${SYNAPSE_VERSION}
# renovate: datasource=pypi depName=synapse-s3-storage-provider
ARG S3_PROVIDER_VERSION=1.7.0
RUN pip install --no-cache-dir "synapse-s3-storage-provider==${S3_PROVIDER_VERSION}" \
 && python3 -c "import s3_storage_provider" \
 && command -v s3_media_upload
