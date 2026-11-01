#!/usr/bin/env bash
# No arguments: run the single-use runner. With arguments: run them as the runner user (used to check the image).
set -euo pipefail

if [ $# -eq 0 ]; then
  : "${ACTIONS_RUNNER_INPUT_JITCONFIG:?single-use JIT config is required}"
  set -- ./run.sh
fi

dns=()
for server in $DNS_SERVERS; do dns+=(--dns "$server"); done

dockerd "${dns[@]}" >/var/log/dockerd.log 2>&1 &
for _ in $(seq 60); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null 2>&1 || { tail -n 50 /var/log/dockerd.log >&2; echo "dockerd did not start" >&2; exit 1; }

cd /home/runner
# setpriv keeps root's HOME; --reset-env would drop ACTIONS_RUNNER_INPUT_JITCONFIG.
export HOME=/home/runner USER=runner LOGNAME=runner
exec setpriv --reuid=runner --regid=runner --init-groups "$@"
