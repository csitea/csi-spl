#!/usr/bin/env bash
# SPL-1605: a role seat (c-001 orch, c-002/c-003 dispatch) respawned by its
# rotation under another vendor (ROTATE_ROLE_VENDOR=grok) keeps its id. On
# 2026-10-13 09:06Z the live orch rotation on one box failed with
# "spawn-window: c-001 is not a grok id": the rotation tests stub the spawn,
# so only the REAL spawn-window.sh (dry run) shows the refusal.
#
# Allowed: exactly a role seat id + SPAWN_REUSE_ID=1. Still refused: a role
# seat without reuse, and a lane id under another kind with reuse.
#
# LIVE HOP: the 10:05Z rotation (480a44659 live) still failed: spawn-window
# passed the dry run, but the launcher in the NEW PANE refused the id again
# ("TITLE 'c-001' does not carry the grok prefix GRK-") because SPAWN_REUSE_ID
# did not cross the tmux hop. Here spawn-window runs live in the sandbox tmux;
# only the pane's launcher is a dry run (SPAWN_DRY_RUN=1 in the server env).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux SPAWN_DRY_RUN=1
SW="$T_SCRIPTS/spawn-window.sh"
echo brief > "$T_TMP/brief.md"
ORC="$T_TMP/orc"; mkdir -p "$ORC"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/lane.calls"\n' "$T_TMP" > "$ORC/run"; chmod +x "$ORC/run"
export LANE_MAP_ORC="$ORC"
git init -q -b master "$T_TMP/repo"
git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init

sw() {  # REUSE KIND ID
  SPAWN_REUSE_ID="$1" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool \
    timeout 60 bash "$SW" "$2" "$3" "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1
}

for id in c-001 c-002 c-003; do
  mkdir -p "$SPOOL_ROOT/$id"/{inbox,outbox,archive,lifetime}
  out="$(sw 1 grok "$id")"; rc=$?
  eq "$id grok reuse: dry run exits 0" 0 "$rc"
  hasnt "$id grok reuse: no kind/id refusal" "is not a grok id" "$out"
  has "$id grok reuse: plans the window under the same id" "PLAN window" "$out"
  has "$id grok reuse: prints the id" "$id -" "$out"
done

# controls: every other mismatch is still refused
out="$(sw 0 grok c-001)"; rc=$?
eq "c-001 grok without reuse: refused, exit 2" 2 "$rc"
has "c-001 grok without reuse: names the mismatch" "c-001 is not a grok id" "$out"
mkdir -p "$SPOOL_ROOT/c-777"/{inbox,outbox,archive,lifetime}
out="$(sw 1 grok c-777)"; rc=$?
eq "lane c-777 grok reuse: refused, exit 2" 2 "$rc"
has "lane c-777 grok reuse: names the mismatch" "c-777 is not a grok id" "$out"
out="$(sw 1 claude g-001)"; rc=$?
eq "g-001 claude reuse: refused, exit 2" 2 "$rc"

# the live hop: the pane's launcher must see SPAWN_REUSE_ID=1 too
pane_out() {  # PANE: the pane's screen once its launcher has finished
  local n=0
  while [ "$n" -lt 50 ]; do
    n=$((n + 1))
    [ "$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$1" '#{pane_dead}' 2>/dev/null)" = 1 ] && break
    sleep 0.2
  done
  tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -J -S - -t "$1" 2>/dev/null
}
mkdir -p "$SPOOL_ROOT/c-001"/{inbox,outbox,archive,lifetime}
out="$(SPAWN_REUSE_ID=1 SPAWN_START_CHECK=0 SPOOL_BIN=/opt/x/spool timeout 60 bash "$SW" grok c-001 "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1)"; rc=$?
eq "live c-001 grok reuse: spawn-window exits 0" 0 "$rc"
pane="$(grep -m1 -oE '^c-001 %[0-9]+' <<<"$out" | cut -d' ' -f2)"
has "live c-001 grok reuse: prints the new pane" "%" "$pane"
scr="$(pane_out "$pane")"
hasnt "live c-001 grok reuse: the pane's launcher does not refuse the id" "does not carry the grok" "$scr"
has "live c-001 grok reuse: the pane's launcher reaches the launch" "PLAN launch" "$scr"
# control: the same live hop without reuse is refused before a window opens
out="$(SPAWN_START_CHECK=0 SPOOL_BIN=/opt/x/spool timeout 60 bash "$SW" grok c-001 "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1)"; rc=$?
eq "live c-001 grok without reuse: refused, exit 2" 2 "$rc"

t_done
