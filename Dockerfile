FROM debian:12-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    iproute2 \
    lsof \
    procps \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --uid 1000 powerpipe

COPY vendor/bin/steampipe /usr/local/bin/steampipe
COPY vendor/bin/powerpipe /usr/local/bin/powerpipe
COPY scripts/compose-runner.sh /usr/local/bin/compose-runner.sh

RUN chmod 0755 /usr/local/bin/steampipe /usr/local/bin/powerpipe /usr/local/bin/compose-runner.sh \
  && mkdir -p /workspace /home/powerpipe/.aws /home/powerpipe/.steampipe /tmp \
  && chown -R powerpipe:powerpipe /workspace /home/powerpipe /tmp

WORKDIR /workspace
ENV HOME=/home/powerpipe

USER powerpipe
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash", "/usr/local/bin/compose-runner.sh"]
