#!/usr/bin/env bash
# test-pane-scan.sh — pane-scan.sh prompt-glyph recognition (ported from the
# frozen box engine, specs/048 SPL-1160). Captured pane text is replayed into a
# private tmux server's panes.
#
#   agy's input box is ASCII `>`: it counts only for AGY-* (and QWN-*) ids;
#   U+276F stays preferred; claude's dim placeholder is not typed text; a poke
#   line left in a prompt (spool or markdown inbox) is RESIDUE and exit 1.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE
SUT="$T_SCRIPTS/pane-scan.sh"
FIX="$T_HERE/fixtures"
t_tmux
show_fix() { t_window "$1" "cat $2; stty -echo; exec sleep 600" >/dev/null; }
show_fix "AGY-90 idle"        "$FIX/pane-agy-idle.txt"
show_fix "AGY-91 typed"       "$FIX/pane-agy-typed.txt"
show_fix "CLE-80 idle"        "$FIX/pane-claude-idle.txt"
show_fix "GRK-80 idle"        "$FIX/pane-grok-idle.txt"
show_fix "CLE-81 dim"         "$FIX/pane-claude-dim.txt"
# CLE id + agy TYPED fixture: ASCII `>` is not a claude prompt, so still clear.
show_fix "tbx: CLE-82 agyglyph" "$FIX/pane-agy-typed.txt"
show_fix "AGY-92 claudeglyph" "$FIX/pane-claude-idle.txt"
t_window "AGY-93 noglyph" 'exec sleep 600' >/dev/null
sleep 0.4

OUT="$(bash "$SUT" 2>&1)"; RC=$?
kind_of() { printf '%s\n' "$OUT" | grep -E "^[[:space:]]*(clear|TYPED|RESIDUE)[[:space:]]+$1([[:space:]]|$)" | awk '{print $1}' | head -1; }
eq "agy idle pane: clear (ASCII > glyph)" clear "$(kind_of AGY-90)"
eq "agy typed pane: TYPED" TYPED "$(kind_of AGY-91)"
eq "claude idle pane with > in scrollback: clear" clear "$(kind_of CLE-80)"
eq "grok idle pane (U+276F inside U+2502): clear" clear "$(kind_of GRK-80)"
eq "claude dim placeholder is not typed text" clear "$(kind_of CLE-81)"
eq "a tagged claude id + agy typed text: still clear" clear "$(kind_of CLE-82)"
eq "agy id + claude U+276F: clear (U+276F preferred)" clear "$(kind_of AGY-92)"
eq "agy pane with no glyph: clear, not TYPED" clear "$(kind_of AGY-93)"
eq "no residue -> exit 0" 0 "$RC"
has "the summary reports RESIDUE 0" "RESIDUE (poke text stuck in a prompt) : 0" "$OUT"

# A poke stuck in a prompt: the spool doorbell, and the older inbox's.
printf '%s\n' "── " "❯ : 'SPOOL CLE-83: from CLE-01 note hello'" "── " >"$T_TMP/spool-residue.txt"
printf '%s\n' "── " "❯ INBOX CLE-84: read and act on /x/inbox/m.md" "── " >"$T_TMP/inbox-residue.txt"
show_fix "CLE-83 stuck" "$T_TMP/spool-residue.txt"
show_fix "CLE-84 stuck" "$T_TMP/inbox-residue.txt"
sleep 0.4
OUT="$(bash "$SUT" 2>&1)"; RC=$?
eq "a spool poke left in a prompt is RESIDUE" RESIDUE "$(kind_of CLE-83)"
eq "an inbox poke left in a prompt is RESIDUE" RESIDUE "$(kind_of CLE-84)"
eq "residue -> exit 1" 1 "$RC"
t_done
