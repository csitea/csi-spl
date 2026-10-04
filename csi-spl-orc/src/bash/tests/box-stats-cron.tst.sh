#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box-stats history gets one sample per box per 5 min (rdb 0117).
#   1. do_post_box_stats posts ONE sample (load, cpus, memory, swap, live
#      agents) through `spool box-stats put`, and nothing else (no lane read,
#      no BOX-0 row); hub down -> exit 1 naming it; an unreadable
#      /proc/loadavg sends nothing; no fleet is refused before any hub call
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
echo "$*" >>"$HUB_DIR/calls"
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
[ "$1 $2 $3 $4" = "box-stats put --json -" ] || { echo "unexpected: $*" >&2; exit 2; }
jq -c . >>"$HUB_DIR/stats.jsonl" && echo '{"ok":true}'
STUB
chmod +x "$T/bin/hub"
printf '2.50 1.75 0.47 3/900 12345\n' >"$T/loadavg"
printf 'MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n' >"$T/meminfo"
printf '0 c-001@sat\n0 c-150@sat wip\n1 c-151@sat\n0 shell\n' >"$T/panes"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 60 40 60%% /\n/dev/sdb1 900 400 500 45%% /mnt/my data\n/dev/sda1 100 60 40 60%% /\nsrv:/x - - - - /net\n' >"$T/df"

post() {
  env SPOOL_ROOT="$T/spool" SPOOL_DESK_BOX=sat LANE_FLEET=main LANE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" \
    LANE_LOADAVG="$T/loadavg" LANE_MEMINFO="$T/meminfo" LANE_NPROC=8 LANE_PANES_CMD="cat $T/panes" LANE_DF_CMD="cat $T/df" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/post-box-stats.func.sh"
    do_post_box_stats'
}
out="$(post)"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK box stats of sat recorded"* ]] &&
  jq -s -e '. == [{"box":"sat","load1":2.5,"load5":1.75,"load15":0.47,"cpus":8,"mem_total_kb":16000000,"mem_avail_kb":6000000,"swap_used_kb":600,"agents_live":2,"disks":[{"mount":"/","total_kb":100,"avail_kb":40},{"mount":"/mnt/my data","total_kb":900,"avail_kb":500}]}]' "$T/hub/stats.jsonl" >/dev/null &&
  pass "one sample: load, cpus, memory, swap used, 2 live agents (a dead pane, a shell: not), disks per mount (a space kept, a repeat and a dash row dropped)" || fail "post (rc=$rc): $out / $(cat "$T/hub/stats.jsonl" 2>&1)"
[[ "$(wc -l <"$T/hub/calls")" -eq 1 ]] && pass "...and ONE hub call: no lane read, no BOX-0 row" || fail "calls: $(cat "$T/hub/calls")"
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
