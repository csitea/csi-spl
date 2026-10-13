#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_install_agy_cli (SPL-1652), hermetic: a temp agent home, a temp
#          cnf, the vendor installer served from a file:// URL, an agy stub.
#   1. DRY_RUN is the default: the plan names the installer, nothing runs
#   2. a fresh install (DRY_RUN=0): the vendor installer runs once, agy is at
#      the cnf pin, the action reads back `agy --version`
#   3. a re-run at the pin: no installer, no update, "not reinstalled"
#   4. an agy below the pin: its own `update`, then at the pin
#   5. an agy above the pin (it updates itself): kept, named, bump the cnf
#   6. CONTROLS: a vendor that serves a version below the pin is refused
#      (exit 4); a cnf pin of latest is refused (exit 2) before anything runs;
#      a cnf with no agy_cli reads the 1.3.4 default
#   7. the sign-in is never read: a planted token is in no output and no log,
#      and unchanged; nothing outside the agent home is written
#   8. CONTROL: without the pin (plain install.sh --cli agy, the old path)
#      an agy below 1.3.4 is not refused: only the action's pin refuses it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
command -v curl >/dev/null || { echo "SKIP: no curl (file:// installer)"; exit 0; }

ME="$(id -un)"
TOKEN="canaryAgyT0ken${RANDOM}${RANDOM}Z"
mkdir -p "$T/www" "$T/spool"
: >"$T/calls.log"
# the agy a stub install lays down: --version prints <agy>.ver, and `update`
# moves it to the vendor's latest (FAKE_AGY_LATEST)
cat >"$T/agy.stub" <<'TPL'
#!/usr/bin/env bash
echo "agy $*" >>"$STUB_LOG"
case "$1" in
  --version) cat "$0.ver" ;;
  update) echo "${FAKE_AGY_LATEST:-1.3.4}" >"$0.ver" ;;
esac
TPL
chmod +x "$T/agy.stub"
# the vendor installer: the latest into ~/.local/bin, as the real one does
cat >"$T/www/install.sh" <<TPL
#!/bin/bash
echo "agy-installer ran" >>"\$STUB_LOG"
mkdir -p "\$HOME/.local/bin"; cp "$T/agy.stub" "\$HOME/.local/bin/agy"
echo "\${FAKE_AGY_LATEST:-1.3.4}" >"\$HOME/.local/bin/agy.ver"
TPL
cnf() { if [[ -n "$1" ]]; then printf 'env:\n  box:\n    agy_cli:\n      version: %s\n' "$1"; else printf 'env:\n  box: {}\n'; fi >"$T/cnf.yaml"; }
cnf 1.3.4

H="$T/agent-home"; mkdir -p "$H/.gemini/antigravity-cli"
printf '%s\n' "$TOKEN" >"$H/.gemini/antigravity-cli/antigravity-oauth-token"; chmod 600 "$H/.gemini/antigravity-cli/antigravity-oauth-token"
tok_sum="$(sha256sum <"$H/.gemini/antigravity-cli/antigravity-oauth-token")"
# ai [VAR=value]...: the action as the hermetic agent; output in $T/o. PATH
# holds no agy of this machine.
ai() {
  PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" in_orc SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
    AGY_CLI_AGENT_HOME="$H" AGY_CLI_CNF="$T/cnf.yaml" SNIPPET=do_install_agy_cli \
    SPOOL_INSTALL_URL_AGY="file://$T/www/install.sh" "$@" >"$T/o" 2>&1
}
n() { grep -c "$1" "$T/calls.log"; }
lay() { mkdir -p "$H/.local/bin"; cp "$T/agy.stub" "$H/.local/bin/agy"; echo "$1" >"$H/.local/bin/agy.ver"; }
touch -d '1 minute ago' "$T/marker"

# --- 1. DRY_RUN is the default -------------------------------------------------------------------
ai; rc=$?
[[ $rc -eq 0 && "$(n agy-installer)" == 0 && ! -e "$H/.local/bin/agy" ]] && grep -q 'would: install agy (pin 1.3.4 or newer)' "$T/o" &&
  pass "1: DRY_RUN defaults to 1: the plan names the installer, nothing runs" || fail "1: dry (rc=$rc): $(cat "$T/o")"

# --- 2. a fresh install --------------------------------------------------------------------------
ai DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(n agy-installer)" == 1 && -x "$H/.local/bin/agy" ]] && grep -q "OK agy 1.3.4 for $ME" "$T/o" &&
  pass "2: fresh: the vendor installer ran once, agy --version read back 1.3.4" || fail "2: fresh (rc=$rc): $(tail -n4 "$T/o")"

# --- 3. a re-run at the pin ------------------------------------------------------------------------
ai DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(n agy-installer)" == 1 && "$(n 'agy update')" == 0 ]] && grep -q 'at or above the pin 1.3.4: not reinstalled' "$T/o" &&
  pass "3: a re-run at the pin installs nothing, updates nothing" || fail "3: re-run (rc=$rc): $(tail -n3 "$T/o")"

# --- 4. below the pin: update --------------------------------------------------------------------------
lay 1.2.0
ai DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(n 'agy update')" == 1 && "$(n agy-installer)" == 1 ]] && grep -q 'is 1.2.0, below the pin 1.3.4' "$T/o" &&
  grep -q "OK agy 1.3.4" "$T/o" && pass "4: agy 1.2.0 below the pin: its own update, then 1.3.4" || fail "4: update (rc=$rc): $(tail -n4 "$T/o")"

# --- 5. above the pin -----------------------------------------------------------------------------------
lay 1.4.0
ai DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(n 'agy update')" == 1 ]] && grep -q 'WARN agy: 1.4.0 is past the cnf pin 1.3.4' "$T/o" && grep -q 'OK agy 1.4.0' "$T/o" &&
  pass "5: agy 1.4.0 (self-updated) is kept and named: bump the cnf" || fail "5: above (rc=$rc): $(tail -n3 "$T/o")"

# --- 6. controls ---------------------------------------------------------------------------------------
rm -f "$H/.local/bin/agy"
ai DRY_RUN=0 FAKE_AGY_LATEST=1.2.0; rc=$?
[[ $rc -eq 4 ]] && grep -q 'is 1.2.0, below the pin 1.3.4' "$T/o" &&
  pass "6: CONTROL: a vendor serving 1.2.0 under the pin 1.3.4 is refused (exit 4)" || fail "6: low vendor (rc=$rc): $(tail -n3 "$T/o")"
rm -f "$H/.local/bin/agy"; n0="$(n agy-installer)"
cnf latest; ai DRY_RUN=0; rc=$?
[[ $rc -eq 2 && "$(n agy-installer)" == "$n0" ]] && grep -q 'must be one X.Y.Z' "$T/o" &&
  pass "6: CONTROL: cnf pin latest refused (exit 2), nothing ran" || fail "6: latest (rc=$rc): $(tail -n2 "$T/o")"
cnf ""; ai; rc=$?
[[ $rc -eq 0 ]] && grep -q 'agy 1.3.4 or newer' "$T/o" && pass "6: a cnf with no agy_cli reads the 1.3.4 default" || fail "6: default (rc=$rc): $(tail -n2 "$T/o")"
cnf 1.3.4

# --- 7. the sign-in, and nothing outside the home ---------------------------------------------------------
ai DRY_RUN=0; cp "$T/o" "$T/o.last"
! grep -rq "$TOKEN" "$T/o.last" "$T/calls.log" && [[ "$(sha256sum <"$H/.gemini/antigravity-cli/antigravity-oauth-token")" == "$tok_sum" ]] &&
  pass "7: the planted sign-in token is in no output or log, and unchanged" || fail "7: the token leaked or changed"
{ cat "$T/o.last"; echo "$TOKEN"; } >"$T/o.planted"
grep -q "$TOKEN" "$T/o.planted" && pass "7: CONTROL: the leak check catches a planted echo" || fail "7: CONTROL missed the plant"
out="$(find "$T" -newer "$T/marker" -type f ! -path "$H/*" ! -path "$T/o*" ! -name calls.log ! -name cnf.yaml ! -path "$T/www/*" ! -name agy.stub)"
[[ -z "$out" ]] && pass "7: nothing outside the agent home was written" || fail "7: written outside the home: $out"

# --- 8. the old path has no floor ------------------------------------------------------------------------------
lay 1.2.0
PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" HOME="$H" STUB_LOG="$T/calls.log" FAKE_AGY_LATEST=1.2.0 \
  bash "$PROJ_ROOT/src/bash/features/spool-install/install.sh" --cli agy --cli-only >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'below the pin' "$T/o" &&
  pass "8: CONTROL: without the pin install.sh keeps agy 1.2.0 (only the action refuses it)" || fail "8: old path (rc=$rc): $(tail -n3 "$T/o")"

echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
