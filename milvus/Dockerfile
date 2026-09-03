# Use official image as base
ARG MILVUS_VERSION=2.6.7
FROM milvusdb/milvus:v${MILVUS_VERSION}

# Run as root for the user/permission setup below; base images >= 3.0 default to USER milvus
USER 0:0

# Ensure a non-root user at uid/gid 1000 (standard in most clusters, and what every
# published MilvusVersion's securityContext.runAsUser expects).
# Milvus < 3.0 base images have no milvus user -> create it at 1000.
# Milvus >= 3.0 base images ship a milvus user at uid/gid 999 -> remap it to 1000 so
# data written by older versions (uid 1000) stays readable after an upgrade.
RUN set -eux; \
    if id milvus >/dev/null 2>&1; then \
        groupmod -g 1000 milvus; \
        usermod -u 1000 -g 1000 milvus; \
    else \
        groupadd --gid 1000 milvus; \
        useradd --uid 1000 --gid milvus --shell /bin/bash --create-home milvus; \
    fi

# Fix permissions only where needed (base-image files may be owned by uid 999)
RUN chown -R 1000:1000 /milvus/bin /milvus/lib /milvus/configs && \
    chmod -R 755 /milvus/bin /milvus/lib

# Allow 'Others' (user 1000) to traverse (enter) the configs folder
RUN chmod o+rx /milvus/configs

RUN mkdir -p /var/lib/milvus/data /var/lib/milvus/logs && \
    chown -R 1000:1000 /var/lib/milvus/data /var/lib/milvus/logs

# Switch to non-root user
USER 1000:1000

# Keep original working directory and entrypoint
WORKDIR /milvus
EXPOSE 19530 9091

ENTRYPOINT ["/tini", "--", "/milvus/bin/milvus"]

CMD ["run", "standalone"]