#!/usr/bin/env bash
# Checks run.sh's guards with fake gh and docker on PATH: no network, no Docker, no root. Usage: bash test.sh
set -euo pipefail
# run.sh needs bash 4.3+ (wait -n), as on Ubuntu 24.04. On macOS: brew install bash, then run this with it.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "test.sh needs bash 4.3 or newer, this is $BASH_VERSION" >&2; exit 1
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/gh.log"
case "$*" in
  *generate-jitconfig*) printf '%s\n' 42 FAKE_JIT_CONFIG ;;
  *--jq\ .private*) echo "$FAKE_PRIVATE" ;;
esac
FAKE
cat >"$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/docker.log"
# `run` waits (up to 5 s) until FAKE_RUNS runs started, so parallel workers are all seen before any ends.
if [ "$1" = run ]; then
  for _ in $(seq 100); do [ "$(grep -c '^run ' "$FAKE_DIR/docker.log")" -ge "${FAKE_RUNS:-1}" ] && break; /bin/sleep 0.05; done
fi
FAKE
# run.sh sleeps between loops; failing here ends its `set -e` loop after the first pass.
printf '#!/bin/sh\nexit 99\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/gh" "$tmp/bin/docker" "$tmp/bin/sleep"
echo faketoken >"$tmp/token"

export FAKE_DIR=$tmp PATH="$tmp/bin:$PATH" OWNER=fakeowner TOKEN_FILE=$tmp/token IMAGE=fake:image
fails=0

# usage: run_kit <private|public> <repo>; sets rc, empties the logs first
run_kit() {
  : >"$tmp/gh.log"; : >"$tmp/docker.log"
  FAKE_PRIVATE=$([ "$1" = private ] && echo true || echo false) && export FAKE_PRIVATE
  rc=0
  "$BASH" "$here/run.sh" "$2" >"$tmp/out" 2>&1 || rc=$?
}

check() {
  if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); fi
}

run_kit public pubrepo
if [ "$rc" -eq 78 ] && ! grep -q '^run ' "$tmp/docker.log"; then check "public repo: exit 78, no docker run" ok; else check "public repo: exit 78, no docker run (rc=$rc)" no; fi

run_kit private privrepo
if grep -q -- '^run .*--runtime=sysbox-runc' "$tmp/docker.log"; then check "private repo: docker run with sysbox-runc" ok; else check "private repo: docker run with sysbox-runc" no; fi
if grep -q -- 'generate-jitconfig.*labels\[\]=sysbox' "$tmp/gh.log"; then check "private repo: sysbox label in generate-jitconfig" ok; else check "private repo: sysbox label in generate-jitconfig" no; fi

run_kit private 'bad/name'
if [ "$rc" -eq 78 ] && [ ! -s "$tmp/docker.log" ] && [ ! -s "$tmp/gh.log" ]; then check "bad name: exit 78, nothing called" ok; else check "bad name: exit 78, nothing called (rc=$rc)" no; fi

RUNNER_COUNT=3 FAKE_RUNS=3 run_kit private privrepo
names=$(grep '^run ' "$tmp/docker.log" | grep -o -- '--name [^ ]*' | sort -u | wc -l)
if [ "$names" -eq 3 ]; then check "RUNNER_COUNT=3: three runners, distinct names" ok; else check "RUNNER_COUNT=3: three runners, distinct names (got $names)" no; fi

RUNNER_COUNT=0 run_kit private privrepo
if [ "$rc" -eq 78 ] && [ ! -s "$tmp/docker.log" ] && [ ! -s "$tmp/gh.log" ]; then check "RUNNER_COUNT=0: exit 78, nothing called" ok; else check "RUNNER_COUNT=0: exit 78, nothing called (rc=$rc)" no; fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
