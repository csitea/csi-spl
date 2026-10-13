#!/usr/bin/env bash
# SPL-1605: a role seat (c-001 orch, c-002/c-003 dispatch) respawned by its
# rotation under another vendor (ROTATE_ROLE_VENDOR=grok) keeps its id. On
# 2026-10-13 09:06Z the live orch rotation on one box failed with
# "spawn-window: c-001 is not a grok id": the rotation tests stub the spawn,
# so only the REAL spawn-window.sh (dry run) shows the refusal.
#
# Allowed: exactly a role seat id + SPAWN_REUSE_ID=1. Still refused: a role
# seat without reuse, and a lane id under another kind with reuse.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
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

t_done
