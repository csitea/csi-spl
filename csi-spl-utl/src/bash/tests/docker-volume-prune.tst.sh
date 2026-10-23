#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_docker_volume_prune (SPL-3087): anonymous dangling docker
# volumes older than the age limit are removed, nothing else.
# Drives the action against a STUB docker (listing files and an rm log under a
# temp dir); the box's docker daemon is never touched.
#   1. DRY_RUN=1 (the default): plans the old anonymous dangling volume with
#      its size and the total, removes nothing, exit 1
#   2. DRY_RUN=0 removes exactly that one volume (docker volume rm, no -f)
#   3. a named dangling volume is kept
#   4. an anonymous dangling volume younger than the limit (59 min) is kept
#   5. one mounted by a stopped container is kept (docker listed it dangling)
#   6. DOCKER_VOLUME_PRUNE_MIN_AGE_MIN overrides the limit
#   7. build cache: plan only with DRY_RUN=1, `builder prune -f --filter
#      until=60m` with DRY_RUN=0, nothing without the flag
#   8. a failed rm: WARN, counted, exit 1
#   9. docker volume ls fails -> exit 2; a bad age -> exit 2
#  10. nothing to do -> exit 0
#  11. ./run -a do_docker_volume_prune runs it
#  12. the code never calls `volume prune` or `system prune`
#  13. LIVE GUARD: no call reached a docker outside $T
# CONTROL: DOCKER_VOLUME_PRUNE_TST_FUNC_SH=<copy without the age check> makes
# case 4 fail (the young volume is planned).
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="${DOCKER_VOLUME_PRUNE_TST_FUNC_SH:-$UTL_ROOT/src/bash/run/docker-volume-prune.func.sh}"

T=$(mktemp -d /tmp/dvp.XXXXXX)
trap 'rm -rf "$T"' EXIT
BIN="$T/bin" LIVE="$T/live.log" RM_LOG="$T/rm.log" CALLS="$T/calls.log"
mkdir -p "$BIN"
: >"$LIVE"; : >"$RM_LOG"; : >"$CALLS"

NOW=$(date -d '2026-10-23 12:00:00 +0000' +%s)
hex() { printf '%064d' 0 | tr 0 "$1"; }
OLD=$(hex a) YOUNG=$(hex b) STOPPED=$(hex c) NAMED=spl-lde_pg-data
# ctime <minutes ago>: a volume CreatedAt in docker's format
ctime() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%dT%H:%M:%SZ'; }

# the listings: dangling volumes; created times; sizes; container mounts
setup() {
  printf '%s\n' "$OLD" "$YOUNG" "$STOPPED" "$NAMED" >"$T/dangling"
  { echo "$OLD $(ctime 600)"; echo "$YOUNG $(ctime 59)"; echo "$STOPPED $(ctime 900)"; echo "$NAMED $(ctime 9000)"; } >"$T/created"
  printf '%s 869.2MB;%s 12MB;%s 1.5GB;%s 3GB;' "$OLD" "$YOUNG" "$STOPPED" "$NAMED" >"$T/df"
  echo "ctr-stopped" >"$T/ps"
  echo "$STOPPED" >"$T/mounts"
}

cat >"$BIN/docker-stub" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$CALLS"
case "\$1 \$2" in
  "volume ls") [[ -f "$T/ls.fail" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
      cat "$T/dangling" ;;
  "volume inspect") awk -v n="\${!#}" '\$1 == n { print \$2 }' "$T/created" ;;
  "volume rm") printf '%s\n' "\$*" >>"$RM_LOG"; [[ -f "$T/rm.fail" ]] && { echo "volume is in use" >&2; exit 1; }; exit 0 ;;
  "ps -aq") cat "$T/ps" ;;
  "inspect --format") cat "$T/mounts" ;;
  "system df") cat "$T/df" ;;
  "builder prune") printf '%s\n' "\$*" >>"$RM_LOG"; echo "Total reclaimed space: 1GB" ;;
  *) echo "unexpected docker \$*" >>"$LIVE"; exit 1 ;;
esac
EOF
# sentinel: a real docker reached through PATH
printf '#!/bin/bash\necho "LIVE docker $*" >>"%s"\nexit 1\n' "$LIVE" >"$BIN/docker"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

unset DRY_RUN DOCKER_VOLUME_PRUNE_MIN_AGE_MIN DOCKER_VOLUME_PRUNE_BUILD_CACHE
export DOCKER_VOLUME_PRUNE_DOCKER="$BIN/docker-stub" DOCKER_VOLUME_PRUNE_NOW="$NOW"

# shellcheck source=/dev/null
run_fn() { (source "$FUNC_SH"; do_docker_volume_prune) >"$T/out" 2>&1; echo $? >"$T/rc"; }
rc() { cat "$T/rc"; }
has() { grep -qF -- "$1" "$T/out"; }

# 1. DRY_RUN unset = 1
setup; : >"$RM_LOG"
run_fn
if [[ "$(rc)" == 1 ]] && has "PLAN remove volume $OLD (869.2MB, 600 min old" && [[ ! -s "$RM_LOG" ]] &&
  has "would remove 1 anonymous dangling volume(s) older than 60 min, total 869.2 MB"; then
  pass "1. default DRY_RUN=1 plans the old volume with size and total, removes nothing, exit 1"
else fail "1. rc=$(rc) rm=$(cat "$RM_LOG") $(cat "$T/out")"; fi

# 2. DRY_RUN=0
: >"$RM_LOG"
DRY_RUN=0 run_fn
if [[ "$(rc)" == 1 && "$(cat "$RM_LOG")" == "volume rm $OLD" ]] && has "removed 1 anonymous"; then
  pass "2. DRY_RUN=0 removes exactly the old anonymous dangling volume (volume rm, no -f)"
else fail "2. rc=$(rc) rm=[$(cat "$RM_LOG")] $(cat "$T/out")"; fi

# 3. / 4. / 5. (from the DRY_RUN=0 run above)
if ! grep -q "$NAMED" "$RM_LOG" && has "kept 1 named"; then pass "3. a named dangling volume is kept"
else fail "3. $(cat "$T/out")"; fi
if ! grep -q "$YOUNG" "$RM_LOG" && has "1 younger"; then pass "4. a 59 min anonymous dangling volume is kept"
else fail "4. young volume not kept: rm=$(cat "$RM_LOG") $(cat "$T/out")"; fi
if ! grep -q "$STOPPED" "$RM_LOG" && has "keep ${STOPPED:0:12}: a container mounts it"; then
  pass "5. a volume mounted by a stopped container is kept"
else fail "5. $(cat "$T/out")"; fi

# 6. age override
: >"$RM_LOG"
DRY_RUN=0 DOCKER_VOLUME_PRUNE_MIN_AGE_MIN=30 run_fn
if [[ "$(sort "$RM_LOG")" == "$(printf 'volume rm %s\nvolume rm %s' "$OLD" "$YOUNG" | sort)" ]]; then
  pass "6. DOCKER_VOLUME_PRUNE_MIN_AGE_MIN=30 also removes the 59 min one"
else fail "6. rm=$(cat "$RM_LOG")"; fi

# 7. build cache
: >"$RM_LOG"
DOCKER_VOLUME_PRUNE_BUILD_CACHE=1 run_fn
r1="$(rc)"; p1=0; has "PLAN docker builder prune -f --filter until=60m" && p1=1; s1="$(cat "$RM_LOG")"
DRY_RUN=0 DOCKER_VOLUME_PRUNE_BUILD_CACHE=1 run_fn
if [[ "$r1" == 1 && "$p1" == 1 && -z "$s1" ]] && grep -qx 'builder prune -f --filter until=60m' "$RM_LOG"; then
  : >"$RM_LOG"; DRY_RUN=0 run_fn
  if ! grep -q builder "$RM_LOG"; then pass "7. build cache: plan, then prune until=60m with DRY_RUN=0, none without the flag"
  else fail "7. builder pruned without the flag"; fi
else fail "7. r1=$r1 p1=$p1 s1=$s1 rm=$(cat "$RM_LOG")"; fi

# 8. failed rm
touch "$T/rm.fail"
DRY_RUN=0 run_fn
rm -f "$T/rm.fail"
if [[ "$(rc)" == 1 ]] && has "WARN cannot remove volume $OLD" && has "failed 1"; then
  pass "8. a failed rm is WARNed, counted, exit 1"
else fail "8. rc=$(rc) $(cat "$T/out")"; fi

# 9. docker fails / bad age
touch "$T/ls.fail"; run_fn; r1="$(rc)"; rm -f "$T/ls.fail"
DOCKER_VOLUME_PRUNE_MIN_AGE_MIN=abc run_fn
if [[ "$r1" == 2 && "$(rc)" == 2 ]]; then pass "9. docker volume ls failure and a bad age -> exit 2"
else fail "9. r1=$r1 rc=$(rc)"; fi

# 10. nothing to do
printf '%s\n' "$YOUNG" "$NAMED" >"$T/dangling"; : >"$RM_LOG"
DRY_RUN=0 run_fn
if [[ "$(rc)" == 0 && ! -s "$RM_LOG" ]]; then pass "10. nothing to do -> exit 0"
else fail "10. rc=$(rc) $(cat "$T/out")"; fi

# 11. ./run
setup; : >"$RM_LOG"
if [[ -z "${DOCKER_VOLUME_PRUNE_TST_FUNC_SH:-}" ]]; then
  (cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_docker_volume_prune) >"$T/out" 2>&1
  r=$?
  if [[ "$r" == 1 ]] && has "PLAN remove volume $OLD" && [[ ! -s "$RM_LOG" ]]; then
    pass "11. ./run -a do_docker_volume_prune runs it (exit 1, plan only)"
  else fail "11. ./run rc=$r $(tail -5 "$T/out")"; fi
fi

# 12. no blanket prune anywhere in the calls or the code
if [[ -f "$FUNC_SH" ]] && ! grep -qE 'volume prune|system prune' "$CALLS" && ! grep -vE '^\s*#' "$FUNC_SH" | grep -E 'volume prune|system prune' >/dev/null; then
  pass "12. never calls docker volume prune or docker system prune"
else fail "12. a blanket prune: $(grep -nE 'volume prune|system prune' "$CALLS" "$FUNC_SH")"; fi

# 13. live guard
if [[ ! -s "$LIVE" ]]; then pass "13. LIVE GUARD: no real docker reached"
else fail "13. LIVE calls: $(cat "$LIVE")"; fi

echo "docker-volume-prune: $fails failure(s)"
[[ "$fails" -eq 0 ]]
