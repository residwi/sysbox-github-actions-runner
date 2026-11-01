#!/bin/bash
# One-time host setup for the CI runner VM (Ubuntu 24.04 x86_64). Run as root, either as cloud-init user-data
# (first boot) or by hand: `sudo bash setup.sh`. Safe to re-run. `setup.sh verify` only repeats the checks.
# It clones the kit, installs everything but the token and starts no runner: `systemctl enable --now ci-runner@<repo>`
# does that. Log: /var/log/ci-runner-setup.log, last line PASS or FAIL.
set -euo pipefail

# Edit the defaults before use, e.g. OWNER=${OWNER:-myaccount}. OWNER: the GitHub account that owns the served repositories (required).
# KIT_REF: a full commit SHA of the kit, e.g. KIT_REF=${KIT_REF:-<40-char sha>}. Left empty it falls back to `main`,
# which moves; a re-run reuses the ref stored in /etc/ci-runner/env.
OWNER=${OWNER:-}
KIT_REF=${KIT_REF:-}
KIT_REPO=https://github.com/residwi/sysbox-github-actions-runner.git

KIT=/usr/local/src/ci-runner
LOG=/var/log/ci-runner-setup.log
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
SYSBOX_VERSION=0.7.1
SYSBOX_SHA256=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
SMOKE_IMAGE=docker:dind
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=600 -y -q)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
exec > >(tee -a "$LOG") 2>&1
STEP=start
log() { echo "$(date -u +%FT%TZ) $*"; }
step() { STEP=$1; log "step: $1"; }
# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
finish() {
  local rc=$?
  docker rm -f sysbox-smoke >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then log "PASS: ci-runner host setup complete"; else log "FAIL: at step \"$STEP\" (exit $rc)"; fi
}
trap finish EXIT

install_packages() {
  step "preconditions"
  [ "$(uname -m)" = x86_64 ] || { echo "x86_64 only" >&2; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID}-${VERSION_ID}" = ubuntu-24.04 ] || { echo "Ubuntu 24.04 only, found ${ID}-${VERSION_ID}" >&2; exit 1; }
  if [ -z "$OWNER" ] && [ -r /etc/ci-runner/env ]; then OWNER=$(sed -n 's/^OWNER=//p' /etc/ci-runner/env | tail -n 1); fi
  [[ $OWNER =~ ^[A-Za-z0-9-]+$ ]] || { echo "OWNER is required: a GitHub account name" >&2; exit 1; }
  if [ -z "$KIT_REF" ] && [ -r /etc/ci-runner/env ]; then KIT_REF=$(sed -n 's/^KIT_REF=//p' /etc/ci-runner/env | tail -n 1); fi
  if [ -z "$KIT_REF" ]; then
    log "warning: KIT_REF is not set and none is stored; using main, which moves. Pin a commit SHA."
    KIT_REF=main
  fi

  step "base packages"
  "${APT[@]}" update
  "${APT[@]}" install ca-certificates curl git gnupg jq gh unattended-upgrades

  step "unattended upgrades with reboot"
  printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";' 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' \
    >/etc/apt/apt.conf.d/52ci-runner

  step "kit $KIT_REF"
  install -d "$KIT"
  git -C "$KIT" init -q
  git -C "$KIT" remote add origin "$KIT_REPO" 2>/dev/null || git -C "$KIT" remote set-url origin "$KIT_REPO"
  git -C "$KIT" fetch -q --depth 1 origin "$KIT_REF"
  git -C "$KIT" checkout -q --force FETCH_HEAD
  log "kit commit $(git -C "$KIT" rev-parse HEAD)"

  step "docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | grep "^fpr:::::::::${DOCKER_KEY_FPR}:" >/dev/null \
    || { echo "Docker apt key fingerprint mismatch" >&2; exit 1; }
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOT
  "${APT[@]}" update
  # Unpinned: a re-run upgrades to the latest, and the upgrade restarts dockerd, which stops running jobs.
  "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin

  step "sysbox"
  if ! dpkg-query -W -f='${Version}' sysbox-ce 2>/dev/null | grep "^${SYSBOX_VERSION}" >/dev/null; then
    local deb=/tmp/sysbox-ce.deb
    curl -fsSL -o "$deb" "https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}.linux_amd64.deb"
    echo "${SYSBOX_SHA256}  $deb" | sha256sum -c -
    "${APT[@]}" install "$deb"
    rm -f "$deb"
  fi

  step "egress filter"
  install -m 755 -D "$KIT/firewall.sh" /opt/ci-runner/firewall.sh
  install -m 644 "$KIT/ci-firewall.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now ci-firewall

  step "image"
  # --no-cache: a cached layer would keep the image's old Docker.
  docker build --no-cache --platform linux/amd64 -t ci-runner:local "$KIT"

  step "runner user, loop, unit, journal, status command, OWNER, KIT_REF"
  id ci-runner >/dev/null 2>&1 || useradd --system --create-home --groups docker ci-runner
  install -m 755 -D "$KIT/run.sh" /opt/ci-runner/run.sh
  install -m 644 "$KIT/ci-runner@.service" /etc/systemd/system/
  install -m 644 -D "$KIT/journald-ci-runner.conf" /etc/systemd/journald.conf.d/ci-runner.conf
  install -m 755 "$KIT/ci-runner-status" /usr/local/bin/ci-runner-status
  install -d -m 700 -o ci-runner /etc/ci-runner
  touch /etc/ci-runner/env
  sed -i '/^OWNER=/d;/^KIT_REF=/d' /etc/ci-runner/env
  printf '%s\n' "OWNER=$OWNER" "KIT_REF=$KIT_REF" >>/etc/ci-runner/env
  systemctl daemon-reload
  systemctl restart systemd-journald
}

verify() {
  step "sysbox runtime registered"
  docker info | grep -i runtimes | grep sysbox-runc >/dev/null
  log "PASS: sysbox-runc registered"

  step "sysbox smoke test (nested docker)"
  docker rm -f sysbox-smoke >/dev/null 2>&1 || true
  docker run -d --pull always --runtime=sysbox-runc --name sysbox-smoke "$SMOKE_IMAGE" >/dev/null
  for _ in $(seq 60); do docker exec sysbox-smoke docker info >/dev/null 2>&1 && break; sleep 2; done
  docker exec sysbox-smoke docker info >/dev/null
  docker exec sysbox-smoke docker run --rm hello-world | grep 'Hello from Docker!' >/dev/null
  docker rm -f sysbox-smoke >/dev/null
  log "PASS: sysbox smoke test"

  step "egress filter rules"
  [ "$(iptables -S DOCKER-USER | grep -c -- '-i docker0 .*-j DROP')" -eq 6 ]
  iptables -S INPUT | grep -- '-i docker0 -m conntrack --ctstate NEW -j DROP' >/dev/null
  if command -v ip6tables >/dev/null 2>&1; then ip6tables -S INPUT | grep -- '-i docker0 -j DROP' >/dev/null; fi
  log "PASS: egress filter rules"

  step "image: metadata blocked, DNS, nested docker"
  docker run --rm --runtime=sysbox-runc --dns 1.1.1.1 --dns 8.8.8.8 ci-runner:local bash -c '
    if curl -sS -m 5 http://169.254.169.254/; then echo "metadata reachable" >&2; exit 1; fi
    getent hosts github.com
    docker run --rm hello-world | grep "Hello from Docker!" >/dev/null'
  log "PASS: image checks"

  step "runner binary"
  docker run --rm --entrypoint setpriv ci-runner:local --reuid=runner --regid=runner --init-groups \
    /home/runner/bin/Runner.Listener --version
  log "PASS: runner binary"
}

main() {
  [ "${1:-}" = verify ] || install_packages
  verify
}

# Re-running a checkout's own copy replaces this file mid-run: exit before bash reads past this line.
main "$@"; exit $?
