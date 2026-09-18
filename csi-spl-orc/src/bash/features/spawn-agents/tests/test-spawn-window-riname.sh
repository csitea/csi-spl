#!/usr/bin/env bash
# spawn-window.sh against a PRIVATE tmux server: the window is created detached
# (focus stays put), named for the id, the id is claimed under SPOOL_ROOT, and
# the launcher runs in it. Then riname.sh renames it by id.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
# Panes inherit the server's environment: a dry-run launcher prints its plan
# and ends, and remain-on-exit keeps the pane to read.
t_tmux SPAWN_DRY_RUN=1
SW="$T_SCRIPTS/spawn-window.sh"
WD="$T_TMP/plain"; mkdir -p "$WD"
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
active() { "${TM[@]}" list-windows -t t -F '#{window_active} #{window_name}' | awk '$1 == 1 { $1 = ""; sub(/^ /, ""); print }'; }

out="$(bash "$SW" claude CLE-4441 "$WD")"; rc=$?
eq "explicit id: exit 0" 0 "$rc"
read -r ID PANE <<<"$out"
eq "prints the id" CLE-4441 "$ID"
check "prints a pane id" grep -qxE '%[0-9]+' <<<"$PANE"
check "the id was claimed under SPOOL_ROOT" test -d "$SPOOL_ROOT/CLE-4441/inbox"
eq "focus stayed on the original window (new-window -d)" home "$(active)"
has "the window is named for the id" "CLE-4441" "$("${TM[@]}" list-windows -t t -F '#{window_name}')"
sleep 1
has "the launcher ran in the pane (dry-run plan visible)" "PLAN spooldir" "$("${TM[@]}" capture-pane -p -t "$PANE" -S -200)"

bash "$SW" claude CLE-4441 "$WD" >/dev/null 2>&1; eq "a taken id is refused (exit 3)" 3 "$?"
out="$(SPAWN_REUSE_ID=1 bash "$SW" claude CLE-4441 "$WD")"; eq "SPAWN_REUSE_ID=1 respawns it" 0 "$?"
bash "$SW" grok CLE-4442 "$WD" >/dev/null 2>&1; eq "kind/prefix mismatch refused (exit 2)" 2 "$?"
bash "$SW" agy BOX-1 "$WD" >/dev/null 2>&1;     eq "BOX id refused (exit 2)" 2 "$?"

out="$(bash "$SW" agy auto "$WD")"; read -r ID PANE <<<"$out"
eq "auto allocates the first AGY id" AGY-01 "$ID"
eq "focus still on the original window" home "$(active)"

out="$(SPOOL_BOX_TAG=tg bash "$SW" grok auto "$WD")"; read -r ID PANE <<<"$out"
eq "auto allocates GRK-01" GRK-01 "$ID"
has "SPOOL_BOX_TAG decorates the window name" "tg: GRK-01" "$("${TM[@]}" list-windows -t t -F '#{window_name}')"

SPOOL_TMUX_SOCKET="$T_TMP/none.sock" bash "$SW" claude CLE-4450 "$WD" >/dev/null 2>&1
eq "no tmux session: exit 5" 5 "$?"
check "…and the id was NOT claimed" test ! -e "$SPOOL_ROOT/CLE-4450"

# ---- riname --------------------------------------------------------------
P="$(t_window CLE-95 'sleep 600')"
printf 'CLE-95\tclaude\t%s\t/x\t20260101T000000Z\n' "$P" >> "$SPOOL_ROOT/registry.tsv"
out="$(bash "$T_SCRIPTS/riname.sh" --agent CLE-95 'spool msg test')"; eq "riname --agent: exit 0" 0 "$?"
eq "window renamed, id kept" "CLE-95 spool msg test" "$("${TM[@]}" display-message -p -t "$P" '#{window_name}')"
out="$(SPOOL_BOX_TAG=tg bash "$T_SCRIPTS/riname.sh" --agent CLE-95 'again #[fg=red]')"
eq "tagged rename strips tmux format bytes" "tg: CLE-95 again [fg=red]" "$("${TM[@]}" display-message -p -t "$P" '#{window_name}')"
bash "$T_SCRIPTS/riname.sh" --agent CLE-96 x >/dev/null 2>&1; eq "no window for the id: exit 4" 4 "$?"
out="$(TMUX_PANE="$P" bash "$T_SCRIPTS/riname.sh" 'self')"
eq "self-target via TMUX_PANE" "CLE-95 self" "$("${TM[@]}" display-message -p -t "$P" '#{window_name}')"

t_done
