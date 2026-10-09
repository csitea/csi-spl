#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box-restart pair on fixtures (a fake /proc, ps, registry,
# desk-cron clone and spool-send) in a mktemp dir.
#   1. do_spl_box_restart_prepare: the dry run (default) plans the snapshot and
#      the notes and writes, fetches and sends nothing; an MCP child is not a
#      second session; an id with no registry row is not listed
#   2. DRY_RUN=0 checks the desk-cron out at origin/master, writes the
#      snapshot and sends one note per live agent but the sender; no sender
#      is refused
#   3. do_spl_box_restart_check: every id back once passes; a missing id
#      (control) and a doubled id fail; --resume is counted, the wd BOOT line
#      shown; no snapshot fails
#   4. every kind (drill 5, 2026-10-09): a claude and a mistral seat (comm
#      "Vibe CLI", an MCP node child) are both in the snapshot; the check
#      prints "kinds:" back/before per kind; the mistral seat with no vibe
#      (only its orphan node) is MISSING and the check FAILs; control: both
#      running -> OK
#   5. the drain on a busy trunk (drills 6 and 7, 2026-10-09, DEFERRED): a
#      busy runner that keeps its labels takes the next queued job and never
#      shows idle. The drain takes the custom labels off first (DELETE),
#      waits for the running job to end, then stops the unit (never while
#      busy) and reboots; the labels are kept in <dir>/unlabeled across the
#      reboot and put back (PUT) by the after-boot restore; the dry run
#      touches no label. Control: the DELETE refused -> the runner stays
#      busy, DEFER, the units started again and every label put back
#   6. the reboot logind refuses (drill 7, the desktop box, 2026-10-09: "Call to Reboot
#      failed: Access denied", a desktop box whose GNOME session holds a
#      shutdown BLOCK inhibitor; systemd 257 obeys it even for root): the
#      refused reboot leaves NO last-week (the old code wrote it, so the slot
#      window would skip the week) and no pending; a held block lock DEFERS
#      before the drain and the notes (cnf env.box.restart.inhibitors =
#      respect, the default); ignore reboots past it through PID 1
#      (start reboot.target): a stub systemctl that answers logind's reboot
#      the way the box did in the rerun ("Interactive authentication
#      required", even with --check-inhibitors=no) fails the old command; a delay lock is not a block; the tick writes
#      last-week once the box has booted; gh: the token file when gh is not
#      logged in, the repo from cnf. Control: the success path reboots with
#      the plain command and writes last-week
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" P="$T/proc" D="$T/desk" O="$T/origin.git"
mkdir -p "$SP/dispatch" "$P" "$T/bin"
printf 'c-901\tclaude\t%%1\t/x\t20261008T000000Z\nc-902\tclaude\t%%2\t/x\t20261008T000000Z\tc-001\nc-903\tclaude\t%%3\t/x\t20261008T000000Z\n' >"$SP/registry.tsv"
touch "$SP/dispatch/wd.c-901" "$SP/dispatch/wd.c-902"
# proc PID ID - a fake /proc/<pid>/environ carrying SPOOL_AGENT_ID=<id>
proc() { mkdir -p "$P/$1"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
boot() { echo "btime $1" >"$P/stat"; }
boot 1000
cat >"$T/ps" <<'EOF'
100 1 claude claude --dangerously-skip-permissions
101 100 node node mcp-server
200 1 bash bash launcher
201 200 claude claude --dangerously-skip-permissions
300 1 claude claude
EOF
proc 100 c-901; proc 101 c-901; proc 200 c-902; proc 201 c-902; proc 300 c-999

gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
W="$O.work"; F=csi-spl-orc/src/bash/run/spl-watchdog.func.sh
gq init "$W"; mkdir -p "$W/${F%/*}"; printf 'spl_wd_boot_pass\nspl_wd_boot_pass\n' >"$W/$F"
gq -C "$W" add -A; gq -C "$W" commit -m one; gq clone --bare "$W" "$O"; gq clone "$O" "$D"
echo x >>"$W/$F"; gq -C "$W" commit -am two; gq -C "$W" push "$O" master
head0="$(git -C "$D" rev-parse HEAD)"; head1="$(git -C "$W" rev-parse HEAD)"

printf '#!/bin/sh\necho "send $*" >>"%s"\n' "$T/sent.log" >"$T/bin/send"; chmod +x "$T/bin/send"
run() {
  local s="$1"; shift
  SNIPPET="$s" in_orc SPOOL_ROOT="$SP" LEASE_PROC_ROOT="$P" BOX_RESTART_PS_CMD="cat $T/ps" BOX_RESTART_DESK="$D" \
    BOX_RESTART_SEND="$T/bin/send" BOX_RESTART_NOW=20261008T120000Z SPOOL_AGENT_ID=c-901 "$@" 2>&1
}

# ---- 1. the dry run -------------------------------------------------------------
out="$(run do_spl_box_restart_prepare)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$SP/dispatch/box-restart" ] && [ ! -e "$T/sent.log" ] && [ "$(git -C "$D" rev-parse HEAD)" = "$head0" ] \
  && pass "1. the dry run writes, fetches and sends nothing" || fail "1. dry run (rc $rc: $out)"
grep -qP '^  agent\tc-901\t100\t%1\tclaude$' <<<"$out" && grep -qP '^  agent\tc-902\t201\t%2\tclaude$' <<<"$out" \
  && [ "$(grep -c '  agent' <<<"$out")" = 2 ] && pass "1. one line per live registry id (pid, pane); no MCP child, no unregistered id" || fail "1. agents ($out)"
grep -q 'PLAN note to c-902' <<<"$out" && ! grep -q 'note to c-901' <<<"$out" && pass "1. the notes are planned, never to the sender" || fail "1. notes ($out)"
grep -qP '^  wd\tc-901 c-902$' <<<"$out" && grep -qP '^  btime\t1000$' <<<"$out" && pass "1. btime and the wd verdict list" || fail "1. btime/wd ($out)"

# ---- 2. DRY_RUN=0 -----------------------------------------------------------------
S="$SP/dispatch/box-restart/20261008T120000Z.before"
out="$(run do_spl_box_restart_prepare DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$D" rev-parse HEAD)" = "$head1" ] && [ -z "$(git -C "$D" symbolic-ref -q HEAD)" ] \
  && pass "2. the desk-cron is detached at origin/master" || fail "2. desk (rc $rc: $out)"
[ "$(grep -c '^agent' "$S" 2>/dev/null)" = 2 ] && grep -qP '^desk_sha\t' "$S" && grep -qP '^wd_boot_pass\t2$' "$S" \
  && pass "2. the snapshot is written" || fail "2. snapshot ($(cat "$S" 2>&1))"
[ "$(wc -l <"$T/sent.log")" = 1 ] && grep -q -- '--from c-901 --to c-902 --kind note' "$T/sent.log" \
  && pass "2. one note, to the live agent but the sender" || fail "2. sent ($(cat "$T/sent.log" 2>&1))"
out="$(run do_spl_box_restart_prepare DRY_RUN=0 SPOOL_AGENT_ID= BOX_RESTART_NOW=20261008T110000Z)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no sender' <<<"$out" && pass "2. no sender is refused" || fail "2. no sender (rc $rc: $out)"
rm -f "$SP/dispatch/box-restart/20261008T110000Z.before"

# ---- 3. the check -----------------------------------------------------------------
boot 2000
echo "2026 wd BOOT 2026-10-08T12:05:00Z done: 2 restart(s) started (cause reboot)" >"$SP/dispatch/wd.log"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 0 ] && grep -q 'btime changed: 1000 -> 2000' <<<"$out" && [ "$(grep -c ' back$' <<<"$out")" = 2 ] \
  && pass "3. every id back once: exit 0" || fail "3. all back (rc $rc: $out)"
grep -q 'BOOT .* done: 2 restart' <<<"$out" && grep -q -- '--resume processes: 0' <<<"$out" && pass "3. the wd BOOT line and the --resume count" || fail "3. boot/resume ($out)"
sed -i '/^20[01] /d' "$T/ps"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -qE '^c-902 .*MISSING$' <<<"$out" && grep -q 'ids missing: c-902$' <<<"$out" \
  && pass "3. control: a missing id turns the check red" || fail "3. missing (rc $rc: $out)"
echo "201 1 claude claude --resume abc" >>"$T/ps"; echo "202 1 claude claude" >>"$T/ps"; proc 202 c-902
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -qE '^c-902 .*DOUBLED \(2 processes\)$' <<<"$out" && grep -q -- '--resume processes: 1' <<<"$out" \
  && pass "3. a doubled id turns it red; --resume is counted" || fail "3. doubled (rc $rc: $out)"
rm -rf "$SP/dispatch/box-restart"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no snapshot' <<<"$out" && pass "3. no snapshot: exit 1" || fail "3. no snapshot (rc $rc: $out)"

# ---- 4. every kind: a claude and a mistral seat ---------------------------------
SP4="$T/spool4"; mkdir -p "$SP4/dispatch"; S4="$SP4/dispatch/box-restart/20261009T070000Z.before"
printf 'c-911\tclaude\t%%11\t/x\t20261009T000000Z\nm-912\tmistral\t%%12\t/x\t20261009T000000Z\n' >"$SP4/registry.tsv"
cat >"$T/ps4" <<'EOF'
400 1 claude claude --dangerously-skip-permissions
500 1 Vibe CLI Vibe CLI
501 500 node node mcp-server
EOF
proc 400 c-911; proc 500 m-912; proc 501 m-912; boot 3000
run4() { run "$1" SPOOL_ROOT="$SP4" BOX_RESTART_PS_CMD="cat $T/ps4" BOX_RESTART_NOW=20261009T070000Z "${@:2}"; }
out="$(run4 do_spl_box_restart_prepare)"
grep -qP '^  agent\tc-911\t400\t%11\tclaude$' <<<"$out" && grep -qP '^  agent\tm-912\t500\t%12\tvibe$' <<<"$out" \
  && [ "$(grep -c '  agent' <<<"$out")" = 2 ] && grep -q 'PLAN note to m-912' <<<"$out" \
  && pass "4. the snapshot lists the claude AND the mistral seat (vibe, not its node child)" || fail "4. kinds snapshot ($out)"
run4 do_spl_box_restart_prepare DRY_RUN=0 >/dev/null
[ "$(grep -c '^agent' "$S4" 2>/dev/null)" = 2 ] && pass "4. the written snapshot has both seats" || fail "4. snapshot ($(cat "$S4" 2>&1))"
boot 4000
out="$(run4 do_spl_box_restart_check)"; rc=$?
[ "$rc" = 0 ] && grep -q 'kinds: claude 1/1 mistral 1/1$' <<<"$out" && grep -qE '^m-912 .* back$' <<<"$out" \
  && pass "4. control: both kinds running -> OK, kinds: claude 1/1 mistral 1/1" || fail "4. both back (rc $rc: $out)"
printf '400 1 claude claude --resume abc\n501 1 node node mcp-server\n' >"$T/ps4"
out="$(run4 do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -qE '^m-912 .*MISSING$' <<<"$out" && grep -q 'FAIL ids missing: m-912$' <<<"$out" \
  && grep -q 'kinds: claude 1/1 mistral 0/1$' <<<"$out" && grep -qE '^c-911 .* back$' <<<"$out" \
  && pass "4. the mistral seat with no vibe (a stray node only) FAILs, kinds: claude 1/1 mistral 0/1" || fail "4. no vibe (rc $rc: $out)"

# ---- 5. the drain on a busy trunk ------------------------------------------------
# Stubs: gh (runner 12 is busy while it has its labels: it takes the next
# queued job; once they are off it ends its job two reads later), systemctl,
# sudo and the reboot. Every call is logged in calls5.log, with each read's
# busy flag of runner 12, so the order "idle, then stopped" is checkable.
S5="$T/s5" G5="$T/g5" A5="$T/active5" L5="$T/calls5.log"; BR5="$SP/dispatch/box-restart"
V1=actions.runner.o.box-spl-01.service V2=actions.runner.o.box-spl-02.service
mkdir -p "$S5" "$G5" "$A5"
cat >"$S5/gh" <<EOF
#!/bin/bash
echo "gh \$*" >>"$L5"
case "\$*" in
  "api orgs/o/actions/runners --paginate"*) n=\$(( \$(cat "$G5/n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$G5/n"
    l1=spool-ci; [ -f "$G5/off.11" ] && l1=""; l2=spool-ci; b2=true
    if [ -f "$G5/off.12" ]; then l2=""; [ "\$n" -gt \$(( \$(cat "$G5/off.12") + 1 )) ] && b2=false; fi
    echo "read \$n runner 12 busy=\$b2" >>"$L5"
    printf 'box-spl-01\tonline\tfalse\t11\t%s\nbox-spl-02\tonline\t%s\t12\t%s\nother-01\tonline\ttrue\t13\tspool-ci\n' "\$l1" "\$b2" "\$l2" ;;
  "api -X DELETE orgs/o/actions/runners/"*) [ -f "$G5/deny.\$(cut -d/ -f5 <<<"\$4")" ] && exit 1
    id=\$(cut -d/ -f5 <<<"\$4"); cat "$G5/n" >"$G5/off.\$id" ;;
  "api -X PUT orgs/o/actions/runners/"*) id=\$(cut -d/ -f5 <<<"\$4"); echo "put \$id \$(cat)" >>"$L5"; rm -f "$G5/off.\$id" ;;
esac
EOF
cat >"$S5/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >>"$L5"
case "\$1" in
  list-units) for u in $V1 $V2; do printf '%s loaded active running x\n' "\$u"; done ;;
  is-active) [ -e "$A5/\$3" ] ;;
  stop) rm -f "$A5/\$2" ;;
  start) touch "$A5/\$2" ;;
esac
EOF
printf '#!/bin/bash\nwhile [ "$1" = -n ]; do shift; done\nexec "$@"\n' >"$S5/sudo"
printf '#!/bin/sh\necho "REBOOTED $*" >>"%s"\n' "$T/reboot5.log" >"$S5/reboot"
chmod +x "$S5/"*
reset5() { rm -rf "$BR5" "$L5" "$T/reboot5.log" "${G5:?}"/*; touch "$A5/$V1" "$A5/$V2"; boot 1000; cp "$T/ps.base" "$T/ps"; }
cp "$T/ps" "$T/ps.base"
printf '100 1 claude claude --dangerously-skip-permissions\n201 1 claude claude\n' >"$T/ps.base"; proc 201 c-902
run5() {
  run "$1" PATH="$S5:$PATH" BOX_RESTART_REPO=o/r BOX_RESTART_SYSTEMCTL="$S5/reboot" \
    BOX_RESTART_WAIT=3 BOX_RESTART_POLL=0 BOX_RESTART_GRACE=0 BOX_RESTART_CGROUP_ROOT="$T/nocg" \
    BOX_RESTART_INHIBITORS_CMD="cat $T/locks.json" "${@:2}"
}
# no inhibitor but the delay locks every box has
LOCK_DELAY='["sleep","NetworkManager","NetworkManager needs to turn off networks","delay",0,1177]'
LOCK_BLOCK='["shutdown","dev-user","user session inhibited","block",1000,391047]'
locks_set() { local IFS=,; printf '{"type":"a(ssssuu)","data":[[%s]]}\n' "$*" >"$T/locks.json"; }
locks_set "$LOCK_DELAY"
# stopped_while_busy: 0 when runner 12's last read before its stop said busy
stopped_while_busy() { awk -v u="systemctl stop $V2" '/runner 12 busy=/ {b = $NF} $0 == u {exit b == "busy=true" ? 0 : 1} END {exit 1}' "$L5"; }

reset5; out="$(run5 do_spl_box_restart_run)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'gh api -X' "$L5" 2>/dev/null && ! grep -q 'systemctl stop' "$L5" 2>/dev/null && [ ! -e "$BR5" ] \
  && grep -q "PLAN drain $V2: take its custom labels off" <<<"$out" && pass "5. the dry run plans the label-off drain and touches no label" || fail "5. dry (rc $rc: $out)"
reset5; out="$(run5 do_spl_box_restart_run DRY_RUN=0)"; rc=$?
n5="$(cat "$G5/n" 2>/dev/null)"
[ "$rc" = 0 ] && grep -q REBOOTED "$T/reboot5.log" 2>/dev/null && ! ls "$BR5"/*.deferred >/dev/null 2>&1 \
  && grep -q 'gh api -X DELETE orgs/o/actions/runners/12/labels' "$L5" && grep -q 'gh api -X DELETE orgs/o/actions/runners/11/labels' "$L5" \
  && ! grep -q 'runners/13/labels' "$L5" && pass "5. a busy runner: labels off, its job ends, drained, rebooted (API reads: $n5)" || fail "5. busy trunk (rc $rc: $out)"
grep -q "systemctl stop $V2" "$L5" && ! stopped_while_busy && [ ! -e "$A5/$V2" ] \
  && pass "5. the busy runner is stopped only after the API read it idle (no job killed)" || fail "5. stop order ($(cat "$L5"))"
[ "$(grep -c . "$BR5/unlabeled" 2>/dev/null)" = 2 ] && grep -qP '^o\tbox-spl-02\t12\tspool-ci$' "$BR5/unlabeled" && [ -f "$BR5/pending" ] \
  && ! grep -q 'gh api -X PUT' "$L5" && pass "5. the labels are kept in <dir>/unlabeled across the reboot, none put back yet" || fail "5. unlabeled ($(cat "$BR5/unlabeled" 2>&1))"
out="$(run5 'spl_brx_labels_restore "$SPOOL_ROOT/dispatch/box-restart"')"; rc=$?
[ "$rc" = 0 ] && grep -q 'put 12 {"labels":\["spool-ci"\]}' "$L5" && grep -q 'put 11 {"labels":\["spool-ci"\]}' "$L5" && [ ! -e "$BR5/unlabeled" ] \
  && pass "5. the after-boot restore puts both runners' labels back and drops the file" || fail "5. restore (rc $rc: $out)"
reset5; touch "$G5/deny.12"; out="$(run5 do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'DEFER the restart: a runner is still busy' <<<"$out" && [ ! -e "$T/reboot5.log" ] && grep -q 'box-spl-02: could not take its labels' <<<"$out" \
  && ! grep -q "systemctl stop $V2" "$L5" && pass "5. control: the DELETE refused -> the runner keeps taking jobs, DEFER (API reads: $(cat "$G5/n"))" || fail "5. control (rc $rc: $out)"
[ -e "$A5/$V1" ] && grep -q "systemctl start $V1" "$L5" && grep -q 'put 11 ' "$L5" && grep -q 'put 12 ' "$L5" && [ ! -e "$BR5/unlabeled" ] \
  && pass "5. control: the defer starts the drained unit again and puts every label back" || fail "5. control restore ($(cat "$L5"))"

# ---- 6. the reboot logind refuses ------------------------------------------------
W6="$(TZ=UTC date +%G-W%V)"
printf '#!/bin/sh\necho "DENIED $*" >>"%s"\necho "Call to Reboot failed: Access denied" >&2\nexit 1\n' "$T/reboot5.log" >"$S5/reboot-denied"
chmod +x "$S5/reboot-denied"
reset5; out="$(run5 do_spl_box_restart_run DRY_RUN=0 BOX_RESTART_SYSTEMCTL="$S5/reboot-denied")"; rc=$?
[ "$rc" = 1 ] && grep -q 'Access denied' <<<"$out" && grep -q 'ERROR the reboot command failed' <<<"$out" && grep -q 'DENIED reboot$' "$T/reboot5.log" \
  && [ ! -e "$BR5/last-week" ] && [ ! -e "$BR5/pending" ] && [ -e "$A5/$V1" ] && [ -e "$A5/$V2" ] \
  && pass "6. a refused reboot (Access denied) writes no last-week, no pending; the runners run again" || fail "6. denied (rc $rc: $out; last-week: $(cat "$BR5/last-week" 2>&1))"
reset5; out="$(run5 do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/reboot5.log")" = "REBOOTED reboot" ] && [ "$(cat "$BR5/last-week" 2>/dev/null)" = "$W6" ] && [ -f "$BR5/pending" ] \
  && pass "6. control: success reboots with the plain command (delay locks only), last-week $W6, pending kept" || fail "6. success (rc $rc: $out; $(cat "$T/reboot5.log" 2>&1))"
locks_set "$LOCK_DELAY" "$LOCK_BLOCK"
reset5; : >"$T/sent.log"; out="$(run5 do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'DEFER the restart: a shutdown block inhibitor is held: dev-user (user session inhibited; uid 1000 pid 391047)' <<<"$out" \
  && [ ! -e "$T/reboot5.log" ] && [ ! -s "$T/sent.log" ] && ! grep -q 'systemctl stop' "$L5" 2>/dev/null && ! grep -q 'gh api -X' "$L5" 2>/dev/null \
  && [ ! -e "$BR5/last-week" ] && ls "$BR5"/*.deferred >/dev/null 2>&1 \
  && pass "6. a held block lock (respect, the cnf default) DEFERS before the drain and the notes; no last-week" || fail "6. respect (rc $rc: $out)"
reset5; out="$(run5 do_spl_box_restart_run)"; rc=$?
[ "$rc" = 0 ] && grep -q 'PLAN DEFER here, before the drain and the notes: a shutdown block inhibitor is held' <<<"$out" && [ ! -e "$BR5" ] \
  && pass "6. the dry run names the lock it would defer on" || fail "6. dry respect (rc $rc: $out)"
# the box in the rerun: logind refuses every reboot past the lock, even
# root's with --check-inhibitors=no (polkit ALWAYS_CHECK); PID 1 does not ask
cat >"$S5/reboot-locked" <<EOF
#!/bin/sh
case "\$1" in
  reboot) echo "DENIED \$*" >>"$T/reboot5.log"; echo "Call to Reboot failed: Interactive authentication required." >&2; exit 1 ;;
  start) echo "REBOOTED \$*" >>"$T/reboot5.log" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$S5/reboot-locked"
reset5; out="$(run5 do_spl_box_restart_run DRY_RUN=0 BOX_RESTART_INHIBITORS=ignore BOX_RESTART_SYSTEMCTL="$S5/reboot-locked")"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/reboot5.log" 2>/dev/null)" = "REBOOTED start reboot.target --job-mode=replace-irreversibly --no-block" ] \
  && grep -q 'WARN a shutdown block inhibitor is held' <<<"$out" && [ "$(cat "$BR5/last-week" 2>/dev/null)" = "$W6" ] \
  && pass "6. ignore reboots past the lock through PID 1 (start reboot.target), not logind's refused reboot" || fail "6. ignore (rc $rc: $out; $(cat "$T/reboot5.log" 2>&1))"
reset5; out="$(run5 do_spl_box_restart_run DRY_RUN=0 BOX_RESTART_SYSTEMCTL="$S5/reboot-locked")"; rc=$?
[ "$rc" = 0 ] && grep -q 'DEFER the restart: a shutdown block inhibitor is held' <<<"$out" && [ ! -e "$T/reboot5.log" ] \
  && pass "6. control: respect with the same lock still defers, nothing reboots" || fail "6. respect control (rc $rc: $out)"
reset5; out="$(run5 do_spl_box_restart_run BOX_RESTART_INHIBITORS=force)"; rc=$?
[ "$rc" = 1 ] && grep -q 'must be respect or ignore' <<<"$out" && pass "6. any other inhibitors value is refused" || fail "6. bad value (rc $rc: $out)"
locks_set "$LOCK_DELAY"
reset5; mkdir -p "$BR5"; printf 'utc\t20261008T120000Z\nweek\t%s\nbtime\t999\n' "$W6" >"$BR5/pending"
out="$(run5 'do_spl_box_restart_after() { echo AFTER; }; do_spl_box_restart_tick' BOX_RESTART_AT='0 04:00 UTC')"; rc=$?
[ "$rc" = 0 ] && grep -q AFTER <<<"$out" && [ "$(cat "$BR5/last-week" 2>/dev/null)" = "$W6" ] \
  && pass "6. the tick writes last-week once the box has booted" || fail "6. tick (rc $rc: $out)"
S6="$T/s6"; mkdir -p "$S6"; printf '#!/bin/sh\n[ "$1" = auth ] && exit 1\nexit 0\n' >"$S6/gh"; chmod +x "$S6/gh"
echo tok-6 >"$T/token6"; repo6="$(yq -r '.env.steps."017-github-wif-deploy".github_repository' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
out="$(run 'spl_brx_conf && echo "repo=$SPL_BRX_REPO tok=$GH_TOKEN mode=$SPL_BRX_INHIBIT"' PATH="$S6:$PATH" GH_TOKEN= BOX_RESTART_REPO= \
  BOX_RESTART_GH_TOKEN_FILE="$T/token6" BOX_RESTART_INHIBITORS=)"; rc=$?
[ "$rc" = 0 ] && [ -n "$repo6" ] && grep -qx "repo=$repo6 tok=tok-6 mode=respect" <<<"$out" \
  && pass "6. gh not logged in: GH_TOKEN from the token file; the repo and inhibitors=respect from cnf" || fail "6. conf (rc $rc: $out)"

echo "box-restart: ${fails} failure(s)"
[ "$fails" -eq 0 ]
