#!/usr/bin/env bash
# spool-notify.sh: a message already in an inbox is made VISIBLE in the
# recipient's pane — sender, kind, ids and the body itself, sanitised and
# bounded (specs/028-spool-terminal-delivery, contracts/poke-line.md).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
SN="$T_SCRIPTS/spool-notify.sh"

# ---- rendering (no tmux needed) -------------------------------------------
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
spool_env_resolve

spool_notify_render L CLE-91 task CLE-90 T-1 M-1 'ping from 90'
has "the line is shell-inert"            ": 'SPOOL CLE-91:" "$L"
has "it names the kind and the sender"   "task from CLE-90" "$L"
has "it names the task and the msg"      "task T-1 msg M-1" "$L"
has "it CARRIES the body"                ":: ping from 90 ::" "$L"
has "it names how to read it in full"    "run: spool recv --as CLE-91" "$L"
check "one line only" test "$(printf '%s' "$L" | wc -l)" -eq 0

spool_notify_render L CLE-91 '' '' '' '' ''
has "no kind -> ping"        "ping from ?" "$L"
has "no body -> (no body)"   ":: (no body) ::" "$L"
hasnt "no task when empty"   " task  " "$L"

# A body that would break the quoting, repaint the pane or submit early.
spool_notify_render L CLE-91 note CLE-90 T M "it's \$(rm -rf /) $(printf '\033[31mRED\033[0m')
second line	tabbed"
hasnt "a single quote never survives" "'s" "$L"
has   "it becomes a double quote"     'it"s' "$L"
hasnt "ESC sequences are dropped"     "$(printf '\033')" "$L"
has   "the payload text is still readable" 'rm -rf /' "$L"
has   "RED text kept, colour dropped" 'RED second line tabbed' "$L"
check "still one line" test "$(printf '%s' "$L" | wc -l)" -eq 0
# The whole line must parse as one no-op command with one argument.
check "bash parses it as inert" bash -n <<<"$L"
eq "…and running it does nothing" "" "$(eval "$L" 2>&1)"

long="$(head -c 4000 /dev/zero | tr '\0' 'x')"
SPOOL_NOTIFY_BODY_MAX=50 spool_notify_render L CLE-91 note CLE-90 T M "$long"
has "a long body is cut" ' …' "$L"
check "…to the configured bound" test "${#L}" -lt 300
case "$L" in *"'") ok "a cut line is still closed" ;; *) nok "a cut line is still closed" ;; esac

# ---- the doorbell, against a private tmux server --------------------------
t_tmux
P91="$(t_window CLE-91 'sleep 600')"
printf 'CLE-91\tclaude\t%s\t/x\t20260101T000000Z\n' "$P91" >> "$SPOOL_ROOT/registry.tsv"
P92="$(t_window CLE-92 'sleep 600')"

out="$(bash "$SN" --to CLE-91 --from CLE-90 --kind task --task T-7 --msg-id M-7 --body 'hello from the hub')"
eq "notify exits 0" 0 "$?"
has "it reports the registered pane" "poke: ${P91} (CLE-91)" "$out"
sleep 0.5
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P91")"
has "the pane shows the sender and kind" "SPOOL CLE-91: task from CLE-90" "$screen"
has "the pane shows the BODY"            "hello from the hub" "$screen"
has "the pane shows the msg id"          "msg M-7" "$screen"
# FR-007: nobody else sees it.
other="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P92")"
hasnt "CONTROL: another agent's pane stays clean" "hello from the hub" "$other"

printf 'body from a file' > "$T_TMP/body.txt"
bash "$SN" --to CLE-91 --body-file "$T_TMP/body.txt" >/dev/null; eq "--body-file: exit 0" 0 "$?"
printf 'body from stdin' | bash "$SN" --to CLE-91 --body-stdin >/dev/null; eq "--body-stdin: exit 0" 0 "$?"
sleep 0.4
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P91")"
has "the file body reached the pane"  "body from a file" "$screen"
has "the stdin body reached the pane" "body from stdin" "$screen"

# ---- the outcomes ---------------------------------------------------------
bash "$SN" --to CLE-95 --body x >/dev/null;  eq "no window for the id: exit 5" 5 "$?"
t_window CLE-96 'bash --norc' >/dev/null
bash "$SN" --to CLE-96 --body x >/dev/null;  eq "pane with only a shell: exit 7" 7 "$?"
t_window CLE-97 "sh -c 'printf \"❯ half typed\\n\"; sleep 600'" >/dev/null
sleep 0.3
bash "$SN" --to CLE-97 --body x >/dev/null;  eq "unsent typed text: refused, exit 6" 6 "$?"
# A pane still holding a PREVIOUS poke line is not a human mid-sentence.
bash "$SN" --to CLE-91 --body 'second message' >/dev/null
eq "a pane holding an earlier poke is poked again" 0 "$?"

# ---- the hot path stays cheap (CLE-3435) ----------------------------------
# The notifier is the last hop of a <300 ms delivery budget, and its cost used
# to grow with the size of the fleet: spool_pane_of forked a `sed` for every
# live pane, once per registry row of the id. These pin the two properties
# that removed it, so a later edit cannot quietly put the forks back.

# spool_id_of_window_var is the fork-free form; the printing wrapper must
# agree with it on every name shape the window list can hold.
for _n in 'CLE-07' 'CLE-07 > wip' 'box: CLE-07' 'box: CLE-07 > wip' \
          'bash' '' 'a b: CLE-07' 'BOX-1' 'cle-7'; do
  spool_id_of_window_var _v "$_n"
  eq "id_of_window agrees with its _var form on '${_n}'" "$(spool_id_of_window "$_n")" "$_v"
done
eq "a tag prefix is stripped"        CLE-07 "$(spool_id_of_window 'box: CLE-07 > wip')"
eq "a prefix with a space is not"    ""     "$(spool_id_of_window 'a b: CLE-07')"

# spool_pane_of must hand back the pane's tty from the SAME tmux call, so the
# poke needs no second round trip to learn it.
SPOOL_PANE_TTY=sentinel
spool_pane_of_var _p CLE-91
eq "spool_pane_of finds the registered pane" "$P91" "$_p"
case "$SPOOL_PANE_TTY" in
  /dev/*) ok "…and caches that pane's tty for the poke" ;;
  *) nok "…and caches that pane's tty for the poke (got '${SPOOL_PANE_TTY}')" ;;
esac
SPOOL_PANE_TTY=sentinel
spool_pane_of_var _p CLE-95
eq "no pane for an unknown id" "" "$_p"
eq "…and the printing wrapper agrees" "" "$(spool_pane_of CLE-95)"
eq "…and no stale tty is left behind" "" "$SPOOL_PANE_TTY"

# ---- the VERBATIM prompt (poke-line.md 1.1, owner 2026-09-22) -------------
# "the communication would be as a human would be typing into this chat
# textbox": a human's message reaches a TUI prompt as the human's own words.

P="$(spool_notify_clean_prompt "it's a \"quoted\" word")"
eq "an apostrophe SURVIVES the prompt cleaner" "it's a \"quoted\" word" "$P"
CL="$(spool_notify_clean "it's a word")"
has "the shell cleaner still kills it, so the poke line stays inert" 'it"s' "$CL"

P="$(spool_notify_clean_prompt "$(printf 'red \033[31mtext\033[0m\nsecond\tline')")"
eq "ESC, newline and tab are still removed" "red text second line" "$P"
check "the prompt is one line" test "$(printf '%s' "$P" | wc -l)" -eq 0

spool_notify_render_prompt P '   spaced   out   '
eq "whitespace collapsed and trimmed" "spaced out" "$P"
spool_notify_render_prompt P ''
eq "an empty body renders no prompt, never a bare Enter" "" "$P"
SPOOL_NOTIFY_PROMPT_MAX=20 spool_notify_render_prompt P "$(head -c 200 /dev/zero | tr '\0' 'y')"
check "a huge body is bounded" test "${#P}" -lt 30

spool_notify_is_human HUM-17 && ok "HUM- is a human"   || nok "HUM- is a human"
spool_notify_is_human GST-3  && ok "GST- is a human"   || nok "GST- is a human"
spool_notify_is_human CLE-90 && nok "CLE- is not"      || ok "CLE- is not"

spool_notify_has_unsent '  │ ❯ │' && nok "an input-box border is not unsent text" || ok "an input-box border is not unsent text"
spool_notify_has_unsent '❯' && nok "an empty prompt is not unsent text" || ok "an empty prompt is not unsent text"
spool_notify_has_unsent '❯ half typed' && ok "real typing is still unsent text" || nok "real typing is still unsent text"

# A pane on the ALTERNATE screen is the agent-TUI shape; one on the normal
# screen is a shell, where a raw body would EXECUTE and must never be typed.
PT="$(t_window CLE-81 "sh -c 'printf \"\033[?1049h\"; sleep 600'")"
printf 'CLE-81\tclaude\t%s\t/x\t20260101T000000Z\n' "$PT" >> "$SPOOL_ROOT/registry.tsv"
sleep 0.4
eq "the test TUI pane is on the alternate screen" 1 \
   "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PT" '#{alternate_on}')"

bash "$SN" --to CLE-81 --from HUM-17 --kind note --msg-id M-8 \
     --body "fix the Ansible years too, it's wrong" >/dev/null
sleep 0.6
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PT")"
has   "a HUMAN message reaches the prompt VERBATIM" "fix the Ansible years too, it's wrong" "$screen"
hasnt "with no SPOOL wrapper round it"              ": 'SPOOL CLE-81:" "$screen"

# CONTROL 1: an AGENT sender keeps the poke line - `from` and the `spool recv`
# tail are the inter-agent protocol and a bare body would strip both.
bash "$SN" --to CLE-81 --from CLE-90 --kind task --msg-id M-9 --body 'agent to agent' >/dev/null
sleep 0.6
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PT")"
has "an AGENT sender still gets the inert poke line" ": 'SPOOL CLE-81:" "$screen"

# CONTROL 2: the same human message at a SHELL pane (normal screen) must NOT
# be typed raw - this is the control that turns red if the alternate_on gate
# is deleted, and it is the whole safety argument for the gate.
PS_="$(t_window CLE-82 "sh -c 'printf \"shell here\n\"; sleep 600'")"
printf 'CLE-82\tclaude\t%s\t/x\t20260101T000000Z\n' "$PS_" >> "$SPOOL_ROOT/registry.tsv"
sleep 0.4
eq "the control pane is on the NORMAL screen" 0 \
   "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$PS_" '#{alternate_on}')"
bash "$SN" --to CLE-82 --from HUM-17 --kind note --msg-id M-10 --body 'rm -rf /tmp/nope' >/dev/null
sleep 0.6
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PS_")"
has "a shell pane keeps the SHELL-INERT line" ": 'SPOOL CLE-82:" "$screen"

# SPOOL_POKE_STYLE=line pins the old behaviour for a caller that wants it.
SPOOL_POKE_STYLE=line bash "$SN" --to CLE-81 --from HUM-17 --msg-id M-11 --body 'styled as a line' >/dev/null
sleep 0.6
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$PT")"
has "SPOOL_POKE_STYLE=line restores the poke line for a human too" ": 'SPOOL CLE-81:" "$screen"

# ---- usage ----------------------------------------------------------------
bash "$SN" --body x >/dev/null 2>&1;             eq "no --to: exit 2" 2 "$?"
bash "$SN" --to BOX-1 --body x >/dev/null 2>&1;  eq "BOX recipient: exit 2" 2 "$?"
bash "$SN" --to cle-1 --body x >/dev/null 2>&1;  eq "bad id: exit 2" 2 "$?"

t_done
