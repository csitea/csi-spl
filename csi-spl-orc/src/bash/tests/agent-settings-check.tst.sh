#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_settings_check, the desk reconcile cron's read-only
#          check of the agent user's and the box user's ~/.claude/settings.json
#          (2026-10-07: an allow rule "mcp__*" parked every new session on
#          a Settings Warning dialog). Throwaway files and spool root, a
#          spool-send stub; the action runs under ./run's set -E + ERR trap.
#          Each case has its control: one input flipped.
#   1. a good file: SETTINGS OK, exit 0, nobody told.
#      Control: the same file with "mcp__*" added is BAD (case 2)
#   2. a bare "mcp__*" allow rule: BAD naming it, exit 1, ONE note with the
#      file's mtime; the next run tells nobody. Control: "mcp__slack__*" and
#      "Bash(git log:*)" (a glob after a literal server / in the arguments)
#      are accepted
#   3. the bad file edited again (a new mtime): one more note
#   4. fixed: ONE "SETTINGS FIXED" note, then silence
#   5. defaultMode auto, invalid JSON, a missing file: each BAD.
#      Control: defaultMode bypassPermissions is OK (case 1)
#   6. both users: the box user's file bad, the agent user's good -> only the
#      box user is flagged and told
#   7. neither file is ever written (content and mtime unchanged)
#   8. the default users are the agent user and the box user, once each
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
export SPOOL_TEST=1
unset TMUX TMUX_PANE SPOOL_AGENT_ID SPOOL_TMUX_SOCKET SETTINGS_CHECK_USERS SETTINGS_CHECK_FILES SETTINGS_CHECK_TO
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S="$T/spool"; mkdir -p "$S/dispatch" "$T/bin" "$T/a" "$T/b"
case "$S" in /var/spool-hub*) echo "FAIL: refusing a live spool root"; exit 1 ;; esac
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
printf 'LEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
echo "send $*" >>"${SENT:-$T/sent}"
EOF
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_require_bin() { command -v "$1" >/dev/null; }
source "$PROJ_PATH/src/bash/run/spl-agent-settings-check.func.sh"
do_spl_agent_settings_check || exit $?
EOF
chmod +x "$T/bin/"*
export T PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SETTINGS_CHECK_SEND="$T/bin/send"
A="$T/a/settings.json"; B="$T/b/settings.json"
good='{"permissions":{"defaultMode":"bypassPermissions","allow":["mcp__slack__*","Bash(git log:*)","Read"]},"skipDangerousModePermissionPrompt":true}'
withstar='{"permissions":{"defaultMode":"bypassPermissions","allow":["mcp__slack__*","mcp__*"]}}'
go() { env "$@" "$T/bin/act" >"$T/o" 2>&1; echo $?; }
sent() { cat "$T/sent" 2>/dev/null | grep -c . || true; }
iso() { date -u -d "@$(stat -c %Y "$1")" +%FT%TZ; }

# --- 1. a good file ---------------------------------------------------------------------
echo "$good" >"$A"
rc="$(go SETTINGS_CHECK_FILES="agent=$A")"
[[ "$rc" == 0 && "$(sent)" == 0 ]] && grep -q "SETTINGS OK agent $A mtime $(iso "$A")\$" "$T/o" &&
  pass "1. a good file (globs after mcp__slack__ and in Bash args): OK, exit 0, nobody told" || fail "1. rc=$rc $(cat "$T/o")"

# --- 2. a bare mcp__* --------------------------------------------------------------------
echo "$withstar" >"$A"; touch -d '2026-10-07 16:29:00 UTC' "$A"
rc="$(go SETTINGS_CHECK_FILES="agent=$A")"
[[ "$rc" == 1 ]] && grep -q "SETTINGS BAD agent $A mtime 2026-10-07T16:29:00Z: allow rule \"mcp__\*\": a wildcard tool name outside mcp__<server>__" "$T/o" &&
  ! grep -q 'mcp__slack__' "$T/o" && pass "2. a bare \"mcp__*\": BAD naming it with the mtime, exit 1; mcp__slack__* not flagged" || fail "2. rc=$rc $(cat "$T/o")"
[[ "$(sent)" == 1 ]] && grep -q -- "--from c-001 --to c-001 --kind note --task agent-settings-check --no-ask --body SETTINGS BAD on .*agent $A mtime 2026-10-07T16:29:00Z: allow rule \"mcp__\*\"" "$T/sent" &&
  pass "2. ONE note to the orchestrator (LEASE_ORCH) with the file's mtime" || fail "2. sent: $(cat "$T/sent" 2>&1)"
go SETTINGS_CHECK_FILES="agent=$A" >/dev/null
[[ "$(sent)" == 1 ]] && pass "2. the next run, nothing changed: nobody told again" || fail "2. resent: $(cat "$T/sent")"
for r in '"*"' '"Bash*"' '"mcp__sl*__x"' '"*(foo)"'; do
  echo "{\"permissions\":{\"defaultMode\":\"bypassPermissions\",\"allow\":[$r]}}" >"$T/one.json"
  go SETTINGS_CHECK_FILES="x=$T/one.json" SETTINGS_CHECK_STATE_DIR="$T/st1" SENT="$T/sent.x" >/dev/null
  grep -qF "SETTINGS BAD x $T/one.json" "$T/o" && grep -qF "allow rule $r: a wildcard" "$T/o" || fail "2. $r not flagged: $(cat "$T/o")"
done
pass "2. also flagged: \"*\", \"Bash*\", \"mcp__sl*__x\", \"*(foo)\""

# --- 3. edited again while bad -------------------------------------------------------------
touch -d '2026-10-07 16:35:00 UTC' "$A"
go SETTINGS_CHECK_FILES="agent=$A" >/dev/null
[[ "$(sent)" == 2 ]] && grep -q 'mtime 2026-10-07T16:35:00Z' "$T/sent" && pass "3. a new mtime on the bad file: one more note" || fail "3. sent: $(cat "$T/sent")"

# --- 4. fixed ----------------------------------------------------------------------------
echo "$good" >"$A"
rc="$(go SETTINGS_CHECK_FILES="agent=$A")"
[[ "$rc" == 0 && "$(sent)" == 3 ]] && grep -q -- "--body SETTINGS FIXED: agent's $A mtime .* (was: $A mtime 2026-10-07T16:35:00Z" <<<"$(tail -1 "$T/sent")" &&
  pass "4. fixed: ONE SETTINGS FIXED note" || fail "4. rc=$rc $(cat "$T/sent")"
go SETTINGS_CHECK_FILES="agent=$A" >/dev/null
[[ "$(sent)" == 3 ]] && pass "4. ... then silence" || fail "4. resent: $(tail -1 "$T/sent")"

# --- 5. other bad shapes -------------------------------------------------------------------
echo '{"permissions":{"defaultMode":"auto"}}' >"$T/c.json"
go SETTINGS_CHECK_FILES="c=$T/c.json" SETTINGS_CHECK_STATE_DIR="$T/st5" >/dev/null
grep -q 'SETTINGS BAD c .*permissions.defaultMode is "auto", not bypassPermissions' "$T/o" && pass "5. defaultMode auto: BAD" || fail "5. auto: $(cat "$T/o")"
echo '{"permissions":' >"$T/c.json"
go SETTINGS_CHECK_FILES="c=$T/c.json" SETTINGS_CHECK_STATE_DIR="$T/st5" >/dev/null
grep -q 'SETTINGS BAD c .*not valid JSON' "$T/o" && pass "5. invalid JSON: BAD" || fail "5. json: $(cat "$T/o")"
rc="$(go SETTINGS_CHECK_FILES="c=$T/none.json" SETTINGS_CHECK_STATE_DIR="$T/st5")"
[[ "$rc" == 1 ]] && grep -q "SETTINGS BAD c $T/none.json mtime -: missing or unreadable" "$T/o" && pass "5. a missing file: BAD" || fail "5. missing rc=$rc $(cat "$T/o")"
grep -q ERRTRAP "$T/o" && fail "5. ERRTRAP: $(cat "$T/o")"

# --- 6. both users ---------------------------------------------------------------------------
echo "$good" >"$A"; echo "$withstar" >"$B"; : >"$T/sent"
rc="$(go SETTINGS_CHECK_FILES="ai=$A box=$B" SETTINGS_CHECK_STATE_DIR="$T/st6")"
[[ "$rc" == 1 ]] && grep -q "SETTINGS OK ai $A" "$T/o" && grep -q "SETTINGS BAD box $B" "$T/o" &&
  [[ "$(sent)" == 1 ]] && grep -q "body SETTINGS BAD on .*box $B" "$T/sent" &&
  pass "6. the box user's file bad, the agent user's good: only the box user flagged and told" || fail "6. rc=$rc $(cat "$T/o") $(cat "$T/sent")"

# --- 7. never written ------------------------------------------------------------------------
before="$(md5sum "$A" "$B"; stat -c '%Y %a' "$A" "$B")"
go SETTINGS_CHECK_FILES="ai=$A box=$B" SETTINGS_CHECK_STATE_DIR="$T/st7" >/dev/null
[[ "$(md5sum "$A" "$B"; stat -c '%Y %a' "$A" "$B")" == "$before" ]] && pass "7. neither file written (content, mtime, mode)" || fail "7. a file changed"

# --- 8. the default users ------------------------------------------------------------------
me="$(id -un)"; home="$(getent passwd "$me" | cut -d: -f6)"
go SETTINGS_CHECK_STATE_DIR="$T/st8" SETTINGS_CHECK_TO=c-9 >/dev/null
[[ "$(grep -c ' SETTINGS ' "$T/o")" == 1 ]] && grep -qE " SETTINGS (OK|BAD) $me $home/.claude/settings.json " "$T/o" &&
  pass "8. default: the agent user and the box user (the same here), checked once" || fail "8. $(cat "$T/o")"
go SETTINGS_CHECK_USERS="$me nosuchuser-$$" SETTINGS_CHECK_STATE_DIR="$T/st8" >/dev/null; rc=$?
grep -q "FATAL no passwd entry for 'nosuchuser-$$'" "$T/o" && pass "8. control: an unknown user is a usage error" || fail "8. control: $(cat "$T/o")"

echo "agent-settings-check: $( ((fails)) && echo "$fails failure(s)" || echo "all passed")"
exit $(( fails > 0 ))
