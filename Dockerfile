# Single-use GitHub Actions runner with its own Docker daemon, meant for `--runtime=sysbox-runc`.
# Versions: actions/runner v2.338.2, cli/cli v2.103.3, moby docker-v29.9.2 (static build from
# download.docker.com), Ubuntu 24.04 index digest. Build for linux/amd64.
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
ARG GH_VERSION=2.103.3
ARG GH_SHA256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG DOCKER_VERSION=29.9.2
ARG DOCKER_SHA256=9ac225999fd5e863f7694c728ef23d480616b1e5639328fa309befd4243d69eb

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

RUN set -eux; \
    curl -fsSL -o /tmp/docker.tgz "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"; \
    echo "${DOCKER_SHA256}  /tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1; \
    curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    echo "${GH_SHA256}  /tmp/gh.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tgz -C /usr/local --strip-components=1 "gh_${GH_VERSION}_linux_amd64/bin/gh"; \
    rm /tmp/docker.tgz /tmp/gh.tgz

# Passwordless sudo grants nothing new: runner is already root-equivalent inside this throwaway container
# through its docker group (the inner dockerd is root-owned).
RUN groupadd docker \
 && useradd --create-home --shell /bin/bash --groups docker runner \
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
