# Single-use GitHub Actions runner with its own Docker daemon, meant for `--runtime=sysbox-runc`.
# Versions: actions/runner v2.338.2, cli/cli v2.103.3, Ubuntu 24.04 index digest; Docker is the latest from
# Docker's apt repository at build time. Build for linux/amd64.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
ARG GH_VERSION=2.103.3
ARG GH_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# RUNNER_MANUALLY_TRAP_SIG and ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT as in the upstream image
# (actions/runner v2.338.2 images/Dockerfile): stop signals reach the runner, logs reach docker logs.
# DNS_SERVERS: public resolvers for the inner dockerd; run.sh passes the same list to `docker run --dns`.
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    DNS_SERVERS="1.1.1.1 8.8.8.8"

# build-essential: `go test -race` needs cgo. iptables: dockerd. sudo, unzip, xz-utils, zstd, jq, python3: tools
# that setup-* actions and common job scripts expect on a GitHub-hosted runner.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg build-essential iptables \
       sudo unzip xz-utils zstd jq python3 \
 && rm -rf /var/lib/apt/lists/*

# Docker unpinned: apt checks the repository's signature, and DOCKER_KEY_FPR the key (same as setup.sh).
# The key file must hold that one key only: apt trusts every key in a signed-by file.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    test "$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}')" = "$DOCKER_KEY_FPR"; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      >/etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    echo "${GH_SHA256}  /tmp/gh.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tgz -C /usr/local --strip-components=1 "gh_${GH_VERSION}_linux_amd64/bin/gh"; \
    rm /tmp/gh.tgz

# Passwordless sudo grants nothing new: runner is already root-equivalent inside this throwaway container
# through its docker group (the inner dockerd is root-owned).
# The docker group comes from the docker-ce package.
RUN useradd --create-home --shell /bin/bash --groups docker runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

WORKDIR /home/runner
RUN set -eux; \
    curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  runner.tgz" | sha256sum -c -; \
    tar -xzf runner.tgz; rm runner.tgz; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner /home/runner

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
