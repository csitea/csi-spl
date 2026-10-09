#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the scheduled box restart on fixtures (stub gh, systemctl, sudo,
# docker and crontab; a fake /proc, ps, registry and desk-cron clone) in a
# mktemp dir.
#   1. do_spl_box_restart_run, the dry run (default): the plan is printed, no
#      runner is stopped, nothing is written, nothing reboots
#   2. a busy runner REFUSES the reboot (DEFER, the drained runners started
#      again); control: every runner idle -> drained, prepared, rebooted
#   2b. the API says idle but a Runner.Worker runs in the unit (the job
#      assignment the API has not reported yet): not stopped, DEFER;
#      control: the same unit without the worker is stopped
#   3. a wf 20 deploy in flight refuses without touching a runner; the wait:
#      a deploy that ends, and a runner that goes idle, within the wait reboot
#   4. do_spl_box_restart_after: the drained runners started (a parked one
#      never), online, do_check_gh_runner, the killed run re-run (another box's run is not), one
#      desk-reconcile pass, the agent check, pending -> .after; control: a
#      docker that does not answer fails it
#   5. do_spl_box_restart_tick: due in the slot window, silent before it, on
#      another day and in a week that has restarted; a pending restart that
#      booted runs the after-boot pass
#   6. do_spl_box_restart_install_cron: one tagged line, idempotent (twice =
#      the same crontab), replaced in place, other lines kept; check and remove
#   7. the cnf's two default slots differ; control: a cnf repeating a slot is
#      refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" P="$T/proc" D="$T/desk" O="$T/origin.git" G="$T/gh" A="$T/active" CG="$T/cgroup"
mkdir -p "$SP/dispatch" "$P" "$T/bin" "$G" "$A" "$T/stub"
printf 'c-901\tclaude\t%%1\t/x\t20261008T000000Z\nc-902\tclaude\t%%2\t/x\t20261008T000000Z\n' >"$SP/registry.tsv"
proc() { mkdir -p "$P/$1"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
boot() { echo "btime $1" >"$P/stat"; }
boot 1000
printf '100 1 claude claude --dangerously-skip-permissions\n200 1 claude claude --resume x\n' >"$T/ps"
proc 100 c-901; proc 200 c-902
gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
W="$O.work"; F=csi-spl-orc/src/bash/run/spl-watchdog.func.sh
gq init "$W"; mkdir -p "$W/${F%/*}"; printf 'spl_wd_boot_pass\nspl_wd_boot_pass\n' >"$W/$F"
gq -C "$W" add -A; gq -C "$W" commit -m one; gq clone --bare "$W" "$O"; gq clone "$O" "$D"
printf '#!/bin/sh\necho "send $*" >>"%s"\n' "$T/sent.log" >"$T/bin/send"; chmod +x "$T/bin/send"

U1=actions.runner.o.box-spl-01.service U2=actions.runner.o.box-spl-02.service
# gh: every call logged; answers from $G (runners.<call n> beats runners)
cat >"$T/stub/gh" <<EOF
#!/bin/bash
echo "gh \$*" >>"$T/calls.log"
case "\$*" in
  "repo view"*) echo o/r ;;
  *"--workflow"*) st=\$(sed -n 's/.*--status \([a-z_]*\).*/\1/p' <<<"\$*"); wf=\$(sed -n 's/.*--workflow \([^ ]*\).*/\1/p' <<<"\$*")
    f="$G/inflight.\$wf.\$st"; [ -f "\$f" ] || exit 0; n=\$(cat "\$f.n" 2>/dev/null || echo 0); echo \$((n + 1)) >"\$f.n"
    [ -f "\$f.once" ] && [ "\$n" -ge 1 ] && exit 0; cat "\$f" ;;
  "api orgs/o/actions/runners"*) n=\$(cat "$G/runners.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$G/runners.n"
    if [ -f "$G/runners.\$n" ]; then cat "$G/runners.\$n"; else cat "$G/runners"; fi ;;
  "run list -R o/r --limit"*) cat "$G/runs" 2>/dev/null ;;
  "api repos/o/r/actions/runs/"*) id=\${2#repos/o/r/actions/runs/}; cat "$G/jobs.\${id%/jobs}" 2>/dev/null ;;
  "run rerun"*) exit 0 ;;
esac
EOF
cat >"$T/stub/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >>"$T/calls.log"
case "\$1" in
  list-units) for u in $U1 $U2; do printf '%s loaded active running x\n' "\$u"; done ;;
  is-active) [ -e "$A/\$3" ] ;;
  stop) rm -f "$A/\$2" ;;
  start) touch "$A/\$2" ;;
  show) u=""; k=""; while [ \$# -gt 0 ]; do case "\$1" in -p) k="\$2"; shift ;; actions.*) u="\$1" ;; esac; shift; done
    case "\$k" in ControlGroup) echo "/sys.slice/\$u" ;; ActiveState) if [ -e "$A/\$u" ]; then echo active; else echo inactive; fi ;; Restart) echo always ;; *) id -un ;; esac ;;
  reboot) echo REBOOTED >>"$T/reboot.log" ;;
esac
EOF
cat >"$T/stub/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
EOF
printf '#!/bin/sh\nexit "$(cat %s 2>/dev/null || echo 0)"\n' "$T/docker.rc" >"$T/stub/docker"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat "%s" 2>/dev/null; else cp "$1" "%s"; fi\n' "$T/crontab" "$T/crontab" >"$T/stub/crontab"
chmod +x "$T/stub/"*

idle() { printf 'box-spl-01\tonline\tfalse\nbox-spl-02\tonline\tfalse\nother-01\tonline\ttrue\n' >"$G/runners"; }
reset() { rm -rf "${CG:?}" "$T/docker.rc" "$T/budget" "$SP/dispatch/box-restart" "$T/reboot.log" "$T/calls.log" "$T/sent.log" "${G:?}"/*; touch "$A/$U1" "$A/$U2"; idle; boot 1000; }
SUN=1791682500
run() {
  local s="$1"; shift
  SNIPPET="$s" in_orc SPOOL_ROOT="$SP" LEASE_PROC_ROOT="$P" BOX_RESTART_PS_CMD="cat $T/ps" BOX_RESTART_DESK="$D" \
    BOX_RESTART_SEND="$T/bin/send" BOX_RESTART_NOW=20261011T013500Z BOX_RESTART_EPOCH="$SUN" BOX_RESTART_REPO=o/r \
    BOX_RESTART_WAIT=0 BOX_RESTART_POLL=0 BOX_RESTART_GRACE=0 BOX_RESTART_RUNNER_WAIT=0 BOX_RESTART_AGENT_WAIT=0 \
    BOX_RESTART_CGROUP_ROOT="$CG" BOX_RESTART_TMUX_CMD="echo 'c-901 x'" CPU_BUDGET_STATE_DIR="$T/budget" SPOOL_AGENT_ID=c-001 "$@" 2>&1
}
BR="$SP/dispatch/box-restart"

# ---- 1. the dry run ---------------------------------------------------------------
reset
out="$(run do_spl_box_restart_run)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$BR" ] && [ ! -e "$T/reboot.log" ] && [ ! -e "$T/sent.log" ] && ! grep -q 'systemctl stop' "$T/calls.log" \
  && [ -e "$A/$U1" ] && pass "1. the dry run stops, writes, sends and reboots nothing" || fail "1. dry run (rc $rc: $out)"
grep -q "PLAN drain $U1" <<<"$out" && grep -q "PLAN drain $U2" <<<"$out" && grep -q 'PLAN sleep 0s.*systemctl reboot' <<<"$out" \
  && grep -q 'OK no deploy' <<<"$out" && pass "1. the plan: deploy check, drain per runner, the reboot" || fail "1. plan ($out)"

# ---- 2. a busy runner refuses; control: idle reboots --------------------------------
reset; printf 'box-spl-01\tonline\tfalse\nbox-spl-02\tonline\ttrue\n' >"$G/runners"
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'DEFER the restart: a runner is still busy' <<<"$out" && [ ! -e "$T/reboot.log" ] && [ ! -e "$BR/pending" ] \
  && [ -s "$BR/20261011T013500Z.deferred" ] && pass "2. a busy runner: DEFER, no reboot" || fail "2. busy (rc $rc: $out)"
grep -q "systemctl stop $U1" "$T/calls.log" && grep -q "systemctl start $U1" "$T/calls.log" && [ -e "$A/$U1" ] \
  && ! grep -q "systemctl stop $U2" "$T/calls.log" && pass "2. the idle runner was drained and started again; the busy one never stopped" || fail "2. runners ($(cat "$T/calls.log"))"
reset
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q REBOOTED "$T/reboot.log" && [ ! -e "$A/$U1" ] && [ ! -e "$A/$U2" ] && [ -f "$BR/20261011T013500Z.before" ] \
  && grep -q 'note to c-902' <<<"$out" && pass "2. control: every runner idle -> drained, prepared, rebooted" || fail "2. control (rc $rc: $out)"
grep -qP '^since\t2026-10-11T01:35:00Z$' "$BR/pending" && grep -qP '^btime\t1000$' "$BR/pending" && [ "$(cat "$BR/last-week")" = 2026-W41 ] \
  && grep -qP "^drained\t$U1 $U2\$" "$BR/pending" && pass "2. pending: since, btime, the drained units; last-week" || fail "2. pending ($(cat "$BR/pending" "$BR/last-week" 2>&1))"

# ---- 2b. idle per the API, a job in the unit: not stopped ----------------------------
# drill 3 (2026-10-09) killed no job, but stop-on-API-idle has this window:
# a job assigned after the API read is cancelled by the stop.
worker() { mkdir -p "$CG/sys.slice/$1" "$P/$2"; printf '901\n%s\n' "$2" >"$CG/sys.slice/$1/cgroup.procs"; echo "$3" >"$P/$2/comm"; }
reset; worker "$U2" 950 Runner.Worker
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'box-spl-02: the API says idle, but a Runner.Worker runs' <<<"$out" && grep -q 'DEFER the restart: a runner is still busy' <<<"$out" \
  && ! grep -q "systemctl stop $U2" "$T/calls.log" && [ -e "$A/$U2" ] && [ ! -e "$T/reboot.log" ] \
  && pass "2b. API idle, a Runner.Worker in the unit: not stopped, DEFER" || fail "2b. worker (rc $rc: $out)"
reset; worker "$U2" 950 Runner.Listener
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q "systemctl stop $U2" "$T/calls.log" && grep -q REBOOTED "$T/reboot.log" \
  && pass "2b. control: only the listener in the unit -> stopped, rebooted" || fail "2b. control (rc $rc: $out)"

# ---- 3. a deploy in flight; the wait --------------------------------------------------
reset; echo 4711 >"$G/inflight.20_hub-build-deploy.yml.in_progress"
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && grep -q 'DEFER.*deploy or terraform' <<<"$out" && grep -q '20_hub-build-deploy.yml in_progress: run(s) 4711' <<<"$out" \
  && [ ! -e "$T/reboot.log" ] && ! grep -q 'systemctl stop' "$T/calls.log" && pass "3. a wf 20 deploy in flight: DEFER, no runner touched" || fail "3. deploy (rc $rc: $out)"
reset; printf 'p\n' >"$T/ps.tf"; cp "$T/ps" "$T/ps.keep"; echo '300 1 terraform terraform apply' >>"$T/ps"
out="$(run do_spl_box_restart_run DRY_RUN=0)"; rc=$?; cp "$T/ps.keep" "$T/ps"
grep -q 'terraform pid 300' <<<"$out" && [ ! -e "$T/reboot.log" ] && pass "3. a terraform run: DEFER" || fail "3. terraform ($out)"
reset; echo 4711 >"$G/inflight.30_wui-build-deploy.yml.queued"; touch "$G/inflight.30_wui-build-deploy.yml.queued.once"
printf 'box-spl-01\tonline\ttrue\nbox-spl-02\tonline\ttrue\n' >"$G/runners.1"
out="$(run do_spl_box_restart_run DRY_RUN=0 BOX_RESTART_WAIT=30)"; rc=$?
[ "$rc" = 0 ] && grep -q 'waiting: deploy 30_wui' <<<"$out" && grep -q '2 runner(s) still busy' <<<"$out" && grep -q REBOOTED "$T/reboot.log" \
  && pass "3. the wait: the deploy ends, the runners go idle, then the reboot" || fail "3. wait (rc $rc: $out)"

# ---- 4. after the boot -------------------------------------------------------------------
after_setup() {
  reset; run do_spl_box_restart_run DRY_RUN=0 >/dev/null; boot 2000; rm -f "$T/calls.log" "$G/runners.n"
  printf '501\n502\n' >"$G/runs"; printf 'box-spl-02\nother-01\n' >"$G/jobs.501"; printf 'other-01\n' >"$G/jobs.502"
  printf '*/3 * * * * echo pass >> %s # csi-spl:desk-reconcile\n# x # csi-spl:desk-reconcile\n0 1 * * * echo no >> %s # other\n' "$T/desk.log" "$T/desk.log" >"$T/crontab"
  rm -f "$T/desk.log" "$T/docker.rc"
}
after_setup
out="$(run do_spl_box_restart_after)"; rc=$?
[ "$rc" = 0 ] && [ -e "$A/$U1" ] && [ -e "$A/$U2" ] && grep -q 'every active runner of this box is online' <<<"$out" && grep -q 'CHECK gh-runner OK: 2 runner' <<<"$out" \
  && pass "4. the drained runners started, online, do_check_gh_runner OK" || fail "4. runners (rc $rc: $out)"
grep -q 'gh run rerun 501' "$T/calls.log" && ! grep -q 'gh run rerun 502' "$T/calls.log" && grep -qP '\trerun\t501\tbox-spl-02\tok$' "$BR/20261011T013500Z.rerun" \
  && [ "$(grep -c . "$BR/20261011T013500Z.rerun")" = 1 ] && pass "4. the killed run is re-run and logged; another box's run is not" || fail "4. rerun ($out)"
[ "$(cat "$T/desk.log" 2>/dev/null)" = pass ] && grep -q 'every id of the snapshot is back' <<<"$out" && [ ! -e "$BR/pending" ] && [ -f "$BR/20261011T013500Z.after" ] \
  && pass "4. one desk-reconcile pass, the agent check, pending -> .after" || fail "4. desk/check ($out; desk: $(cat "$T/desk.log" 2>&1))"
after_setup; echo 1 >"$T/docker.rc"
out="$(run do_spl_box_restart_after)"; rc=$?
[ "$rc" = 1 ] && grep -q 'CHECK gh-runner FAIL' <<<"$out" && grep -q 'does not answer' <<<"$out" && pass "4. control: a dead rootless docker fails the after-boot pass" || fail "4. docker control (rc $rc: $out)"
# a runner the CPU budget parked before the restart: not drained, not started, PARKED is no fault
reset; rm -f "$A/$U2"; mkdir -p "$T/budget"; echo "$U2" >"$T/budget/parked"
run do_spl_box_restart_run DRY_RUN=0 >/dev/null; boot 2000; rm -f "$T/calls.log"; printf '' >"$T/crontab"
out="$(run do_spl_box_restart_after)"; rc=$?
[ "$rc" = 0 ] && grep -qP "^drained\t$U1\$" "$BR/20261011T013500Z.after" && [ -e "$A/$U1" ] && [ ! -e "$A/$U2" ] && ! grep -q "systemctl start $U2" "$T/calls.log" \
  && grep -q 'OK box-spl-02: service PARKED' <<<"$out" && pass "4. a parked runner: not drained, not started, PARKED is OK" || fail "4. parked (rc $rc: $out)"

# ---- 5. the tick -----------------------------------------------------------------------------
AT="0 04:30 Europe/Helsinki"
reset; out="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT")"; rc=$?
[ "$rc" = 0 ] && grep -q 'slot 0 04:30 Europe/Helsinki is due' <<<"$out" && grep -q REBOOTED "$T/reboot.log" && pass "5. Sunday 04:35 in the slot window: the restart" || fail "5. due (rc $rc: $out)"
out="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT" BOX_RESTART_EPOCH=$((SUN + 600)))"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(grep -c . "$T/reboot.log")" = 1 ] && pass "5. pending, not booted yet: the tick waits silently" || fail "5. pending wait (rc $rc: $out)"
rm -f "$BR/pending"; out="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT" BOX_RESTART_EPOCH=$((SUN + 900)))"
[ -z "$out" ] && [ "$(grep -c . "$T/reboot.log")" = 1 ] && pass "5. the week has restarted: no second reboot in the window" || fail "5. last-week ($out)"
reset
out1="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT" BOX_RESTART_EPOCH=1791680400)"; out2="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT" BOX_RESTART_EPOCH=1791768900)"
[ -z "$out1$out2" ] && [ ! -e "$T/reboot.log" ] && pass "5. before the slot and on Monday: nothing, silently" || fail "5. not due ($out1 | $out2)"
reset; run do_spl_box_restart_tick BOX_RESTART_AT="$AT" >/dev/null; boot 3000; printf '' >"$T/crontab"
out="$(run do_spl_box_restart_tick BOX_RESTART_AT="$AT" BOX_RESTART_EPOCH=$((SUN + 600)))"
grep -q 'after the restart 20261011T013500Z' <<<"$out" && [ -f "$BR/20261011T013500Z.after" ] && pass "5. booted: the tick runs the after-boot pass" || fail "5. after tick ($out)"
out="$(run do_spl_box_restart_tick BOX_RESTART_AT='7 04:30 Europe/Helsinki')"; rc=$?
[ "$rc" = 1 ] && grep -q 'FATAL BOX_RESTART_AT' <<<"$out" && pass "5. a bad slot is refused" || fail "5. bad slot (rc $rc: $out)"

# ---- 6. the installer -----------------------------------------------------------------------
SRC="$T/src"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/src/bash/scripts/box-restart-cron.sh"; chmod +x "$SRC/csi-spl-orc/src/bash/scripts/box-restart-cron.sh"
printf '17 * * * * keep-me # mine\n' >"$T/crontab"
inst() { run do_spl_box_restart_install_cron DESK_CRON_SRC="$SRC" DESK_CRON_SELF_UPDATE=0 BOX_RESTART_LOG_DIR="$T/log" "$@"; }
out="$(inst BOX_RESTART_SLOT=0)"
cmp -s "$T/crontab" <(printf '17 * * * * keep-me # mine\n') && grep -q 'PLAN\|crontab diff' <<<"$out" && grep -q "+\*/5 .* --at '0 04:00 Europe/Helsinki'" <<<"$out" \
  && pass "6. the dry run prints the diff and writes nothing" || fail "6. dry ($out)"
inst BOX_RESTART_SLOT=0 DRY_RUN=0 >/dev/null; c1="$(cat "$T/crontab")"; inst BOX_RESTART_SLOT=0 DRY_RUN=0 >/dev/null
[ "$c1" = "$(cat "$T/crontab")" ] && [ "$(grep -c '# csi-spl:box-restart$' "$T/crontab")" = 1 ] && grep -q 'keep-me # mine' "$T/crontab" \
  && pass "6. installed twice = one tagged line, the same crontab, the other line kept" || fail "6. idempotent ($(cat "$T/crontab"))"
grep -qx "\*/5 \* \* \* \* $SRC/csi-spl-orc/src/bash/scripts/box-restart-cron.sh --at '0 04:00 Europe/Helsinki' >> $T/log/box-restart.out 2>&1 # csi-spl:box-restart" "$T/crontab" \
  && pass "6. the line: every 5 min, the script, slot 0 from cnf, the log" || fail "6. line ($(cat "$T/crontab"))"
printf '0 0 * * * first # x\n%s\n9 9 * * * last # y\n' "$(grep box-restart "$T/crontab")" >"$T/crontab"
inst BOX_RESTART_SLOT=1 DRY_RUN=0 >/dev/null
[ "$(sed -n 2p "$T/crontab" | grep -c "04:30 Europe/Helsinki.*# csi-spl:box-restart$")" = 1 ] && [ "$(grep -c box-restart "$T/crontab")" = 1 ] \
  && pass "6. another slot replaces the line in place" || fail "6. in place ($(cat "$T/crontab"))"
out="$(inst BOX_RESTART_CRON_ACTION=check)"; rc=$?
[ "$rc" = 0 ] && grep -q 'is installed and its script is executable' <<<"$out" && pass "6. check: installed" || fail "6. check ($out)"
inst CRON_REMOVE=1 DRY_RUN=0 >/dev/null; out="$(inst BOX_RESTART_CRON_ACTION=check)"; rc=$?
[ "$rc" = 1 ] && ! grep -q box-restart "$T/crontab" && grep -q 'first # x' "$T/crontab" && pass "6. remove: the line is gone (check fails), the rest kept" || fail "6. remove (rc $rc: $(cat "$T/crontab"))"
out="$(inst DRY_RUN=0)"; rc=$?
[ "$rc" = 1 ] && grep -q 'BOX_RESTART_SLOT must be set' <<<"$out" && pass "6. no slot: refused" || fail "6. no slot (rc $rc: $out)"

# ---- 7. the cnf's slots ------------------------------------------------------------------------
s0="$(run 'spl_brx_cron_slot && echo "$SPL_BRX_CRON_AT"' SPL_ORG_APP=csi-spl BOX_RESTART_SLOT=0 | tail -n 1)"
s1="$(run 'spl_brx_cron_slot && echo "$SPL_BRX_CRON_AT"' SPL_ORG_APP=csi-spl BOX_RESTART_SLOT=1 | tail -n 1)"
[ -n "$s0" ] && [ -n "$s1" ] && [ "$s0" != "$s1" ] && [ "${s0%% *}" = "${s1%% *}" ] && pass "7. the two boxes' default slots differ ($s0 / $s1)" || fail "7. slots ($s0 / $s1)"
printf 'env:\n  box:\n    restart:\n      timezone: Europe/Helsinki\n      weekday: 0\n      slots: ["04:00", "04:00"]\n' >"$T/dup.yaml"
out="$(run spl_brx_cron_slot SPL_ORG_APP=csi-spl BOX_RESTART_SLOT=1 BOX_RESTART_CNF="$T/dup.yaml")"; rc=$?
[ "$rc" = 1 ] && grep -q 'repeats 04:00' <<<"$out" && pass "7. control: a cnf repeating a slot is refused" || fail "7. dup (rc $rc: $out)"

echo "box-restart-schedule: $fails failure(s)"
[ "$fails" = 0 ]
