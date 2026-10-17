#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-07: stale ephemeral test container pruner (SPL-2450)
# Drives do_docker_test_container_prune against a STUB docker (a listing file
# and an rm log under a temp dir), stub tmux and temp registries; the box's
# docker daemon, tmux server and spool are never touched.
#   1. DRY_RUN=1: the retired lane's labelled 3 h container is planned, no rm
#      call, PLAN note only, exit 1
#   2. DRY_RUN=0: exactly the gone lanes' old labelled containers are removed
#      (docker rm -f -v <id>), one note to orchestrator (--no-poke), stamp
#   3. unlabelled old container: reported in the note, never removed; a
#      compose-made unlabelled one is not reported
#   4. NAME PATTERN control: a c999-pg / pg-c999 name without a label is never
#      removed, even when c-999 is retired
#   5. a lane with a live tmux window keeps its container (even if retired)
#   6. a lane in registry.tsv (not retired) keeps its container
#   7. age: 119 min kept, 121 min removed (DOCKER_PRUNE_MIN_AGE_MIN=120)
#   8. infrastructure whitelist names are kept with a gone-lane label
#   9. a label that is not an agent id (empty, "foo") is reported only
#  10. same set again -> throttled; a changed set -> sent at once
#  11. a failed rm: WARN, counted, exit 1, the note says FAILED
#  12. docker ps fails -> exit 2
#  13. nothing to do -> exit 0; DRY_RUN=0 clears the stamp
#  14. ./run -a do_docker_test_container_prune runs it
#  15. the four call sites label what they start with csi-spl.lane
#  16. CreatedAt in docker's own format (offset + zone name) is read
#  17. LIVE GUARD: no call reached a docker, tmux or spool-send outside $T
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
REPO_ROOT=$(cd "$UTL_ROOT/.." && pwd)
FUNC_SH="${DOCKER_PRUNE_TST_FUNC_SH:-$UTL_ROOT/src/bash/run/docker-test-container-prune.func.sh}"

T=$(mktemp -d /tmp/dtcp.XXXXXX)
trap 'rm -rf "$T"' EXIT
BIN="$T/bin" LIVE="$T/live.log" RM_LOG="$T/rm.log" SENT="$T/sent.log" LIST="$T/ps.list"
mkdir -p "$BIN" "$T/state"
: >"$LIVE"; : >"$RM_LOG"; : >"$SENT"

FS=$'\x1f'
NOW=$(date -d '2026-10-18 12:00:00 +0000' +%s)
# ctime <minutes ago>: a CreatedAt in docker's format, UTC
ctime() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%d %H:%M:%S +0000 UTC'; }
# row <id> <name> <minutes ago> <lane label or -> <compose project>
row() {
  local id="$1" name="$2" ago="$3" lane="$4" proj="${5:-}" labels=""
  [[ "$lane" != - ]] && labels="csi-spl.lane=$lane"
  [[ -n "$proj" ]] && labels="${labels:+$labels,}com.docker.compose.project=$proj"
  [[ "$lane" == - ]] && lane=""
  printf '%s\n' "$id$FS$name$FS$(ctime "$ago")$FS$lane$FS$proj$FS$labels"
}

# the stub docker: ps prints $LIST; rm logs its args (fails when $T/rm.fail)
cat >"$BIN/docker-stub" <<EOF
#!/bin/bash
case "\$1" in
  ps) [[ -f "$T/ps.fail" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
      cat "$LIST" ;;
  rm) printf '%s\n' "\$*" >>"$RM_LOG"; [[ -f "$T/rm.fail" ]] && { echo "conflict" >&2; exit 1; }; exit 0 ;;
  *) echo "unexpected docker \$*" >>"$LIVE"; exit 1 ;;
esac
EOF
cat >"$BIN/tmux-stub" <<EOF
#!/bin/bash
cat "$T/windows" 2>/dev/null
EOF
cat >"$BIN/send-stub" <<EOF
#!/bin/bash
printf 'SEND %s\n' "\$*" >>"$SENT"
EOF
# sentinels: a real docker / tmux / spool binary reached through PATH
for s in docker tmux spool; do
  printf '#!/bin/bash\necho "LIVE %s $*" >>"%s"\nexit 1\n' "$s" "$LIVE" >"$BIN/$s"
done
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

printf 'c-100\tclaude\t%%1\t/wt/c-100\t20261018T000000Z\nc-200\tclaude\t%%2\t/wt/c-200\t20261018T000000Z\n' >"$T/registry.tsv"
printf 'c-200\tclaude\t%%2\t/wt/c-200\t20261017T000000Z\t20261017T010000Z\nc-300\tclaude\t%%3\t/wt/c-300\t20261017T000000Z\t20261017T010000Z\nc-999\tclaude\t%%9\t/wt/c-999\t20261017T000000Z\t20261017T010000Z\nc-400\tclaude\t%%4\t/wt/c-400\t20261017T000000Z\t20261017T010000Z\n' >"$T/registry.retired.tsv"
echo "c-400 rel-lane" >"$T/windows"

unset SPOOL_AGENT_ID SPOOL_TMUX_SOCKET DOCKER_PRUNE_ALERT_FROM DEV_BOX
export DOCKER_PRUNE_DOCKER="$BIN/docker-stub" DOCKER_PRUNE_TMUX="$BIN/tmux-stub"
export DOCKER_PRUNE_SEND_CMD="$BIN/send-stub" DOCKER_PRUNE_NOW="$NOW"
export DOCKER_PRUNE_ACTIVE_REGISTRY="$T/registry.tsv" DOCKER_PRUNE_RETIRED_REGISTRY="$T/registry.retired.tsv"
export DOCKER_PRUNE_STATE_DIR="$T/state" DEV_BOX=PC

full_list() {
  {
    row id-retired c300-pg 180 c-300           # retired, 3 h -> remove
    row id-absent  spl-x-pg-1 180 c-555        # in no registry, no window -> remove
    row id-reused  c200-pg 180 c-200           # in both registries -> retired -> remove
    row id-live    c100-pg 180 c-100           # active -> keep
    row id-window  c400-pg 180 c-400           # retired but a live window -> keep
    row id-young   spl-y-pg-2 119 c-300        # 119 min -> keep
    row id-old121  spl-z-pg-3 121 c-300        # 121 min -> remove
    row id-infra   con-csi-csi-spl-tf-runner 9000 c-300   # whitelist -> keep
    row id-nolab   c999-pg 4000 -              # unlabelled, name looks like a lane -> report only
    row id-nolab2  pg-c999 4000 -              # same
    row id-compose con-other-rdb 9000 - other  # compose-made unlabelled -> silent
    row id-empty   spl-e-pg 300 ""             # empty label -> report only
    row id-foo     spl-f-pg 300 foo            # not an agent id -> report only
  } >"$LIST"
}

# shellcheck source=/dev/null
run_fn() { (source "$FUNC_SH"; do_docker_test_container_prune) >"$T/out" 2>&1; echo $? >"$T/rc"; }
rc() { cat "$T/rc"; }
has() { grep -qF -- "$1" "$T/out"; }

# 1. DRY_RUN=1
full_list; : >"$RM_LOG"; : >"$SENT"
DRY_RUN=1 run_fn
if [[ "$(rc)" == 1 ]] && has "PLAN remove c300-pg (lane c-300 gone, 180 min old)" && [[ ! -s "$RM_LOG" ]] &&
  [[ ! -s "$SENT" ]] && has "INFO PLAN note to orchestrator" && [[ ! -e "$T/state/alert.stamp" ]]; then
  pass "1. DRY_RUN=1 plans the removal, removes nothing, sends nothing, exit 1"
else fail "1. DRY_RUN=1: rc=$(rc) rm=$(cat "$RM_LOG") sent=$(cat "$SENT") $(cat "$T/out")"; fi

# 2. DRY_RUN=0
: >"$RM_LOG"; : >"$SENT"
DRY_RUN=0 run_fn
want=$'rm -f -v id-absent\nrm -f -v id-old121\nrm -f -v id-retired\nrm -f -v id-reused'
got="$(sort "$RM_LOG")"
if [[ "$(rc)" == 1 && "$got" == "$want" ]]; then
  pass "2. DRY_RUN=0 removes exactly the 4 gone-lane containers older than 2 h"
else fail "2. removed: [$got] rc=$(rc) $(cat "$T/out")"; fi
if [[ "$(wc -l <"$SENT")" == 1 ]] && grep -q -- '--to orchestrator' "$SENT" && grep -q -- '--no-poke' "$SENT" &&
  grep -q -- '--kind note' "$SENT" && grep -q 'removed 4 stale' "$SENT" && [[ -s "$T/state/alert.stamp" ]]; then
  pass "2b. one note to orchestrator (--kind note --no-poke), stamp written"
else fail "2b. sent=$(cat "$SENT")"; fi

# 3. unlabelled
if grep -q 'c999-pg (4000 min, no csi-spl.lane label)' "$SENT" && ! grep -q 'con-other-rdb' "$SENT" &&
  ! grep -q 'id-nolab\|id-compose' "$RM_LOG"; then
  pass "3. unlabelled old container reported, never removed; compose-made one silent"
else fail "3. sent=$(cat "$SENT") rm=$(cat "$RM_LOG")"; fi

# 4. name pattern control
if ! grep -q 'id-nolab' "$RM_LOG" && has "WARN unlabelled, report only: pg-c999"; then
  pass "4. c999-pg / pg-c999 with retired c-999 and no label: never removed by name"
else fail "4. rm=$(cat "$RM_LOG")"; fi

# 5. / 6. / 8.
if ! grep -q 'id-window' "$RM_LOG" && has "keep c400-pg: lane c-400 has a tmux window"; then
  pass "5. a lane with a live tmux window keeps its container"
else fail "5. $(cat "$T/out")"; fi
if ! grep -q 'id-live' "$RM_LOG" && has "keep c100-pg: lane c-100 is in registry.tsv"; then
  pass "6. a lane in registry.tsv keeps its container"
else fail "6. $(cat "$T/out")"; fi
if ! grep -q 'id-infra' "$RM_LOG" && has "keep con-csi-csi-spl-tf-runner: infrastructure"; then
  pass "8. infrastructure whitelist kept with a gone-lane label"
else fail "8. $(cat "$T/out")"; fi

# 7. age
if ! grep -q 'id-young' "$RM_LOG" && grep -q 'id-old121' "$RM_LOG"; then
  pass "7. 119 min kept, 121 min removed"
else fail "7. rm=$(cat "$RM_LOG")"; fi

# 9. non-agent-id label
if has "spl-e-pg (300 min, csi-spl.lane='' is not an agent id)" && has "spl-f-pg (300 min, csi-spl.lane='foo' is not an agent id)" &&
  ! grep -q 'id-empty\|id-foo' "$RM_LOG"; then
  pass "9. empty / non-agent-id label reported only"
else fail "9. $(cat "$T/out")"; fi

# 10. throttle (the stub's rm does not change the listing: same set again)
: >"$SENT"
DRY_RUN=0 run_fn
if [[ ! -s "$SENT" ]] && has "throttled"; then pass "10. same set again -> throttled"
else fail "10. sent=$(cat "$SENT")"; fi
row id-new c301-pg 200 c-300 >>"$LIST"
DRY_RUN=0 run_fn
if [[ "$(wc -l <"$SENT")" == 1 ]] && grep -q 'removed 5 stale' "$SENT"; then pass "10b. changed set -> sent at once"
else fail "10b. sent=$(cat "$SENT")"; fi
echo "x 1" >"$T/state/alert.stamp"; : >"$SENT"
DRY_RUN=0 run_fn
DRY_RUN=0 DOCKER_PRUNE_THROTTLE_S=0 run_fn
if [[ "$(wc -l <"$SENT")" == 2 ]]; then pass "10c. new set, then DOCKER_PRUNE_THROTTLE_S=0 -> sent each time"
else fail "10c. sent=$(cat "$SENT")"; fi

# 11. failed rm
row id-retired c300-pg 180 c-300 >"$LIST"; : >"$SENT"; touch "$T/rm.fail"; rm -f "$T/state/alert.stamp"
DRY_RUN=0 run_fn
rm -f "$T/rm.fail"
if [[ "$(rc)" == 1 ]] && has "WARN cannot remove c300-pg" && has "failed 1" && grep -q 'FAILED' "$SENT"; then
  pass "11. a failed rm is WARNed, counted, exit 1, the note says FAILED"
else fail "11. rc=$(rc) $(cat "$T/out") sent=$(cat "$SENT")"; fi

# 12. docker ps fails
touch "$T/ps.fail"
DRY_RUN=1 run_fn
rm -f "$T/ps.fail"
if [[ "$(rc)" == 2 ]] && has "FATAL docker ps failed"; then pass "12. docker ps failure -> exit 2"
else fail "12. rc=$(rc) $(cat "$T/out")"; fi

# 13. nothing to do
{ row id-live c100-pg 180 c-100; row id-young spl-y-pg-2 30 c-300; row id-compose con-other-rdb 9000 - other; } >"$LIST"
echo "x 1" >"$T/state/alert.stamp"; : >"$RM_LOG"; : >"$SENT"
DRY_RUN=1 run_fn
r1="$(rc)"; s1=0; [[ -e "$T/state/alert.stamp" ]] && s1=1
DRY_RUN=0 run_fn
if [[ "$r1" == 0 && "$s1" == 1 && "$(rc)" == 0 && ! -e "$T/state/alert.stamp" && ! -s "$RM_LOG" && ! -s "$SENT" ]]; then
  pass "13. nothing to do -> exit 0; DRY_RUN=1 keeps the stamp, DRY_RUN=0 clears it"
else fail "13. r1=$r1 s1=$s1 rc=$(rc) $(cat "$T/out")"; fi

# 14. ./run
full_list; : >"$RM_LOG"
if [[ -z "${DOCKER_PRUNE_TST_FUNC_SH:-}" ]]; then
  (cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_docker_test_container_prune) >"$T/out" 2>&1
  r=$?
  if [[ "$r" == 1 ]] && has "PLAN remove c300-pg" && [[ ! -s "$RM_LOG" ]]; then
    pass "14. ./run -a do_docker_test_container_prune runs it (exit 1, plan only)"
  else fail "14. ./run rc=$r $(tail -5 "$T/out")"; fi
fi

# 15. call sites
miss=""
for f in csi-spl-api/src/bash/tests/hub-pg.tst.sh csi-spl-orc/src/bash/tests/box-purge.tst.sh \
  csi-spl-orc/src/bash/run/spl-doc-tree-timing.func.sh csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh; do
  # shellcheck disable=SC2016  # the literal expansion text is what is searched
  grep -q 'docker run .*--label "csi-spl.lane=${AGENT_ID:-${SPOOL_AGENT_ID:-}}"' "$REPO_ROOT/$f" || miss+=" $f"
done
if [[ -z "$miss" ]]; then pass "15. the four call sites label with csi-spl.lane"
else fail "15. no csi-spl.lane label in:$miss"; fi

# 16. docker's own CreatedAt format with a zone name
when="$(TZ=Europe/Helsinki date -d "@$((NOW - 200 * 60))" '+%Y-%m-%d %H:%M:%S %z %Z')"
printf '%s\n' "id-tz${FS}tz-pg${FS}$when${FS}c-300${FS}${FS}csi-spl.lane=c-300" >"$LIST"
DRY_RUN=1 run_fn
if has "PLAN remove tz-pg (lane c-300 gone, 200 min old)"; then pass "16. CreatedAt '$when' read as 200 min"
else fail "16. $(cat "$T/out")"; fi

# 17. live guard
if [[ ! -s "$LIVE" ]]; then pass "17. LIVE GUARD: no real docker, tmux or spool reached"
else fail "17. LIVE calls: $(cat "$LIVE")"; fi

echo "docker-test-container-prune: $fails failure(s)"
[[ "$fails" -eq 0 ]]
