#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_qas_ci_accept moves a qas issue to done only when it is
# UI-only AND a passing CI browser proof live on dev and prd covers it (owner,
# t1 0f2ed820 msg e768eb42). A throwaway git repo plays trunk, a gh stub the
# CI runs, file:// build.json the two envs; the hub calls are stubbed and
# logged, so the test proves which issues get a comment and a move.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/repo"
E2E="$R/csi-spl-wui/tests/e2e"
mkdir -p "$E2E" "$R/csi-spl-api" "$R/csi-spl-wui/src" "$R/csi-spl-doc" "$R/.github/workflows"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
# commit MSG FILE=TEXT...: write each file, commit them all.
commit() {
  local m="$1" kv; shift
  for kv in "$@"; do printf '%s\n' "${kv#*=}" >>"$R/${kv%%=*}"; done
  g add -A >/dev/null && g commit -q -m "$m" && g rev-parse HEAD
}
g init -q -b master
printf 'b.test.mjs   needs a live hub\n' >"$E2E/ci-skip.txt"
commit "chore: base" csi-spl-wui/src/base.vue=base >/dev/null
commit "feat(wui, SPL-10): a ui change" csi-spl-wui/src/a.vue=a "csi-spl-wui/tests/e2e/a.test.mjs=// SPL-10 a" \
  csi-spl-doc/a.md=doc .github/workflows/10.yml=ci >/dev/null
commit "feat(hub, SPL-11): an api change" csi-spl-api/x.go=x csi-spl-wui/src/x.vue=x "csi-spl-wui/tests/e2e/a.test.mjs=// SPL-11" >/dev/null
commit "test(wui): fixture key

uses SPL-12 as a sample" csi-spl-wui/src/f.vue=f "csi-spl-wui/tests/e2e/a.test.mjs=// SPL-12" >/dev/null
commit "feat(wui, SPL-13): skipped test only" csi-spl-wui/src/s.vue=s "csi-spl-wui/tests/e2e/b.test.mjs=// SPL-13" >/dev/null
commit "feat(wui, SPL-14): linked by ci-proof" csi-spl-wui/src/p.vue=p >/dev/null
commit "feat(wui, SPL-100): a longer key" csi-spl-wui/src/l.vue=l >/dev/null
P=$(g rev-parse HEAD)
NEW=$(commit "fix(wui, SPL-16): after the proof" csi-spl-wui/src/n.vue=n "csi-spl-wui/tests/e2e/a.test.mjs=// SPL-16") || exit 1
g checkout -q -b side "$P~1" && SIDE=$(commit "chore: side" csi-spl-wui/src/side.vue=x) && g checkout -q master

issue() { printf '{"key":"%s","status":"qas","kind":"%s","description":"%s"}' "$1" "$2" "$3"; }
{
  printf '{"env":"dev","result":{"next_cursor":"","issues":['
  issue SPL-10 issue ""; printf ,; issue SPL-11 issue ""; printf ,; issue SPL-12 issue ""; printf ,
  issue SPL-13 issue ""; printf ,; issue SPL-14 issue 'what it is\nci-proof: a.test.mjs'; printf ,
  issue SPL-15 epic ""; printf ,; issue SPL-16 issue ""; printf ,; issue SPL-1 issue ""
  printf ',{"key":"SPL-17","status":"done","kind":"issue"}]}}\n'
} >"$T/list.json"
python3 -m json.tool "$T/list.json" >/dev/null || { echo "FAIL: the fixture list is not JSON"; exit 1; }

# gh stub: runs newest first; GH_FAIL_RUN names a run whose shard 3/5 failed.
mkdir -p "$T/stub"
cat >"$T/stub/gh" <<'GH'
#!/bin/sh
echo "gh $*" >>"$STUB_LOG"
case "$*" in
  "run list"*) printf '103 %s\n102 %s\n101 %s\n100 %s\n' "$GH_SHA_SIDE" "$GH_SHA_NEW" "$GH_SHA_P" "$GH_SHA_P" ;;
  *runs/101/jobs*) echo "5 4" ;;
  *runs/100/jobs*) [ "${GH_FAIL_RUN:-}" = 100 ] && echo "5 4" || echo "5 5" ;;
  *runs/102/jobs*) echo "5 5" ;;
  *runs/103/jobs*) echo "5 5" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/stub/gh"
live() { printf '{"commit":"%s"}\n' "$2" >"$T/$1.json"; }

STUBS='spl_issue_list_fetch() { echo "list $*" >>"$STUB_LOG"; cat "$LIST"; }
spl_desk_issue_run() {
  echo "hub $*" >>"$STUB_LOG"
  [[ "$1 $3" == "update ${HUB_FAIL:-none}" ]] && return 1
  return 0
}
'
run() {
  : >"$T/calls.log"
  SNIPPET="${STUBS}do_spl_qas_ci_accept" in_orc APP_PATH="$R" LIST="$T/list.json" TENANT_ID=t1 DESK_AGENT=c-002 \
    QAS_REF=master QAS_FETCH=0 GH_TOKEN=x QAS_BUILD_URL_DEV="file://$T/dev.json" QAS_BUILD_URL_PRD="file://$T/prd.json" \
    GH_SHA_P="$P" GH_SHA_NEW="$NEW" GH_SHA_SIDE="$SIDE" "$@" >"$T/o" 2>&1
}
row() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$T/o"; }
rows() { local k; for k in SPL-10 SPL-11 SPL-12 SPL-13 SPL-14 SPL-15 SPL-16 SPL-1; do printf '%s=%s ' "$k" "$(row "$k")"; done; }

# dev serves the newest commit, prd the proof sha: run 102 (on NEW) is not
# live on prd, run 101 failed a shard, so run 100 on P is the proof.
live dev "$NEW"; live prd "$P"
run DRY_RUN=1
rc=$?
want="SPL-10=would-move SPL-11=kept SPL-12=kept SPL-13=kept SPL-14=would-move SPL-15=kept SPL-16=kept SPL-1=kept "
[[ $rc -eq 0 && "$(rows)" == "$want" ]] && grep -q 'proof run 100 ' "$T/o" && ! grep -q '^hub ' "$T/calls.log" &&
  pass "dry run: SPL-10 + SPL-14 would move on run 100, the other six stay, no hub call" ||
  fail "dry run (rc=$rc): $(rows) / $(cat "$T/o")"
[[ "$(row SPL-17)" == "" ]] && pass "an issue that is not in qas gets no row" || fail "SPL-17 got a row"

# The reasons, one per rule.
reason() { awk -F'\t' -v k="$1" '$1 == k { print $3 }' "$T/o"; }
check() {
  [[ "$(reason "$1")" == *"$2"* ]] && pass "$1 stays: $3" || fail "$1 reason '$(reason "$1")', want '$2'"
}
check SPL-11 "touches csi-spl-api/x.go" "not UI-only (an api file)"
check SPL-12 "names SPL-12 in its subject scope" "a key only quoted in a commit body is not that issue's work"
check SPL-13 "no CI browser test" "its only test is in ci-skip.txt"
check SPL-15 "epic: closes with its children" "an epic never moves on a proof"
check SPL-16 "is newer than the proof run's sha" "its commit is not in the proof sha"
check SPL-1 "no commit on master names SPL-1 in" "SPL-100's commit is not SPL-1's"

run DRY_RUN=0
rc=$?
hub="$(grep '^hub ' "$T/calls.log")"
[[ $rc -eq 0 && "$(row SPL-10)" == moved && "$(row SPL-14)" == moved ]] &&
  [[ "$(grep -c '^hub comment' <<<"$hub")" == 2 && "$(grep -c '^hub update' <<<"$hub")" == 2 ]] &&
  grep -q '^hub update --ref SPL-10 --status done' <<<"$hub" && grep -q '^hub update --ref SPL-14 --status done' <<<"$hub" &&
  pass "DRY_RUN=0: exactly SPL-10 and SPL-14 get a comment and move to done" ||
  fail "DRY_RUN=0 (rc=$rc): $(rows) / $hub"
c10="$(awk '/^hub comment --ref SPL-10 /,/newest is/' "$T/calls.log")"
[[ "$c10" == *"run: 100 "* && "$c10" == *"sha: $P"* && "$c10" == *"test: csi-spl-wui/tests/e2e/a.test.mjs"* ]] &&
  pass "the comment names the run id, the sha and the test" || fail "comment: $c10"
c14="$(awk '/^hub comment --ref SPL-14 /,/newest is/' "$T/calls.log")"
[[ "$c14" == *"test: csi-spl-wui/tests/e2e/a.test.mjs"* ]] &&
  pass "SPL-14 is linked by its ci-proof: line" || fail "SPL-14 comment: $c14"
[[ "$(grep -m1 "SPL-10" "$T/calls.log")" == *"hub comment"* ]] &&
  pass "the comment goes before the move" || fail "order: $(grep SPL-10 "$T/calls.log")"

# A move that fails is reported; the other still moves; the run is red.
run DRY_RUN=0 HUB_FAIL=SPL-10
rc=$?
[[ $rc -ne 0 && "$(row SPL-10)" == kept && "$(row SPL-14)" == moved ]] &&
  pass "a failed move: SPL-10 kept and reported, SPL-14 still moves, exit non-zero" ||
  fail "failed move (rc=$rc): $(rows)"

# Controls: no proof run means nothing moves.
run DRY_RUN=0 GH_FAIL_RUN=100
rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no completed' "$T/o" && ! grep -q '^hub ' "$T/calls.log" && ! grep -q '^list ' "$T/calls.log" &&
  pass "control: every live run has a failed shard -> FATAL, no list, no hub call" ||
  fail "control failed shard (rc=$rc): $(cat "$T/o")"
live prd "$(g rev-parse "$P~2")"
run DRY_RUN=0
rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no completed' "$T/o" && ! grep -q '^hub ' "$T/calls.log" &&
  pass "control: prd serves an older build than every green run -> nothing moves" ||
  fail "control old prd (rc=$rc): $(cat "$T/o")"
live prd "$P"; printf 'junk' >"$T/dev.json"
run DRY_RUN=0
rc=$?
[[ $rc -ne 0 ]] && grep -q 'serves no commit' "$T/o" && ! grep -q '^hub ' "$T/calls.log" &&
  pass "control: a junk build.json -> FATAL, nothing moves" || fail "control junk (rc=$rc): $(cat "$T/o")"

# The hourly cron: it runs the action only where the desk agent is seated.
F="$T/fake/x-y-orc"
mkdir -p "$F/src/bash/scripts" "$F/lib/bash/funcs"
cp "$PROJ_ROOT/src/bash/scripts/qas-ci-accept-cron.sh" "$F/src/bash/scripts/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-box.func.sh" "$F/lib/bash/funcs/"
printf '#!/bin/sh\necho "run $* ENV=$ENV TENANT_ID=$TENANT_ID DESK_AGENT=$DESK_AGENT DRY_RUN=$DRY_RUN" >>"$CRON_LOG"\n' >"$F/run"
chmod +x "$F/run"
cron() { : >"$T/cron.log"; env CRON_LOG="$T/cron.log" QAS_TOOLS=sh QAS_STATE_ROOT="$T/st" SPOOL_DESK_BOX=bx bash "$F/src/bash/scripts/qas-ci-accept-cron.sh" >"$T/co" 2>&1; }
cron
rc=$?
[[ $rc -eq 0 && ! -s "$T/cron.log" ]] && grep -q 'SKIP prd:t1: c-002 is not seated on bx' "$T/co" &&
  pass "cron: no seat on this box -> skip, the action is not run" || fail "cron skip (rc=$rc): $(cat "$T/co")"
mkdir -p "$T/st/prd/desk/t1/bx/spool/c-002"
cron
rc=$?
[[ $rc -eq 0 && "$(cat "$T/cron.log")" == "run -a do_spl_qas_ci_accept ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 DRY_RUN=0" ]] &&
  pass "cron: seated -> do_spl_qas_ci_accept DRY_RUN=0 on prd t1 as c-002" || fail "cron run (rc=$rc): $(cat "$T/cron.log") / $(cat "$T/co")"
grep -qE '^qas-ci-accept +\| [0-9]+ \* \* \* \* +\| src/bash/scripts/qas-ci-accept-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  pass "the box-crons manifest carries the hourly qas-ci-accept row" || fail "no qas-ci-accept row in box-crons.manifest"

echo "fails=$fails"
exit $(( fails > 0 ))
