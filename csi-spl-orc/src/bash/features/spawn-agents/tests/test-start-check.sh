#!/usr/bin/env bash
# lib/start-check.inc.sh: the dialogs a fresh claude session can be parked on,
# read off the screens measured on claude 2.1.292 in a throwaway HOME
# (2026-10-07), and spool_start_check against a PRIVATE tmux server. Each
# dialog case has its control: the plain input box is not a dialog.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
. "$T_FEAT/lib/start-check.inc.sh"
t_sandbox

R='────────────────────────────────────────'
settings="$R
  Settings Warning

  <HOME>/.claude/settings.json
  └ permissions.allow: Invalid permission rule \"mcp__*\" was skipped: Wildcard tool name \"mcp__*\" is not supported in allow rules.

  The values listed above were skipped; the rest of the file is in effect.

  ❯ 1. Continue
    2. Fix with Claude
    3. Exit and fix manually

  Enter to confirm · Esc to cancel"
trust="$R
 Accessing workspace:

 <WORKDIR>

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team).

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel"
automode="$R
 Make auto mode your default permission mode?

   ❯ Yes, set auto mode as my default permission mode
     No, keep bypass permissions"
nologin="$R
❯ $(printf '\302\240')
$R
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents          Not logged in · Run /login"
limit="$R
❯
$R
  Claude usage limit reached · resets 7:20am"
plain="$R
❯ $(printf '\302\240\033[2m')Try \"refactor this\"$(printf '\033[0m')
$R
  ⏵⏵ bypass permissions on (shift+tab to cycle)"

eq "Settings Warning named" "Settings Warning" "$(spool_start_dialog <<<"$settings")"
eq "trust prompt named" "trust prompt" "$(spool_start_dialog <<<"$trust")"
eq "auto-mode offer named" "auto-mode offer" "$(spool_start_dialog <<<"$automode")"
eq "not logged in (box drawn, login footer) named auth/login" "auth/login" "$(spool_start_dialog <<<"$nologin")"
eq "usage limit named" "usage limit" "$(spool_start_dialog <<<"$limit")"
eq "control: the plain input box is no dialog" "" "$(spool_start_dialog <<<"$plain")"
check "control: the plain input box is a box (ghost text cut)" spool_screen_input_box <<<"$plain"
eq "...and it reads empty" "" "$(spool_screen_input_box <<<"$plain")"
if spool_screen_input_box <<<"$settings" >/dev/null; then nok "the Settings Warning draws no input box (one rule)"
else ok "the Settings Warning draws no input box (one rule)"; fi
has "the Settings Warning hint names both users' settings.json" "box user's ~/.claude/settings.json" "$(spool_start_hint 'Settings Warning')"
eq "no hint for a usage limit" "" "$(spool_start_hint 'usage limit')"

# spool_start_check with a capture command
cap_file() { cat "$T_TMP/screen.$1" 2>/dev/null; }
gone_file() { [ -e "$T_TMP/gone.$1" ]; }
printf '%s\n' "$settings" > "$T_TMP/screen.a"
out="$(START_CHECK_POLL=0.2 spool_start_check a 5 cap_file)"; rc=$?
eq "a dialog: exit 3" 3 "$rc"; eq "...naming it" "Settings Warning" "$out"
printf '%s\n' "$plain" > "$T_TMP/screen.b"
out="$(START_CHECK_POLL=0.2 spool_start_check b 5 cap_file)"; rc=$?
eq "control: the input box: exit 0" 0 "$rc"; eq "...printing nothing" "" "$out"
printf 'Welcome to Claude Code\n' > "$T_TMP/screen.c"
s=$SECONDS; out="$(START_CHECK_POLL=0.2 spool_start_check c 1 cap_file)"; rc=$?
eq "neither within the wait: exit 4" 4 "$rc"; eq "...saying so" "no input box within 1s" "$out"
check "...after about the wait" test $((SECONDS - s)) -le 3
touch "$T_TMP/gone.c"
out="$(START_CHECK_POLL=0.2 spool_start_check c 30 cap_file gone_file)"; rc=$?
eq "the pane ended: exit 5 at once" 5 "$rc"

# against a real (private) tmux: the dialog painted after a start delay
t_tmux
printf '%s\n' "$settings" > "$T_TMP/settings.txt"
P="$(t_window c-990 "sleep 1; cat '$T_TMP/settings.txt'; sleep 60")"
cap_tmux() { tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -e -t "$1" 2>/dev/null; }
s=$SECONDS; out="$(START_CHECK_POLL=0.3 spool_start_check "$P" 20 cap_tmux)"; rc=$?
eq "tmux: the dialog painted after 1 s: exit 3" 3 "$rc"; eq "...Settings Warning" "Settings Warning" "$out"
check "...within seconds, not the wait" test $((SECONDS - s)) -le 6
printf '%s\n' "$plain" > "$T_TMP/plain.txt"
P="$(t_window c-991 "sleep 1; cat '$T_TMP/plain.txt'; sleep 60")"
out="$(START_CHECK_POLL=0.3 spool_start_check "$P" 20 cap_tmux)"; rc=$?
eq "tmux control: the input box painted: exit 0" 0 "$rc"

t_done
