#!/usr/bin/env bash
# test-poke-retiring-pane.sh — after a lane rotation the poke goes to the id's
# LIVE pane, never to the old window the rotation renamed "<ID>-<hhmm>Z-retiring"
# (spl_rotate_retiring_name, csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh).
#
# 2026-10-24 (n=1): an ACCEPTED for a rotated agy lane was typed into its old
# pane; the live session idled at its prompt. A path into the old pane: an
# identity pass that read only the OLD process (the new one skipped, e.g. its
# environ unreadable that pass) rewrites the map to the old pane, and the
# reconcile then renames the retiring window back to the lane's name.
#
# A private tmux server gives real pane ids; a fake /proc (AI_PROC_ROOT) holds
# both CLI processes, each carrying SPOOL_AGENT_ID=a-112 (the overlap).
#
#   1. map adopted to the new pid -> spool_pane_of = the new pane (control)
#   2. map pointing at the old pane, old window "-retiring" -> the new pane
#   3. registry's newest row is the old pane -> still the new pane
#   4. the reconcile never renames a "-retiring" window back to the id
#   5. spool_notify_poke types into the new pane only
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG
P="$T_TMP/proc"; mkdir -p "$P" "$SPOOL_ROOT/agents" "$SPOOL_ROOT/a-112/inbox"
export AI_PROC_ROOT="$P"
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/agent-identity.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve
t_tmux
OLD="$(t_window 'a-112-1336Z-retiring' 'cat')"
NEW="$(t_window 'a-112@box1 lane' 'cat')"

proc() {  # PID START ARGV0 ENV-ID
  mkdir -p "$P/$1"; printf '%s\0' "$3" > "$P/$1/cmdline"
  printf 'SPOOL_AGENT_ID=%s\0' "$4" > "$P/$1/environ"
  printf '%s (%s) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' "$1" "${3##*/}" "$2" > "$P/$1/stat"
  printf '%s\n' "${3##*/}" > "$P/$1/comm"
}
record() {  # ID PID START PANE
  python3 - "$SPOOL_ROOT/agents/$1.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
f, i, pid, start, pane = sys.argv[1:6]
json.dump({"v": 1, "id": i, "kind": "agy", "pid": int(pid), "proc_start": start, "pane_id": pane,
           "alive": True, "session_id": "s", "title": "lane"}, open(f, "w"), indent=1, sort_keys=True)
PY
}
proc 201 700 /usr/bin/agy a-112
proc 202 900 /usr/bin/agy a-112

# --- 1 ------------------------------------------------------------------------------
record a-112 202 900 "$NEW"
eq "1. map adopted to the new pid -> the new pane" "$NEW" "$(spool_pane_of a-112)"

# --- 2 ------------------------------------------------------------------------------
record a-112 201 700 "$OLD"
eq "2. map on the old pane, its window '-retiring' -> the new pane" "$NEW" "$(spool_pane_of a-112)"

# --- 3 ------------------------------------------------------------------------------
printf 'a-112\tx\t%s\tx\n' "$NEW" "$OLD" > "$SPOOL_ROOT/registry.tsv"
eq "3. registry's newest row is the old pane -> the new pane" "$NEW" "$(spool_pane_of a-112)"

# --- 4 ------------------------------------------------------------------------------
# One pass that reads only the OLD process: no conflict holds the record back.
pf="$T_TMP/panes.tsv"
printf 't\t@1\t%s\t201\ta-112-1336Z-retiring\n' "$OLD" > "$pf"
mv "$P/202/environ" "$P/202/environ.off"
out="$(AI_PANES_FILE="$pf" ai_reconcile 2>&1)"
mv "$P/202/environ.off" "$P/202/environ"
has "4. (the pass saw only the old process)" "1 live agent(s)" "$out"
hasnt "4. reconcile plans no rename of the '-retiring' window" "PLAN rename $OLD" "$out"

# --- 5 ------------------------------------------------------------------------------
out="$(SPOOL_NOTIFY_ENTER_DELAY=0 spool_notify_poke a-112 ": 'SPOOL a-112: test'" 2>&1)"
has "5. the poke names the new pane" "poke: $NEW (a-112)" "$out"
sleep 0.3
hasnt "5. ... and the old pane got no keystroke" "SPOOL a-112" "$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$OLD")"

t_done
