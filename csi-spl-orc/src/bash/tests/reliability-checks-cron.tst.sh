#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 12 checks of the reliability round (spec 146, SPL-4064) are all
# scheduled: 11 as box crons, installed by do_install_box_crons from the rows
# rel-* of cnf/box-crons/box-crons.manifest, row 10 in workflow 45.
#   1. the installer's crontab (the real manifest, a fixture crontab) carries
#      a `csi-spl:box-cron:rel-*` line whose row maps to each of the 11 box
#      actions, and 45_db-backup.yml runs the 12th: all 12 covered
#   2. red control: the same manifest with one rel row dropped -> not covered
#   3. reliability-check-cron.sh runs the row's action from csi-spl-utl with
#      DRY_RUN=0, writes the row's beat for the cron snitch, passes rc 1 on
#   3b. ...sends its notes as this box's orchestrator seat (LEASE_ORCH):
#      spool-send.sh refuses the checks' own <check>@<box> default
#   4. ...refuses an unknown row and an agent worktree; a second run while the
#      first holds the lock exits 0 without running the action
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

REPO="$(cd "$PROJ_ROOT/.." && pwd)"
CHECKS="do_os_systemd_unit_check do_os_reboot_required_check do_net_cert_expiry_check
do_net_external_api_check do_fleet_tmux_health_guard do_fleet_orphan_process_reap
do_docker_test_container_prune do_gh_runner_health_check do_os_clock_sync_check
do_cloud_sql_backup_verify do_cron_heartbeat_snitch do_box_beat_telemetry_check"
WRAP="$PROJ_ROOT/src/bash/scripts/reliability-check-cron.sh"

# every check is a real csi-spl-utl action (a renamed action would leave a
# row calling nothing)
for a in $CHECKS; do
  grep -qE "^$a\(\)" "$REPO"/csi-spl-utl/src/bash/run/*.func.sh || fail "0. $a is no csi-spl-utl action"
done

printf '#!/bin/sh\nif [ "$1" = -l ]; then cat "$CT" 2>/dev/null; else cp "$1" "$CT"; fi\n' >"$T/fake-crontab"; chmod +x "$T/fake-crontab"

# covered <manifest> - install it on an empty fixture crontab; print each of
# the 12 checks that no installed rel line (via its row script and the
# wrapper's row table) nor workflow 45 runs. Empty output = all covered.
covered() {
  local man="$1" ct="$T/crontab.$RANDOM" line script row a got=""
  : >"$ct"
  CT="$ct" SNIPPET='do_install_box_crons' in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_MANIFEST="$man" \
    BOX_CRONS_ALLOW_WORKTREE=1 BOX_CRONS_STATE_DIR="$T/state" DRY_RUN=0 CT="$ct" >"$T/inst.out" 2>&1 \
    || { echo "INSTALL-FAILED"; return; }
  while IFS= read -r line; do
    [[ "$line" =~ /bin/bash\ \'([^\']+)\'.*\#\ csi-spl:box-cron:rel-[a-z0-9-]+$ ]] || continue
    script="${BASH_REMATCH[1]}"
    row="$(sed -n 's/.*reliability-check-cron\.sh" \([a-z0-9-]*\)$/\1/p' "$script")"
    a="$(sed -n "s/^ *$row) *echo \(do_[a-z_]*\) ;;\$/\1/p" "$WRAP")"
    [ -n "$a" ] && got="$got $a"
  done <"$ct"
  grep -q 'run -a do_cloud_sql_backup_verify' "$REPO/.github/workflows/45_db-backup.yml" && got="$got do_cloud_sql_backup_verify"
  for a in $CHECKS; do [[ " $got " == *" $a "* ]] || echo "$a"; done
}

MAN="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
out="$(covered "$MAN")"
[ -z "$out" ] && [ "$(grep -c '^rel-' "$MAN")" = 11 ] \
  && pass "1. the installed crontab carries the 11 box checks and workflow 45 the 12th" \
  || fail "1. not covered: ${out:-none} ($(cat "$T/inst.out"))"

grep -v '^rel-clock-sync ' "$MAN" >"$T/dropped.manifest"
out="$(covered "$T/dropped.manifest")"
[ "$out" = do_os_clock_sync_check ] && pass "2. red control: dropping the rel-clock-sync row is caught" \
  || fail "2. red control not caught (got: '$out')"

# a fake csi-spl-utl: ./run records the action and DRY_RUN; --beat records the beat
U="$T/utl"; mkdir -p "$U/src/bash/run"
cat >"$U/run" <<'EOF'
#!/bin/bash
echo "ran $2 DRY_RUN=$DRY_RUN" >>"$REL_TEST_LOG"; echo "from ${SPOOL_AGENT_ID:-unset}" >>"$REL_TEST_LOG"; [ -n "${REL_TEST_SLEEP:-}" ] && sleep "$REL_TEST_SLEEP"
echo "INFO hidden"; echo "WARN shown"; exit "${REL_TEST_RC:-0}"
EOF
printf '#!/bin/bash\necho "beat $*" >>"$REL_TEST_LOG"\n' >"$U/src/bash/run/cron-heartbeat-snitch.func.sh"
chmod +x "$U/run"
mkdir -p "$T/spool/dispatch"; printf 'LEASE_ORCH=c-001\n' >"$T/spool/dispatch/lease.conf"
wrap() { env -u SPOOL_AGENT_ID REL_CRON_UTL="$U" REL_CRON_ALLOW_WORKTREE=1 REL_CRON_LOCK_DIR="$T/lock" REL_TEST_LOG="$T/run.log" \
  SPOOL_ROOT="$T/spool" "$@" bash "$PROJ_ROOT/src/bash/scripts/rel-clock-sync-cron.sh" 2>&1; }

: >"$T/run.log"; out="$(wrap)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'ran do_os_clock_sync_check DRY_RUN=0' "$T/run.log" && grep -qx 'beat --beat box-cron:rel-clock-sync 0' "$T/run.log" \
  && grep -q 'rel-clock-sync WARN shown' <<<"$out" && ! grep -q hidden <<<"$out" \
  && pass "3. the row runs its action with DRY_RUN=0 and beats rc 0" || fail "3. run (rc $rc: $out; $(cat "$T/run.log"))"
: >"$T/run.log"; out="$(wrap REL_TEST_RC=1)"; rc=$?
[ "$rc" = 1 ] && grep -qx 'beat --beat box-cron:rel-clock-sync 1' "$T/run.log" \
  && pass "3. an alerting check exits 1 and still beats" || fail "3. rc 1 (rc $rc: $out; $(cat "$T/run.log"))"

: >"$T/run.log"; wrap >/dev/null
grep -qx 'from c-001' "$T/run.log" && pass "3b. the notes go out as the box's orchestrator seat (LEASE_ORCH c-001)" \
  || fail "3b. sender ($(cat "$T/run.log"))"
mv "$T/spool/dispatch/lease.conf" "$T/lease.conf.off"; : >"$T/run.log"; out="$(wrap)"
grep -qx 'from unset' "$T/run.log" && grep -q 'WARN no LEASE_ORCH' <<<"$out" \
  && pass "3b. no lease conf: a WARN names the refused notes" || fail "3b. no conf ($out; $(cat "$T/run.log"))"
mv "$T/lease.conf.off" "$T/spool/dispatch/lease.conf"

out="$(bash "$WRAP" nope 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown row 'nope'" <<<"$out" && pass "4. an unknown row is refused" || fail "4. unknown row (rc $rc: $out)"
: >"$T/run.log"; out="$(env -u REL_CRON_ALLOW_WORKTREE REL_CRON_UTL="$U" REL_TEST_LOG="$T/run.log" bash "$PROJ_ROOT/src/bash/scripts/rel-clock-sync-cron.sh" 2>&1)"; rc=$?
case "$PROJ_ROOT" in
  *-wt/*) [ "$rc" = 2 ] && grep -q 'agent worktree' <<<"$out" && [ ! -s "$T/run.log" ] \
            && pass "4. an agent worktree is refused, nothing ran" || fail "4. worktree (rc $rc: $out)" ;;
  *) pass "4. (not in an agent worktree: the refusal is not reachable here)" ;;
esac
: >"$T/run.log"
wrap REL_TEST_SLEEP=3 >/dev/null & first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q ran "$T/run.log" && break; sleep 0.2; done
out="$(wrap)"; rc=$?
wait "$first"
[ "$rc" = 0 ] && grep -q 'another rel-clock-sync run holds' <<<"$out" && [ "$(grep -c '^ran ' "$T/run.log")" = 1 ] \
  && pass "4. a second run while the first holds the lock runs nothing" || fail "4. lock (rc $rc: $out; $(cat "$T/run.log"))"

echo "reliability-checks-cron: ${fails} failure(s)"
[ "$fails" -eq 0 ]
