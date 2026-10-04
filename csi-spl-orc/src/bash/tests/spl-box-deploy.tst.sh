#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_deploy (specs/071 section 5.3, lane B) with stub
# installers, a stub crontab, a stub spl_host_spool and a stub do_spl_pool_ctl
# (its section 4 contract). Every check has a failing control: the same
# assertion run on an input that must make it fail.
#   1. the dry run (default) plans every step and changes nothing
#   2. install: one line per tag, the binary built, the pool started, status ok
#   3. install twice: one line per tag still, and the run says nothing changed
#   4. a missing tool is refused and named; nothing is called
#   5. a worktree APP_PATH is refused; nothing is called
#   6. a missing key is refused and named, its body never printed
#   7. a missing ENV fails fast and names it
#   8. a failing installer stops the run and is named
#   9. a stopped row after start fails the install
#  10. remove: pool stopped, no csi-spl: line left, other lines kept
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

APP="$T/app"
git init -q -b master "$APP" && git -C "$APP" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
mkdir -p "$T/spool" "$T/state/dev"
printf 'SECRET-KEY-BODY\n' >"$T/key.json"
CT="$T/crontab"
printf '0 8 * * * /opt/other/run-me.sh # other:job\n' >"$CT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
TAGS="desk-reconcile unanswered-sweep orch-rotate dispatch-rotate agent-id-reap agent-identity-reconcile agent-boot-restore box-cron:box-save-sessions weekly-full-scan box-update"

# the stubs: each installer records its call and, on DRY_RUN=0, puts (or
# drops) one tagged line, replaced in place as the real ones do
STUBS='
inst() { local tag="$1" act="$2"; echo "installer $tag $act DRY_RUN=$DRY_RUN" >>"$STUB_LOG"
  [[ -n "${STUB_FAIL:-}" && "$STUB_FAIL" == "$tag" ]] && return 1
  [[ "$DRY_RUN" == 0 ]] || return 0
  grep -v " # csi-spl:$tag\$" "$CT" >"$CT.n"; [[ "$act" == install ]] && echo "* * * * * x # csi-spl:$tag" >>"$CT.n"; mv "$CT.n" "$CT"; }
do_spl_desk_install_service() { inst desk-reconcile "$DESK_SERVICE_ACTION"; }
do_spl_unanswered_sweep_install_cron() { inst unanswered-sweep "$SWEEP_CRON_ACTION"; }
do_spl_orch_rotate_install_cron() { inst orch-rotate "$ROTATE_CRON_ACTION"; }
do_spl_dispatch_rotate_install_cron() { inst dispatch-rotate "$ROTATE_CRON_ACTION"; }
do_spl_agent_id_reap_install_cron() { inst agent-id-reap "$REAP_CRON_ACTION"; }
do_spl_agent_identity_install() { inst agent-identity-reconcile "$([[ $IDENTITY_UNINSTALL == 1 ]] && echo remove || echo install)"; }
do_spl_agent_boot_restore_install_cron() { inst agent-boot-restore "$BOOT_CRON_ACTION"; }
do_install_box_crons() { inst box-cron:box-save-sessions "$BOX_CRONS_ACTION"; }
do_install_weekly_full_scan_cron() { inst weekly-full-scan "$WEEKLY_SCAN_CRON_ACTION"; }
do_spl_box_update_install_cron() { inst box-update "$BOX_UPDATE_CRON_ACTION"; }
do_spl_cloud_cnf() { SPL_ORG_APP=csi-spl; SPL_CNF="$SPL_STATE_DIR/dev.env.yaml"; }
spl_host_spool_verdict() { [[ -x "$1" ]] && echo "keep built from HEAD" || echo "build no binary yet"; }
spl_host_spool() { echo "spl_host_spool" >>"$STUB_LOG"; SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  [[ -x "$SPL_SPOOL" ]] && return 0; mkdir -p "$SPL_STATE_DIR/bin"; printf "#!/bin/sh\n" >"$SPL_SPOOL"; chmod +x "$SPL_SPOOL"; echo "abc clean" >"$SPL_SPOOL.src"; }
do_spl_pool_ctl() { echo "pool $POOL_CMD DRY_RUN=$DRY_RUN" >>"$STUB_LOG"
  case "$POOL_CMD" in
    start) [[ "$DRY_RUN" == 1 ]] || touch "$T/pool.up" ;;
    stop) [[ "$DRY_RUN" == 1 ]] || rm -f "$T/pool.up" ;;
    status) local s; s=$([[ -e "$T/pool.up" ]] && echo running || echo stopped)
      echo "desk:t1/box-desk $s pid 1"; echo "lease $([[ -n "${STUB_LEASE_DOWN:-}" ]] && echo stopped || echo "$s") fleet"
      echo "pool-serve missing not built yet (spec 070 L3)" ;;
  esac; }
'
dep() {
  SNIPPET="$STUBS do_spl_box_deploy" in_orc APP_PATH="$APP" CT="$CT" T="$T" SPOOL_TEST=1 SPOOL_ROOT="$T/spool" \
    BOX_DEPLOY_CRONTAB="$T/fake-crontab" BOX_DEPLOY_TOOLS="bash git" BOX_DEPLOY_KEY="$T/key.json" USER=tester "$@" 2>&1
}
# one_per_tag <crontab>: every tag of $TAGS exactly once
one_per_tag() { local t; for t in $TAGS; do [ "$(grep -c " # csi-spl:$t\$" "$1")" = 1 ] || return 1; done; }
calls() { cat "$T/calls.log" 2>/dev/null; }
reset_calls() { : >"$T/calls.log"; }

# 1. dry run
reset_calls; cp "$CT" "$T/ct.0"
out="$(dep BOX_DEPLOY_CMD=install)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$CT" "$T/ct.0" && [ ! -e "$T/state/dev/bin/spool" ] && ! grep -q 'DRY_RUN=0' "$T/calls.log" \
  && pass "1. the dry run changes nothing and calls nothing with DRY_RUN=0" || fail "1. dry run (rc $rc: $out)"
[ "$(grep -c '^PLAN installer ' <<<"$out")" = 10 ] && grep -q '^PLAN binary: spl_host_spool' <<<"$out" && grep -q '^PLAN pool: .*POOL_CMD=start' <<<"$out" \
  && pass "1. ...and plans every step (binary, 10 installers, pool start)" || fail "1. plan ($out)"
grep -q 'DRY_RUN=0' <<<"installer x install DRY_RUN=0" && pass "1. control: the DRY_RUN=0 detector fires on a live call" || fail "1. control"

# 2. install
reset_calls
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && one_per_tag "$CT" && grep -q 'other:job' "$CT" && pass "2. install: one line per tag, the other line kept" || fail "2. install (rc $rc: $out; $(cat "$CT"))"
grep -q '^spl_host_spool$' "$T/calls.log" && grep -q '^pool start DRY_RUN=0$' "$T/calls.log" && grep -q 'OK pool status: every row' <<<"$out" \
  && grep -q '^DONE changed' <<<"$out" && pass "2. ...the binary built, the pool started, status all running" || fail "2. steps ($(calls); $out)"
[ "$(grep -n -m1 'spl_host_spool' "$T/calls.log" | cut -d: -f1)" -lt "$(grep -n -m1 installer "$T/calls.log" | cut -d: -f1)" ] \
  && pass "2. ...the binary is built before the crons are installed" || fail "2. order ($(calls))"
printf '%s\n' "$(cat "$CT")" "* * * * * y # csi-spl:orch-rotate" >"$T/ct.dup"
one_per_tag "$T/ct.dup" && fail "2. control: one_per_tag accepted a duplicated tag" || pass "2. control: one_per_tag rejects a duplicated tag"

# 3. install twice
cp "$CT" "$T/ct.1"; reset_calls
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && one_per_tag "$CT" && cmp -s "$CT" "$T/ct.1" && grep -q '^OK nothing changed' <<<"$out" \
  && pass "3. a second install: one line per tag, and it says nothing changed" || fail "3. second install (rc $rc: $out)"
grep -v 'csi-spl:weekly-full-scan$' "$T/ct.1" >"$CT"
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0)"
grep -q '^DONE changed' <<<"$out" && one_per_tag "$CT" && pass "3. control: a box missing one line is changed, and says so" || fail "3. control ($out)"

# 4. missing tool
reset_calls; cp "$CT" "$T/ct.2"
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0 BOX_DEPLOY_TOOLS="bash no-such-tool-x")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'PREREQ tools missing no-such-tool-x' <<<"$out" && grep -q 'missing prerequisite(s): tools' <<<"$out" \
  && [ ! -s "$T/calls.log" ] && cmp -s "$CT" "$T/ct.2" && pass "4. a missing tool is refused and named, nothing called" || fail "4. tool (rc $rc: $out; $(calls))"
out="$(dep BOX_DEPLOY_CMD=install BOX_DEPLOY_TOOLS="bash no-such-tool-x")"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^PLAN installer weekly-full-scan' <<<"$out" && grep -q 'DRY_RUN=0 run refuses: missing tools' <<<"$out" \
  && pass "4. ...the dry run still plans every step, names it and exits non-zero" || fail "4. dry-run tool (rc $rc: $out)"
out="$(dep BOX_DEPLOY_CMD=check)"
grep -q 'PREREQ tools ok bash git' <<<"$out" && pass "4. control: the same check passes with every tool present" || fail "4. control ($out)"

# 5. worktree APP_PATH
git -C "$APP" worktree add -q --detach "$T/app-wt" 2>/dev/null
reset_calls
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0 APP_PATH="$T/app-wt")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'PREREQ checkout missing .* is a linked worktree' <<<"$out" && [ ! -s "$T/calls.log" ] \
  && pass "5. a worktree APP_PATH is refused, nothing called" || fail "5. worktree (rc $rc: $out)"
out="$(dep BOX_DEPLOY_CMD=check)"
grep -q "PREREQ checkout ok $APP on master" <<<"$out" && pass "5. control: the main checkout on master passes" || fail "5. control ($out)"

# 6. missing key
reset_calls
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0 BOX_DEPLOY_KEY="$T/no-key.json")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "PREREQ key missing $T/no-key.json" <<<"$out" && [ ! -s "$T/calls.log" ] \
  && pass "6. a missing key is refused and named" || fail "6. key (rc $rc: $out)"
out="$(dep BOX_DEPLOY_CMD=check)"
grep -q 'PREREQ key ok' <<<"$out" && ! grep -q SECRET-KEY-BODY <<<"$out" \
  && pass "6. control: a present key passes, and its body is never printed" || fail "6. control ($out)"

# 7. missing ENV
out="$(dep ENV= BOX_DEPLOY_CMD=install)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FATAL ENV must be set' <<<"$out" && pass "7. a missing ENV fails fast and is named" || fail "7. ENV ($out)"
out="$(dep ENV=stg BOX_DEPLOY_CMD=install)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "ENV must be dev or prd" <<<"$out" && pass "7. control: a set but wrong ENV is refused by the cloud-env rule" || fail "7. control ($out)"

# 8. failing installer
reset_calls
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0 STUB_FAIL=agent-id-reap)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FATAL installer agent-id-reap (install) failed' <<<"$out" && ! grep -q 'agent-boot-restore\|^pool' "$T/calls.log" \
  && pass "8. a failing installer stops the run and is named" || fail "8. installer fail (rc $rc: $out; $(calls))"
reset_calls; dep BOX_DEPLOY_CMD=install DRY_RUN=0 >/dev/null
grep -q 'agent-boot-restore' "$T/calls.log" && pass "8. control: without the failure the later installers run" || fail "8. control ($(calls))"

# 9. a stopped row after start
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0 STUB_LEASE_DOWN=1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FAIL pool status: not running after start: lease' <<<"$out" && ! grep -q 'not running.*pool-serve' <<<"$out" \
  && pass "9. a stopped row fails the install, a missing row does not" || fail "9. status (rc $rc: $out)"
out="$(dep BOX_DEPLOY_CMD=install DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && pass "9. control: all running exits 0" || fail "9. control (rc $rc: $out)"

# 10. remove
reset_calls
out="$(dep BOX_DEPLOY_CMD=remove DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '# csi-spl:' "$CT" && grep -q 'other:job' "$CT" && grep -q '^pool stop DRY_RUN=0$' "$T/calls.log" \
  && [ "$(head -1 "$T/calls.log")" = "pool stop DRY_RUN=0" ] && [ -e "$T/state/dev/bin/spool" ] \
  && pass "10. remove: pool stopped first, no csi-spl: line left, other line and binary kept" || fail "10. remove (rc $rc: $out; $(cat "$CT"))"
grep -q '# csi-spl:' "$T/ct.1" && pass "10. control: the no-csi-spl-line check fires on a deployed crontab" || fail "10. control"
out="$(dep BOX_DEPLOY_CMD=remove DRY_RUN=0)"
grep -q '^OK nothing changed' <<<"$out" && pass "10. a second remove changes nothing" || fail "10. second remove ($out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
