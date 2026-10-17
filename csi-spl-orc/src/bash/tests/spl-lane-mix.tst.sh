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
#          backup, else claude. The data rule: secret goes to claude, grok
#          or mistral only (never qwen or agy), else hold; orchestration
#          is secret-class the same way. The language rule: i18n goes to agy, and
#          any other pick carries flag=needs_agy_review.
#          A fake agent home, registry and journal; the cnf is a copy of the
#          real all.env.yaml with the section 2 table pinned, so a cnf change
#          does not move these cases; it also pins mistral_coding_allowed
#          true, and section 16 checks the coding rule (owner HUM-10 msg
#          91bf8278: mistral does docs and reviews only) with it false.
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
  | .env.box.agent_split.mistral_coding_allowed = true
  | .env.box.agent_split_by_kind = {
      "specs_and_docs": {"agy": 70, "mistral": 20, "claude": 10, "backup": "claude"},
      "tests": {"claude": 70, "mistral": 30, "backup": "mistral"},
      "simple_coding": {"mistral": 80, "claude": 20, "backup": "claude"},
      "complex_coding": {"claude": 80, "mistral": 20, "backup": "mistral"},
      "i18n": {"agy": 100, "backup": "claude"},
      "secret": {"claude": 100, "backup": "mistral"},
      "orchestration": {"claude": 65, "grok": 35, "backup": "grok"}}' "$REAL_CNF" >"$CNF"
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
    -u LANE_MIX_INSTANCE -u LANE_MIX_REPORT -u LANE_MIX_BRIEF -u LANE_MIX_PATHS \
    MIX_SRC="$([[ "${MIX_FULL:-}" == 1 ]] && echo '*' || echo "$MIX_SRC")" \
    PROJ_PATH="${MIX_PROJ:-$PROJ_ROOT}" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T" \
    LANE_MIX_REGISTRY="$T/registry.tsv" LANE_MIX_AGENT_HOME="$H" LANE_MIX_CNF="$CNF" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    read -ra gs <<<"$MIX_SRC"
    for g in "${gs[@]}"; do for f in "$PROJ_PATH"/src/bash/run/$g.func.sh; do [[ -e "$f" ]] && source "$f"; done; done
    eval "${MIX_BODY:-do_spl_lane_mix}"' >"$T/out" 2>&1 </dev/null
}
# A pick reads only the action and the hub client (spl_lane_init and
# spl_lane_spool, spl-lane-map). Sourcing all ~440 run/*.func.sh cost 0.33 s
# of each of the ~600 picks here, 4/5 of this file's time (L5, spec 133
# action 6). MIX_FULL=1 sources them all (a MIX_PROJ copy holds only the
# spl-lane-mix files, so it reads the same either way); section 6
# checks that both print the same bytes.
MIX_SRC='spl-lane-mix* spl-lane-map'
pick() { sed -n 's/^pick=\([a-z]*\) .*/\1/p' "$T/out"; }
kindof() { sed -n 's/^pick=[a-z]* launcher=[^ ]* kind=\([a-z0-9_]*\) .*/\1/p' "$T/out"; }

FUNC="$PROJ_ROOT/src/bash/run/spl-lane-mix.func.sh"
bash -n "$FUNC" && bash -n "$PROJ_ROOT/src/bash/run/spl-lane-mix-journal.func.sh" \
  && pass "0. both actions parse" || fail "0. action syntax"
bad=""
for k in specs_and_docs tests simple_coding complex_coding i18n secret orchestration; do
  [[ "$(yq -r ".env.box.agent_split_by_kind.$k | (.claude // 0) + (.grok // 0) + (.agy // 0) + (.qwen // 0) + (.mistral // 0)" "$REAL_CNF")" == 100 \
     && -n "$(yq -r ".env.box.agent_split_by_kind.$k.backup // \"\"" "$REAL_CNF")" ]] || bad+=" $k"
done
[[ -z "$bad" ]] && [[ "$(yq -r '.env.box.agent_split.auth_marker.mistral' "$REAL_CNF")" == .vibe/.env ]] \
  && pass "0. the real cnf carries the seven kind rows, each summing to 100 with a backup" \
  || fail "0. real cnf rows:$bad"
grep -q '_spl_lane_mix_next\|first=(\[spec\]' "$FUNC" \
  && fail "0. the fixed chain or the D5 first= map is still in the picker" \
  || pass "0. _spl_lane_mix_next and the D5 first= map are gone (spec 115 section 7.2)"

# --- 1. kinds, aliases and their mains (T7) -----------------------------------
: >"$T/registry.tsv"
for kv in specs_and_docs:agy tests:claude simple_coding:mistral complex_coding:claude i18n:agy secret:claude orchestration:claude; do
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
  && [[ "$(pick)" == mistral ]] && grep -q 'no simple_coding vendor is further under its weight than the main; mistral is the main' "$T/out" \
  && pass "2. on target: 20 of simple_coding (a row with no kind counts, seats and other kinds do not) -> main" \
  || fail "2. table: rc=$rc $(cat "$T/out")"
mix LANE_MIX_KIND=complex_coding
grep -q '^window=20 n=1 ' "$T/out" && [[ "$(pick)" == claude ]] \
  && pass "2. complex_coding counts only its own rows" || fail "2. other kind: $(cat "$T/out")"

# --- 3. the per-kind nudge (T3) ---------------------------------------------
registry simple_coding 0 20 0
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -qE '^claude +20% +20% +0% +0 yes +under$' "$T/out" \
  && grep -q 'claude has 0 of the last 20 simple_coding spawns, under its 20 of 100' "$T/out" \
  && pass "3. simple_coding at 100% mistral: the next pick is claude" || fail "3. nudge: $(cat "$T/out")"
# any deficit nudges, not only one past the band: gated on the band the
# smaller vendors settled 6..11 points under their weights (T1 below)
registry simple_coding 3 17 0
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == claude ]] && grep -qE '^claude +20% +20% +15% +3 yes +ok$' "$T/out" \
  && pass "3. claude 15% of 20%, inside the band but under its weight: claude" || fail "3. under, in band: $(cat "$T/out")"
registry simple_coding 5 15 0
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && grep -q 'no simple_coding vendor is further under its weight than the main; mistral is the main' "$T/out" \
  && pass "3. claude 25% of 20%, mistral 75% of 80%: the main mistral" || fail "3. main under: $(cat "$T/out")"

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
CTL="$T/ctl/csi-spl-orc"; mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"; ln -s "$PROJ_ROOT/src/bash/features" "$CTL/src/bash/features"
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
# MIX_SRC: a pick with the action and the hub client only prints the same
# bytes as one with every run/*.func.sh sourced (hub, local, secret, i18n)
bad=""
for c in "hmix LANE_MIX_KIND=simple_coding" "mix LANE_MIX_KIND=tests" "hmix LANE_MIX_KIND=secret" "hmix LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1"; do
  MIX_FULL=1 $c; cp "$T/out" "$T/out.full"; $c
  cmp -s "$T/out" "$T/out.full" || bad+=" [$c]"
done
[[ -z "$bad" && -s "$T/out.full" ]] && pass "6. MIX_SRC: the narrow source picks byte-for-byte as the full one" \
  || fail "6. MIX_SRC differs from the full source:$bad"
mv "$T/hub.json" "$T/hub.keep"; MIX_FULL=1 hmix LANE_MIX_KIND=simple_coding; cp "$T/out" "$T/out.full"; mv "$T/hub.keep" "$T/hub.json"
hmix LANE_MIX_KIND=simple_coding
cmp -s "$T/out" "$T/out.full" && fail "6. control: MIX_SRC cmp cannot tell two picks apart" \
  || pass "6. control: a pick with the hub file gone differs, so the cmp is live"
rm -f "$T/out.full"
MIX_BODY='declare -F do_spl_desk_up >/dev/null && echo full || echo narrow' mix; a="$(cat "$T/out")"
MIX_FULL=1 MIX_BODY='declare -F do_spl_desk_up >/dev/null && echo full || echo narrow' mix
[[ "$a" == narrow && "$(cat "$T/out")" == full ]] && pass "6. control: MIX_SRC sources fewer files than MIX_FULL=1" \
  || fail "6. control: MIX_SRC narrow=$a full=$(cat "$T/out")"
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

# --- 7. the data rule: secret goes to claude, grok or mistral only, else hold (T2)
registry secret 0 0 0
hub '[]'
hmix LANE_MIX_KIND=secret
[[ "$(pick)" == claude ]] && grep -q 'reason=data rule: secrets or personal data go to claude, grok or mistral only' "$T/out" \
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
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q 'data rule allows claude, grok or mistral only, .*backup=agy' "$T/out" \
  && pass "7. a secret row with backup agy is refused" || fail "7. backup agy: rc=$rc $(cat "$T/out")"
# grok joined the data rule (owner msgs 26117740, 474f32a0): the cnf row may
# name it as the main or the backup; qwen and agy stay refused in every form.
hub '[]'
hmix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND='claude=0 grok=100 agy=0 qwen=0 mistral=0 backup=claude'
[[ "$(pick)" == grok ]] && grep -q '^pick=grok launcher=/grok-spawn kind=secret reason=data rule: ' "$T/out" \
  && pass "7. a secret row with main grok -> grok" || fail "7. grok main: $(cat "$T/out")"
hub '["claude"]'
hmix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND='claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=grok'
[[ "$(pick)" == grok ]] && grep -q 'skip (claude off in instance settings); share to grok$' "$T/out" \
  && pass "7. claude off, backup grok: secret goes to grok" || fail "7. grok backup: $(cat "$T/out")"
hub '["grok"]'
hmix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND='claude=0 grok=100 agy=0 qwen=0 mistral=0 backup=mistral'
[[ "$(pick)" == mistral ]] && pass "7. grok off: secret goes to the backup mistral" || fail "7. grok off: $(cat "$T/out")"
rm -rf "$T/dispatch"
mkdir -p "$H/.qwen"; printf '#!/bin/sh\n' >"$H/.local/bin/qwen"; chmod +x "$H/.local/bin/qwen"; : >"$H/.qwen/settings.json"
bad=""
for row in 'claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=mistral' 'claude=0 grok=100 agy=0 qwen=0 mistral=0 backup=claude' \
           'claude=0 grok=0 agy=0 qwen=0 mistral=100 backup=grok'; do
  for m in $(seq 0 31); do
    off=""; i=0
    for v in claude grok agy qwen mistral; do (( m >> i & 1 )) && off+="${off:+,}\"$v\""; i=$((i + 1)); done
    hub "[$off]"
    hmix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND="$row"
    case "$(pick)" in claude|grok|mistral|hold) ;; *) bad+=" {$row}[$off]:$(pick)" ;; esac
  done
done
[[ -z "$bad" ]] && pass "7. three secret rows x 32 vendors-off sets, qwen and agy installed: never qwen or agy" \
  || fail "7. data rule broken with grok rows:$bad"
for c in 'claude=90 grok=0 agy=0 qwen=10 mistral=0 backup=mistral' 'claude=90 grok=0 agy=10 qwen=0 mistral=0 backup=grok' \
         'claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=qwen'; do
  mix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND="$c"; rc=$?
  [[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q 'data rule allows claude, grok or mistral only' "$T/out" \
    && pass "7. secret row refused: $c" || fail "7. secret row not refused: $c rc=$rc $(cat "$T/out")"
done
# orchestration (dispatching and orchestrating, owner msgs a1e5c678,
# ff1baf01) is secret-class: claude 65 / grok 35, backup grok; never qwen or agy
: >"$T/registry.tsv"
hub '[]'
hmix LANE_MIX_KIND=orchestration
[[ "$(pick)" == claude && "$(kindof)" == orchestration ]] && grep -q 'main=claude backup=grok row=cnf ' "$T/out" \
  && grep -q 'reason=data rule: ' "$T/out" \
  && pass "7. kind orchestration -> its main claude, under the data rule" || fail "7. orchestration: $(cat "$T/out")"
hub '["claude"]'
hmix LANE_MIX_KIND=orchestration
[[ "$(pick)" == grok ]] && pass "7. claude off: orchestration goes to the backup grok" || fail "7. orchestration backup: $(cat "$T/out")"
bad=""
for m in $(seq 0 31); do
  off=""; i=0
  for v in claude grok agy qwen mistral; do (( m >> i & 1 )) && off+="${off:+,}\"$v\""; i=$((i + 1)); done
  hub "[$off]"
  hmix LANE_MIX_KIND=orchestration
  case "$(pick)" in claude|grok|mistral|hold) ;; *) bad+=" [$off]:$(pick)" ;; esac
done
[[ -z "$bad" ]] && pass "7. orchestration under all 32 vendors-off sets, qwen and agy installed: never qwen or agy" \
  || fail "7. data rule broken in orchestration:$bad"
for c in 'claude=90 grok=0 agy=10 qwen=0 mistral=0 backup=grok' 'claude=90 grok=0 agy=0 qwen=10 mistral=0 backup=grok' \
         'claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=agy'; do
  mix LANE_MIX_KIND=orchestration LANE_MIX_SPLIT_KIND="$c"; rc=$?
  [[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q 'data rule allows claude, grok or mistral only' "$T/out" \
    && pass "7. orchestration row refused: $c" || fail "7. orchestration row not refused: $c rc=$rc $(cat "$T/out")"
done
rm -f "$H/.local/bin/qwen"; rm -rf "$H/.qwen"

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

# --- 11. T1: 1,000 simulated picks per coding kind, never agy -----------------
# T1 runs on the REAL cnf rows (simple_coding claude 59 / grok 41, mistral 0
# in every coding kind since owner msg 91bf8278), not the pinned ones: the band must hold for the rows
# the fleet spawns by.
# simulate <n>: do_spl_lane_mix once (row, instance setting, availability),
# then <n> picks of the one rule in the same process, each appended to a
# registry that keeps the last `window` rows (all the nudge reads). Prints
# `<vendor>=<picks>` for every vendor and hold, then `eff <vendor>=<weight>`.
simulate() {
  local n="$1"; shift
  : >"$T/registry.tsv"
  mix LANE_FLEET=f1 LANE_HUB_CMD="$T/hub" SIM_N="$n" "$@" MIX_BODY='
    do_spl_lane_mix >/dev/null || exit 1
    declare -A got=([hold]=0); for v in "${LANE_MIX_VENDORS[@]}"; do got[$v]=0; done
    win=()
    for (( i = 1; i <= SIM_N; i++ )); do
      _spl_lane_mix_actual "$LANE_MIX_REGISTRY"; _LM_TRIES=0
      _spl_lane_mix_choose "$_LM_MAIN"
      got[$_LM_CHOICE]=$(( got[$_LM_CHOICE] + 1 ))
      [[ "$_LM_CHOICE" == hold ]] && continue
      printf -v row "%s-%04d\t%s\t%%1\t/w/x\t20261003T%06dZ\tc-001\t%s" "${_LM_CHOICE:0:1}" "$i" "$_LM_CHOICE" "$i" "$_LM_KIND"
      win+=("$row"); (( ${#win[@]} > _LM_WIN )) && win=("${win[@]:1}")
      printf "%s\n" "${win[@]}" >"$LANE_MIX_REGISTRY"
    done
    for v in "${LANE_MIX_VENDORS[@]}" hold; do echo "$v=${got[$v]}"; done
    for v in "${LANE_MIX_VENDORS[@]}"; do echo "eff $v=${_LM_EFF[$v]}"; done'
}
got() { sed -n "s/^$1=//p" "$T/out"; }
eff() { sed -n "s/^eff $1=//p" "$T/out"; }
# t1_check <off-json>: agy 0 of 1,000, and every vendor's share of the picks
# within the band of its effective weight (out of the weights left: an out
# claude that is its own backup leaves its 20 of simple_coding to nobody), or
# all 1,000 hold when nothing is left (claude and mistral out of a row with
# no other vendor, as complex_coding without grok). The band is the
# tolerance, 5 points (spec 115 section 2.1).
t1_check() {
  local v share want sum=0 band=5 bad=""
  [[ "$(got agy)" == 0 ]] || bad+=" agy=$(got agy)"
  for v in claude grok agy qwen mistral; do sum=$(( sum + $(eff "$v") )); done
  if (( sum == 0 )); then
    [[ "$(got hold)" == 1000 ]] || bad+=" hold=$(got hold)"
  else
    [[ "$(got hold)" == 0 ]] || bad+=" hold=$(got hold)"
    for v in claude grok agy qwen mistral; do
      share=$(( ($(got "$v") + 5) / 10 )) want=$(( $(eff "$v") * 100 / sum ))
      (( share >= want - band && share <= want + band )) || bad+=" $v=$share%/$want%"
    done
  fi
  echo "$bad"
}
# one background job per kind, each in its own dir (out, registry, hub
# stub): 12,000 picks take about 90 s of CPU on one core
pids=()
for k in tests simple_coding complex_coding; do
  ( T="$T/t1-$k"; mkdir -p "$T"; cp "${T%/*}/hub" "$T/hub"
    for off in '[]' '["mistral"]' '["claude"]' '["claude","mistral"]'; do
      hub "$off"
      simulate 1000 LANE_MIX_KIND=$k LANE_MIX_CNF="$REAL_CNF"; rc=$?
      [[ $rc -eq 0 ]] || { echo " $k$off:rc=$rc $(tail -n 1 "$T/out")"; continue; }
      r="$(t1_check "$off")"
      [[ -z "$r" ]] || echo " $k$off:$r"
    done >"$T/bad" ) &
  pids+=("$!")
done
wait "${pids[@]}"
bad="$(cat "$T"/t1-*/bad)"; rm -rf "$T"/t1-*
[[ -z "$bad" ]] && pass "11. T1: 1,000 picks of tests, simple_coding and complex_coding under each of the 4 claude/mistral in/out sets: agy 0, every share within the band of its weight" \
  || fail "11. T1:$bad"
# CONTROL: agy 10 in simple_coding, on a copy of the picker whose row check
# lets it through (the validator refuses it, section 13), must pick agy
CTL="$T/ctl/csi-spl-orc"; mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"; ln -s "$PROJ_ROOT/src/bash/features" "$CTL/src/bash/features"
cp "$PROJ_ROOT"/src/bash/run/spl-lane-mix*.func.sh "$CTL/src/bash/run/"
sed -i 's/^\( *\)(( _LM_TGT\[agy\] == 0 )) && \[\[ "\$_LM_BACKUP" != agy \]\] || {$/\1true || {/' "$CTL/src/bash/run/spl-lane-mix.func.sh"
hub '[]'
MIX_PROJ="$CTL" simulate 1000 LANE_MIX_KIND=simple_coding LANE_MIX_SPLIT_KIND='claude=20 grok=0 agy=10 qwen=0 mistral=70 backup=claude'
(( $(got agy) > 0 )) \
  && pass "11. control: agy 10 in simple_coding (row check removed) gives agy $(got agy) of 1,000 picks (T1 would be red)" \
  || fail "11. control: agy 10 did not reach a pick: $(cat "$T/out")"
rm -rf "$T/ctl"
# CONTROL: the nudge gated on the band again (a deficit past the tolerance
# only, as before c-851) on the three-vendor simple_coding row of 2026-10-11
# (the real row has two since owner msg 91bf8278) must break the band
mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"; ln -s "$PROJ_ROOT/src/bash/features" "$CTL/src/bash/features"
cp "$PROJ_ROOT"/src/bash/run/spl-lane-mix*.func.sh "$CTL/src/bash/run/"
sed -i 's/^\( *\)d=\$(( _LM_EFF\[\$v\] \* (_LM_N + 1) - _LM_CNT\[\$v\] \* sum ))$/\1d=$(( _LM_EFF[$v] * _LM_N - _LM_CNT[$v] * sum )); (( d * 100 > _LM_TOL * _LM_N * sum )) || d=0/' "$CTL/src/bash/run/spl-lane-mix.func.sh"
MIX_PROJ="$CTL" simulate 1000 LANE_MIX_KIND=simple_coding LANE_MIX_SPLIT_KIND='claude=20 grok=41 agy=0 qwen=0 mistral=39 backup=claude'
r="$(t1_check '[]')"
grep -qF '_LM_TOL * _LM_N' "$CTL/src/bash/run/spl-lane-mix.func.sh" && [[ -n "$r" ]] \
  && pass "11. control: the nudge gated on the band drifts out of it on simple_coding:$r (T1 would be red)" \
  || fail "11. control: the band-gated nudge held the band: '$r' $(tail -n 3 "$T/out")"
rm -rf "$T/ctl"

# --- 12. T9: i18n with personal data never reaches agy ----------------------
# Spec 115 section 2: an i18n task that is also secret is drafted under the
# data rule. LANE_MIX_SENSITIVE=1 turns i18n into secret, so agy (and qwen)
# is never picked for it: agy receives none of the text, masked or not.
registry i18n 0 0 0
mkdir -p "$H/.qwen"; printf '#!/bin/sh\n' >"$H/.local/bin/qwen"; chmod +x "$H/.local/bin/qwen"; : >"$H/.qwen/settings.json"
t9() {  # t9 <picker-proj>: the bad picks of i18n+secret over the 32 vendors-off sets
  local m off i v b=""
  for m in $(seq 0 31); do
    off=""; i=0
    for v in claude grok agy qwen mistral; do (( m >> i & 1 )) && off+="${off:+,}\"$v\""; i=$((i + 1)); done
    hub "[$off]"
    MIX_PROJ="$1" hmix LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1
    [[ "$(kindof)" == secret || "$(pick)" == hold ]] || b+=" [$off]:kind=$(kindof)"
    case "$(pick)" in claude|grok|mistral|hold) ;; *) b+=" [$off]:$(pick)" ;; esac
  done
  echo "$b"
}
bad="$(t9 "$PROJ_ROOT")"
[[ -z "$bad" ]] && pass "12. T9: i18n + LANE_MIX_SENSITIVE=1 under all 32 vendors-off sets, agy and qwen installed: kind secret, never agy or qwen" \
  || fail "12. T9: personal data reached agy or qwen:$bad"
# CONTROL: a picker that lets i18n keep its kind under LANE_MIX_SENSITIVE=1
# sends the personal data to agy (T9 would be red)
CTL="$T/ctl/csi-spl-orc"; mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"; ln -s "$PROJ_ROOT/src/bash/features" "$CTL/src/bash/features"
cp "$PROJ_ROOT"/src/bash/run/spl-lane-mix*.func.sh "$CTL/src/bash/run/"
sed -i 's/^  \[\[ "\$3" == 1 \]\] || return 0$/  [[ "$3" == 1 \&\& "$_LM_KIND" != i18n ]] || return 0/' "$CTL/src/bash/run/spl-lane-mix.func.sh"
bad="$(t9 "$CTL")"
[[ "$bad" == *:agy* ]] && pass "12. control: i18n kept under LANE_MIX_SENSITIVE=1 sends the personal data to agy (T9 would be red)" \
  || fail "12. control: the unmasked route did not reach agy: '$bad'"
rm -rf "$T/ctl"; rm -f "$H/.local/bin/qwen"; rm -rf "$H/.qwen"

# --- 13. T8: the row validator ------------------------------------------------
# The data-rule set is the cnf validator's SECRET_VENDORS (claude, grok,
# mistral since e6ef6ecfa), not the spec's older {claude, mistral}.
: >"$T/registry.tsv"
SECRET_SET="$(sed -n 's/^SECRET_VENDORS *= *\(.*\)$/\1/p' "$APP_ROOT/csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py" | tr -dc 'a-z,' | tr , ' ')"
t8() {  # t8 <picker-proj>: the section 8 T8 rows that are NOT refused
  local c k row why rc b=""
  for c in 'simple_coding|claude=50 grok=0 agy=0 qwen=0 mistral=60 backup=claude|sums to 110, not 100' \
           'complex_coding|claude=30 grok=0 agy=0 qwen=0 mistral=60 backup=claude|sums to 90, not 100' \
           'tests|claude=50 grok=0 agy=0 qwen=0 mistral=50 backup=grok|tied main at 50' \
           'specs_and_docs|claude=40 grok=0 agy=40 qwen=0 mistral=20 backup=claude|tied main at 40' \
           'tests|claude=80 grok=0 agy=10 qwen=0 mistral=10 backup=mistral|agy writes no code' \
           'complex_coding|claude=80 grok=0 agy=0 qwen=0 mistral=20 backup=agy|agy writes no code' \
           'secret|claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=agy|data rule allows claude, grok or mistral only' \
           'secret|claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=qwen|data rule allows claude, grok or mistral only'; do
    k="${c%%|*}" row="${c#*|}"; why="${row#*|}" row="${row%%|*}"
    MIX_PROJ="$1" mix LANE_MIX_KIND="$k" LANE_MIX_SPLIT_KIND="$row"; rc=$?
    [[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && grep -q "$why" "$T/out" || b+=" {$k $row}"
  done
  echo "$b"
}
bad="$(t8 "$PROJ_ROOT")"
[[ -z "$bad" ]] && pass "13. T8: a row off 100, a tied main, agy in a coding kind and a secret backup agy or qwen are refused" \
  || fail "13. T8: not refused:$bad"
bad=""
for v in $SECRET_SET; do
  [[ "$v" == claude ]] && row="claude=0 grok=0 agy=0 qwen=0 mistral=100 backup=claude" || row="claude=100 grok=0 agy=0 qwen=0 mistral=0 backup=$v"
  mix LANE_MIX_KIND=secret LANE_MIX_SPLIT_KIND="$row" || bad+=" backup=$v"
done
[[ "$SECRET_SET" == "claude grok mistral" && -z "$bad" ]] \
  && pass "13. T8: every backup in the cnf validator's data-rule set ($SECRET_SET) is accepted" \
  || fail "13. T8: data-rule set '$SECRET_SET' refused:$bad"
# CONTROL: a picker that accepts a tie lets the tied row through (T8 red)
CTL="$T/ctl/csi-spl-orc"; mkdir -p "$CTL/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$CTL/lib"; ln -s "$PROJ_ROOT/src/bash/features" "$CTL/src/bash/features"
cp "$PROJ_ROOT"/src/bash/run/spl-lane-mix*.func.sh "$CTL/src/bash/run/"
sed -i 's/^  (( ties == 0 )) || {/  true || {/' "$CTL/src/bash/run/spl-lane-mix.func.sh"
bad="$(t8 "$CTL")"
[[ "$bad" == *"tests claude=50 grok=0 agy=0 qwen=0 mistral=50"* ]] \
  && pass "13. control: a picker that accepts a tie lets the tied row through (T8 would be red)" \
  || fail "13. control: the tie was still refused: '$bad'"
rm -rf "$T/ctl"

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

# --- 14. specs_and_docs is agy 80 +/- 3 of 1,000 picks (SPL-1656) ------------
# The seed is the empty registry and picks 1..1000 in order: the nudge is
# deterministic, so that sequence is the fixed seed. The real cnf row.
# code_review and review are the same row (owner msg cb1b623e). The control
# is the old 60/30/10 row, which must fall outside the band.
docs80() {  # <kind> [extra mix args...] -> bad text, empty when agy is 770..830 and eff 80
  local kind="$1" n bad="" rc; shift
  hub '[]'
  simulate 1000 LANE_MIX_KIND="$kind" LANE_MIX_CNF="$REAL_CNF" "$@"; rc=$?
  n="$(got agy)"
  [[ $rc -eq 0 && "$n" =~ ^[0-9]+$ && "$n" -ge 770 && "$n" -le 830 && "$(eff agy)" == 80 ]] \
    || bad=" $kind:rc=$rc agy=${n:-?}/1000 eff=$(eff agy)"
  printf '%s' "$bad"
}
bad="$(docs80 specs_and_docs)"
[[ -z "$bad" ]] && pass "14. specs_and_docs, real cnf, 1,000 picks from an empty registry: agy $(got agy) (80% +/- 3)" \
  || fail "14. specs_and_docs band:$bad"
bad="$(docs80 code_review)"
n="$(got agy)"
mix LANE_MIX_KIND=code_review LANE_MIX_CNF="$REAL_CNF"
[[ -z "$bad" && "$(kindof)" == specs_and_docs && "$(pick)" == agy ]] \
  && pass "14. code_review is the specs_and_docs row: agy $n of 1,000" \
  || fail "14. code_review:$bad kind=$(kindof) pick=$(pick)"
mix LANE_MIX_KIND=review LANE_MIX_CNF="$REAL_CNF"
[[ "$(kindof)" == specs_and_docs && "$(pick)" == agy ]] \
  && pass "14. review is specs_and_docs, main agy" || fail "14. review: $(cat "$T/out")"
# CONTROL: the old 60/30/10 row must miss the 80 +/- 3 band (this case would
# be green if the assertion still accepted 60).
bad="$(docs80 specs_and_docs LANE_MIX_SPLIT_KIND='claude=10 grok=0 agy=60 qwen=0 mistral=30 backup=claude')"
[[ -n "$bad" && "$(eff agy)" == 60 ]] \
  && pass "14. control: the old 60 row misses the 80 band ($bad)" \
  || fail "14. control: the old 60 row held the 80 band: '$bad' eff=$(eff agy)"

# --- 15. UI work never goes to mistral until the re-test passes (SPL-2263) ---
# Owner HUM-10, t1 b61851fb: a brief or paths under csi-spl-wui/ never get
# mistral as main or backup while cnf mistral_ui_allowed is not true
# (do_spl_vendor_ui_retest flips it). The RED CONTROL is the same lane with no
# UI signal: today's mix gives it to mistral.
rm -rf "$T/dispatch"; : >"$T/registry.tsv"
printf 'Fix the hover in csi-spl-wui/src/components/x.vue\n' >"$T/ui-brief.md"
printf 'Rewrite csi-spl-doc/doc/md/x.md\n' >"$T/docs-brief.md"
mix LANE_MIX_KIND=simple_coding
[[ "$(pick)" == mistral ]] && pass "15. control: with no UI signal simple_coding goes to mistral (the mix the rule changes)" \
  || fail "15. control: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding LANE_MIX_BRIEF="$T/ui-brief.md"
[[ "$(pick)" == claude ]] && grep -q '^mistral .*skip (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/)); share to claude' "$T/out" \
  && pass "15. a WUI brief never routes to mistral: claude, mistral's weight to claude" || fail "15. ui brief: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding LANE_MIX_PATHS="csi-spl-orc/x.sh,./csi-spl-wui/src/pages/a.vue"
[[ "$(pick)" == claude ]] && grep -q 'path ./csi-spl-wui/src/pages/a.vue is under csi-spl-wui/' "$T/out" \
  && pass "15. a csi-spl-wui/ path is UI work too" || fail "15. ui paths: $(cat "$T/out")"
mix LANE_MIX_KIND=simple_coding LANE_MIX_BRIEF="$T/docs-brief.md" LANE_MIX_PATHS="csi-spl-wuix/a,csi-spl-doc/x.md"
[[ "$(pick)" == mistral ]] && pass "15. a docs brief (no csi-spl-wui/) still may go to mistral" || fail "15. docs brief: $(cat "$T/out")"
mix LANE_MIX_KIND=specs_and_docs LANE_MIX_BRIEF="$T/docs-brief.md" LANE_MIX_SPLIT_KIND='claude=10 grok=0 agy=0 qwen=0 mistral=90 backup=claude'
[[ "$(pick)" == mistral ]] && pass "15. specs_and_docs with mistral main, docs brief: mistral" || fail "15. docs main: $(cat "$T/out")"
attempt task-ui claude fail:F2; attempt task-ui claude fail:F2
mix LANE_MIX_KIND=complex_coding LANE_MIX_TASK=task-ui
[[ "$(pick)" == mistral ]] && pass "15. control: claude failed twice, no UI signal: the backup mistral" || fail "15. backup control: $(cat "$T/out")"
mix LANE_MIX_KIND=complex_coding LANE_MIX_TASK=task-ui LANE_MIX_BRIEF="$T/ui-brief.md"
[[ "$(pick)" == grok ]] && grep -q 'mistral is out (mistral takes no UI work' "$T/out" && grep -q 'grok is the last fallback' "$T/out" \
  && pass "15. a WUI brief never gets mistral as the backup either: claude, else grok" || fail "15. ui backup: $(cat "$T/out")"
rm -rf "$T/dispatch"
mix LANE_MIX_KIND=secret LANE_MIX_BRIEF="$T/ui-brief.md" LANE_MIX_SPLIT_KIND='claude=0 grok=0 agy=0 qwen=0 mistral=100 backup=claude'
[[ "$(pick)" == claude ]] && pass "15. the data rule keeps working: secret UI work with a mistral main goes to claude" || fail "15. secret: $(cat "$T/out")"
yq -i '.env.box.agent_split.mistral_ui_allowed = true' "$CNF"
mix LANE_MIX_KIND=simple_coding LANE_MIX_BRIEF="$T/ui-brief.md"
[[ "$(pick)" == mistral ]] && pass "15. mistral_ui_allowed: true (the re-test passed) lifts the rule" || fail "15. allowed: $(cat "$T/out")"
yq -i '.env.box.agent_split.mistral_ui_allowed = false' "$CNF"
[[ "$(yq -r '.env.box.agent_split.mistral_ui_allowed' "$REAL_CNF")" == false ]] \
  && pass "15. the real cnf holds mistral_ui_allowed: false" || fail "15. real cnf switch: $(yq -r '.env.box.agent_split.mistral_ui_allowed' "$REAL_CNF")"

# --- 16. coding never goes to mistral (owner HUM-10, t1 b61851fb, msg 91bf8278) ---
# "Docs and reviews only, no coding": every kind but specs_and_docs and i18n
# never picks mistral, as main or backup, while cnf mistral_coding_allowed is
# not true, even from a hub row (LANE_MIX_SPLIT_KIND) that still names it.
# RED CONTROL: the same picks with the switch true (today's behaviour before
# the order) give mistral.
rm -rf "$T/dispatch"; : >"$T/registry.tsv"; hub '[]'
yq -i '.env.box.agent_split.mistral_coding_allowed = false' "$CNF"
bad="" ctl=""
for k in tests simple_coding complex_coding secret orchestration; do
  row="claude=10 grok=0 agy=0 qwen=0 mistral=90 backup=claude"
  mix LANE_MIX_KIND=$k LANE_MIX_SPLIT_KIND="$row"
  [[ "$(pick)" != mistral ]] && grep -q "^mistral .*skip (mistral writes no code, kind $k (owner HUM-10 t1 b61851fb msg 91bf8278" "$T/out"     || bad+=" $k:main=$(pick)"
  attempt "task-nc-$k" claude fail:F2; attempt "task-nc-$k" claude fail:F2
  mix LANE_MIX_KIND=$k LANE_MIX_TASK="task-nc-$k" LANE_MIX_SPLIT_KIND="claude=90 grok=0 agy=0 qwen=0 mistral=10 backup=mistral"
  [[ "$(pick)" != mistral ]] && grep -q 'mistral is out (mistral writes no code' "$T/out" || bad+=" $k:backup=$(pick)"
  yq -i '.env.box.agent_split.mistral_coding_allowed = true' "$CNF"
  mix LANE_MIX_KIND=$k LANE_MIX_SPLIT_KIND="$row"
  [[ "$(pick)" == mistral ]] || ctl+=" $k:main=$(pick)"
  mix LANE_MIX_KIND=$k LANE_MIX_TASK="task-nc-$k" LANE_MIX_SPLIT_KIND="claude=90 grok=0 agy=0 qwen=0 mistral=10 backup=mistral"
  [[ "$(pick)" == mistral ]] || ctl+=" $k:backup=$(pick)"
  yq -i '.env.box.agent_split.mistral_coding_allowed = false' "$CNF"
done
[[ -z "$bad" ]] && pass "16. no coding kind picks mistral, as main or backup, even from a hub row naming it" || fail "16. coding:$bad $(cat "$T/out")"
[[ -z "$ctl" ]] && pass "16. control: mistral_coding_allowed true gives the same picks to mistral" || fail "16. control:$ctl"
rm -rf "$T/dispatch"
mix LANE_MIX_KIND=hard LANE_MIX_SPLIT_KIND="claude=10 grok=0 agy=0 qwen=0 mistral=90 backup=claude"
[[ "$(pick)" == claude ]] && pass "16. an alias (hard = complex_coding) is coding too: claude" || fail "16. hard: $(cat "$T/out")"
mix LANE_MIX_SENSITIVE=1 LANE_MIX_KIND=specs_and_docs LANE_MIX_SPLIT_KIND="claude=10 grok=0 agy=0 qwen=0 mistral=90 backup=claude"
[[ "$(pick)" == claude ]] && pass "16. sensitive docs are secret, so coding-class: claude" || fail "16. sensitive: $(cat "$T/out")"
for k in specs_and_docs review; do
  mix LANE_MIX_KIND=$k LANE_MIX_SPLIT_KIND="claude=10 grok=0 agy=0 qwen=0 mistral=90 backup=claude"
  [[ "$(pick)" == mistral ]] && pass "16. $k still goes to mistral" || fail "16. $k: $(cat "$T/out")"
done
mix LANE_MIX_KIND=complex_coding LANE_MIX_CNF="$REAL_CNF"
[[ "$(pick)" == claude ]] && grep -q 'mistral writes no code' "$T/out"   && pass "16. the real cnf: complex_coding goes to claude, mistral out by the coding rule" || fail "16. real cnf: $(cat "$T/out")"
[[ "$(yq -r '.env.box.agent_split.mistral_coding_allowed' "$REAL_CNF")" == false ]]   && pass "16. the real cnf holds mistral_coding_allowed: false" || fail "16. real cnf switch: $(yq -r '.env.box.agent_split.mistral_coding_allowed' "$REAL_CNF")"
bad=""
for k in tests simple_coding complex_coding secret orchestration; do
  [[ "$(yq -r ".env.box.agent_split_by_kind.$k.mistral // 0" "$REAL_CNF")" == 0 && "$(yq -r ".env.box.agent_split_by_kind.$k.backup" "$REAL_CNF")" != mistral ]] || bad+=" $k"
done
[[ -z "$bad" && "$(yq -r '.env.box.agent_split_by_kind.specs_and_docs.mistral' "$REAL_CNF")" -gt 0 ]]   && pass "16. the real cnf rows: mistral 0 and never the backup in every coding kind, still in specs_and_docs" || fail "16. real rows:$bad"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
