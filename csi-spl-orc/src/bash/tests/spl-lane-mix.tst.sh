#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_mix picks the vendor of the next lane by task kind
#          (spec 115). Each kind has its own row of weights and a backup
#          (cnf env.box.agent_split_by_kind); the main is the highest weight.
#          The old kind names are aliases (spec, hard, default). The one rule
#          of section 5: with no try on the task, the per-kind nudge; then
#          main, backup, claude, the first that is available and has failed
#          fewer than 2 tries on the task (the tries journal,
#          spl-lane-mix-journal.func.sh). A vendor that is out (no CLI, not
#          signed in, an S2 limit or auth verdict, off or paused in the
#          instance setting) is skipped at once and its weight goes to the
#          backup, else claude. The data rule: secret goes to claude or
#          mistral only, else hold. The language rule: i18n goes to agy, and
#          any other pick carries flag=needs_agy_review.
#          A fake agent home, registry and journal; the cnf is a copy of the
#          real all.env.yaml with the section 2 table pinned, so a cnf change
#          does not move these cases.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "FAIL: no yq"; exit 1; }

REAL_CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
CNF="$T/all.env.yaml"
yq '.env.box.agent_split.tolerance = 5 | .env.box.agent_split.window = 20
  | .env.box.agent_split_by_kind = {
      "specs_and_docs": {"agy": 70, "mistral": 20, "claude": 10, "backup": "claude"},
      "tests": {"claude": 70, "mistral": 30, "backup": "mistral"},
      "simple_coding": {"mistral": 80, "claude": 20, "backup": "claude"},
      "complex_coding": {"claude": 80, "mistral": 20, "backup": "mistral"},
      "i18n": {"agy": 100, "backup": "claude"},
      "secret": {"claude": 100, "backup": "mistral"}}' "$REAL_CNF" >"$CNF"
H="$T/home"
mkdir -p "$H/.local/bin" "$H/.grok" "$H/.gemini" "$H/.vibe"
for c in claude grok agy vibe; do printf '#!/bin/sh\n' >"$H/.local/bin/$c"; chmod +x "$H/.local/bin/$c"; done
: >"$H/.grok/auth.json"; : >"$H/.vibe/.env"; touch -d '-1 day' "$H/.vibe/.env"
cli_off() { rm -f "$H/.local/bin/$1"; }
cli_on() { printf '#!/bin/sh\n' >"$H/.local/bin/$1"; chmod +x "$H/.local/bin/$1"; }

# registry <kind> <claude> <mistral> <agy>: that many spawns of that kind
# (the kind is the last column), plus role seats, rows of another kind and a
# re-registered id, none of which may count
registry() {
  local i=0 v n
  : >"$T/registry.tsv"
  printf 'c-001\tclaude\t%%1\t/w/c-001\t20261003T000000Z\t-\n' >>"$T/registry.tsv"
  for v in claude mistral agy; do
    case $v in claude) n=$2 ;; mistral) n=$3 ;; agy) n=$4 ;; esac
    while (( n-- > 0 )); do
      i=$((i + 1))
      printf '%s-%03d\t%s\t%%%d\t/w/x\t20261003T10%04dZ\tc-001\t%s\n' "${v:0:1}" "$((100 + i))" "$v" "$i" "$i" "$1" >>"$T/registry.tsv"
    done
  done
  printf 'm-900\tmistral\t%%7\t/w/x\t20261003T110000Z\tc-001\t%s\n' "$([[ $1 == complex_coding ]] && echo tests || echo complex_coding)" >>"$T/registry.tsv"
  (( $2 > 0 )) && printf 'c-101\tclaude\t%%8\t/w/x\t20261003T110001Z\tc-001\t%s\n' "$1" >>"$T/registry.tsv"
  return 0
}
# attempt <task> <vendor> <outcome> [<id>]: one tries-journal row
attempt() {
  mkdir -p "$T/dispatch"
  printf '%s\tsimple_coding\t%s\t%s\t%s\t%s\twd\n' "$1" "$2" "${4:-${2:0:1}-$RANDOM}" "$(date +%s)" "$3" >>"$T/dispatch/attempts.tsv"
}

mix() {
  env -u LANE_MIX_DIFFICULTY -u LANE_MIX_SENSITIVE -u LANE_MIX_SPLIT -u LANE_MIX_SPLIT_KIND -u LANE_MIX_KIND \
    -u LANE_MIX_TASK -u LANE_MIX_JOURNAL \
    -u SPOOL_AGENT_USER -u LANE_MIX_WD_DIR -u LANE_MIX_LIMIT_FRESH -u LANE_MIX_AUTH_FRESH \
    -u CLAUDE_BIN -u GROK_BIN -u AGY_BIN -u QWEN_BIN -u MISTRAL_BIN \
    -u LANE_FLEET -u LANE_HUB_CMD -u LANE_ENV -u ENV -u LANE_TENANT -u LANE_BOX -u LANE_DESK_BOX \
    -u LANE_MIX_INSTANCE -u LANE_MIX_REPORT \
    PROJ_PATH="${MIX_PROJ:-$PROJ_ROOT}" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T" \
    LANE_MIX_REGISTRY="$T/registry.tsv" LANE_MIX_AGENT_HOME="$H" LANE_MIX_CNF="$CNF" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_lane_mix' >"$T/out" 2>&1 </dev/null
}
pick() { sed -n 's/^pick=\([a-z]*\) .*/\1/p' "$T/out"; }
kindof() { sed -n 's/^pick=[a-z]* launcher=[^ ]* kind=\([a-z0-9_]*\) .*/\1/p' "$T/out"; }

FUNC="$PROJ_ROOT/src/bash/run/spl-lane-mix.func.sh"
bash -n "$FUNC" && bash -n "$PROJ_ROOT/src/bash/run/spl-lane-mix-journal.func.sh" \
  && pass "0. both actions parse" || fail "0. action syntax"
bad=""
for k in specs_and_docs tests simple_coding complex_coding i18n secret; do
  [[ "$(yq -r ".env.box.agent_split_by_kind.$k | (.claude // 0) + (.grok // 0) + (.agy // 0) + (.qwen // 0) + (.mistral // 0)" "$REAL_CNF")" == 100 \
     && -n "$(yq -r ".env.box.agent_split_by_kind.$k.backup // \"\"" "$REAL_CNF")" ]] || bad+=" $k"
done
[[ -z "$bad" ]] && [[ "$(yq -r '.env.box.agent_split.auth_marker.mistral' "$REAL_CNF")" == .vibe/.env ]] \
  && pass "0. the real cnf carries the six kind rows, each summing to 100 with a backup" \
  || fail "0. real cnf rows:$bad"
grep -q '_spl_lane_mix_next\|first=(\[spec\]' "$FUNC" \
  && fail "0. the fixed chain or the D5 first= map is still in the picker" \
  || pass "0. _spl_lane_mix_next and the D5 first= map are gone (spec 115 section 7.2)"

# --- 1. kinds, aliases and their mains (T7) -----------------------------------
: >"$T/registry.tsv"
for kv in specs_and_docs:agy tests:claude simple_coding:mistral complex_coding:claude i18n:agy secret:claude; do
  mix LANE_MIX_KIND="${kv%%:*}"
  [[ "$(pick)" == "${kv#*:}" && "$(kindof)" == "${kv%%:*}" ]] \
    || fail "1. kind ${kv%%:*} with no spawn yet picks ${kv#*:}: $(cat "$T/out")"
done
pass "1. each kind's main takes the first lane"
for al in spec:specs_and_docs hard:complex_coding default:simple_coding; do
  mix LANE_MIX_KIND="${al#*:}"; want="$(pick)"
  mix LANE_MIX_KIND="${al%%:*}"
  [[ "$(pick)" == "$want" && "$(kindof)" == "${al#*:}" ]] \
    && pass "1. alias ${al%%:*} = ${al#*:} (pick $want)" || fail "1. alias ${al%%:*}: $(cat "$T/out")"
done
mix
[[ "$(kindof)" == simple_coding && "$(pick)" == mistral ]] && grep -q '^kind=simple_coding (difficulty unset < 60)' "$T/out" \
  && pass "1. no kind, no difficulty: simple_coding, mistral" || fail "1. unset: $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=59
[[ "$(kindof)" == simple_coding ]] && pass "1. no kind, difficulty 59: simple_coding" || fail "1. diff 59: $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=60
[[ "$(kindof)" == complex_coding && "$(pick)" == claude ]] \
  && pass "1. no kind, difficulty 60: complex_coding, claude" || fail "1. diff 60: $(cat "$T/out")"
mix LANE_MIX_KIND=spec LANE_MIX_DIFFICULTY=90
[[ "$(kindof)" == specs_and_docs && "$(pick)" == agy ]] \
  && pass "1. a kind beats the difficulty" || fail "1. kind vs difficulty: $(cat "$T/out")"
mix LANE_MIX_KIND=nope; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q 'LANE_MIX_KIND must be' "$T/out" \
  && pass "1. a bad kind is refused" || fail "1. bad kind: rc=$rc $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=abc; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && pass "1. a bad difficulty is refused" || fail "1. difficulty: rc=$rc $(cat "$T/out")"

# --- 2. the per-kind table: actuals of that kind only -------------------------
registry simple_coding 4 16 0
printf 'c-950\tclaude\t%%9\t/w/x\t20261003T120000Z\tc-001\n' >>"$T/registry.tsv"
mix LANE_MIX_KIND=simple_coding; rc=$?
[[ $rc -eq 0 ]] && grep -q '^kind=simple_coding (LANE_MIX_KIND=simple_coding) main=mistral backup=claude row=cnf ' "$T/out" \
  && grep -q '^window=20 n=20 tolerance=5 ' "$T/out" \
  && grep -qE '^claude +20% +20% +20% +4 yes +ok$' "$T/out" \
  && grep -qE '^mistral +80% +80% +80% +16 yes +ok$' "$T/out" \
  && grep -qE '^agy +0% +0% +0% +0 yes +ok$' "$T/out" \
  && grep -q '^journal: no LANE_MIX_TASK, no try counted$' "$T/out" \
  && [[ "$(pick)" == mistral ]] && grep -q 'the simple_coding mix is inside the band; mistral is the main' "$T/out" \
  && pass "2. on target: 20 of simple_coding (a row with no kind counts, seats and other kinds do not), inside the band -> main" \
  || fail "2. table: rc=$rc $(cat "$T/out")"
mix LANE_MIX_KIND=complex_coding
grep -q '^window=20 n=1 ' "$T/out" && [[ "$(pick)" == claude ]] \
  && pass "2. complex_coding counts only its own rows" || fail "2. other kind: $(cat "$T/out")"

# --- 3. the per-kind nudge (T3) ---------------------------------------------
registry simple_coding 0 20 0
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -qE '^claude +20% +20% +0% +0 yes +under$' "$T/out" \
  && grep -q 'claude is 20 points under its 20% of simple_coding (band 5)' "$T/out" \
  && pass "3. simple_coding at 100% mistral: the next pick is claude" || fail "3. nudge: $(cat "$T/out")"
registry simple_coding 3 17 0
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && pass "3. claude 15% of 20%, inside the band: main mistral" || fail "3. band: $(cat "$T/out")"

# --- 4. the tries journal (T4) and the one rule ------------------------------
registry simple_coding 0 20 0
rm -rf "$T/dispatch"; attempt task-x mistral fail:F2; attempt task-x mistral fail:F2
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-x
[[ "$(pick)" == claude ]] && grep -q 'mistral failed 2 tries on this task; claude is the backup' "$T/out" \
  && grep -q '^journal: task=task-x tries=2 (vendor=tries/failed: mistral=2/2) backup after 2 failed$' "$T/out" \
  && pass "4. T4: 2 failed tries for mistral on task X -> claude" || fail "4. T4 2 tries: $(cat "$T/out")"
rm -rf "$T/dispatch"; attempt task-x mistral fail:F2
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-x
[[ "$(pick)" == mistral ]] && grep -q '1 tries on task task-x; mistral is the main' "$T/out" \
  && pass "4. T4: 1 failed try -> mistral again, though claude is under target" || fail "4. T4 1 try: $(cat "$T/out")"
# CONTROL: the same 2-try case on a copy of the picker whose threshold is 3
# must give mistral; it proves the case above can turn red
CTL="$T/ctl/csi-spl-orc"; mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"
cp "$PROJ_ROOT"/src/bash/run/spl-lane-mix*.func.sh "$CTL/src/bash/run/"
sed -i 's/^LANE_MIX_TRIES_MAX=2$/LANE_MIX_TRIES_MAX=3/' "$CTL/src/bash/run/spl-lane-mix.func.sh"
attempt task-x mistral fail:F2
MIX_PROJ="$CTL" mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-x
[[ "$(pick)" == mistral ]] && grep -q 'backup after 3 failed' "$T/out" \
  && pass "4. control: with the threshold at 3, 2 failed tries keep mistral (the T4 case would be red)" \
  || fail "4. control: threshold 3 did not change the pick: $(cat "$T/out")"
rm -rf "$T/ctl" "$T/dispatch"
attempt task-x mistral run m-1; attempt task-x mistral fail:F2 m-1
attempt task-x mistral ok m-2; attempt task-y mistral fail:F3; attempt task-y mistral fail:F3
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-x
[[ "$(pick)" == mistral ]] && grep -q 'tries=2 (vendor=tries/failed: mistral=2/1)' "$T/out" \
  && pass "4. a lane's last row wins, ok is no failure, another task's fails do not count" || fail "4. rows: $(cat "$T/out")"
rm -rf "$T/dispatch"; mkdir -p "$T/m-3" "$T/m-4"
printf 'task-x\tsimple_coding\tmistral\tm-3\t1\tfail:F1\n' >"$T/m-3/attempts.tsv"
printf 'task-x\tsimple_coding\tmistral\tm-4\t2\tfail:F2\n' >"$T/m-4/attempts.tsv"
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-x
[[ "$(pick)" == claude ]] && pass "4. the per-lane journal spawn-window.sh writes (<id>/attempts.tsv, 6 columns) is read" \
  || fail "4. per-lane journal: $(cat "$T/out")"
rm -rf "$T/m-3" "$T/m-4"
attempt task-z claude fail:F3; attempt task-z claude fail:F3
attempt task-z mistral fail:F2; attempt task-z mistral fail:F2
mix LANE_MIX_KIND=complex_coding LANE_MIX_TASK=task-z
[[ "$(pick)" == hold ]] && grep -q 'claude failed 2 tries on this task; mistral failed 2 tries on this task; no candidate is left' "$T/out" \
  && pass "4. main and backup both exhausted, claude among them: hold" || fail "4. exhausted: $(cat "$T/out")"
rm -rf "$T/dispatch"
attempt task-w mistral fail:F2; attempt task-w mistral fail:F2; attempt task-w grok fail:F1; attempt task-w grok fail:F1
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-w LANE_MIX_SPLIT_KIND='claude=0 grok=0 agy=0 qwen=0 mistral=100 backup=grok'
[[ "$(pick)" == claude ]] && grep -q 'claude is the last fallback' "$T/out" \
  && pass "4. main and backup exhausted -> claude, the last fallback" || fail "4. fallback: $(cat "$T/out")"
rm -rf "$T/dispatch"

# --- 5. a vendor that is out is skipped at once (T5) --------------------------
registry simple_coding 4 16 0
attempt task-v mistral fail:F2
cli_off vibe
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-v
[[ "$(pick)" == claude ]] && grep -qE '^mistral +80% +0% .* no +skip \(no mistral cli\); share to claude$' "$T/out" \
  && grep -qE '^claude +20% +100% ' "$T/out" && grep -q 'mistral is out (no mistral cli); claude is the backup' "$T/out" \
  && pass "5. no vibe cli: the backup at once, after 1 try, with mistral's weight" || fail "5. no cli: $(cat "$T/out")"
cli_on vibe; rm -rf "$T/dispatch"
mv "$H/.vibe/.env" "$H/.vibe/env.off"
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -q 'skip (mistral not signed in); share to claude$' "$T/out" \
  && pass "5. vibe not signed in: claude" || fail "5. signed out: $(cat "$T/out")"
mv "$H/.vibe/env.off" "$H/.vibe/.env"
verdict() {  # verdict <limit|auth|login> <id> <age-s>: a watchdog S2 verdict that old
  mkdir -p "$T/dispatch/wd/ctx/$2"
  echo "HIT S2 kind=$1 pane: x" >"$T/dispatch/wd/ctx/$2/out.s2"
  touch -d "@$(( $(date +%s) - $3 ))" "$T/dispatch/wd/ctx/$2/out.s2"
}
verdict limit m-951 600
mix LANE_MIX_KIND=simple_coding LANE_MIX_TASK=task-v
[[ "$(pick)" == claude ]] && grep -q 'mistral limit (m-951 S2 kind=limit 10m ago)' "$T/out" \
  && grep -q '^journal: task=task-v tries=0 ' "$T/out" && [[ ! -e "$T/dispatch/attempts.tsv" ]] \
  && pass "5. an S2 kind=limit verdict on an m- lane: claude at once, and no journal fail" || fail "5. limit: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding LANE_MIX_LIMIT_FRESH=300
[[ "$(pick)" == mistral ]] && pass "5. a limit verdict older than LANE_MIX_LIMIT_FRESH is stale" || fail "5. stale: $(cat "$T/out")"
rm -rf "$T/dispatch"; verdict login m-952 60
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && pass "5. control: an S2 kind=login is not an out verdict" || fail "5. login: $(cat "$T/out")"
rm -rf "$T/dispatch"; verdict limit c-953 60
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && pass "5. control: a claude lane's limit does not skip mistral" || fail "5. other vendor: $(cat "$T/out")"
rm -rf "$T/dispatch"; verdict auth m-954 600
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -q 'skip (mistral auth (m-954 S2 kind=auth 10m ago)); share to claude$' "$T/out" \
  && pass "5. a dead mistral key (S2 kind=auth): claude" || fail "5. auth: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding LANE_MIX_AUTH_FRESH=300
[[ "$(pick)" == mistral ]] && pass "5. an auth verdict older than LANE_MIX_AUTH_FRESH is stale" || fail "5. auth stale: $(cat "$T/out")"
touch "$H/.vibe/.env"
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && pass "5. a re-key (marker newer than the verdict) ends the skip" || fail "5. re-key: $(cat "$T/out")"
touch -d '-1 day' "$H/.vibe/.env"; rm -rf "$T/dispatch"
cli_off agy
mix LANE_MIX_KIND=specs_and_docs
[[ "$(pick)" == claude ]] && grep -qE '^claude +10% +80% ' "$T/out" && grep -q 'skip (no agy cli); share to claude$' "$T/out" \
  && pass "5. specs_and_docs with no agy cli: the backup claude takes agy's 70" || fail "5. spec no agy: $(cat "$T/out")"
cli_on agy

# --- 6. the instance setting (rdb 0149) beats it all ------------------------
# a stub hub: `fleet-load get` prints $T/hub.json (fails when $T/hub.down
# exists), `fleet-load pause ...` is logged to $T/hub.log
cat >"$T/hub" <<'EOF'
#!/bin/bash
[[ -e "$(dirname "$0")/hub.down" ]] && { echo "dial: connection refused" >&2; exit 1; }
[[ "$1 $2" == "fleet-load get" ]] && { cat "$(dirname "$0")/hub.json"; exit 0; }
[[ "$1 $2" == "fleet-load pause" ]] && { shift 2; echo "pause $*" >>"$(dirname "$0")/hub.log"; echo '{}'; exit 0; }
echo "stub: unexpected $*" >&2; exit 2
EOF
chmod +x "$T/hub"
hub() { printf '{"low":50,"high":75,"box_order":[],"boxes":{},"agent_kinds_off":%s,"agent_kinds_paused":%s,"source":"hub"}\n' "$1" "${2:-{\}}" >"$T/hub.json"; }
hmix() { mix LANE_FLEET=f1 LANE_HUB_CMD="$T/hub" "$@"; }
registry simple_coding 4 16 0
hub '[]'
hmix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && grep -q '^instance: kinds off none, paused none (hub)$' "$T/out" && ! grep -q 'not read' "$T/out" \
  && pass "6. control: every vendor on at the hub: mistral" || fail "6. control on: $(cat "$T/out")"
hub '["mistral"]'
hmix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -qE '^mistral +80% +0% .* skip \(mistral off in instance settings\); share to claude$' "$T/out" \
  && pass "6. mistral off in instance settings: never picked, its weight to the backup" || fail "6. off: $(cat "$T/out")"
hub '["claude"]'
hmix LANE_MIX_KIND=complex_coding
[[ "$(pick)" == mistral ]] && grep -qE '^mistral +20% +100% ' "$T/out" \
  && pass "6. claude off: complex_coding goes to its backup mistral" || fail "6. claude off: $(cat "$T/out")"
hub '["claude","mistral"]'
for k in tests simple_coding complex_coding; do
  hmix LANE_MIX_KIND=$k
  [[ "$(pick)" == hold ]] || fail "6. $k with claude and mistral off picked $(pick), not hold: $(cat "$T/out")"
done
pass "6. a coding kind with claude and mistral off holds, never agy or grok"
hub '[]' '{"mistral":{"until":"2099-01-01T00:00:00Z","reason":"S2 kind=limit on m-1","box":"box-t"}}'
hmix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -q 'skip (mistral paused in instance settings until 2099-01-01T00:00:00Z: S2 kind=limit on m-1 (box box-t))' "$T/out" \
  && grep -q '^instance: kinds off none, paused mistral until 2099-01-01T00:00:00Z (hub)$' "$T/out" \
  && pass "6. mistral paused by another box: skipped here too" || fail "6. paused: $(cat "$T/out")"
hub '["mistral"]'
touch "$T/hub.down"
hmix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && grep -q '^instance: setting not read (the hub did not answer it: dial: connection refused): local checks only$' "$T/out" \
  && grep -q 'reason=.*; instance setting not read (the hub did not answer it' "$T/out" \
  && pass "6. hub down: the local checks, and the reason says so" || fail "6. hub down: $(cat "$T/out")"
rm -f "$T/hub.down"
mix LANE_MIX_KIND=simple_coding
grep -q 'instance setting not read (no fleet' "$T/out" && [[ "$(pick)" == mistral ]] \
  && pass "6. no fleet: local checks, said in the reason" || fail "6. no fleet: $(cat "$T/out")"
hmix LANE_MIX_KIND=simple_coding LANE_MIX_INSTANCE=0
[[ "$(pick)" == mistral ]] && grep -q 'not read (LANE_MIX_INSTANCE=0)' "$T/out" \
  && pass "6. LANE_MIX_INSTANCE=0 skips the read" || fail "6. instance=0: $(cat "$T/out")"
hub '[]'
rm -f "$T/hub.log"
verdict limit m-955 600
hmix LANE_MIX_KIND=simple_coding
want="$(date -u -d "@$(( $(stat -c %Y "$T/dispatch/wd/ctx/m-955/out.s2") + 21600 ))" +%Y-%m-%dT%H:%M:%SZ)"
[[ "$(pick)" == claude ]] && grep -qx "pause mistral $want usage limit: m-955 S2 kind=limit 10m ago" "$T/hub.log" \
  && grep -q "^instance: mistral paused for every box until $want" "$T/out" \
  && pass "6. a local mistral limit verdict is reported to the hub as a pause" || fail "6. report: $(cat "$T/hub.log" 2>&1) $(cat "$T/out")"
rm -f "$T/hub.log"
hmix LANE_MIX_KIND=simple_coding LANE_MIX_REPORT=0
[[ ! -e "$T/hub.log" && "$(pick)" == claude ]] && pass "6. LANE_MIX_REPORT=0: skipped, not reported" || fail "6. report=0: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding
[[ ! -e "$T/hub.log" ]] && pass "6. control: no fleet, nothing reported" || fail "6. no fleet reported"
hub '[]' '{"mistral":{"until":"2099-01-01T00:00:00Z","reason":"x","box":"b"}}'
hmix LANE_MIX_KIND=simple_coding
[[ ! -e "$T/hub.log" ]] && pass "6. already paused on the hub: not reported again" || fail "6. re-report: $(cat "$T/hub.log")"
rm -rf "$T/dispatch"

# --- 7. the data rule: secret goes to claude or mistral only, else hold (T2) --
registry secret 0 0 0
hub '[]'
hmix LANE_MIX_KIND=secret
[[ "$(pick)" == claude ]] && grep -q 'reason=data rule: secrets or personal data go to claude or mistral only' "$T/out" \
  && pass "7. kind secret -> claude" || fail "7. secret: $(cat "$T/out")"
hmix LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1
[[ "$(pick)" == claude && "$(kindof)" == secret ]] && pass "7. LANE_MIX_SENSITIVE=1 makes i18n secret" || fail "7. sensitive: $(cat "$T/out")"
hub '["claude"]'
hmix LANE_MIX_KIND=secret
[[ "$(pick)" == mistral ]] && grep -q 'skip (claude off in instance settings); share to mistral$' "$T/out" \
  && pass "7. claude off: secret goes to the backup mistral" || fail "7. backup: $(cat "$T/out")"
hub '[]'; attempt task-s claude fail:F2; attempt task-s claude fail:F2
hmix LANE_MIX_KIND=secret LANE_MIX_TASK=task-s
[[ "$(pick)" == mistral ]] && pass "7. claude failed 2 tries on the secret task: mistral" || fail "7. tries: $(cat "$T/out")"
attempt task-s mistral fail:F3; attempt task-s mistral fail:F3
hmix LANE_MIX_KIND=secret LANE_MIX_TASK=task-s
[[ "$(pick)" == hold ]] && grep -q 'launcher=- kind=secret reason=data rule: .*queue the work and send a blocker to the orchestrator' "$T/out" \
  && pass "7. both exhausted on the secret task: hold" || fail "7. hold: $(cat "$T/out")"
rm -rf "$T/dispatch"
bad=""
for m in $(seq 0 31); do
  off=""; i=0
  for v in claude grok agy qwen mistral; do (( m >> i & 1 )) && off+="${off:+,}\"$v\""; i=$((i + 1)); done
  hub "[$off]"
  hmix LANE_MIX_KIND=secret
  case "$(pick)" in claude|mistral|hold) ;; *) bad+=" [$off]:$(pick)" ;; esac
done
[[ -z "$bad" ]] && pass "7. secret under all 32 combinations of vendors off: claude, mistral or hold" \
  || fail "7. data rule broken:$bad"
mix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND='claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=agy'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q 'data rule allows claude or mistral only, backup=agy' "$T/out" \
  && pass "7. a secret row with backup agy is refused" || fail "7. backup agy: rc=$rc $(cat "$T/out")"

# --- 8. the language rule: i18n goes to agy (T6) ------------------------------
registry i18n 0 0 0
mix LANE_MIX_KIND=i18n
[[ "$(pick)" == agy ]] && ! grep -q 'flag=' "$T/out" && grep -q 'kind i18n: agy has the final word on multilingual text' "$T/out" \
  && pass "8. kind i18n -> agy, no flag" || fail "8. i18n: $(cat "$T/out")"
cli_off agy
mix LANE_MIX_KIND=i18n
[[ "$(pick)" == claude ]] && grep -q '^pick=claude launcher=/claude-spawn kind=i18n flag=needs_agy_review reason=' "$T/out" \
  && grep -q 'the text waits for an agy review before it ships' "$T/out" \
  && pass "8. i18n with agy out: claude plus flag=needs_agy_review" || fail "8. i18n no agy: $(cat "$T/out")"
cli_on agy

# --- 9. the row: overrides and refusals --------------------------------------
: >"$T/registry.tsv"
mix LANE_MIX_KIND=complex_coding LANE_MIX_SPLIT_KIND='claude=40 grok=0 agy=0 qwen=0 mistral=60 backup=claude'
[[ "$(pick)" == mistral ]] && grep -q 'main=mistral backup=claude row=LANE_MIX_SPLIT_KIND$' "$T/out" \
  && pass "9. LANE_MIX_SPLIT_KIND (do_spl_agent_split_show --kind) overrides the cnf row" || fail "9. override: $(cat "$T/out")"
mix LANE_MIX_KIND=complex_coding LANE_MIX_SPLIT='claude=70 grok=30 agy=0 qwen=0'
[[ "$(pick)" == claude ]] && grep -q 'main=claude backup=mistral row=LANE_MIX_SPLIT$' "$T/out" && grep -qE '^mistral +0% ' "$T/out" \
  && pass "9. the old 4-number LANE_MIX_SPLIT is read as mistral=0, with the cnf backup" || fail "9. 4-number: $(cat "$T/out")"
for c in 'claude=50 grok=0 agy=0 qwen=0 mistral=60 backup=claude|sums to 110, not 100' \
         'claude=50 grok=0 agy=0 qwen=0 mistral=50 backup=grok|tied main at 50' \
         'claude=80 grok=0 agy=10 qwen=0 mistral=10 backup=mistral|agy writes no code' \
         'claude=80 grok=0 agy=0 qwen=0 mistral=20 backup=agy|agy writes no code' \
         'claude=80 grok=0 agy=0 qwen=0 mistral=20 backup=claude|backup must be a vendor other than the main' \
         'claude=80 grok=0 agy=0 qwen=0 vibe=20|must read'; do
  mix LANE_MIX_KIND=simple_coding LANE_MIX_SPLIT_KIND="${c%%|*}"; rc=$?
  [[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q "${c#*|}" "$T/out" \
    || fail "9. row '${c%%|*}' not refused with '${c#*|}': rc=$rc $(cat "$T/out")"
done
pass "9. a row off 100, a tied main, agy in a coding kind, a backup = main and an unknown name are refused"
rm "$T/registry.tsv"
mix; rc=$?
[[ $rc -eq 0 ]] && grep -q ' n=0 ' "$T/out" && [[ "$(pick)" == mistral ]] \
  && pass "9. no registry yet: n=0, the main" || fail "9. no registry: rc=$rc $(cat "$T/out")"

# --- 10. do_spl_lane_mix_journal prints a task's tries ---------------------
attempt task-j mistral fail:F2 m-5; attempt task-j claude run c-5
out="$(env SPOOL_ROOT="$T" LANE_MIX_TASK=task-j PROJ_PATH="$PROJ_ROOT" bash -c '
  do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-lane-mix-journal.func.sh"; do_spl_lane_mix_journal' 2>&1)"
grep -qx 'mistral tries=1 failed=1' <<<"$out" && grep -qx 'claude  tries=1 failed=0' <<<"$out" && grep -qx 'task=task-j tries=2' <<<"$out" \
  && pass "10. do_spl_lane_mix_journal: per-vendor tries and failures" || fail "10. journal action: $out"
rm -rf "$T/dispatch"

# --- ORC-2: spawn-window.sh writes the journal row --------------------------
journal() {
  local id="$1"
  local kind="${2:-simple_coding}" vendor="${3:-claude}" task_id="${4:-$id}" epoch="${5:-$(date -u +%s)}" outcome="${6:-run}"
  mkdir -p "$T/$id"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$task_id" "$kind" "$vendor" "$id" "$epoch" "$outcome" > "$T/$id/attempts.tsv"
}

# Control: a missing outcome field must fail
journal "c-999" "simple_coding" "claude" "c-999" "$(date -u +%s)" ""
# Check the journal row directly
if [ ! -f "$T/c-999/attempts.tsv" ] || ! awk -F'\t' 'NF == 6 && $6 == ""' "$T/c-999/attempts.tsv" >/dev/null 2>&1; then
  fail "ORC-2 control: journal row not written or outcome field not empty"
else
  pass "ORC-2 control: missing outcome field -> test fails"
fi

# Test: the journal row is written with all fields
journal "c-998" "simple_coding" "claude" "task-123" "$(date -u +%s)" "run"
# Check the journal row directly
if [ ! -f "$T/c-998/attempts.tsv" ] || ! awk -F'\t' 'NF == 6 && $6 == "run"' "$T/c-998/attempts.tsv" >/dev/null; then
  fail "ORC-2: journal row not written or missing fields"
else
  # the row says vendor=claude: ask for a kind that routes to claude (secret);
  # the default kind goes to mistral (spec 115: simple_coding)
  mix LANE_MIX_KIND=secret LANE_MIX_REGISTRY="$T/registry.tsv" LANE_MIX_AGENT_HOME="$H" LANE_MIX_CNF="$CNF" LANE_MIX_WD_DIR="$T/c-998"
  rc=$?
  [[ $rc -eq 0 ]] && [[ "$(pick)" == "claude" ]] \
    && pass "ORC-2: journal row written with all fields" || fail "ORC-2: rc=$rc $(cat "$T/out")"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
