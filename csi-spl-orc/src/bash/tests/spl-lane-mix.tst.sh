#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_mix reads the vendor split from cnf env.box.agent_split
#          and the box's recent spawns from registry.tsv, and picks the next
#          vendor approximately: spec work goes to agy, secrets and the most
#          complex coding go to claude, and a difficulty left unset defaults
#          to grok. Easy work (difficulty under 60) goes to the vendor
#          furthest below target beyond the tolerance, else to the largest
#          non-claude share. A vendor with no CLI or no sign-in is skipped
#          and its share goes to claude. A fake agent home and registry; the
#          cnf is the real all.env.yaml.
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
    -u SPOOL_AGENT_USER \
    -u CLAUDE_BIN -u GROK_BIN -u AGY_BIN -u QWEN_BIN \
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
[[ "$(pick)" != agy ]] && grep -qE '^agy +25% +0% .* no +skip \(no agy cli; share to claude\)$' "$T/out" \
  && grep -qE '^claude +20% +45% ' "$T/out" \
  && pass "5. no agy cli: skipped, claude's share 20 -> 45" || fail "5. no agy: $(cat "$T/out")"
rm "$H/.grok/auth.json"
registry 4 16 0
mix LANE_MIX_DIFFICULTY=30
[[ "$(pick)" == claude ]] && grep -q 'skip (grok not signed in; share to claude)' "$T/out" \
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
[[ "$(pick)" == claude ]] && grep -q 'kind spec but agy is skipped (no agy cli); share to claude' "$T/out" \
  && pass "7. spec with no agy cli -> claude" || fail "7. spec skipped: $(cat "$T/out")"
printf '#!/bin/sh\n' >"$H/.local/bin/agy"; chmod +x "$H/.local/bin/agy"

mix LANE_MIX_KIND=nope; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^pick=' "$T/out" \
  && pass "7. a bad kind is refused" || fail "7. kind: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
