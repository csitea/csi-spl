#!/usr/bin/env bash
# test-spawn-hub-dns.sh — HUB DNS (SPL-4253, drill finding #5 on a box,
# 2026-10-29): the box that launches resolves the hub API host BEFORE any id
# claim. Then c-660 and c-696 were each refused at the lane issue step
# (exit 12, "lookup <hub host>: i/o timeout") on a box the bench read healthy.
# No live launch, no DNS: the resolver (SPAWN_HUB_DNS_CMD) and the issue step
# (SPAWN_ISSUE_CMD) are stubs that log each call.
#   1. the resolver fails on this box -> exit 14, one line naming the box,
#      the host and the reason; nothing claimed, the issue step never runs.
#      CONTROL (today's code: a copy with the check cut out): the same spawn
#      claims the id and runs the issue step (exit 12 there, the incident)
#   2. resolves -> on to the issue step; cannot judge (`unknown`, or the
#      probe itself failed) -> a WARN, still on to the issue step
#   3. skipped: a dry run, a respawn (SPAWN_REUSE_ID=1), no fleet
#   4. RE-PICK: the load target picks box-b, box-b's own spawn-window refuses
#      (its reply exit 4, the DNS line) -> the requester re-picks this box
#      after the same check here: here resolves -> on to the issue step here;
#      here fails too -> exit 14 (the placer puts the row back in line)
#   5. the default resolver is the uplink action's dns mode with the lease's
#      env (the stubbed run sees UPLINK_PROBE_CMD=dns ENV=prd)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
unset LEASE_MACHINE LANE_FLEET LANE_ENV SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK_CMD \
  SPAWN_ORC_RUN SPAWN_ISSUE SPAWN_ISSUE_CREATE SPAWN_ISSUE_CMD SPAWN_REUSE_ID SPAWN_LANE_TOPIC REPORT_TO SPAWN_HUB_DNS_CMD
export SPOOL_BIN=/opt/x/spool SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' SPAWN_START_CHECK=0
export SPOOL_DESK_BOX=box-a SPOOL_VENDOR_CLIS_CMD="echo claude"
mkdir -p "$SPOOL_ROOT/dispatch" "$T_TMP/bin"
printf '%s\n' LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 LEASE_ORCH=c-001 LEASE_FLEET=main LEASE_ENV=prd \
  LEASE_PRIORITY=box-a,box-b >"$SPOOL_ROOT/dispatch/lease.conf"
echo "c-001@box-a 1" >"$SPOOL_ROOT/dispatch/lease.orch"

R="$T_TMP/repo"
git init -q --bare "$T_TMP/origin.git"
git init -q -b master "$R"
git -C "$R" -c user.name='FirstName LastName' -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$R" remote add origin "$T_TMP/origin.git"
printf '# Brief: fix the widget\n\nIssue: SPL-77\n\n## Task\nDo it.\n' >"$T_TMP/key.md"

L="$T_TMP/calls"
B="$T_TMP/bin"
# the issue step as the incident saw it: the hub lookup times out
printf '#!/bin/sh\necho "issue $AGENT_ID" >>"%s"\necho "FATAL spool issue create for $AGENT_ID: lookup hub.invalid: i/o timeout"\nexit 1\n' "$L" >"$B/issue"
dns() {  # NAME LINE RC: a resolver stub that logs its call
  printf '#!/bin/sh\necho "dns" >>"%s"\necho "%s"\nexit %s\n' "$L" "$2" "$3" >"$B/$1"
}
dns dns-fail "uplink-dns FAIL hub.invalid: no DNS answer within 5s" 1
dns dns-ok "uplink-dns ok hub.invalid 3ms" 0
dns dns-unknown "uplink-dns unknown: no hub API host (cnf unreadable): not judged" 0
dns dns-broken "FATAL something else" 3
printf '#!/bin/sh\nexit 0\n' >"$B/claude"
chmod +x "$B"/*
export CLAUDE_BIN="$B/claude"

CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i 's/^sw_hub_dns || exit \$?$/:/' "$CTL/scripts/spawn-window.sh"
check "control: the copy has no hub DNS check" sh -c "! grep -q '^sw_hub_dns ' '$CTL/scripts/spawn-window.sh'"

sw() {  # SCRIPTS ENV... -- ARGS -> output in $T_TMP/o, rc in $RC, the calls log reset first
  local d="$1"; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : >"$L"
  env SPAWN_ISSUE_CMD="$B/issue" "${envs[@]}" bash "$d/spawn-window.sh" "$@" >"$T_TMP/o" 2>&1; RC=$?
}
out() { cat "$T_TMP/o"; }
calls() { tr '\n' ' ' <"$L" | sed 's/ $//'; }

# --- 1. the resolver fails here ------------------------------------------------
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-fail" -- claude c-061 "$R" "$T_TMP/key.md" widget
eq "1 resolver fails: exit 14" 14 "$RC"
has "1 ... one line names the box" "REFUSED c-061 on box-a: this box cannot resolve the hub API host" "$(out)"
has "1 ... the host and the reason" "hub.invalid: no DNS answer within 5s" "$(out)"
eq "1 ... the issue step never ran (only the resolver was called)" "dns" "$(calls)"
check "1 ... nothing claimed" test ! -e "$SPOOL_ROOT/c-061"
sw "$CTL/scripts" SPAWN_HUB_DNS_CMD="$B/dns-fail" -- claude c-061 "$R" "$T_TMP/key.md" widget
eq "1 CONTROL today's code: the same spawn goes on to the issue step, exit 12" 12 "$RC"
eq "1 CONTROL ... it claimed c-061 and ran the issue step" "issue c-061" "$(calls)"

# --- 2. resolves / cannot judge ----------------------------------------------
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-ok" -- claude c-062 "$R" "$T_TMP/key.md" widget
eq "2a resolves: on to the issue step (its stub refuses: 12)" "12 dns issue c-062" "$RC $(calls)"
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-unknown" -- claude c-063 "$R" "$T_TMP/key.md" widget
eq "2b unknown host: on to the issue step" "12 dns issue c-063" "$RC $(calls)"
has "2b ... with a WARN" "WARN the hub DNS check on box-a did not judge" "$(out)"
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-broken" -- claude c-064 "$R" "$T_TMP/key.md" widget
eq "2c the probe itself fails: on to the issue step, never a refusal" "12 dns issue c-064" "$RC $(calls)"

# --- 3. skipped ----------------------------------------------------------------
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-fail" SPAWN_DRY_RUN=1 -- claude c-065 "$R" "$T_TMP/key.md" widget
eq "3a dry run: no resolver call, plans" "0 " "$RC $(calls)"
mkdir -p "$SPOOL_ROOT/c-066"
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-fail" SPAWN_REUSE_ID=1 -- claude c-066 "$R" "$T_TMP/key.md" widget
[ "$(calls)" = "" ] && [ "$RC" != 14 ] && ok "3b respawn (SPAWN_REUSE_ID=1): no resolver call, not refused (rc $RC)" || nok "3b respawn: calls '$(calls)', rc $RC: $(out | tail -2)"
mv "$SPOOL_ROOT/dispatch/lease.conf" "$T_TMP/lease.conf"
sw "$T_SCRIPTS" SPAWN_HUB_DNS_CMD="$B/dns-fail" -- claude c-067 "$R" "$T_TMP/key.md" widget
eq "3c no fleet: no resolver call, on to the issue step" "12 issue c-067" "$RC $(calls)"
mv "$T_TMP/lease.conf" "$SPOOL_ROOT/dispatch/lease.conf"

# --- 4. re-pick after the target box refused -------------------------------------
printf '#!/bin/sh\necho "spawn-remote: refused by box-b: spawn-window rc=14: spawn-window: REFUSED a new claude lane on box-b: this box cannot resolve the hub API host (hub.invalid: no DNS answer within 5s)" >&2\necho "remote $*" >>"%s"\nexit 4\n' "$L" >"$B/remote"
chmod +x "$B/remote"
PLACE=(SPAWN_BOX_PICK_CMD="echo pick=box-b reason=below-low" SPAWN_REMOTE_CMD="$B/remote"
       SPAWN_PLACE_MAP_CMD="echo {\"lanes\":[],\"load\":[]}")
sw "$T_SCRIPTS" "${PLACE[@]}" SPAWN_HUB_DNS_CMD="$B/dns-ok" -- claude auto "$R" "$T_TMP/key.md" widget
has "4a box-b refused on DNS: the requester re-picks this box" "WARN the spawn on box-b did not start (spawn-remote exit 4" "$(out)"
[[ "$RC" = 12 && "$(calls)" =~ ^remote\ --box\ box-b.*\ dns\ issue\ c-[0-9]+$ ]] &&
  ok "4a ... checks DNS here, then on to the issue step here" || nok "4a: rc $RC, calls '$(calls)'"
sw "$T_SCRIPTS" "${PLACE[@]}" SPAWN_HUB_DNS_CMD="$B/dns-fail" -- claude auto "$R" "$T_TMP/key.md" widget
eq "4b here cannot resolve either: exit 14 (the row goes back in line)" 14 "$RC"
[[ "$(calls)" =~ ^remote\ --box\ box-b.*\ dns$ ]] && ok "4b ... no issue step anywhere" || nok "4b: calls '$(calls)'"
has "4b ... the line names this box" "REFUSED a new claude lane on box-a" "$(out)"

# --- 5. the default resolver --------------------------------------------------
printf '#!/bin/sh\necho "run $* UPLINK_PROBE_CMD=$UPLINK_PROBE_CMD ENV=$ENV T=$UPLINK_DNS_TIMEOUT_S" >>"%s"\necho "uplink-dns FAIL hub.invalid: no DNS answer within 5s"\nexit 1\n' "$L" >"$B/run"
chmod +x "$B/run"
sw "$T_SCRIPTS" SPAWN_ORC_RUN="$B/run" -- claude c-068 "$R" "$T_TMP/key.md" widget
eq "5 default: the uplink action's dns mode, the lease env, 5 s" "14 run -a do_spl_uplink_probe UPLINK_PROBE_CMD=dns ENV=prd T=5" "$RC $(calls)"

t_done
