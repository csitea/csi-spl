#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the two actions that make the desks survive a restart (CLE-3447):
#          do_spl_desk_up_all, which seats every LIVE agent and retires the
#          ones whose window is gone, and do_spl_desk_install_service, which
#          puts the recurring reconcile in the box user's crontab.
#   1. spl_desk_live_agents reads the SAME fact the notifier routes on - a tmux
#      window whose name carries an agent id - through the same library, and
#      ignores a window that carries none
#   2. spl_desk_dead_agents names the agent dirs the hub is announcing that no
#      live window backs. CONTROL: a live agent is never in that list, and
#      neither is .hub or any other non-agent dir
#   3. SAFETY: with NO live agent at all, do_spl_desk_up_all refuses and retires
#      NOTHING. "tmux is not answering" and "this box has no agents" are
#      different facts and only one of them means retire; conflating them would
#      have taken the whole roster off the hub the morning this was written
#   4. spl_desk_retire MOVES a dir, never deletes it - the inbox is the record
#      (spec 002), and an agent that died holding unread messages is exactly
#      when that matters
#   5. the dry runs make no gcloud, curl, docker or spool call. CONTROL: the
#      stub log records one when made
#   6. the crontab leg: one line under a derived tag, REPLACED not appended on
#      a second install, removed cleanly, and a worktree source REFUSED - a
#      crontab line into a worktree keeps looking installed after the worktree
#      is removed and silently runs nothing
#   9. SPL-1004: DESK_SEATED_ONLY re-seats only the live agents already
#      seated on a tenant's desk (CONTROL: without it every live agent is
#      seated) and keeps a hand mute; do_spl_desk_up_tenants runs that for
#      every OTHER tenant desk on the box and skips DESK_SKIP_TENANTS, and
#      the cron script calls it
#  10. do_spl_desk_up_boxes restarts the stale or dead sidecar of every OTHER
#      seated desk box (box-rsp, prd 2026-10-02); CONTROL: a box on the current
#      binary, a reboxed box-desk, a stopped box and the default box are left
#      alone, and do_spl_desk_up_tenants still drives the default box only
#  11. with NO tmux session or agent window (a box just booted) the tick still
#      starts the default desk's dead sidecar; CONTROL: a live sidecar is not
#      started twice, and a desk stopped by hand stays down
# No real crontab, no real tmux, no cloud call: crontab and tmux are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
for b in gcloud curl docker cloud-sql-proxy spool; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
# tmux: answers list-windows from STUB_TMUX_WINDOWS, and logs like the others
# so a dry run that shells out to the real terminal would be caught.
cat >"$T/stub/tmux" <<'EOF'
#!/bin/sh
echo "tmux $*" >>"${STUB_LOG:-/dev/null}"
case "$*" in
  *list-windows*) [ -n "${STUB_TMUX_WINDOWS:-}" ] && cat "$STUB_TMUX_WINDOWS"; exit 0 ;;
esac
exit 0
EOF
# crontab: a whole crontab in one file, so the box user's real one is untouched.
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
F="${STUB_CRONTAB:?STUB_CRONTAB unset}"
case "${1:-}" in
  -l) [ -s "$F" ] && cat "$F"; exit 0 ;;
  -r) : >"$F"; exit 0 ;;
  "") exit 2 ;;
  *)  cat "$1" >"$F"; exit 0 ;;
esac
EOF
chmod +x "$T/stub/"*

# A NON-worktree checkout to point the cron leg at. The tests themselves run
# from an agent worktree most of the time on this box, and a worktree is the
# one source the cron leg must refuse - so it needs a source that is not one,
# and it must not be the real /opt tree either.
CO="$T/checkout"
mkdir -p "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts/"
chmod +x "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts/desk-reconcile-cron.sh"
printf '#!/bin/sh\nexit 0\n' >"$CO/$(basename "$PROJ_ROOT")/run"
chmod +x "$CO/$(basename "$PROJ_ROOT")/run"

# The default desk box comes from the box's live box.env (SPOOL_DESK_BOX=<box>
# on a renamed box), so pin both to nothing: the tests read box-desk everywhere.
in_orc() {
  env -u SPOOL_DESK_BOX PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
      STUB_LOG="$T/calls.log" STUB_CRONTAB="$T/crontab.txt" \
      SPL_ORG_APP="$(basename "$PROJ_ROOT" | sed 's/-orc$//')" \
      SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" SPOOL_TMUX_SOCKET="$T/nosuch.sock" \
      SPOOL_BOX_ENV="$T/no-box.env" \
      PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    # This stub reproduces the ONE property of run.sh do_log that this file
    # tests: it builds its message with `echo $*` UNQUOTED (csi-spl-orc/run,
    # in the type_of_msg / rest_of_msg block), so an argument holding * is
    # glob-expanded against the working directory. A stub that quoted let the
    # defect through - measured 2026-09-22: the planted do_log call passed a
    # gate written specifically to catch it, because only the stub was safe.
    # shellcheck disable=SC2086
    do_log() { echo $*; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}
: >"$T/crontab.txt"

# --- 1. which agents are LIVE ------------------------------------------------------
cat >"$T/windows.txt" <<'EOF'
CLE-00 ORC
tag: CLE-3444 ! a decorated window name
bash
tag: GRK-12 > another kind of agent
sudo
CLE-00 ORC
EOF
out=$(SNIPPET='spl_desk_live_agents' in_orc STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == "CLE-00
CLE-3444
GRK-12" ]] && pass "live agents come from the window names, deduped and sorted" ||
  fail "spl_desk_live_agents: $out"
out=$(SNIPPET='spl_desk_live_agents' in_orc 2>&1)
[[ -z "$out" ]] && pass "a tmux that answers nothing yields no live agent" || fail "empty tmux: $out"

# --- 2. which agent dirs the hub is announcing with no window behind them ----------
# That dir scan IS what the box announces from (hubclient scanAgents), so this
# list is exactly what the hub is currently lying about.
D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool"/{CLE-00,CLE-3444,CLE-999,GRK-12,.hub,files,BOX-1,notanagent}
out=$(SNIPPET="spl_desk_dead_agents '$D' CLE-00 CLE-3444 GRK-12" in_orc 2>&1)
[[ "$out" == "CLE-999" ]] && pass "only an agent dir with no live window is dead" || fail "dead agents: $out"
for keep in .hub files notanagent BOX-1; do
  [[ "$out" != *"$keep"* ]] && pass "…and $keep is not treated as an agent" || fail "$keep read as an agent"
done
out=$(SNIPPET="spl_desk_dead_agents '$T/state/dev/desk/t1/nosuchbox' CLE-00" in_orc 2>&1)
[[ -z "$out" ]] && pass "a desk with no state dir has nothing to retire" || fail "missing state dir: $out"

# --- 3. SAFETY: no live agent means retire NOTHING --------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "no live agent window is a FAILURE, not a quiet success" || fail "empty tmux exited 0: $out"
[[ "$out" == *"not the same fact"* ]] && pass "…and it says why nothing was retired" || fail "no reason given: $out"
[[ -d "$D/spool/CLE-999" ]] && pass "…and the dead agent's dir is untouched" || fail "a dir was retired with no live agent to compare against"
# CONTROL: with windows present the same call finds them.
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == *"live agent windows: CLE-00 CLE-3444 GRK-12"* ]] &&
  pass "CONTROL with windows present the live agents are found" || fail "CONTROL: $out"
[[ "$out" == *"would: retire 1 agent(s)"* && "$out" == *"CLE-999"* ]] &&
  pass "…and the dry run names the one it would retire" || fail "dry run retire list: $out"
[[ "$out" == *"DESK_SKIP"* ]] && fail "DESK_SKIP fired without being set" || pass "nothing is skipped unless DESK_SKIP says so"
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 DESK_SKIP="CLE-00 GRK-12" STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == *"would: seat 1 agent(s)"* && "$out" == *": CLE-3444"* ]] &&
  pass "DESK_SKIP leaves those agents unseated" || fail "DESK_SKIP: $out"
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 DESK_RETIRE=0 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == *"would NOT retire"* ]] && pass "DESK_RETIRE=0 keeps a dead agent announced" || fail "DESK_RETIRE=0: $out"
# tmux IS called - that is how a live agent is found - so the question is
# whether anything that reaches the CLOUD was called.
out_of_band="$(grep -v '^tmux ' "$T/calls.log" | sed -n 1,3p)"
[[ -z "$out_of_band" ]] && pass "no gcloud, curl, docker or spool call in the dry run" ||
  fail "a dry run called out: $out_of_band"
( PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" gcloud version >/dev/null 2>&1 )
[[ -s "$T/calls.log" ]] && pass "CONTROL the stub log records a real call" || fail "CONTROL the stub log stayed empty"

# --- 4. retiring MOVES, never deletes ---------------------------------------------
printf 'an unread message\n' >"$D/spool/CLE-999/inbox.json"
SNIPPET="spl_desk_retire '$D' CLE-999" in_orc >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "a dead agent is retired" || fail "spl_desk_retire failed"
[[ ! -d "$D/spool/CLE-999" ]] && pass "…out of the dir scan the box announces from" || fail "the dir is still in the scan"
kept=$(find "$D/retired" -name inbox.json 2>/dev/null | sed -n 1p)
[[ -s "$kept" ]] && pass "…and its messages are kept, not deleted (the inbox is the record)" ||
  fail "the retired agent's inbox is gone"
SNIPPET="spl_desk_retire '$D' CLE-404" in_orc >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "retiring an agent that has no dir is not a success" || fail "missing dir retired as OK"

# --- 5. the crontab leg -----------------------------------------------------------
SNIPPET='spl_desk_cron_src' in_orc DESK_CRON_SRC="$CO" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "a normal checkout is an acceptable cron source" || fail "a normal checkout was refused"
out=$(SNIPPET='spl_desk_cron_src' in_orc DESK_CRON_SRC="$T/fake-wt/CLE-1" 2>&1)
[[ "$out" == *"not a directory"* ]] && pass "a cron source that does not exist is refused" || fail "missing src: $out"
mkdir -p "$T/csi-spl-wt/CLE-1"
out=$(SNIPPET='spl_desk_cron_src' in_orc DESK_CRON_SRC="$T/csi-spl-wt/CLE-1" 2>&1)
[[ "$out" == *"agent worktree"* ]] && pass "an agent WORKTREE is refused as the cron source" || fail "worktree accepted: $out"
[[ "$out" == *"DESK_CRON_SRC=$T"* ]] && pass "…and the refusal names the shared checkout to use instead" ||
  fail "the refusal does not say what to do: $out"

TAG="$(basename "$PROJ_ROOT" | sed 's/-orc$//'):desk-reconcile"
printf '0 3 * * * echo someone-elses-job\n' >"$T/crontab.txt"
SNIPPET="spl_desk_cron_write '$TAG' '*/5 * * * * first # $TAG'" in_orc >/dev/null 2>&1
SNIPPET="spl_desk_cron_write '$TAG' '*/7 * * * * second # $TAG'" in_orc >/dev/null 2>&1
n=$(grep -cF "# $TAG" "$T/crontab.txt")
[[ "$n" == 1 ]] && pass "a second write REPLACES the tagged line, it does not append" ||
  fail "the crontab holds $n tagged lines after two writes"
grep -q 'someone-elses-job' "$T/crontab.txt" &&
  pass "…and an unrelated crontab line is left alone" || fail "an unrelated crontab line was dropped"
out=$(SNIPPET="spl_desk_cron_line '$TAG'" in_orc 2>&1)
[[ "$out" == "*/7 * * * * second # $TAG" ]] && pass "the tagged line reads back" || fail "cron line: $out"
SNIPPET="spl_desk_cron_write '$TAG' ''" in_orc >/dev/null 2>&1
[[ "$(grep -cF "# $TAG" "$T/crontab.txt")" == 0 ]] && pass "an empty write removes the tagged line" ||
  fail "the tagged line survived a removal"
grep -q 'someone-elses-job' "$T/crontab.txt" &&
  pass "…still without touching anyone else's" || fail "removal took an unrelated line with it"

# --- 6. do_spl_desk_install_service, end to end against the stub crontab -----------
: >"$T/crontab.txt"
svc() { SNIPPET=do_spl_desk_install_service in_orc TENANT_ID=t1 DESK_CRON_SRC="$CO" \
          DESK_CRON_LOG_DIR="$T/log" "$@" 2>&1; }
out=$(svc DESK_SERVICE_ACTION=check); rc=$?
[[ $rc -ne 0 ]] && pass "check FAILS while the reconcile is not installed" || fail "check passed on an empty crontab"
[[ "$out" == *'"installed": false'* ]] && pass "…and says so as JSON" || fail "check JSON: $out"
out=$(svc DRY_RUN=1)
[[ "$out" == *"DRY_RUN would"* ]] && pass "the install is a dry run until DRY_RUN=0" || fail "install dry run: $out"
# The line an operator READS must be the line that gets written. do_log expands
# its argument, and a crontab schedule begins with "*/5 * * * *", so printing it
# that way showed "*/5 dat lib Makefile README.md run src ..." - the file was
# always right and the report was a lie, which is the worse of the two.
[[ "$out" == *"*/5 * * * * ENV=dev"* ]] &&
  pass "the dry run shows the REAL schedule, unglobbed" || fail "the shown schedule was globbed: $out"
hasdir=0
for f in $(ls "$PROJ_ROOT" 2>/dev/null | sed -n 1,3p); do [[ "$out" == *" $f "* ]] && hasdir=1; done
[[ "$hasdir" == 0 ]] && pass "…and no directory listing leaked into it" || fail "a directory listing leaked into the shown line: $out"
[[ "$(wc -c <"$T/crontab.txt")" == 0 ]] && pass "…and it wrote nothing" || fail "the dry run wrote to the crontab"
out=$(svc DRY_RUN=0)
[[ $? -eq 0 ]] && pass "the install succeeds" || fail "install: $out"
[[ "$(grep -cF "# $TAG" "$T/crontab.txt")" == 1 ]] && pass "…leaving exactly one tagged line" ||
  fail "crontab after install: $(cat "$T/crontab.txt")"
grep -q "ENV=dev TENANT_ID=t1" "$T/crontab.txt" && pass "…carrying the env and tenant" ||
  fail "the line has no env/tenant: $(cat "$T/crontab.txt")"
svc DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -cF "# $TAG" "$T/crontab.txt")" == 1 ]] && pass "installing twice is idempotent" ||
  fail "a second install appended: $(cat "$T/crontab.txt")"
out=$(svc DESK_SERVICE_ACTION=check); rc=$?
[[ $rc -eq 0 ]] && pass "check now passes" || fail "check after install: $out"
[[ "$out" == *'"matches": true'* ]] && pass "…and confirms the line is the one this action writes" || fail "check match: $out"
out=$(svc DRY_RUN=0 DESK_CRON_EVERY=9)
[[ "$(grep -c '^\*/9 ' "$T/crontab.txt")" == 1 ]] && pass "DESK_CRON_EVERY sets the interval" ||
  fail "interval: $(cat "$T/crontab.txt")"
# A line installed with OTHER settings still passes the check: it runs. Failing
# it would train people to ignore a check that is mostly about a line that
# cannot run at all.
out=$(svc DESK_SERVICE_ACTION=check); rc=$?
[[ $rc -eq 0 ]] && pass "a line installed with different flags still passes check - it runs" ||
  fail "check after a changed interval: $out"
[[ "$out" == *"different settings"* ]] && pass "…and the difference is reported rather than hidden" ||
  fail "the difference was not reported: $out"

# The failure this check exists for: the script the line names is GONE. A
# crontab pointing into a removed worktree keeps looking installed for ever
# and runs nothing, which is exactly how the desks were lost twice.
mv "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts/desk-reconcile-cron.sh" "$T/moved-away.sh"
out=$(svc DESK_SERVICE_ACTION=check); rc=$?
[[ $rc -ne 0 ]] && pass "check FAILS when the script the line names is gone" ||
  fail "a crontab line running nothing passed the check: $out"
[[ "$out" == *"running NOTHING"* || "$out" == *"runs NOTHING"* ]] &&
  pass "…and says the line runs nothing while looking installed" || fail "no explanation: $out"
mv "$T/moved-away.sh" "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts/desk-reconcile-cron.sh"
svc DESK_SERVICE_ACTION=check >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "CONTROL putting the script back makes check pass again" ||
  fail "CONTROL check still fails with the script restored"
for bad in 0 60 five; do
  svc DRY_RUN=0 DESK_CRON_EVERY="$bad" >/dev/null 2>&1
  [[ $? -ne 0 ]] && pass "DESK_CRON_EVERY=$bad is refused" || fail "DESK_CRON_EVERY=$bad was accepted"
done
# DESK_MUTE has to reach the crontab line. Without it a tick UNDOES a
# deliberate mute - DESK_POKE defaults to 1, so the reconcile deletes the
# .no-poke marker and that seat starts taking poke lines again, five minutes
# after a human decided it should not. A mute a timer reverses is worse than no
# mute, because it reverses when nobody is watching.
svc DRY_RUN=0 DESK_MUTE="CLE-00 CLE-9" >/dev/null 2>&1
line="$(grep -F "# $TAG" "$T/crontab.txt")"
[[ "$line" == *"DESK_MUTE='CLE-00 CLE-9'"* ]] && pass "DESK_MUTE is baked into the cron line" ||
  fail "the cron line carries no DESK_MUTE: $line"
# CONTROL: with none asked for, the line carries none rather than an empty one.
svc DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -F "# $TAG" "$T/crontab.txt")" != *DESK_MUTE* ]] &&
  pass "CONTROL no DESK_MUTE asked for, none in the line" || fail "an empty DESK_MUTE was baked in"
svc DRY_RUN=0 DESK_MUTE="not-an-agent" >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "a DESK_MUTE entry that is not an agent id is refused" ||
  fail "a bogus DESK_MUTE entry was accepted"
# …and the cron script passes it on to the action rather than dropping it.
grep -q 'DESK_MUTE="\${DESK_MUTE:-}"' "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" &&
  pass "the cron script hands DESK_MUTE to the action" || fail "the cron script drops DESK_MUTE"

svc DRY_RUN=0 DESK_SERVICE_ACTION=remove >/dev/null 2>&1
[[ "$(grep -cF "# $TAG" "$T/crontab.txt")" == 0 ]] && pass "remove takes the line out" || fail "remove left the line"
out=$(svc DESK_SERVICE_ACTION=check); rc=$?
[[ $rc -ne 0 ]] && pass "…and check fails again afterwards" || fail "check passed after a removal"
svc DESK_SERVICE_ACTION=nonsense >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "an unknown DESK_SERVICE_ACTION is refused" || fail "a bogus action was accepted"

# --- 7. the cron script refuses to run, or to be printed, from a worktree ---------
CRON="$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh"
[[ -x "$CRON" ]] && pass "the cron entry point is executable" || fail "$CRON is not executable"
WT="$T/csi-spl-wt/CLE-2/$(basename "$PROJ_ROOT")/src/bash/scripts"
mkdir -p "$WT"; cp "$CRON" "$WT/"
out=$(bash "$WT/desk-reconcile-cron.sh" 2>&1); rc=$?
[[ $rc -eq 2 && "$out" == *"agent worktree"* ]] && pass "the cron script refuses to run from a worktree" ||
  fail "worktree run (rc=$rc): $out"
out=$(bash "$WT/desk-reconcile-cron.sh" --print-crontab 2>&1); rc=$?
[[ $rc -eq 2 ]] && pass "…and refuses to PRINT a crontab line pointing at one" ||
  fail "it printed a worktree crontab line: $out"
# CRON'S PATH IS NOT AN INTERACTIVE PATH, and this is the defect that took the
# very first tick after installation: vixie cron runs a job with
# PATH=/usr/bin:/bin, `yq` on this box is in /usr/local/bin, and the tick died
# with "Missing required tool(s): yq" while every interactive test had passed.
# An interactive shell reads a profile; a cron job does not.
out=$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash "$CRON" --check-tools 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "every tool the reconcile needs resolves under a CRON-like PATH" ||
  fail "a cron-like PATH cannot find the tools (rc=$rc): $out"
[[ "$out" == *"yq"* ]] && pass "…and the check names what it looked for" || fail "check-tools names nothing: $out"
# CONTROL: the preflight itself must be able to fail. Point it at a binary that
# cannot exist - a check that has never been seen failing is a check nobody
# should trust, and this one is the difference between "yq is missing" in the
# log and a reconcile that failed for unstated reasons.
out=$(env -i PATH=/usr/bin:/bin HOME="$HOME" DESK_CRON_TOOLS="python3 not-a-real-binary-xyz" \
        bash "$CRON" --check-tools 2>&1); rc=$?
[[ $rc -eq 3 ]] && pass "CONTROL a missing tool is exit 3, not a confusing later failure" ||
  fail "CONTROL a missing tool gave rc=$rc: $out"
[[ "$out" == *"not-a-real-binary-xyz"* && "$out" == *"PATH="* ]] &&
  pass "CONTROL …and the failure names the tool and the PATH it searched" || fail "CONTROL no diagnosis: $out"

out=$(bash "$CO/$(basename "$PROJ_ROOT")/src/bash/scripts/desk-reconcile-cron.sh" --print-crontab 2>&1)
[[ "$out" == *"# $TAG"* && "$out" == *"desk-reconcile-cron.sh"* ]] &&
  pass "--print-crontab from the checkout prints the tagged line" || fail "--print-crontab: $out"

# --- 8. the reconcile asks the HUB, and restarts a STRANDED sidecar -----------------
# 2026-09-25: a tick said "13 seated, none failed" while the box had been
# stranded ~45 min by a hub redeploy - seating only looks at the local pid and
# the local roster cache. spl_desk_heal_stranded reads the hub's roster.
# do_spl_desk_down/up are stubbed: this proves the DECISION, not a real restart.
H="$T/state/dev/desk/t1/box-heal"
mkdir -p "$H/spool/.hub"
# A process whose cmdline carries " hub-run", which is what spl_desk_alive reads.
# The trailing ':' keeps bash from exec'ing sleep, which would drop that argv.
bash -c 'sleep 60; :' _ hub-run & HPID=$!
echo "$HPID" >"$H/spool/.hub/hub-run.pid"
roster() { printf '{"boxes":[{"box_id":"box-heal","online":%s,"agents":["%s"]}]}\n' "$1" "$2" >"$T/hub-roster.json"; }
HEAL='do_spl_desk_down() { echo "CALL down agent=[$DESK_AGENT]"; }
      do_spl_desk_up() { echo "CALL up $DESK_AGENT poke=$DESK_POKE"; }
      spl_desk_heal_stranded "$SPL_STATE_DIR/desk/t1/box-heal" t1 box-heal CLE-00 1; echo "rc=$? HUB=$SPL_DESK_HUB"'
roster false CLE-00
out=$(SNIPPET="$HEAL" in_orc DESK_ROSTER_JSON="$T/hub-roster.json" 2>&1)
[[ "$out" == *"STRANDED"* && "$out" == *"CALL down agent=[]"* && "$out" == *"CALL up CLE-00 poke=1"* && "$out" == *"rc=0 HUB=stranded-repaired"* ]] &&
  pass "a live sidecar the hub calls offline is STRANDED and gets restarted" || fail "stranded heal: $out"
roster true CLE-00
out=$(SNIPPET="$HEAL" in_orc DESK_ROSTER_JSON="$T/hub-roster.json" 2>&1)
[[ "$out" != *"CALL "* && "$out" == *"rc=0 HUB=online"* ]] &&
  pass "CONTROL a box the hub has a session for is left alone" || fail "online box was touched: $out"
roster true CLE-9
out=$(SNIPPET="$HEAL" in_orc DESK_ROSTER_JSON="$T/hub-roster.json" 2>&1)
[[ "$out" != *"CALL "* && "$out" == *"HUB=agent-missing"* ]] &&
  pass "CONTROL agent-missing is not something a restart fixes, so none is made" || fail "agent-missing restarted: $out"
out=$(SNIPPET="$HEAL" in_orc DESK_ROSTER_JSON="$T/no-such-roster.json" 2>&1)
[[ "$out" != *"CALL "* && "$out" == *"WARN"* && "$out" == *"rc=0 HUB=skipped"* ]] &&
  pass "CONTROL a roster read that fails restarts NOTHING (a 429 must not bounce every seat)" || fail "failed read restarted: $out"
pkill -P "$HPID" 2>/dev/null; kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null
roster false CLE-00
out=$(SNIPPET="$HEAL" in_orc DESK_ROSTER_JSON="$T/hub-roster.json" 2>&1)
[[ "$out" != *"CALL "* && "$out" == *"HUB=skipped"* ]] &&
  pass "CONTROL with no live sidecar it is down, not stranded: seating owns that" || fail "dead sidecar healed: $out"
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == *"DRY_RUN would: ask the hub whether"* ]] && pass "the dry run names the hub-side check" || fail "dry run: $out"
out=$(SNIPPET=do_spl_desk_up_all in_orc TENANT_ID=t1 DESK_HUB_CHECK=2 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"DESK_HUB_CHECK must be 0 or 1"* ]] && pass "a bad DESK_HUB_CHECK is refused" || fail "DESK_HUB_CHECK=2: $out"

# --- 9. the other tenants' desks get the tick too (SPL-1004) ------------------------
# prd 2026-09-27: the csi-rel sidecar stopped at 11:47:54Z and stayed down until
# a new agent was seated at 12:28:12Z - the cron reconciled t1 only.
C="$T/state/dev/desk/csi-x/box-desk"
mkdir -p "$C/spool"/{CLE-3444,CLE-999,.hub}
touch "$C/spool/CLE-3444/.no-poke"
UPSTUB='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_AGENT poke=$DESK_POKE"; }
        spl_desk_wait_roster() { return 0; }'
out=$(SNIPPET="$UPSTUB; do_spl_desk_up_all" in_orc TENANT_ID=csi-x DESK_SEATED_ONLY=1 DESK_RETIRE=0 DESK_HUB_CHECK=0 \
  DRY_RUN=0 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$(grep -c '^CALL up' <<<"$out")" == 1 && "$out" == *"CALL up csi-x CLE-3444 poke=0"* ]] &&
  pass "DESK_SEATED_ONLY seats only the live agent already on the desk, and keeps its hand mute" ||
  fail "seated-only: $out"
out=$(SNIPPET="$UPSTUB; do_spl_desk_up_all" in_orc TENANT_ID=csi-x DESK_RETIRE=0 DESK_HUB_CHECK=0 \
  DRY_RUN=0 STUB_TMUX_WINDOWS="$T/windows.txt" 2>&1)
[[ "$out" == *"CALL up csi-x CLE-00 "* && "$out" == *"CALL up csi-x GRK-12 "* ]] &&
  pass "CONTROL without DESK_SEATED_ONLY every live agent is seated" || fail "CONTROL all live: $out"
[[ -d "$C/spool/CLE-999" ]] && pass "DESK_RETIRE=0 left the customer desk's dirs" || fail "a customer dir was retired"
TSTUB='do_spl_desk_up_all() { echo "CALL all $TENANT_ID only=$DESK_SEATED_ONLY retire=$DESK_RETIRE hub=$DESK_HUB_CHECK dry=$DRY_RUN"; }'
mkdir -p "$T/state/dev/desk/lone/other-box/spool"
out=$(SNIPPET="$TSTUB; do_spl_desk_up_tenants" in_orc DESK_SKIP_TENANTS=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"CALL all csi-x only=1 retire=0 hub=0 dry=0"* && "$out" != *"CALL all t1 "* && "$out" != *"CALL all lone "* ]] &&
  pass "do_spl_desk_up_tenants reconciles the other tenant desks, seated-only, and skips t1 and a tenant with no such box" ||
  fail "up_tenants (rc=$rc): $out"
out=$(SNIPPET="$TSTUB; do_spl_desk_up_tenants" in_orc 2>&1)
[[ "$out" == *"CALL all t1 "*"dry=1"* && "$out" == *"CALL all csi-x "*"dry=1"* ]] &&
  pass "CONTROL with no skip list every tenant desk is reconciled, and a dry run stays dry" || fail "CONTROL up_tenants: $out"
grep -q 'do_spl_desk_up_tenants' "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" &&
  pass "the cron tick calls do_spl_desk_up_tenants" || fail "the cron tick does not call do_spl_desk_up_tenants"

# --- 10. the OTHER desk boxes get the tick too (box-rsp, prd 2026-10-02) ------------
# All 6 prd box-rsp sidecars ran a DELETED spool binary for ~14 h: the reconcile
# only ever looked at the default desk box, and RSP-01 has no tmux window.
B="$T/boxes/prd/desk"
# A sidecar on a rebuilt binary: a copied bash whose file is then removed, so
# /proc/<pid>/exe reads "<path> (deleted)", carrying " hub-run" in its argv.
cp "$(command -v bash)" "$T/spool-old"
"$T/spool-old" -c 'sleep 60; :' _ hub-run 2>/dev/null & OLD1=$!
"$T/spool-old" -c 'sleep 60; :' _ hub-run 2>/dev/null & OLD2=$!
bash -c 'sleep 60; :' _ hub-run 2>/dev/null & CUR=$!
bash -c 'exit 0' & DEAD=$!; wait "$DEAD"
sleep 0.2; rm -f "$T/spool-old"
seat_box() { mkdir -p "$B/$1/spool/.hub" "$B/$1/spool/$2/inbox"; [[ -n "${3:-}" ]] && echo "$3" >"$B/$1/spool/.hub/hub-run.pid"; return 0; }
seat_box t1/box-main CLE-00 "$OLD2"            # the default box: up_boxes leaves it to up_all
seat_box t1/box-rsp RSP-01 "$OLD1"        # stale binary -> restart
seat_box csi-x/box-rsp RSP-01 "$DEAD"     # sidecar died -> restart, keeping the mute
touch "$B/csi-x/box-rsp/spool/RSP-01/.no-poke"
seat_box t1/box-ci OPS-01 "$CUR"          # live on the current binary -> left alone
seat_box t1/box-desk CLE-00 "$DEAD"       # retired by do_spl_desk_rebox -> never touched
mkdir -p "$B/t1/box-desk/rebox-retired"
seat_box t1/box-mirror CLE-9              # no pid file: stopped by hand -> not in the set
seat_box t1/box-wui CLE-9 "$DEAD"         # reserved
BSTUB='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_BOX $DESK_AGENT poke=$DESK_POKE boxpoke=$DESK_BOX_POKE"; }'
out=$(SNIPPET="$BSTUB; do_spl_desk_up_boxes" in_orc SPL_STATE_DIR="$T/boxes/prd" DESK_BOX=box-main DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"CALL up t1 box-rsp RSP-01 poke=1 boxpoke=1"* && "$out" == *"restarted (stale-binary) for RSP-01"* ]] &&
  pass "a non-default box (box-rsp) whose sidecar runs a deleted binary is restarted" || fail "stale box-rsp (rc=$rc): $out"
[[ "$out" == *"CALL up csi-x box-rsp RSP-01 poke=0 "* && "$out" == *"restarted (sidecar-dead)"* ]] &&
  pass "a non-default box of another tenant whose sidecar died is restarted, keeping the hand mute" || fail "dead csi-x box-rsp: $out"
[[ "$(grep -c '^CALL up' <<<"$out")" == 2 ]] &&
  pass "CONTROL only those two: box-ci (current binary), box-desk (reboxed), box-mirror (stopped) and box-wui are not restarted" ||
  fail "CONTROL other boxes touched: $out"
[[ "$out" != *"CALL up t1 box-main"* ]] &&
  pass "CONTROL the default box is left to do_spl_desk_up_all, even with a stale sidecar" || fail "default box touched: $out"
out=$(SNIPPET="$BSTUB; do_spl_desk_up_boxes" in_orc SPL_STATE_DIR="$T/boxes/prd" DESK_BOX=box-main 2>&1)
[[ "$out" != *"CALL "* && "$out" == *"DRY_RUN would: restart the sidecar of desk box box-rsp of t1 (stale-binary)"* &&
   "$out" == *"desk box box-ci of t1: in the reconcile set"* ]] &&
  pass "the dry run names box-rsp in the reconcile set and touches nothing" || fail "dry run up_boxes: $out"
# CONTROL: the default-box pass is unchanged - up_tenants still drives only the default box.
TSTUB2='do_spl_desk_up_all() { echo "CALL all $TENANT_ID $DESK_BOX"; }'
out=$(SNIPPET="$TSTUB2; do_spl_desk_up_tenants" in_orc SPL_STATE_DIR="$T/boxes/prd" DESK_BOX=box-main DRY_RUN=0 2>&1)
[[ "$out" == *"CALL all t1 box-main"* && "$out" != *"box-rsp"* && "$out" != *"CALL all csi-x"* ]] &&
  pass "CONTROL do_spl_desk_up_tenants still reconciles the default box only" || fail "CONTROL up_tenants default box: $out"
for p in "$OLD1" "$OLD2" "$CUR"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
grep -q 'do_spl_desk_up_boxes' "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" &&
  pass "the cron tick calls do_spl_desk_up_boxes" || fail "the cron tick does not call do_spl_desk_up_boxes"

# --- 11. the sidecar comes up at BOOT, with no agent window (drill 3, 2026-10-09) ----
# sat booted at 03:44:43Z and its prd sidecar first started at 04:06:03Z: the
# reconcile refused with "no live agent window" until an agent came back, and
# for those 21 min no remote message reached the box. With no window the tick
# still starts the box's sidecar; a live one is never doubled.
BD="$T/boot/dev/desk/t1/box-desk"
mkdir -p "$BD/spool/.hub" "$BD/spool/c-101/inbox" "$BD/spool/c-102/inbox"
touch "$BD/spool/c-101/.no-poke"
bash -c 'exit 0' & BDEAD=$!; wait "$BDEAD"
echo "$BDEAD" >"$BD/spool/.hub/hub-run.pid"
BUP='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_BOX $DESK_AGENT poke=$DESK_POKE"; }'
boot() { SNIPPET="$BUP; do_spl_desk_up_all" in_orc SPL_STATE_DIR="$T/boot/dev" TENANT_ID=t1 "$@" 2>&1; }
out=$(boot DRY_RUN=0); rc=$?
[[ "$out" == *"CALL up t1 box-desk c-101 poke=0"* && "$out" == *"started the hub-run sidecar of box-desk in t1 (sidecar-dead) with no agent window"* ]] &&
  pass "no tmux session or agent window: the dead sidecar is STARTED anyway, keeping the hand mute" || fail "boot start: $out"
[[ $rc -ne 0 && "$out" == *"not the same fact"* && -d "$BD/spool/c-102" ]] &&
  pass "…and the tick still reports no live window and retires nothing" || fail "boot verdict (rc=$rc): $out"
out=$(boot)
[[ "$out" != *"CALL "* && "$out" == *"DRY_RUN would: start the hub-run sidecar of box-desk in t1 (sidecar-dead)"* ]] &&
  pass "the dry run plans that start and touches nothing" || fail "boot dry run: $out"
# CONTROL: a sidecar already running gets no second start.
bash -c 'sleep 60; :' _ hub-run & BLIVE=$!
echo "$BLIVE" >"$BD/spool/.hub/hub-run.pid"
out=$(boot DRY_RUN=0)
[[ "$out" != *"CALL "* && "$out" == *"already live with no agent window: no second one"* ]] &&
  pass "CONTROL an already-running sidecar is not started a second time" || fail "CONTROL live sidecar: $out"
pkill -P "$BLIVE" 2>/dev/null; kill "$BLIVE" 2>/dev/null; wait "$BLIVE" 2>/dev/null
# CONTROL: a desk stopped by hand (do_spl_desk_down removed the pid file) stays down.
rm -f "$BD/spool/.hub/hub-run.pid"
out=$(boot DRY_RUN=0)
[[ "$out" != *"CALL "* ]] && pass "CONTROL a desk stopped by hand (no pid file) is not started" || fail "CONTROL stopped desk: $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-up-all.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
