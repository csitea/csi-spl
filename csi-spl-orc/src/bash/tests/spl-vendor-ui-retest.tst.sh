#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_vendor_ui_retest (owner HUM-10, t1 b61851fb): the measured
#          re-test that alone flips cnf env.box.agent_split.mistral_ui_allowed.
#   1. plan prints the three tasks with the nonce and changes nothing
#   2. verdict, 3 tasks with every check green: retest=pass 3/3, exit 0;
#      DRY_RUN=1 leaves the cnf false, DRY_RUN=0 writes true
#   3. each check turns a task red on its own (CONTROLS): a second path in
#      the commit, a wrong known answer, no PUSHED line, a red CI run, not
#      served on prd, an ACCEPTED forged by the lane itself, a lane that
#      closed itself before its ACCEPTED; a fail with DRY_RUN=0 writes false
#   4. usage: an unknown command, vendor or results line
# A throwaway git repo is APP_PATH; CI and serving are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
for b in git jq yq; do command -v "$b" >/dev/null || { echo "FAIL: no $b"; exit 1; }; done

N=retest-test1
R="$T/repo"; D=csi-spl-wui/src/public/vendor-ui-retest
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
mkdir -p "$R/csi-spl-wui/src/pages/a" "$R/csi-spl-cnf/csi-spl"
: >"$R/csi-spl-wui/src/pages/index.vue"; : >"$R/csi-spl-wui/src/pages/a/b.vue"; : >"$R/csi-spl-wui/src/pages/x.ts"
printf 'env:\n  box:\n    agent_split:\n      claude: 60\n      mistral_ui_allowed: false\n' >"$R/csi-spl-cnf/csi-spl/all.env.yaml"
g init -q -b master; g add -A; g commit -qm base
# commit <file> <content> -> the new sha (one file per commit)
commit() { mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" >"$R/$1"; g add -- "$1"; g commit -qm "$1"; g rev-parse HEAD; }
S1="$(commit "$D/t1.txt" "vendor-ui-retest t1 $N")"
S2="$(commit "$D/t2.json" "{\"task\":\"t2\",\"nonce\":\"$N\",\"pages\":2}")"
S3="$(commit csi-spl-wui/tests/unit/vendor-ui-retest.test.mjs "// reads vendor-ui-retest/t2.json, asserts nonce $N")"

SP="$T/spool"
lane() {  # <id> <sha> <accepted-from> <accepted ts> <heartbeat ts>
  local f="20261020T100000Z--$3--accepted--abcd${1: -3}.json"
  mkdir -p "$SP/$1/lifetime/push-master" "$SP/$1/archive" "$SP/$1/outbox" "$SP/$3/outbox"
  printf 'PUSHED %s\nfinished=x\n' "$2" >"$SP/$1/lifetime/push-master/status"
  jq -n --arg f "$3" --arg t "$1" --arg ts "$4" '{v:1,from:$f,to:$t,ts:$ts,kind:"result",body:"ACCEPTED: good"}' >"$SP/$1/archive/$f"
  cp "$SP/$1/archive/$f" "$SP/$3/outbox/$f"
  jq -n --arg ts "$5" '{ts:$ts}' >"$SP/$1/heartbeat.json"
}
lanes() {
  rm -rf "$SP"
  lane m-901 "$S1" c-002 2026-10-20T10:00:00Z 2026-10-20T10:05:00Z
  lane m-902 "$S2" c-002 2026-10-20T10:00:00Z 2026-10-20T10:05:00Z
  lane m-903 "$S3" c-002 2026-10-20T10:00:00Z 2026-10-20T10:05:00Z
  printf 't1 m-901 %s\nt2 m-902 %s\nt3 m-903 %s\n' "$S1" "$S2" "$S3" >"$T/results"
}
printf '#!/bin/sh\ncase " $RED " in *" $SHA "*) echo %s ;; *) echo %s ;; esac\n' \
  "'[{\"name\":\"10 gate\",\"status\":\"completed\",\"conclusion\":\"failure\"}]'" \
  "'[{\"name\":\"10 gate\",\"status\":\"completed\",\"conclusion\":\"success\"},{\"name\":\"30 wui\",\"status\":\"completed\",\"conclusion\":\"skipped\"}]'" >"$T/ci"
printf '#!/bin/sh\ncase " $UNSERVED " in *" $ENV:$SHA "*) exit 3 ;; esac\nexit 0\n' >"$T/served"
chmod +x "$T/ci" "$T/served"

rt() {
  env -u DRY_RUN -u RETEST_CMD -u RETEST_VENDOR -u RETEST_RESULTS -u RED -u UNSERVED \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPOOL_ROOT="$SP" RETEST_NONCE="$N" RETEST_REF=master \
    RETEST_RESULTS="$T/results" RETEST_CI_CMD="$T/ci" RETEST_SERVED_CMD="$T/served" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-vendor-ui-retest.func.sh"
    do_spl_vendor_ui_retest' >"$T/out" 2>&1
}
cnfv() { yq -r '.env.box.agent_split.mistral_ui_allowed' "$R/csi-spl-cnf/csi-spl/all.env.yaml"; }

# 1. plan
lanes
rt; rc=$?
[[ $rc -eq 0 && "$(cnfv)" == false ]] && grep -q "^t1: add $D/t1.txt holding the one line 'vendor-ui-retest t1 $N'" "$T/out" \
  && grep -q '^t2: ' "$T/out" && grep -q '^t3: ' "$T/out" && grep -q 'nothing was run' "$T/out" \
  && pass "1. plan prints t1..t3 with the nonce and changes nothing" || fail "1. plan rc=$rc: $(cat "$T/out")"

# 2. all green
rt RETEST_CMD=verdict; rc=$?
[[ $rc -eq 0 && "$(grep -c '^PASS t[123] ' "$T/out")" == 3 && "$(cnfv)" == false ]] && grep -q '^retest=pass 3/3 vendor=mistral mistral_ui_allowed=true' "$T/out" \
  && grep -q '^DRY_RUN=1: the cnf is unchanged' "$T/out" \
  && pass "2. 3/3 green: retest=pass, exit 0; DRY_RUN=1 leaves the cnf false" || fail "2. pass rc=$rc: $(cat "$T/out")"
rt RETEST_CMD=verdict DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(cnfv)" == true ]] && pass "2. DRY_RUN=0 writes mistral_ui_allowed: true" || fail "2. write rc=$rc cnf=$(cnfv): $(cat "$T/out")"

# 3. controls: each check alone turns one task red
red() {  # <label> <grep> [env...]: one FAIL line matching <grep>, retest=fail 2/3, exit 3
  local l="$1" w="$2"; shift 2
  rt RETEST_CMD=verdict "$@"; local rc=$?
  [[ $rc -eq 3 && "$(grep -c '^FAIL ' "$T/out")" == 1 ]] && grep -q "^FAIL .*$w" "$T/out" && grep -q '^retest=fail 2/3' "$T/out" \
    && pass "3. control: $l" || fail "3. control $l rc=$rc: $(cat "$T/out")"
}
g reset -q --hard "$S3"
S4="$(mkdir -p "$R/$D"; printf 'vendor-ui-retest t1 %s\n' "$N" >"$R/$D/t1.txt"; printf 'x\n' >"$R/csi-spl-wui/src/pages/index.vue"; g add -A; g commit -qm t1-wide; g rev-parse HEAD)"
lanes; sed -i "s/^t1 m-901 .*/t1 m-901 $S4/" "$T/results"; sed -i "s/$S1/$S4/" "$SP/m-901/lifetime/push-master/status"
red "a commit that changes a second path" "changes '.*index.vue'"
S5="$(commit "$D/t1.txt" "vendor-ui-retest t1 wrong")"
lanes; sed -i "s/^t1 m-901 .*/t1 m-901 $S5/" "$T/results"; sed -i "s/$S1/$S5/" "$SP/m-901/lifetime/push-master/status"
red "a wrong known answer" "t1.txt reads 'vendor-ui-retest t1 wrong'"
lanes; : >"$SP/m-902/lifetime/push-master/status"
red "no PUSHED line from do_spl_push_master" "no 'PUSHED $S2'"
lanes; red "a red CI run" "CI not all green: 10 gate=failure" RED="$S3"
lanes; red "not served on prd" "not served on prd" UNSERVED="prd:$S2"
lanes; mv "$SP/c-002/outbox/"*abcd903* "$SP/m-903/outbox/"
red "an ACCEPTED forged by the lane itself" "no ACCEPTED from another agent"
lanes; jq -n '{ts:"2026-10-20T09:59:00Z"}' >"$SP/m-901/heartbeat.json"
red "a lane that closed itself before its ACCEPTED" "closed itself first"
lanes; jq -n '{ts:"2026-10-20T09:59:00Z"}' >"$SP/m-901/heartbeat.json"
rt RETEST_CMD=verdict DRY_RUN=0; rc=$?
[[ $rc -eq 3 && "$(cnfv)" == false ]] && pass "3. a fail with DRY_RUN=0 writes mistral_ui_allowed: false" || fail "3. fail write rc=$rc cnf=$(cnfv)"

# 4. usage
rt RETEST_CMD=nope; [[ $? -eq 1 ]] && grep -q 'FATAL RETEST_CMD' "$T/out" && pass "4. an unknown RETEST_CMD is FATAL" || fail "4. cmd: $(cat "$T/out")"
rt RETEST_VENDOR=grok; [[ $? -eq 1 ]] && grep -q 'FATAL RETEST_VENDOR' "$T/out" && pass "4. a vendor with no switch is FATAL" || fail "4. vendor: $(cat "$T/out")"
lanes; printf 't1 m-901 %s\nt1 m-902 %s\n' "$S1" "$S2" >"$T/results"
rt RETEST_CMD=verdict; [[ $? -eq 3 ]] && grep -q '^FAIL t1: the line must read' "$T/out" && grep -q '^retest=fail 1/3' "$T/out" \
  && pass "4. a task listed twice counts once" || fail "4. dup: $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
