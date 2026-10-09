#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box-stats history gets one sample per box per 5 min (rdb 0117).
#   1. do_post_box_stats posts ONE sample (load, cpus, memory, swap, live
#      agents) through `spool box-stats put`; hub down -> exit 1 naming it;
#      an unreadable /proc/loadavg sends nothing; no fleet is refused before
#      any hub call
#   1b. the same tick keeps this box's BOX-0 lane-map row fresh (c-615): a box
#      that spawned nothing past LANE_BOX_ROW_MAX_S reads `(no live row)` on
#      the other box; one tick later it reads live. CONTROL: the same tick
#      without the refresh still reads `(no live row)`. At most one write per
#      LANE_BOX_ROW_S; a lane read that fails, or no panes, keeps the sample
#   2. box-stats-cron.sh runs `./run -a do_post_box_stats` in its checkout,
#      exits 1 on a failed post, refuses an agent worktree, --check-tools
#   3. do_setup_box_stats_cron: a dry run writes nothing; install writes ONE
#      `*/5` line tagged `# csi-spl:box-stats`, keeps every other line byte for
#      byte and a re-install changes no byte; check says OK / FAIL; remove
#      takes only its line; a worktree source and bad settings are refused
# No real crontab, hub or tmux is touched.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub" "$T/spool"

# 1. do_post_box_stats ---------------------------------------------------------
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = lane ]; then
  # the `spool lane` contract, one row per <agent>@<box>; its calls are kept
  # apart (lane.calls), so `calls` counts the box-stats puts only
  echo "$*" >>"$HUB_DIR/lane.calls"
  [ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
  [ "${LANE_DOWN:-0}" = 1 ] && { echo "dial: lane refused" >&2; exit 1; }
  shift; agent="" box="" scope="" state=live fleet=""
  while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --agent) agent="$2";; --box) box="$2";;
    --scope) scope="$2";; --state) state="$2";; esac; shift 2; done
  f="$HUB_DIR/lanes.json"; [ -s "$f" ] || echo '{"lanes":[]}' >"$f"
  if [ -n "$agent" ]; then
    jq -c --arg a "$agent" --arg b "$box" --arg s "$scope" --arg st "$state" \
      '.lanes = ([.lanes[] | select(.agent_id != $a or .agent_box != $b)] + [{agent_id:$a, agent_box:$b, repo:"", branch:"", scope:$s, files:[], topic:"", state:$st, age_s:0}])' \
      "$f" >"$f.new" && mv "$f.new" "$f" && echo '{"ok":true}'
  else jq -c --arg f "$fleet" '{fleet:$f, lanes:.lanes}' "$f"; fi
  exit 0
fi
echo "$*" >>"$HUB_DIR/calls"
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
[ "$1 $2 $3 $4" = "box-stats put --json -" ] || { echo "unexpected: $*" >&2; exit 2; }
s="$(cat)"
# OLD_BIN=1: a spool binary from before used_kb refuses the field
[ "${OLD_BIN:-0}" = 1 ] && [[ "$s" == *'"used_kb"'* ]] && { echo 'box-stats put: not one sample object: json: unknown field "used_kb"' >&2; exit 1; }
# OLD_HUB=1: a hub from before used_kb refuses the frame without naming it
[ "${OLD_HUB:-0}" = 1 ] && [[ "$s" == *'"used_kb"'* ]] && { echo 'hub: 400 bad_frame: lane must be one box stat object' >&2; exit 1; }
jq -c . <<<"$s" >>"$HUB_DIR/stats.jsonl" && echo '{"ok":true}'
STUB
chmod +x "$T/bin/hub"
printf '2.50 1.75 0.47 3/900 12345\n' >"$T/loadavg"
printf 'MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n' >"$T/meminfo"
printf '0 c-001@sat\n0 c-150@sat wip\n1 c-151@sat\n0 shell\n' >"$T/panes"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 55 40 58%% /\n/dev/sdb1 900 400 500 45%% /mnt/my data\n/dev/sda1 100 55 40 58%% /\nsrv:/x - - - - /net\n' >"$T/df"

post() {
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=sat LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" \
    LANE_LOADAVG="$T/loadavg" LANE_MEMINFO="$T/meminfo" LANE_NPROC=8 LANE_PANES_CMD="cat $T/panes" LANE_DF_CMD="cat $T/df" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/post-box-stats.func.sh"
    eval "${POST_PRE:-}"
    do_post_box_stats'
}
out="$(post)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK box stats of sat recorded"* ]] &&
  jq -s -e '. == [{"box":"sat","load1":2.5,"load5":1.75,"load15":0.47,"cpus":8,"mem_total_kb":16000000,"mem_avail_kb":6000000,"swap_used_kb":600,"agents_live":2,"disks":[{"mount":"/","total_kb":100,"avail_kb":40,"used_kb":55},{"mount":"/mnt/my data","total_kb":900,"avail_kb":500,"used_kb":400}]}]' "$T/hub/stats.jsonl" >/dev/null &&
  pass "one sample: load, cpus, memory, swap used, 2 live agents (a dead pane, a shell: not), disks per mount with df's Used (a space kept, a repeat and a dash row dropped)" || fail "post (rc=$rc): $out / $(cat "$T/hub/stats.jsonl" 2>&1)"
[[ "$(wc -l <"$T/hub/calls")" -eq 1 ]] && pass "...and ONE box-stats call" || fail "calls: $(cat "$T/hub/calls")"
: >"$T/hub/calls"
out="$(post OLD_BIN=1)"; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/hub/calls")" -eq 2 && "$(tail -1 "$T/hub/stats.jsonl" | jq -c .disks)" == '[{"mount":"/","total_kb":100,"avail_kb":40},{"mount":"/mnt/my data","total_kb":900,"avail_kb":500}]' ]] &&
  pass "a binary or hub that refuses used_kb: the sample goes again without it (2 calls)" || fail "old bin (rc=$rc): $out / $(cat "$T/hub/calls")"
: >"$T/hub/calls"
out="$(post OLD_HUB=1)"; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/hub/calls")" -eq 2 && "$(tail -1 "$T/hub/stats.jsonl" | jq '[.disks[] | has("used_kb")] | any')" == false ]] &&
  pass "a hub from before used_kb (one box stat object): the sample goes again without it" || fail "old hub (rc=$rc): $out"
out="$(post OLD_BIN=1 HUB_DOWN=1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"connection refused"* ]] && pass "control: a failure that is not about used_kb is not retried away" || fail "control (rc=$rc): $out"
out="$(post HUB_DOWN=1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"did not record the sample of sat"*"connection refused"* ]] && pass "hub down: exit 1 naming the error (the cron logs it)" || fail "hub down (rc=$rc): $out"
: >"$T/hub/calls"
out="$(post LANE_LOADAVG="$T/nosuch")"; rc=$?
[[ $rc -eq 1 && ! -s "$T/hub/calls" ]] && pass "an unreadable /proc/loadavg sends nothing half-read" || fail "no loadavg (rc=$rc): $out"
out="$(post LANE_FLEET= LEASE_FLEET=)"; rc=$?
[[ $rc -eq 1 && "$out" == *"live on the hub"* && ! -s "$T/hub/calls" ]] && pass "no fleet: refused before any hub call" || fail "no fleet (rc=$rc): $out"
out="$(post LANE_PANES_CMD=false)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$T/hub/stats.jsonl" | jq .agents_live)" == 0 ]] && pass "tmux unreadable: the sample still goes, 0 live agents" || fail "no panes (rc=$rc): $out"
out="$(post LANE_DF_CMD=false)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$T/hub/stats.jsonl" | jq -c .disks)" == "[]" ]] && pass "df fails: the sample still goes, with disks []" || fail "no df (rc=$rc): $(tail -1 "$T/hub/stats.jsonl")"
seq 1 20 | awk '{print "/dev/x" $1, 10, 1, 9, "10%", "/m" $1}' | sed '1i head' >"$T/df20"
post LANE_DF_CMD="cat $T/df20" >/dev/null
[[ "$(tail -1 "$T/hub/stats.jsonl" | jq '.disks | length')" == 16 ]] && pass "20 mounts: the first 16 go (the hub's cap)" || fail "cap: $(tail -1 "$T/hub/stats.jsonl")"

# 1b. the BOX-0 row ---------------------------------------------------------
row() { jq -r '.lanes[] | select(.agent_id == "BOX-0" and .agent_box == "sat") | "\(.state) \(.age_s) \(.scope)"' "$T/hub/lanes.json"; }
[[ "$(row)" == "live 0 mem_kb=6000000 live=c-001,c-150" && "$(grep -c -- '--agent BOX-0' "$T/hub/lane.calls")" == 1 ]] &&
  pass "the tick writes BOX-0@sat: free kB and the agents with a live pane, as the lane map writes it" || fail "BOX-0 row: $(row) / $(cat "$T/hub/lane.calls")"
: >"$T/hub/lane.calls"; post >/dev/null
[[ "$(cat "$T/hub/lane.calls")" == "lane --fleet main" ]] &&
  pass "a row younger than LANE_BOX_ROW_S (300 s): one read, no write" || fail "rate limit: $(cat "$T/hub/lane.calls")"
# the other box: pc, whose lease.conf ranks sat, so sat has a header line
mkdir -p "$T/pc/dispatch"; printf 'LEASE_PRIORITY=pc,sat\n' >"$T/pc/dispatch/lease.conf"
pcmap() {
  env SPOOL_ROOT="$T/pc" SPOOL_DESK_BOX=pc LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" \
    LANE_PANES_CMD=false LANE_REPO_DIRS="$T/none" bash -c '
    set -uo pipefail
    do_log() { :; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-map.func.sh"
    do_spl_lane_map' | grep '^BOX sat'
}
age_row() { jq -c --argjson a "$1" '.lanes |= map(if .agent_id == "BOX-0" then .age_s = $a else . end)' "$T/hub/lanes.json" >"$T/l.new" && mv "$T/l.new" "$T/hub/lanes.json"; }
age_row 4000
out="$(pcmap)"
[[ "$out" == "BOX sat  busy 0  seats 0  mem ?  (no live row)" ]] &&
  pass "measure: sat spawned nothing for 4000 s (> LANE_BOX_ROW_MAX_S 3600), pc reads it '(no live row)'" || fail "aged row on pc: $out"
post POST_PRE='spl_lane_box_refresh() { :; }' >/dev/null
out="$(pcmap)"
[[ "$out" == *"(no live row)" ]] && pass "control: a tick without the refresh leaves sat '(no live row)' on pc" || fail "control: $out"
post >/dev/null
out="$(pcmap)"
[[ "$out" == "BOX sat  busy 1  seats 1  mem 5.7G" && "$(row)" == "live 0 "* ]] &&
  pass "one tick later, no spawn: pc reads sat live (busy 1, seats 1, mem 5.7G)" || fail "after tick: $out / $(row)"
age_row 4000; : >"$T/hub/calls"
out="$(post LANE_DOWN=1)"; rc=$?
[[ $rc -eq 0 && "$(wc -l <"$T/hub/calls")" -eq 1 && "$(row)" == "live 4000 "* ]] &&
  pass "the lane read fails: the sample still goes, exit 0, the row is left as it was" || fail "lane down (rc=$rc): $out / $(row)"
: >"$T/hub/lane.calls"
post LANE_PANES_CMD=false >/dev/null
[[ ! -s "$T/hub/lane.calls" ]] && pass "tmux unreadable: no lane call, no BOX-0 row made of nothing" || fail "no panes: $(cat "$T/hub/lane.calls")"

# 2. box-stats-cron.sh ---------------------------------------------------------
SH="$T/shared"
mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/box-stats-cron.sh" "$SH/csi-spl-orc/src/bash/scripts/"
printf '#!/usr/bin/env bash\necho "RUN $* in $PWD" >>"%s/run.calls"\nexit "${RUN_RC:-0}"\n' "$T" >"$SH/csi-spl-orc/run"
chmod +x "$SH/csi-spl-orc/run" "$SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh"
out="$(bash "$SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/run.calls")" == "RUN -a do_post_box_stats in $SH/csi-spl-orc" ]] &&
  pass "the cron script runs do_post_box_stats in its own checkout" || fail "cron run (rc=$rc): $out / $(cat "$T/run.calls" 2>&1)"
out="$(RUN_RC=1 bash "$SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL box stats sample rc=1"* ]] && pass "a failed post: exit 1, one FAIL line in the log" || fail "cron fail (rc=$rc): $out"
out="$(bash "$SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh" --check-tools 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK every tool"* ]] && pass "--check-tools: every tool resolves" || fail "check-tools (rc=$rc): $out"
out="$(BOX_STATS_CRON_TOOLS="jq no-such-tool-x" bash "$SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 3 && "$out" == *"no-such-tool-x"* ]] && pass "a missing tool: exit 3 naming it" || fail "missing tool (rc=$rc): $out"
WT="$T/csi-spl-wt/c-999"; mkdir -p "$WT"; cp -r "$SH/csi-spl-orc" "$WT/"
out="$(bash "$WT/csi-spl-orc/src/bash/scripts/box-stats-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"agent worktree"* ]] && pass "an agent worktree is refused (it is deleted when its agent ends)" || fail "worktree (rc=$rc): $out"

# 3. do_setup_box_stats_cron ---------------------------------------------------
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/3 * * * * /x/desk-reconcile-cron.sh >> /l/cron.out 2>&1 # csi-spl:desk-reconcile' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
setup() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" BOX_STATS_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-box-stats-cron.func.sh"
    do_setup_box_stats_cron'
}
want="*/5 * * * * $SH/csi-spl-orc/src/bash/scripts/box-stats-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:box-stats"
out="$(setup)"; rc=$?
[[ $rc -eq 0 && "$out" == *"DRY_RUN nothing was touched"* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "dry run: prints the diff with the */5 line, writes nothing" || fail "dry run (rc=$rc): $out"
out="$(setup BOX_STATS_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 1 && "$out" == *"NOT installed"* ]] && pass "check before install: FAIL, exit 1" || fail "check none (rc=$rc): $out"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:box-stats$' "$T/crontab")" -eq 1 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 && -d "$T/log" ]] &&
  pass "install: ONE line, */5, the self-updating source's script, tagged csi-spl:box-stats" || fail "install (rc=$rc): $out / $(cat "$T/crontab")"
[[ "$(head -2 "$T/crontab")" == "$(cat "$T/crontab.orig")" ]] && pass "every other line is kept byte for byte" || fail "kept: $(cat "$T/crontab")"
cp "$T/crontab" "$T/crontab.1"
setup DRY_RUN=0 >/dev/null
cmp -s "$T/crontab" "$T/crontab.1" && pass "a re-install changes no byte (idempotent)" || fail "reinstall: $(diff "$T/crontab.1" "$T/crontab")"
out="$(setup BOX_STATS_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK the box-stats cron is installed"* ]] && pass "check after install: OK" || fail "check (rc=$rc): $out"
out="$(setup DRY_RUN=0 BOX_STATS_CRON_ACTION=remove)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.orig" && [[ $rc -eq 0 ]] && pass "remove takes only its own line" || fail "remove (rc=$rc): $(cat "$T/crontab")"
out="$(setup DESK_CRON_SRC="$WT" DRY_RUN=0)"; rc=$?
[[ $rc -eq 1 && "$out" == *"agent worktree"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" && pass "a worktree source is refused, nothing written" || fail "wt src (rc=$rc): $out"
for bad in BOX_STATS_CRON_EVERY=0 BOX_STATS_CRON_EVERY=60 BOX_STATS_CRON_OFFSET=5 BOX_STATS_CRON_ACTION=nuke DRY_RUN=2; do
  out="$(setup "$bad")"; rc=$?
  [[ $rc -eq 1 && "$out" == FATAL* ]] || fail "$bad accepted (rc=$rc): $out"
done
cmp -s "$T/crontab" "$T/crontab.orig" && pass "bad EVERY / OFFSET / ACTION / DRY_RUN are refused, nothing written" || fail "bad settings wrote"

echo
if [ "$fails" -eq 0 ]; then echo "box-stats-cron: all passed"; exit 0; fi
echo "box-stats-cron: $fails FAILED"; exit 1
