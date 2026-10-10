#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y14 - the agy lane's exit rule (owner
# 2026-10-10, t1 3b755aef): an agy lane runs /exit-clean only after ACCEPTED.
#   1. a HOME with ~/.gemini gets ~/.gemini/config/rules/30-exit-after-accepted.md:
#      the source text plus its sha256 marker, carrying the ACCEPTED-only rule
#      and the exit-clean closing step (--defer --retire)
#   2. a re-run says current and changes nothing
#   3. a hand-edited file is kept; FORCE_SKILLS=1 replaces it
#   4. an untouched file from an older source is rewritten
#   5. a same-named file without the marker is kept (not ours)
#   6. no ~/.gemini, SPOOL_INSTALL_VENDOR_RULES=0 and DRY=1 write nothing
#   7. install.sh runs the step exactly once, right after y9
# Control: on origin/master before this step, 1 and 7 FAIL (no file, no step).
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2015  # the bash -c body expands in the child; pass || fail
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y14-agy-exit-rule.sh"
SRC="$FEAT/assets/agy/rules/30-exit-after-accepted.md"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fresh() { mkdir -p "$T/$1" && echo "$T/$1"; }
y14() { local h="$1"; shift; env HOME="$h" "$@" bash -c '[ -f "$0" ] && source "$0" && spool_install_agy_exit_rule' "$STEP"; }
sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ── 1. fresh install ──────────────────────────────────────────────────────────
H=$(fresh h1); mkdir -p "$H/.gemini"
y14 "$H" 2>"$T/err1"; rc=$?
dst="$H/.gemini/config/rules/30-exit-after-accepted.md"
want=$(sum "$SRC")
if [ "$rc" = 0 ] && [ -f "$dst" ] && [ "$(tail -1 "$dst")" = "<!-- spool-install: sha256=$want -->" ] &&
   [ "$(head -n -1 "$dst" | sha256sum | cut -d' ' -f1)" = "$want" ]; then
  pass "1: rendered $dst with its sha256 marker"
else
  fail "1: no rendered agy exit rule (rc=$rc: $(cat "$T/err1"))"
fi
grep -q 'body starts with `ACCEPTED`' "$dst" 2>/dev/null && grep -q 'NOT the end of the lane' "$dst" &&
  grep -q 'Never ACCEPTED: your own "done"' "$dst" &&
  pass "1: the file says exit only after ACCEPTED, never on your own done" ||
  fail "1: the ACCEPTED-only rule is missing"
grep -q 'tmux-close-window.sh --agent <YOUR-ID> --defer --retire' "$dst" 2>/dev/null &&
  pass "1: the file carries the exit-clean closing step" || fail "1: the closing step is missing"

# ── 2. re-run is a no-op ──────────────────────────────────────────────────────
before=$(sum "$dst"); y14 "$H" 2>"$T/err2"
[ "$(sum "$dst")" = "$before" ] && grep -q 'current:' "$T/err2" && pass "2: re-run says current, file unchanged" ||
  fail "2: re-run changed the file or did not say current ($(cat "$T/err2"))"

# ── 3. hand edit kept, FORCE_SKILLS replaces ─────────────────────────────────
H=$(fresh h3); mkdir -p "$H/.gemini"; y14 "$H" 2>/dev/null
d3="$H/.gemini/config/rules/30-exit-after-accepted.md"
sed -i '1a my own line' "$d3"; edited=$(sum "$d3"); y14 "$H" 2>"$T/err3"
[ "$(sum "$d3")" = "$edited" ] && grep -q 'kept' "$T/err3" && pass "3: a hand-edited file is kept and named" ||
  fail "3: a hand-edited file was overwritten"
y14 "$H" FORCE_SKILLS=1 2>/dev/null
! grep -q '^my own line$' "$d3" && [ "$(tail -1 "$d3")" = "<!-- spool-install: sha256=$want -->" ] &&
  pass "3: FORCE_SKILLS=1 replaces it" || fail "3: FORCE_SKILLS=1 did not replace it"

# ── 4. an untouched older render is upgraded ─────────────────────────────────
H=$(fresh h4); mkdir -p "$H/.gemini/config/rules"; d4="$H/.gemini/config/rules/30-exit-after-accepted.md"
old="old rule text"; printf '%s\n<!-- spool-install: sha256=%s -->\n' "$old" "$(printf '%s\n' "$old" | sha256sum | cut -d' ' -f1)" >"$d4"
y14 "$H" 2>/dev/null
[ "$(tail -1 "$d4")" = "<!-- spool-install: sha256=$want -->" ] && pass "4: an untouched older render is rewritten" ||
  fail "4: an untouched older render was not upgraded"

# ── 5. a same-named file that is not ours ────────────────────────────────────
H=$(fresh h5); mkdir -p "$H/.gemini/config/rules"; d5="$H/.gemini/config/rules/30-exit-after-accepted.md"
echo "someone else's" >"$d5"; y14 "$H" 2>/dev/null
[ "$(cat "$d5")" = "someone else's" ] && pass "5: a file without the marker is never touched" || fail "5: overwrote a file that is not ours"

# ── 6. skips ─────────────────────────────────────────────────────────────────
H=$(fresh h6a); y14 "$H" 2>/dev/null
[ -z "$(find "$H" -mindepth 1)" ] && pass "6: no ~/.gemini: nothing written" || fail "6: wrote into a HOME without agy"
H=$(fresh h6b); mkdir -p "$H/.gemini"; y14 "$H" SPOOL_INSTALL_VENDOR_RULES=0 2>/dev/null
y14 "$H" DRY=1 >"$T/out6" 2>/dev/null
[ -z "$(find "$H/.gemini" -mindepth 1)" ] && grep -q '^PLAN render ' "$T/out6" &&
  pass "6: SPOOL_INSTALL_VENDOR_RULES=0 and DRY=1 write nothing (DRY prints the plan)" || fail "6: a skip or a dry run wrote"

# ── 7. install.sh wiring ─────────────────────────────────────────────────────
inst="$FEAT/install.sh"
c=$(grep -c 'steps/y14-agy-exit-rule.sh" && spool_install_agy_exit_rule' "$inst")
l9=$(grep -n 'steps/y9-vendor-lane-rule.sh" && spool_install_vendor_lane_rule' "$inst" | cut -d: -f1)
l14=$(grep -n 'steps/y14-agy-exit-rule.sh" && spool_install_agy_exit_rule' "$inst" | cut -d: -f1)
[ "$c" = 1 ] && [ -n "$l9" ] && [ "${l14:-0}" = $((l9 + 1)) ] && pass "7: install.sh runs y14 once, right after y9" ||
  fail "7: install.sh does not run y14 once after y9 (count=$c, y9=$l9, y14=${l14:-none})"

echo "== y14 agy exit rule: $((n - fails))/$n passed"
[ "$fails" = 0 ]
