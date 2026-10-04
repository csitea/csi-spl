#!/usr/bin/env bash
# test-tmux-utf8.sh — tmux -F under LC_ALL=C must still see UTF-8 (ported from
# the frozen box engine, specs/048 SPL-1160).
#
# tmux with LC_ALL=C (cron, @reboot, systemd, a sudo hop without LANG) prints
# every non-ASCII -F field as "_": a window named "CLE-80 x ✓ y" and the
# prompt glyph U+276F would no longer match anything. `tmux -u` forces UTF-8.
# Every tmux call here goes through a -u argv; this runs the scripts that read
# window names or prompts under LC_ALL=C and requires the UTF-8 answer.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE
t_tmux
P="$(t_window 'CLE-80 x ✓ y' "printf '❯ \\n'; stty -echo; exec sleep 600")"
sleep 0.3
# env -i drops SPOOL_NOW. t_sandbox pins it before the legacy-id cutoff so a
# CLE- fixture stays a valid id (specs/061); without it spool_valid_id refuses
# CLE-80 once wall clock passes SPOOL_LEGACY_ID_UNTIL.
cenv=(env -i LC_ALL=C PATH="$PATH" HOME="$HOME" SPOOL_ROOT="$SPOOL_ROOT" SPOOL_TMUX_SOCKET="$SPOOL_TMUX_SOCKET"
      SPOOL_BOX_USER="$SPOOL_BOX_USER" SPOOL_AGENT_USER="$SPOOL_AGENT_USER" SPOOL_NOW="$SPOOL_NOW"
      XDG_CONFIG_HOME="$T_TMP/cfg")

has "LC_ALL=C tmux -u keeps the checkmark" "✓" "$("${cenv[@]}" tmux -u -S "$SPOOL_TMUX_SOCKET" list-windows -F '#{window_name}')"
out="$("${cenv[@]}" tmux -S "$SPOOL_TMUX_SOCKET" list-windows -F '#{window_name}')"
case "$out" in *_*) ok "control: LC_ALL=C without -u turns it into _" ;; *) nok "control: expected _ without -u, got: $out" ;; esac

has "pane-scan under LC_ALL=C sees CLE-80's prompt as clear" "clear   CLE-80" "$("${cenv[@]}" bash "$T_SCRIPTS/pane-scan.sh" 2>&1)"
has "agent-top under LC_ALL=C lists the window by its UTF-8 name" "CLE-80 x ✓ y" "$("${cenv[@]}" bash "$T_SCRIPTS/agent-top.sh" 2>&1)"
has "tmux-close-window under LC_ALL=C resolves CLE-80" "would close window" "$("${cenv[@]}" bash "$T_SCRIPTS/tmux-close-window.sh" --agent CLE-80 --dry-run 2>&1)"
mkdir -p "$SPOOL_ROOT/CLE-80/inbox" "$SPOOL_ROOT/CLE-81/outbox"
if t_spool_bin; then
  out="$("${cenv[@]}" SPOOL_BIN="$SPOOL_BIN" bash "$T_SCRIPTS/spool-send.sh" --from CLE-81 --to CLE-80 --kind note --body 'utf8 probe' 2>&1)"; rc=$?
  eq "spool-send under LC_ALL=C finds and pokes CLE-80 (rc 0)" 0 "$rc"
  has "... in its pane" "poke: $P (CLE-80)" "$out"
else
  nok "cannot build spool"
fi
t_done
