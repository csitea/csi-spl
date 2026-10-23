#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_login2_sync (SPL-2943) on a temp tree with a FAKE
# source credential (no real login is read):
#   1. no source set -> WARN, nothing copied, exit 0
#   2. the source folder has no credential -> WARN, nothing copied
#   3. the source expires later than the destination -> copied (all 3 files,
#      mode 600, folder 700, the old credential kept as .bak-login2-<UTC>),
#      one "copied, expires <UTC>" line, no credential content in the output
#   4. the source expires earlier (or the same) -> nothing copied
#   5. DRY_RUN=1 plans and changes nothing
#   6. the source from box.env SPOOL_LOGIN2_SRC
#   7. a main login as the source (the user's own ~/.claude) or the
#      destination itself -> REFUSED, exit 2
#   8. the cron row is in box-crons.manifest and its script exists
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SECRET="fake-refresh-token-$$"
mkcred() { mkdir -p "$1"; printf '{"claudeAiOauth":{"accessToken":"a-%s","refreshToken":"%s","expiresAt":%s}}\n' "$SECRET" "$SECRET" "$2" > "$1/.credentials.json"; }
run() { SNIPPET='do_spl_agent_login2_sync' in_orc SPOOL_AGENT_USER="$(id -un)" LOGIN2_SUDO= HOME="$T/home" SPOOL_ROOT="$T/spool" "$@" 2>&1; }
mkdir -p "$T/home" "$T/spool"
SRC="$T/backup"; DST="$T/agent/.claude-2"

out="$(run CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"WARN no source set"* && ! -e "$DST" ]] && pass "1. no source: WARN, nothing copied" || fail "1. rc=$rc out=$out"

mkdir -p "$SRC"
out="$(run LOGIN2_SYNC_SRC="$SRC" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"WARN no credential"* && ! -e "$DST" ]] && pass "2. no source credential: WARN, nothing copied" || fail "2. rc=$rc out=$out"

mkcred "$SRC" 1893456000000; echo '{"s":1}' > "$SRC/settings.json"; echo '{"c":1}' > "$SRC/.claude.json"
mkcred "$DST" 1861920000000
out="$(run LOGIN2_SYNC_SRC="$SRC" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"login2-sync: copied, expires 2030-01-01T00:00:00Z"* ]] && pass "3. newer source: copied, expiry logged" || fail "3. rc=$rc out=$out"
cmp -s "$SRC/.credentials.json" "$DST/.credentials.json" && cmp -s "$SRC/settings.json" "$DST/settings.json" && cmp -s "$SRC/.claude.json" "$DST/.claude.json" &&
  pass "3. all three files copied" || fail "3. files differ"
m="$(stat -c %a "$DST/.credentials.json" "$DST/settings.json" "$DST/.claude.json" "$DST" | tr '\n' ' ')"
[[ "$m" == "600 600 600 700 " ]] && pass "3. modes 600 / folder 700" || fail "3. modes: $m"
b="$(ls "$DST"/.credentials.json.bak-login2-* 2>/dev/null | wc -l)"
[[ "$b" == 1 ]] && grep -q 1861920000000 "$DST"/.credentials.json.bak-login2-* && pass "3. the old credential kept as .bak-login2-<UTC>" || fail "3. bak count $b"
[[ "$out" != *"$SECRET"* ]] && pass "3. no credential content in the output" || fail "3. content leaked"

mkcred "$SRC" 1861920000000
out="$(run LOGIN2_SYNC_SRC="$SRC" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"up to date"* ]] && grep -q 1893456000000 "$DST/.credentials.json" && pass "4. older source: nothing copied" || fail "4. rc=$rc out=$out"
mkcred "$SRC" 1893456000000
out="$(run LOGIN2_SYNC_SRC="$SRC" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"
[[ "$out" == *"up to date"* ]] && pass "4. same expiry: nothing copied" || fail "4b. out=$out"

mkcred "$SRC" 1924992000000
out="$(run LOGIN2_SYNC_SRC="$SRC" CLAUDE2_CONFIG_DIR="$DST")"; rc=$?
[[ $rc == 0 && "$out" == *"PLAN copy"* ]] && grep -q 1893456000000 "$DST/.credentials.json" && pass "5. DRY_RUN=1 plans, changes nothing" || fail "5. rc=$rc out=$out"

echo "SPOOL_LOGIN2_SRC=$SRC" > "$T/spool/box.env"
out="$(run SPOOL_BOX_ENV="$T/spool/box.env" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"copied, expires 2031-01-01T00:00:00Z"* ]] && pass "6. source from box.env SPOOL_LOGIN2_SRC" || fail "6. rc=$rc out=$out"

mkcred "$T/home/.claude" 1956528000000
out="$(run LOGIN2_SYNC_SRC="$T/home/.claude" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 2 && "$out" == *REFUSED* ]] && grep -q 1924992000000 "$DST/.credentials.json" && pass "7. a main login as the source: REFUSED" || fail "7. rc=$rc out=$out"
out="$(run LOGIN2_SYNC_SRC="$DST" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 2 && "$out" == *REFUSED* ]] && pass "7. the destination as the source: REFUSED" || fail "7b. rc=$rc out=$out"

grep -qE '^login2-sync +\| .*\| src/bash/scripts/login2-sync-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" && [[ -f "$PROJ_ROOT/src/bash/scripts/login2-sync-cron.sh" ]] &&
  pass "8. the cron row and its script" || fail "8. no login2-sync row or script"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
