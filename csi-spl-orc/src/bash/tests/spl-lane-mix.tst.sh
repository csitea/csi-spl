#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_mix reads the vendor split from cnf env.box.agent_split
#          and the box's recent spawns from registry.tsv, and picks the next
#          vendor approximately: spec work goes to agy, secrets and the most
#          complex coding go to claude, and a difficulty left unset defaults
#          to grok. Easy work (difficulty under 60) goes to the vendor
#          furthest below target beyond the tolerance, else to the largest
#          non-claude share. A vendor with no CLI or no sign-in is skipped
#          and falls down the chain grok -> agy -> claude (its pick and its
#          share). The instance setting (rdb 0149, read
#          from a stubbed hub) beats it all: a kind off or paused there is
#          never picked; a hub that does not answer -> the local checks,
#          said in the reason; a local limit verdict is reported as a pause.
#          A fake agent home and registry; the cnf is the real all.env.yaml.
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

CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
H="$T/home"
mkdir -p "$H/.local/bin" "$H/.grok" "$H/.gemini"
for c in claude grok agy; do printf '#!/bin/sh\n' >"$H/.local/bin/$c"; chmod +x "$H/.local/bin/$c"; done
: >"$H/.grok/auth.json"

# registry <claude> <grok> <agy> [<qwen>]: that many spawns, plus role seats
# and a re-registered id that must count once
registry() {
  local i=0 k n
  : >"$T/registry.tsv"
  printf 'c-001\tclaude\t%%1\t/w/c-001\t20261003T000000Z\n' >>"$T/registry.tsv"
  for k in claude grok agy qwen; do
    case $k in claude) n=$1 ;; grok) n=$2 ;; agy) n=$3 ;; qwen) n=${4:-0} ;; esac
    while (( n-- > 0 )); do
      i=$((i + 1))
      printf '%s-%03d\t%s\t%%%d\t/w/x\t20261003T10%04dZ\n' "${k:0:1}" "$((100 + i))" "$k" "$i" "$i" >>"$T/registry.tsv"
    done
  done
  printf 'c-002\tclaude\t%%2\t/w/c-002\t20261003T235959Z\n' >>"$T/registry.tsv"
  (( $1 > 0 )) && printf 'c-101\tclaude\t%%9\t/w/x\t20261003T200000Z\n' >>"$T/registry.tsv"
  return 0
}

mix() {
  env -u LANE_MIX_DIFFICULTY -u LANE_MIX_SENSITIVE -u LANE_MIX_SPLIT -u LANE_MIX_KIND \
    -u SPOOL_AGENT_USER -u LANE_MIX_WD_DIR -u LANE_MIX_LIMIT_FRESH \
    -u CLAUDE_BIN -u GROK_BIN -u AGY_BIN -u QWEN_BIN \
    -u LANE_FLEET -u LANE_HUB_CMD -u LANE_ENV -u ENV -u LANE_TENANT -u LANE_BOX -u LANE_DESK_BOX \
    -u LANE_MIX_INSTANCE -u LANE_MIX_REPORT \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T" \
    LANE_MIX_REGISTRY="$T/registry.tsv" LANE_MIX_AGENT_HOME="$H" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_lane_mix' >"$T/out" 2>&1 </dev/null
}
pick() { sed -n 's/^pick=\([a-z]*\) .*/\1/p' "$T/out"; }

FUNC="$PROJ_ROOT/src/bash/run/spl-lane-mix.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
[[ "$(yq -r '.env.box.agent_split | [.claude, .grok, .agy, .qwen] | map(tostring) | join(" ")' "$CNF")" == "20 55 25 0" ]] \
  && pass "0. cnf carries the owner's split 20/55/25/0" || fail "0. cnf split: $(yq -r '.env.box.agent_split' "$CNF")"

# --- 1. the table -------------------------------------------------------------
registry 4 11 5
mix; rc=$?
[[ $rc -eq 0 ]] && grep -q '^window=20 n=20 tolerance=5 ' "$T/out" \
  && grep -qE '^claude +20% +20% +20% +4 yes +ok$' "$T/out" \
  && grep -qE '^grok +55% +55% +55% +11 yes +ok$' "$T/out" \
  && grep -qE '^agy +25% +25% +25% +5 yes +ok$' "$T/out" \
  && pass "1. on-target mix: role seats and the duplicate id left out, every vendor ok" || fail "1. table: rc=$rc $(cat "$T/out")"
grep -q '^next easy=grok (mix inside the band' "$T/out" && [[ "$(pick)" == grok ]] \
  && grep -q 'difficulty unset: default is grok' "$T/out" \
  && pass "1. difficulty unset: pick grok, next easy names grok" || fail "1. unset: $(cat "$T/out")"

# --- 2. tolerance: inside the band, easy work goes to grok ---------------------
registry 4 10 6
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == grok ]] && grep -q 'mix inside the band' "$T/out" \
  && pass "2. grok 50% vs 55% is inside the band: easy -> grok" || fail "2. band: $(cat "$T/out")"

# --- 3. the nudge: a vendor below target beyond the band gets the easy work ----
registry 4 16 0
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == agy ]] && grep -qE '^agy +25% +25% +0% +0 yes +under$' "$T/out" \
  && grep -q 'agy is 25 points under its 25% (band 5)' "$T/out" \
  && pass "3. agy at 0% of 25%: easy -> agy" || fail "3. nudge agy: $(cat "$T/out")"
registry 15 2 3
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == grok ]] && grep -q 'grok is 45 points under' "$T/out" \
  && pass "3. grok furthest under (10% of 55%): easy -> grok, not agy" || fail "3. nudge grok: $(cat "$T/out")"
registry 0 12 8
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == claude ]] && grep -qE '^claude .* under$' "$T/out" \
  && pass "3. claude at 0% of 20%: easy -> claude" || fail "3. nudge claude: $(cat "$T/out")"

# --- 4. hard work and the data rule beat the ratio -----------------------------
registry 15 2 3
mix LANE_MIX_DIFFICULTY=60
[[ "$(pick)" == claude ]] && grep -q 'difficulty 60 >= 60' "$T/out" \
  && pass "4. difficulty 60 -> claude though grok is under" || fail "4. hard: $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=10 LANE_MIX_SENSITIVE=1
[[ "$(pick)" == claude ]] && grep -q 'data rule' "$T/out" \
  && pass "4. data rule: easy work with secrets -> claude" || fail "4. data rule: $(cat "$T/out")"

# --- 5. a missing or signed-out CLI is skipped, its share goes to claude -------
rm "$H/.local/bin/agy"
registry 4 16 0
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" != agy ]] && grep -qE '^agy +25% +0% .* no +skip \(no agy cli\); share to claude$' "$T/out" \
  && grep -qE '^claude +20% +45% ' "$T/out" \
  && pass "5. no agy cli: skipped, claude's share 20 -> 45" || fail "5. no agy: $(cat "$T/out")"
rm "$H/.grok/auth.json"
registry 4 16 0
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == claude ]] && grep -q 'skip (grok not signed in); share to claude' "$T/out" \
  && grep -qE '^claude +20% +100% ' "$T/out" \
  && pass "5. grok not signed in and no agy: every share to claude, easy -> claude" || fail "5. signed out: $(cat "$T/out")"
: >"$H/.grok/auth.json"; printf '#!/bin/sh\n' >"$H/.local/bin/agy"; chmod +x "$H/.local/bin/agy"

# --- 6. the split override and refusals ----------------------------------------
registry 10 10 0
mix LANE_MIX_DIFFICULTY=30 LANE_MIX_SPLIT='claude=50 grok=50 agy=0 qwen=0'
[[ "$(pick)" == grok ]] && grep -qE '^agy +0% +0% ' "$T/out" \
  && pass "6. LANE_MIX_SPLIT (the do_spl_agent_split_show line) overrides cnf" || fail "6. override: $(cat "$T/out")"
mix LANE_MIX_SPLIT='claude=50 grok=50 agy=10 qwen=0'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'sums to 110, not 100' "$T/out" && ! grep -q '^pick=' "$T/out" \
  && pass "6. a split that does not sum to 100 is refused" || fail "6. sum: rc=$rc $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=abc; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" && pass "6. a bad difficulty is refused" || fail "6. difficulty: rc=$rc $(cat "$T/out")"
rm "$T/registry.tsv"
mix LANE_MIX_DIFFICULTY=30; rc=$?
[[ $rc -eq 0 ]] && grep -q ' n=0 ' "$T/out" && [[ "$(pick)" == grok ]] \
  && pass "6. no registry yet: n=0, easy -> grok" || fail "6. no registry: rc=$rc $(cat "$T/out")"

# --- 7. task kind: spec -> agy, secret or hard -> claude, default -> grok ------
registry 4 11 5
mix LANE_MIX_KIND=spec
[[ "$(pick)" == agy ]] && grep -q 'kind spec: specifications go to agy' "$T/out" \
  && pass "7. kind spec -> agy" || fail "7. spec: $(cat "$T/out")"
mix LANE_MIX_KIND=spec LANE_MIX_DIFFICULTY=90
[[ "$(pick)" == agy ]] && pass "7. kind spec beats a high difficulty" || fail "7. spec hard: $(cat "$T/out")"
mix LANE_MIX_KIND=spec LANE_MIX_SENSITIVE=1
[[ "$(pick)" == claude ]] && grep -q 'data rule' "$T/out" \
  && pass "7. a spec that carries secrets still goes to claude" || fail "7. spec secret: $(cat "$T/out")"
mix LANE_MIX_KIND=secret LANE_MIX_DIFFICULTY=10
[[ "$(pick)" == claude ]] && grep -q 'data rule' "$T/out" \
  && pass "7. kind secret -> claude" || fail "7. secret: $(cat "$T/out")"
mix LANE_MIX_KIND=hard
[[ "$(pick)" == claude ]] && grep -q 'kind hard: the most complex coding goes to claude' "$T/out" \
  && pass "7. kind hard -> claude even when difficulty is unset" || fail "7. hard: $(cat "$T/out")"
mix LANE_MIX_KIND=default
[[ "$(pick)" == grok ]] && grep -q 'difficulty unset: default is grok' "$T/out" \
  && pass "7. kind default -> grok" || fail "7. default: $(cat "$T/out")"

# control: difficulty left unset used to count as unsure and pick claude.
# The registry is the one where claude is under target, so the easy mix would
# also pick claude. This fails if the default goes back to claude.
registry 0 12 8
mix
[[ "$(pick)" == grok ]] && grep -q 'difficulty unset: default is grok' "$T/out" \
  && ! grep -q 'unsure counts as hard' "$T/out" \
  && pass "7. control: unset difficulty stays grok even when claude is under target" \
  || fail "7. control: default went back to claude: $(cat "$T/out")"
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == claude ]] \
  && pass "7. the same registry with difficulty set still nudges claude" \
  || fail "7. nudge still works: $(cat "$T/out")"

rm "$H/.local/bin/agy"
mix LANE_MIX_KIND=spec
[[ "$(pick)" == claude ]] && grep -q 'kind spec but agy is skipped (no agy cli); falls to claude (chain grok -> agy -> claude)' "$T/out" \
  && grep -q 'skip (no agy cli); share to claude$' "$T/out" \
  && pass "7. spec with no agy cli -> claude" || fail "7. spec skipped: $(cat "$T/out")"
printf '#!/bin/sh\n' >"$H/.local/bin/agy"; chmod +x "$H/.local/bin/agy"

# --- 8. a harness out of quota (spec 102 T029) is skipped -------------------
# the watchdog's ctx/<id>/out.s2 says "HIT S2 kind=limit" for a grok lane on
# this box: within LANE_MIX_LIMIT_FRESH s grok is skipped like a missing cli
limit() {  # limit <id> <age-s>: a watchdog verdict that old
  mkdir -p "$T/dispatch/wd/ctx/$1"
  echo "HIT S2 kind=limit pane: You hit your weekly limit" >"$T/dispatch/wd/ctx/$1/out.s2"
  touch -d "@$(( $(date +%s) - $2 ))" "$T/dispatch/wd/ctx/$1/out.s2"
}
registry 4 11 5
mix
[[ "$(pick)" == grok ]] && pass "8. control: no limit verdict, unset difficulty -> grok" || fail "8. control: $(cat "$T/out")"
limit g-950 600
mix
[[ "$(pick)" == agy ]] && grep -q 'skip (grok limit (g-950 S2 kind=limit 10m ago)); share to agy$' "$T/out" \
  && grep -q 'difficulty unset: default grok is skipped (grok limit (g-950 .*); falls to agy (chain grok -> agy -> claude)' "$T/out" \
  && grep -qE '^agy +25% +80% ' "$T/out" && grep -qE '^claude +20% +20% ' "$T/out" \
  && pass "8. a fresh grok limit verdict: grok skipped, its share and the default fall to agy" || fail "8. limit: $(cat "$T/out")"
# chain, owner HUM-10 t1 65f75266 "if grok is not available we take agy":
# claude is under target here, so the old fallback (the easy pick) gave
# claude while agy was free. This fails if grok falls to the easy pick again.
registry 0 12 8
mix
[[ "$(pick)" == agy ]] && grep -qE '^claude +20% +20% +0% .* under$' "$T/out" \
  && pass "8. chain: grok skipped + agy free -> agy, though claude is under target" || fail "8. chain agy: $(cat "$T/out")"
registry 15 0 5
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == agy ]] && pass "8. easy work skips the limited grok too" || fail "8. easy limit: $(cat "$T/out")"
registry 4 11 5
rm "$H/.local/bin/agy"
mix
[[ "$(pick)" == claude ]] && grep -qE '^claude +20% +100% ' "$T/out" \
  && grep -q 'default grok is skipped (grok limit (g-950 .*); falls to claude (chain grok -> agy -> claude)' "$T/out" \
  && grep -q 'skip (grok limit (g-950 .*)); share to claude$' "$T/out" \
  && pass "8. chain: grok limited and agy skipped -> claude" || fail "8. claude floor: $(cat "$T/out")"
mix LANE_MIX_KIND=spec
[[ "$(pick)" == claude ]] && grep -q 'kind spec but agy is skipped (no agy cli); falls to claude' "$T/out" \
  && pass "8. chain: kind spec + agy skipped -> claude, never the limited grok" || fail "8. spec chain: $(cat "$T/out")"
printf '#!/bin/sh\n' >"$H/.local/bin/agy"; chmod +x "$H/.local/bin/agy"
mix LANE_MIX_LIMIT_FRESH=300
[[ "$(pick)" == grok ]] && pass "8. a verdict older than LANE_MIX_LIMIT_FRESH is stale: grok again" || fail "8. stale: $(cat "$T/out")"
echo "HIT S2 kind=login pane: please run /login" >"$T/dispatch/wd/ctx/g-950/out.s2"
mix
[[ "$(pick)" == grok ]] && pass "8. control: an S2 kind=login is not a quota verdict" || fail "8. login: $(cat "$T/out")"
limit c-950 60
mix
[[ "$(pick)" == grok ]] && pass "8. control: a claude lane's limit does not skip grok" || fail "8. other vendor: $(cat "$T/out")"
rm -rf "$T/dispatch"

# --- 9. the instance setting (rdb 0149): off on the hub = off on every box ---
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
registry 4 11 5
hub '[]'
hmix
[[ "$(pick)" == grok ]] && grep -q '^instance: kinds off none, paused none (hub)$' "$T/out" && ! grep -q 'not read' "$T/out" \
  && pass "9. control: the hub has every kind on: unset difficulty -> grok" || fail "9. control on: $(cat "$T/out")"
hub '["grok"]'
hmix
[[ "$(pick)" == agy ]] && grep -qE '^grok +55% +0% .* skip \(grok off in instance settings\); share to agy$' "$T/out" \
  && grep -qE '^agy +25% +80% ' "$T/out" && grep -q 'default grok is skipped (grok off in instance settings); falls to agy' "$T/out" \
  && pass "9. grok off in instance settings: never picked, its share and the default to agy" || fail "9. grok off: $(cat "$T/out")"
for d in 0 30 60 90; do
  hmix LANE_MIX_DIFFICULTY=$d
  [[ "$(pick)" != grok && -n "$(pick)" ]] || fail "9. grok off, difficulty $d picked $(pick): $(cat "$T/out")"
done
registry 0 20 0
hmix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" != grok ]] && pass "9. grok off but 55 points under target: still not picked" || fail "9. grok under: $(cat "$T/out")"
registry 4 11 5
hub '["claude"]'
hmix LANE_MIX_KIND=hard
[[ "$(pick)" == grok ]] && grep -qE '^claude +20% +0% .*skip \(claude off in instance settings\); share to the others$' "$T/out" \
  && grep -qE '^grok +55% +69% ' "$T/out" && grep -qE '^agy +25% +31% ' "$T/out" \
  && grep -q 'but claude is skipped (claude off in instance settings)' "$T/out" \
  && pass "9. claude off: hard work goes to the largest other share, claude's 20 split 14/6" || fail "9. claude off: $(cat "$T/out")"
hmix LANE_MIX_SENSITIVE=1
[[ "$(pick)" == hold ]] && grep -q 'launcher=- reason=data rule: secrets or personal data go to claude only' "$T/out" \
  && pass "9. claude off + secrets: hold, never another kind" || fail "9. data rule hold: $(cat "$T/out")"
hub '["grok","agy"]'
hmix
[[ "$(pick)" == claude ]] && grep -q 'default grok is skipped (grok off in instance settings); falls to claude' "$T/out" \
  && pass "9. chain: grok and agy off -> claude" || fail "9. chain claude: $(cat "$T/out")"
hub '["grok","agy","qwen"]'
hmix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == claude ]] && grep -qE '^claude +20% +100% ' "$T/out" \
  && pass "9. every kind but claude off: claude" || fail "9. only claude: $(cat "$T/out")"
hub '[]' '{"grok":{"until":"2099-01-01T00:00:00Z","reason":"S2 kind=limit on g-1","box":"box-t"}}'
hmix
[[ "$(pick)" != grok ]] && grep -q 'skip (grok paused in instance settings until 2099-01-01T00:00:00Z: S2 kind=limit on g-1 (box box-t))' "$T/out" \
  && grep -q '^instance: kinds off none, paused grok until 2099-01-01T00:00:00Z (hub)$' "$T/out" \
  && pass "9. grok paused by another box: skipped here too" || fail "9. paused: $(cat "$T/out")"
hub '["grok"]'
touch "$T/hub.down"
hmix
[[ "$(pick)" == grok ]] && grep -q '^instance: setting not read (the hub did not answer it: dial: connection refused): local checks only$' "$T/out" \
  && grep -q 'reason=difficulty unset: default is grok; instance setting not read (the hub did not answer it' "$T/out" \
  && pass "9. hub down: today's behaviour, and the reason says so" || fail "9. hub down: $(cat "$T/out")"
rm -f "$T/hub.down"
mix
grep -q 'instance setting not read (no fleet' "$T/out" && [[ "$(pick)" == grok ]] \
  && pass "9. no fleet: local checks, said in the reason" || fail "9. no fleet: $(cat "$T/out")"
hmix LANE_MIX_INSTANCE=0
[[ "$(pick)" == grok ]] && grep -q 'not read (LANE_MIX_INSTANCE=0)' "$T/out" \
  && pass "9. LANE_MIX_INSTANCE=0 skips the read" || fail "9. instance=0: $(cat "$T/out")"
# a local limit verdict is reported as a pause until it runs out here
hub '[]'
rm -f "$T/hub.log"
limit g-951 600
hmix
want="$(date -u -d "@$(( $(stat -c %Y "$T/dispatch/wd/ctx/g-951/out.s2") + 21600 ))" +%Y-%m-%dT%H:%M:%SZ)"
[[ "$(pick)" != grok ]] && grep -qx "pause grok $want usage limit: g-951 S2 kind=limit 10m ago" "$T/hub.log" \
  && grep -q "^instance: grok paused for every box until $want" "$T/out" \
  && pass "9. a local grok limit verdict is reported to the hub as a pause until it runs out" || fail "9. report: $(cat "$T/hub.log" 2>&1) $(cat "$T/out")"
rm -f "$T/hub.log"
hmix LANE_MIX_REPORT=0
[[ ! -e "$T/hub.log" && "$(pick)" != grok ]] && pass "9. LANE_MIX_REPORT=0: skipped, not reported" || fail "9. report=0: $(cat "$T/out")"
mix
[[ ! -e "$T/hub.log" ]] && pass "9. control: no fleet, nothing reported" || fail "9. no fleet reported"
hub '[]' '{"grok":{"until":"2099-01-01T00:00:00Z","reason":"x","box":"b"}}'
hmix
[[ ! -e "$T/hub.log" ]] && pass "9. already paused on the hub: not reported again" || fail "9. re-report: $(cat "$T/hub.log")"
rm -rf "$T/dispatch"

mix LANE_MIX_KIND=nope; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" \
  && pass "7. a bad kind is refused" || fail "7. kind: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
