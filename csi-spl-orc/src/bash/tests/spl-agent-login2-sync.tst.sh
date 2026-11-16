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
#   7. the box user's own main config folder as the source (owner choice B,
#      t1 678d29e2 msg d168e017) -> copied, and the source folder's files and
#      mtimes are unchanged (read only)
#   7b. the agent user's main ~/.claude, the destination itself -> REFUSED,
#      exit 2; a missing source folder -> WARN, nothing copied
#   8. the cron row is in box-crons.manifest and its script exists
#   L1-L4 (SPL-5695): the peer source, both directions by account label;
#      newest wins within one label; another label never reaches a main
#      login; no credential content or account id in any output
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

mkcred "$T/home/.claude" 1956528000000; echo '{"s":2}' > "$T/home/.claude/settings.json"; echo '{"c":2}' > "$T/home/.claude/.claude.json"
touch -d '2026-01-02 03:04:05' "$T/home/.claude"/.credentials.json "$T/home/.claude"/settings.json "$T/home/.claude"/.claude.json
snap() { (cd "$1" && find . -printf '%p %s %T@ %m\n' | sort && cat .credentials.json settings.json .claude.json | md5sum); }
before="$(snap "$T/home/.claude")"
out="$(run LOGIN2_SYNC_SRC="$T/home/.claude" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"copied, expires 2032-01-01T00:00:00Z"* ]] && grep -q 1956528000000 "$DST/.credentials.json" && cmp -s "$T/home/.claude/settings.json" "$DST/settings.json" &&
  pass "7. the box user's own main config folder as the source: copied" || fail "7. rc=$rc out=$out"
[[ "$(snap "$T/home/.claude")" == "$before" ]] && pass "7. the source folder's files and mtimes unchanged (read only)" || fail "7. the source folder changed"
[[ "$out" != *"$SECRET"* ]] && pass "7. no credential content in the output" || fail "7. content leaked"

mkcred "$T/agent/.claude" 1988150400000
out="$(run LOGIN2_AGENT_HOME="$T/agent" LOGIN2_SYNC_SRC="$T/agent/.claude" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 2 && "$out" == *REFUSED* ]] && grep -q 1956528000000 "$DST/.credentials.json" && pass "7b. the agent user's main login as the source: REFUSED" || fail "7b. rc=$rc out=$out"
out="$(run LOGIN2_SYNC_SRC="$DST" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 2 && "$out" == *REFUSED* ]] && pass "7b. the destination as the source: REFUSED" || fail "7b. rc=$rc out=$out"
out="$(run LOGIN2_SYNC_SRC="$T/no-such-folder" CLAUDE2_CONFIG_DIR="$DST" DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *WARN* ]] && grep -q 1956528000000 "$DST/.credentials.json" && pass "7b. a missing source folder: WARN, nothing copied" || fail "7b. rc=$rc out=$out"

grep -qE '^login2-sync +\| .*\| src/bash/scripts/login2-sync-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" && [[ -f "$PROJ_ROOT/src/bash/scripts/login2-sync-cron.sh" ]] &&
  pass "8. the cron row and its script" || fail "8. no login2-sync row or script"

# ---- peer source, SPL-5695 (spec 060 add-on claude-account-failover.md, L1-L4)
CRED="$PROJ_ROOT/src/bash/scripts/agent-login-cred.sh"
HH="$T/l/here"; PH="$T/l/peer"; H2="$HH/.claude-2"; P2="$PH/.claude-2"
mkacct() { printf '{"oauthAccount":{"accountUuid":"%s"},"hasCompletedOnboarding":true,"projects":{"p":1}}\n' "$2" > "$1"; }
lab() { printf 'acct-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }
lab_of() { lab "$(jq -r '.oauthAccount.accountUuid' "$1")"; }
mkcred "$HH/.claude" 1893456000000; mkacct "$HH/.claude.json" uuid-here
mkcred "$PH/.claude" 1861920000000; mkacct "$PH/.claude.json" uuid-peer
PCMD="f() { LOGIN_AGENT_USER=$(id -un) LOGIN_AGENT_HOME=$PH bash $CRED \"\$2\" \"\$3\"; }; f"
prun() { run LOGIN2_AGENT_HOME="$HH" CLAUDE2_CONFIG_DIR="$H2" LOGIN2_PEER_DEST=peer-dest LOGIN2_PEER_CMD="$PCMD" LOGIN_PEERS= "$@"; }
ALL=""
out="$(prun LOGIN2_SYNC_SRC=peer:sat DRY_RUN=0)"; rc=$?; ALL+="$out"
cmp -s "$PH/.claude/.credentials.json" "$H2/.credentials.json" && cmp -s "$HH/.claude/.credentials.json" "$P2/.credentials.json" &&
  [[ $rc == 0 && "$out" == *"[sat -> here]: replaced the stale account none with $(lab uuid-peer)"* && "$out" == *"[here -> sat]: replaced the stale account none with $(lab uuid-here)"* ]] &&
  pass "L1. peer:sat: sat's main -> the second folder here, here's main -> sat's second folder" || fail "L1. rc=$rc out=$out"
[[ "$(lab_of "$H2/.claude.json")" == "$(lab uuid-peer)" && "$(jq -c 'keys' "$H2/.claude.json")" == '["hasCompletedOnboarding","oauthAccount"]' && "$(lab_of "$P2/.claude.json")" == "$(lab uuid-here)" ]] &&
  pass "L1. each second folder's .claude.json: the lender's account, only its two fields" || fail "L1. json: $(cat "$H2/.claude.json")"
m="$(stat -c %a "$H2" "$H2/.credentials.json" "$H2/.claude.json" | tr '\n' ' ')"
[[ "$m" == "700 600 600 " ]] && pass "L1. second folder 700, files 600" || fail "L1. modes $m"
out="$(prun LOGIN2_SYNC_SRC=peer:sat DRY_RUN=0)"; ALL+="$out"
[[ "$(grep -c 'up to date' <<<"$out")" == 2 ]] && pass "L1. a second run: both directions up to date" || fail "L1. second run: $out"
printf 'SPOOL_LOGIN2_SRC=%s\nSPOOL_LOGIN2_PEER=sat=peer-dest\n' "$SRC" > "$T/spool/box.env"
out="$(prun SPOOL_BOX_ENV="$T/spool/box.env" LOGIN2_PEER_DEST= DRY_RUN=0)"; rc=$?; ALL+="$out"
[[ $rc == 0 && "$(grep -c 'up to date' <<<"$out")" == 2 ]] && pass "L1. box.env SPOOL_LOGIN2_PEER wins over SPOOL_LOGIN2_SRC" || fail "L1. box.env: rc=$rc $out"
out="$(prun LOGIN2_SYNC_SRC=peer:sat LOGIN_PEERS=sat=peer-dest DRY_RUN=0)"; rc=$?; ALL+="$out"
[[ $rc == 2 && "$out" == *"REFUSED peer sat is also in SPOOL_LOGIN_PEERS"* ]] && pass "L1. REFUSED while the main-to-main peer is still set (step 0)" || fail "L1. refuse: rc=$rc $out"

here_main="$(sha256sum < "$HH/.claude/.credentials.json")"
mkcred "$H2" 1924992000000
out="$(prun LOGIN2_SYNC_SRC=peer:sat LOGIN_PROBE_CMD='echo login expired' DRY_RUN=0)"; ALL+="$out"
[[ "$out" == *"[sat -> here]: WARN the second folder's newer $(lab uuid-peer)"*"does not work there (expired)"* ]] && grep -q 1861920000000 "$PH/.claude/.credentials.json" &&
  pass "L2. a newer borrower copy that does not probe ok: not copied back" || fail "L2. expired: $out"
out="$(prun LOGIN2_SYNC_SRC=peer:sat LOGIN_PROBE_CMD='echo ok' DRY_RUN=1)"; ALL+="$out"
[[ "$out" == *"PLAN copied back"* ]] && grep -q 1861920000000 "$PH/.claude/.credentials.json" && pass "L2. DRY_RUN=1 plans the copy back, changes nothing" || fail "L2. dry: $out"
out="$(prun LOGIN2_SYNC_SRC=peer:sat LOGIN_PROBE_CMD='echo ok' DRY_RUN=0)"; ALL+="$out"
cmp -s "$H2/.credentials.json" "$PH/.claude/.credentials.json" && [[ "$out" == *"[sat -> here]: copied back the newer $(lab uuid-peer)"* ]] && ls "$PH/.claude"/.credentials.json.bak-login-* >/dev/null 2>&1 &&
  pass "L2. newest wins within one label: the newer copy goes back into the lender's main login" || fail "L2. ok: $out"

mkcred "$PH/.claude" 1800000000000; mkacct "$PH/.claude.json" uuid-swapped
out="$(prun LOGIN2_SYNC_SRC=peer:sat LOGIN_PROBE_CMD='echo ok' DRY_RUN=0)"; ALL+="$out"
grep -q 1800000000000 "$H2/.credentials.json" && [[ "$(lab_of "$H2/.claude.json")" == "$(lab uuid-swapped)" && "$out" == *"replaced the stale account $(lab uuid-peer) with $(lab uuid-swapped)"* ]] &&
  pass "L3. the owner swapped sat's account: the stale second folder here is replaced, though older" || fail "L3. swap: $out"
[[ "$(lab_of "$PH/.claude.json")" == "$(lab uuid-swapped)" ]] && grep -q 1800000000000 "$PH/.claude/.credentials.json" &&
  [[ "$(sha256sum < "$HH/.claude/.credentials.json")" == "$here_main" && "$(lab_of "$HH/.claude.json")" == "$(lab uuid-here)" ]] &&
  pass "L3. no other label ever reaches a main login (sat keeps the swap, here keeps its own)" || fail "L3. a main login changed"

[[ "$ALL" != *"$SECRET"* && "$ALL" != *uuid-* ]] && pass "L4. no credential content and no account id in any output" || fail "L4. content leaked"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
