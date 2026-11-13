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
# grok 1.0.70, read off g-563's pane %1830 (2026-10-28, SPL-4065)
grok_trust="   g-563-peer-restart worktree /o/c/<repo>-wt/g-563
                     Do you trust the contents of this directory?
                                   <MAIN CHECKOUT>
               Grok Build may run or modify contents in this directory,
                                posing security risks.
                             Yes, proceed                 y
                             No, quit                     n
                                                                 Grok Build  1.0.70 [stable]"
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
# claude's usage-limit menu, as the rotation's SPAWN WAIT line read it
# (box 1 2026-10-24 16:08:46Z, SPL-4507); the banner above it is the weekly one
limit_menu=" You've hit your weekly limit · resets Oct 28, 6pm (Europe/Amsterdam)

 What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Wait here, then continue automatically at Oct 28, 6pm
   3. Switch to usage credits

 Enter to confirm · Esc to cancel"
# the menu's words quoted, not drawn: the rotate.log line of that run in a
# pane (SPL-4728, R7 c-750 N3); control for the numbered-option anchor
quoted="2026-10-24T16:08:46Z 20261024T1601Z-failover SPAWN WAIT %1263: no input box within 45s and no known dialog; screen: ❯ 1. Stop and wait for limit to reset|2. Wait here|3. Switch to usage credits
$ grep -n 'Switch to usage credits' start-check.inc.sh"
# claude 2.1.311's autocompact offer, c-001@sat 2026-11-13 ~08:57Z (SPL-5427,
# the watchdog's S9 snapshot c-001.s9.pane, n=1); the body lines trimmed
compact="$R
 We recommend compacting earlier

   Want to autocompact at 400k tokens instead? Your model doesn't change. Switch back any time with /autocompact.

   ❯ Keep auto (1m tokens)
     Autocompact at ‹ 400k › tokens

   ↑/↓ choose · ←/→ change size · enter confirm · esc not now"
# its title quoted in a reply line: transcript, not the dialog
compact_quoted="● The seat drew \"We recommend compacting earlier\" and S9 restarted it.
$R
❯ $(printf '\302\240')
$R"
plain="$R
❯ $(printf '\302\240\033[2m')Try \"refactor this\"$(printf '\033[0m')
$R
  ⏵⏵ bypass permissions on (shift+tab to cycle)"

eq "Settings Warning named" "Settings Warning" "$(spool_start_dialog <<<"$settings")"
eq "trust prompt named" "trust prompt" "$(spool_start_dialog <<<"$trust")"
eq "grok trust prompt named (SPL-4065)" "trust prompt" "$(spool_start_dialog <<<"$grok_trust")"
has "the trust prompt hint names grok's main checkout key" "main checkout" "$(spool_start_hint 'trust prompt')"
eq "auto-mode offer named" "auto-mode offer" "$(spool_start_dialog <<<"$automode")"
eq "not logged in (box drawn, login footer) named auth/login" "auth/login" "$(spool_start_dialog <<<"$nologin")"
eq "usage limit named" "usage limit" "$(spool_start_dialog <<<"$limit")"
eq "usage-limit menu named usage limit (SPL-4507)" "usage limit" "$(spool_start_dialog <<<"$limit_menu")"
eq "autocompact offer named (SPL-5427)" "autocompact offer" "$(spool_start_dialog <<<"$compact")"
eq "control: the autocompact offer's title quoted in a reply is no dialog" "" "$(spool_start_dialog <<<"$compact_quoted")"
has "the autocompact hint says Escape, never the 400k option" 'Escape ("not now") answers it and changes nothing' "$(spool_start_hint 'autocompact offer')"
eq "control: the plain input box is no dialog" "" "$(spool_start_dialog <<<"$plain")"
eq "control: the menu's words quoted in a log line are no dialog (SPL-4728)" "" "$(spool_start_dialog <<<"$quoted")"
check "control: the plain input box is a box (ghost text cut)" spool_screen_input_box <<<"$plain"
eq "...and it reads empty" "" "$(spool_screen_input_box <<<"$plain")"
if spool_screen_input_box <<<"$settings" >/dev/null; then nok "the Settings Warning draws no input box (one rule)"
else ok "the Settings Warning draws no input box (one rule)"; fi
has "the Settings Warning hint names both users' settings.json" "box user's ~/.claude/settings.json" "$(spool_start_hint 'Settings Warning')"
has "the usage-limit hint names the login's quota and another vendor (SPL-4728)" "login (claude's for a claude seat) has no quota until its limit resets (the screen names when): the successor must be another vendor" "$(spool_start_hint 'usage limit')"

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
