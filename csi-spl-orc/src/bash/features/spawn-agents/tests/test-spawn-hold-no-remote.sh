#!/usr/bin/env bash
# spawn-window HOLD and a remote request that this process will not use.
# A stubbed box pick (SPAWN_BOX_PICK_CMD). The real spawn-remote.sh files
# through SPAWN_REMOTE_SEND_CMD, which writes the target inbox on this spool.
#   1. pick=hold -> exit 10, and the remote inbox has 0 spawn-requests
#   2. pick=<other box> and the target answers -> exactly 1 spawn-request,
#      no cancel
#   3. pick=<other box> and the target does not answer -> the request is
#      withdrawn (spawn-cancel) before the local fallback, and a serve tick
#      spawns nothing
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK SPAWN_BOX_PICK_CMD SPAWN_ORC_RUN SPAWN_PICK_HOP_CMD SPAWN_REMOTE_WAIT SPAWN_REMOTE_POLL REPLY
SW="$T_SCRIPTS/spawn-window.sh"
SR="$T_SCRIPTS/spawn-remote.sh"
HERE_BOX=box-a OTHER=box-b
export SPOOL_DESK_BOX="$HERE_BOX"
mkdir -p "$SPOOL_ROOT/dispatch" "$T_TMP/bin" "$T_TMP/wd"
printf '%s\n' LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main \
  "LEASE_PRIORITY=$HERE_BOX,$OTHER" > "$SPOOL_ROOT/dispatch/lease.conf"
echo "c-001@$HERE_BOX 1" > "$SPOOL_ROOT/dispatch/lease.orch"

cat > "$T_TMP/bin/pick" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PICK_OUT"
STUB
cat > "$T_TMP/bin/send" << STUB
#!/usr/bin/env bash
from="" to="" task="" kind="" bodyf=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --from) from="\$2"; shift 2 ;;
    --to) to="\$2"; shift 2 ;;
    --task) task="\$2"; shift 2 ;;
    --kind) kind="\$2"; shift 2 ;;
    --body-file) bodyf="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
id="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
mkdir -p "$SPOOL_ROOT/c-001/inbox"
body="\$(cat "\$bodyf")"
case "\$from" in *@*) qf="\$from" ;; *) qf="\$from@$HERE_BOX" ;; esac
jq -n --arg m "\$id" --arg t "\$task" --arg f "\$qf" --arg k "\$kind" --arg b "\$body" \
  '{v:1, msg_id:\$m, task_id:\$t, ts:"x", from:\$f, to:"c-001", kind:\$k, body:\$b, files:[]}' \
  > "$SPOOL_ROOT/c-001/inbox/\$id.json"
if [ "\${REPLY:-}" = 1 ] && printf '%s\n' "\$body" | head -1 | grep -qx 'spawn-request v1'; then
  rid="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
  jq -n --arg m "\$rid" --arg t "\$task" \
    --arg b \$'spawn-reply v1\nstatus: ok\nagent: c-200@$OTHER\npane: %9' \
    '{v:1, msg_id:\$m, task_id:\$t, ts:"x", from:"c-001@$OTHER", to:"c-001", kind:"result", body:\$b, files:[]}' \
    > "$SPOOL_ROOT/c-001/inbox/reply-\$rid.json"
fi
echo '{"delivery":"sent","msg_id":"'"\$id"'","task_id":"'"\$task"'","ts":"x"}'
STUB
cat > "$T_TMP/bin/window" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T_TMP/spawn.calls"
echo "c-009 %42"
STUB
chmod +x "$T_TMP/bin/"*
export SPAWN_BOX_PICK_CMD="$T_TMP/bin/pick" SPAWN_REMOTE_SEND_CMD="$T_TMP/bin/send"

reset_box() { rm -rf "$SPOOL_ROOT/c-001" "$SPOOL_ROOT/spawn-remote" "$T_TMP/spawn.calls"; }
n_magic() {  # MAGIC -> count of inbox bodies whose first line is MAGIC
  local n=0 f
  [ -d "$SPOOL_ROOT/c-001/inbox" ] || { echo 0; return 0; }
  for f in "$SPOOL_ROOT/c-001/inbox"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.body // ""' "$f" | sed -n 1p)" = "$1" ] && n=$((n + 1))
  done
  echo "$n"
}

# 1. HOLD files nothing.
export PICK_OUT="pick=hold reason=no box with a sample is below its overflow mark (200% of its high): queue the lane, spawn nothing"
unset REPLY
reset_box
OUT="$(bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "1. pick=hold: exit 10" 10 "$RC"
has "1. ... and says nothing was spawned" "nothing was spawned" "$OUT"
eq "1. ... 0 spawn-requests in the remote inbox" 0 "$(n_magic 'spawn-request v1')"
eq "1. ... and no cancel" 0 "$(n_magic 'spawn-cancel v1')"

# 2. A real remote spawn files exactly one request.
export PICK_OUT="pick=$OTHER reason=$OTHER is the first box in order below its high mark (40% < 75%)"
export REPLY=1
reset_box
OUT="$(bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "2. the target answers: exit 0" 0 "$RC"
has "2. ... stdout is the remote id" "c-200@$OTHER %9" "$OUT"
eq "2. ... exactly 1 spawn-request" 1 "$(n_magic 'spawn-request v1')"
eq "2. ... and no cancel" 0 "$(n_magic 'spawn-cancel v1')"

# 3. No answer: withdraw before the local fallback. A later serve spawns nothing.
unset REPLY
export SPAWN_REMOTE_WAIT=1 SPAWN_REMOTE_POLL=1
reset_box
OUT="$(bash "$SW" claude auto "$T_TMP/wd" 2>&1)"; RC=$?
eq "3. no answer: falls back here (no tmux, exit 5)" 5 "$RC"
has "3. ... and says it is starting here" "starting here instead" "$OUT"
eq "3. ... the request was filed" 1 "$(n_magic 'spawn-request v1')"
eq "3. ... and withdrawn" 1 "$(n_magic 'spawn-cancel v1')"
env SPAWN_REMOTE_WINDOW_CMD="$T_TMP/bin/window" bash "$SR" --serve >/dev/null 2>&1
eq "3. ... a serve tick spawns nothing" 0 "$([ -f "$T_TMP/spawn.calls" ] && wc -l < "$T_TMP/spawn.calls" || echo 0)"

t_done
