#!/usr/bin/env bash
# Host loop for one repository: one single-use JIT runner container per job. Needs gh, docker and the Sysbox runtime.
# Usage: run.sh <repository name under OWNER>. systemd passes the ci-runner@<repo> instance name.
set -euo pipefail

EX_CONFIG=78
REPO=${1:-}
OWNER=${OWNER:-}
IMAGE=${IMAGE:-ci-runner:local}
TOKEN_FILE=${TOKEN_FILE:-/etc/ci-runner/token}
# Starting points, not measurements: tune against a real run (docker stats while a job runs).
RUNNER_MEMORY=${RUNNER_MEMORY:-6g}
RUNNER_PIDS_LIMIT=${RUNNER_PIDS_LIMIT:-4096}
# Jobs this repository runs at once: one worker, and one single-use runner, each.
RUNNER_COUNT=${RUNNER_COUNT:-1}
export DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 8.8.8.8}"
NAME_PREFIX=ci-runner

if ! [[ $REPO =~ ^[A-Za-z0-9._-]+$ && $REPO != . && $REPO != .. && $OWNER =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "usage: run.sh <repository name>; the name and OWNER (set in /etc/ci-runner/env) must be plain GitHub names" >&2
  exit "$EX_CONFIG"
fi
if ! [[ $RUNNER_COUNT =~ ^[1-9][0-9]?$ ]]; then
  echo "RUNNER_COUNT must be a number from 1 to 99, got '$RUNNER_COUNT'" >&2
  exit "$EX_CONFIG"
fi

# A public repository takes pull requests from forks, whose code would run here: never register for one.
# Exit 78 is in RestartPreventExitStatus, so systemd leaves the instance stopped. A failed lookup only retries.
check_private() {
  local private
  if ! private=$(GH_TOKEN="$token" gh api "repos/$OWNER/$REPO" --jq .private); then
    echo "cannot look up $OWNER/$REPO (wrong name, or not in the token's repository access)" >&2
    return 1
  fi
  if [ "$private" != true ]; then
    echo "refusing: $OWNER/$REPO is not private (.private=$private); this runner never serves a public repository" >&2
    exit "$EX_CONFIG"
  fi
}

dns=()
for server in $DNS_SERVERS; do dns+=(--dns "$server"); done

remove_containers() {
  docker ps -aq --filter "label=ci-runner.repo=$OWNER/$REPO" | while read -r id; do docker rm -f "$id" >/dev/null; done
}
remove_containers

worker() {
  while true; do
    if ! token=$(<"$TOKEN_FILE"); then
      echo "cannot read $TOKEN_FILE; retrying in 30s" >&2
      sleep 30
      continue
    fi
    check_private || { sleep 30; continue; }
    # GitHub caps a runner name at 64 characters: 7 + 40 + 1 + at most 16 here; the suffix keeps it unique.
    base="$REPO-$(hostname -s)"
    name="sysbox-${base:0:40}-$(date +%s)-$RANDOM"
    if ! jit_response=$(GH_TOKEN="$token" gh api -X POST "repos/$OWNER/$REPO/actions/runners/generate-jitconfig" \
        -f "name=$name" -F runner_group_id=1 \
        -f 'labels[]=self-hosted' -f 'labels[]=Linux' -f 'labels[]=X64' -f 'labels[]=sysbox' \
        --jq '.runner.id, .encoded_jit_config'); then
      echo "generate-jitconfig failed; retrying in 30s" >&2
      sleep 30
      continue
    fi
    runner_id=${jit_response%%$'\n'*}
    jit_config=${jit_response#*$'\n'}
    if [ -z "$runner_id" ] || [ -z "$jit_config" ] || [ "$jit_config" = "$jit_response" ]; then
      echo "generate-jitconfig returned no runner id or config; retrying in 30s" >&2
      sleep 30
      continue
    fi
    export ACTIONS_RUNNER_INPUT_JITCONFIG=$jit_config
    if ! docker run --rm --pull never --runtime=sysbox-runc --name "$NAME_PREFIX-$name" \
        --label "ci-runner.repo=$OWNER/$REPO" \
        --memory "$RUNNER_MEMORY" --pids-limit "$RUNNER_PIDS_LIMIT" "${dns[@]}" \
        -e ACTIONS_RUNNER_INPUT_JITCONFIG -e DNS_SERVERS "$IMAGE"; then
      echo "runner container exited non-zero; deleting runner $runner_id" >&2
      GH_TOKEN="$token" gh api -X DELETE "repos/$OWNER/$REPO/actions/runners/$runner_id" >/dev/null \
        || echo "could not delete runner $runner_id (already gone is fine)" >&2
      sleep 30
    fi
    unset ACTIONS_RUNNER_INPUT_JITCONFIG
    sleep 2
  done
}

for _ in $(seq "$RUNNER_COUNT"); do worker & done
# A worker only ends on exit 78 or an error: end the unit so systemd restarts every worker (or, on 78, stays stopped).
# On any exit, stop the other workers' containers: on 78 their idle runners would stay registered for a public repository.
trap 'exit 143' TERM
trap remove_containers EXIT
rc=0
wait -n || rc=$?
jobs -p | while read -r pid; do kill "$pid" 2>/dev/null || true; done
wait
exit "$rc"
