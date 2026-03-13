# -- STAGE 1: downloader (Pinned by Digest for Reproducibility) --
FROM debian:12-slim@sha256:12c49e9849567996c56f8f5539d09c2d1b5a59302633010f3c535df21a141b21 AS downloader

# Version arguments for bit-for-bit reproducibility
ARG STEAMPIPE_VERSION=2.4.0
ARG POWERPIPE_VERSION=1.5.0
ARG TAILPIPE_VERSION=0.7.2
ARG ARCH=linux_amd64

# Copy the generated checksums file
COPY vendor/bin/tool_checksums.txt /tmp/checksums.txt

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL "https://github.com/turbot/steampipe/releases/download/v${STEAMPIPE_VERSION}/steampipe_${ARCH}.tar.gz" -o /tmp/steampipe_v${STEAMPIPE_VERSION}.tar.gz \
    && curl -fsSL "https://github.com/turbot/powerpipe/releases/download/v${POWERPIPE_VERSION}/powerpipe.linux.amd64.tar.gz" -o /tmp/powerpipe_v${POWERPIPE_VERSION}.tar.gz \
    && curl -fsSL "https://github.com/turbot/tailpipe/releases/download/v${TAILPIPE_VERSION}/tailpipe.linux.amd64.tar.gz" -o /tmp/tailpipe_v${TAILPIPE_VERSION}.tar.gz \
    && cd /tmp && sha256sum -c /tmp/checksums.txt \
    && tar -xzf steampipe_v${STEAMPIPE_VERSION}.tar.gz -C /usr/local/bin \
    && tar -xzf powerpipe_v${POWERPIPE_VERSION}.tar.gz -C /usr/local/bin \
    && tar -xzf tailpipe_v${TAILPIPE_VERSION}.tar.gz -C /usr/local/bin

# -- STAGE 2: runtime (Pinned by Digest) --
FROM debian:12-slim@sha256:12c49e9849567996c56f8f5539d09c2d1b5a59302633010f3c535df21a141b21

# Set shell with pipefail for safer execution
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime dependencies (Minimized)
RUN apt-get update && apt-get install -y --no-install-recommends \
    awscli \
    bash \
    ca-certificates \
    python3 \
    postgresql-client \
    procps \
    lsof \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --uid 1000 powerpipe \
    && mkdir -p /workspace /home/powerpipe/.aws /home/powerpipe/.steampipe /home/powerpipe/.powerpipe /home/powerpipe/.tailpipe \
    && chown -R powerpipe:powerpipe /workspace /home/powerpipe

# Copy verified binaries from downloader
COPY --from=downloader --chown=root:root /usr/local/bin/steampipe /usr/local/bin/steampipe
COPY --from=downloader --chown=root:root /usr/local/bin/powerpipe /usr/local/bin/powerpipe
COPY --from=downloader --chown=root:root /usr/local/bin/tailpipe /usr/local/bin/tailpipe

# Orchestration scripts
COPY --chown=root:root scripts/compose-steampipe.sh /usr/local/bin/
COPY --chown=root:root scripts/compose-powerpipe.sh /usr/local/bin/
COPY --chown=root:root scripts/compose-benchmark-runner.sh /usr/local/bin/
COPY --chown=root:root scripts/compose-tailpipe.sh /usr/local/bin/
COPY --chown=root:root pyproject.toml /opt/turbot-ops/pyproject.toml
COPY --chown=root:root src /opt/turbot-ops/src
RUN chmod 0555 /usr/local/bin/compose-*.sh

USER powerpipe
WORKDIR /workspace

# Pre-install plugins and mods into the image to eliminate runtime network dependencies
RUN steampipe plugin install aws && \
    tailpipe plugin install aws && \
    tailpipe mod install github.com/turbot/tailpipe-mod-aws-cloudtrail-log-detections && \
    tailpipe mod install github.com/turbot/tailpipe-mod-aws-vpc-flow-log-detections && \
    tailpipe mod install github.com/turbot/tailpipe-mod-aws-s3-server-access-log-detections && \
    tailpipe mod install github.com/turbot/tailpipe-mod-aws-cost-usage-report-insights

# Force the container to run as the non-root user
USER powerpipe
CMD ["/usr/local/bin/compose-powerpipe.sh"]
