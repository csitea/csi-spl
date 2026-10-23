#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the three lane lifecycle reporting actions, hermetic (test round 2
#          row 11): do_spl_rotate_status (spl-rotate-status.func.sh),
#          do_spl_local_hub_status (spl-local-hub-status.func.sh) and
#          do_spl_dispatch_deploy_lag (spl-dispatch-deploy-lag.func.sh).
#          Nothing live is read: the spool root, lease.conf and rotate.log are
#          fixtures in a temp dir, /proc is a fake (LEASE_PROC_ROOT), tmux,
#          crontab, curl and ss are stubs, compose and the deploy-lag probe
#          are replaced; no hub, no docker, no network.
#   1. rotate status: the two tables' headers; per role the id@box, pid, age
#      in minutes, pane state and the launch flags read from the fake
#      cmdline; a role missing from lease.conf is named; the last rid /
#      phase / DONE / SKIP come from rotate.log (PLAN and SKIP lines are not
#      a "last" phase); the next slots are :05 (orch) and :15 within the
#      hour; rotate.hold, the switches and the cron count; exit 0
#   2. rotate status: a stalled pane (usage-limit footer) reads "stalled";
#      rotate.hold shows its age; a rotate.conf switch is shown; no
#      rotate.log reads "-"; a bad ROTATE_* knob is refused (exit 1, FATAL)
#   3. local hub status: all PASS = exit 0, one OK line per check; a hub
#      that is not 200, a WUI that does not answer, a wildcard listener,
#      a port nobody listens on, a restarting / exited service, no service
#      at all: each one an ERROR line, the FAIL count and exit 1; the
#      missing ports gate is a WARN, a loaded one is one more check
#   4. dispatch deploy lag: the markdown header, one row per env+component
#      with url= dropped and '|' made '/', exit 0 while current/pending;
#      lagging = GAP row + exit 1; an unknown verdict, an empty probe and a
#      missing do_check_deploy_lag = "cannot tell", never a GAP; lines of
#      another env or component are ignored; ENV, SHA and GRACE_MINUTES
#      reach the probe; DISPATCH_LAG_ENVS narrows the envs
#   5. CONTROLS: a mutant of each action (a header renamed, a status line
#      dropped or wrong, the exit-code contract broken) is caught by the
#      same checks
#------------------------------------------------------------------------------
set -uo pipefail
# the actions read SPOOL_* / ROTATE_* / LEASE_* / DISPATCH_* / LDE_* from the
# env: drop the caller's, the sandbox sets the ones it needs
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(SPOOL_|ROTATE_|LEASE_|DISPATCH_|LDE_)')
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# ============================================================================
# 1-2. do_spl_rotate_status
# ============================================================================
S="$T/spool"; D="$S/dispatch"; P="$T/proc"
mkdir -p "$D" "$P" "$T/stub"
TCK=$(getconf CLK_TCK)
echo "100000.00 0.00" >"$P/uptime"
# proc <pid> <age-s> <id> <argv...>: a fake claude carrying SPOOL_AGENT_ID=<id>
proc() {
  local pid="$1" age="$2" id="$3"; shift 3
  mkdir -p "$P/$pid"; echo claude >"$P/$pid/comm"
  printf 'SPOOL_AGENT_ID=%s\0' "$id" >"$P/$pid/environ"
  echo "$pid (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (100000 - age) * TCK ))" >"$P/$pid/stat"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
}
proc 4242 600 c-900 claude --dangerously-skip-permissions --model opus
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
printf 'LEASE_ORCH=c-900\nLEASE_MASTER=c-901\n' >"$D/lease.conf"
cat >"$D/rotate.log" <<'EOF'
2026-10-20T10:05:01Z 20261020T1005Z-orch GATE OK
2026-10-20T10:07:01Z 20261020T1005Z-orch DONE OK new pid 4242
2026-10-20T11:05:01Z 20261020T1105Z-orch GATE SKIP young (600s)
2026-10-20T09:15:01Z 20261020T0915Z-master ACK FAIL no ack in 900s
2026-10-20T11:15:01Z 20261020T1115Z-master GATE PLAN would rotate
EOF
# tmux: one pane %7 holding pid 4242; its screen is $SCREEN
cat >"$T/stub/tmux" <<'EOF'
#!/bin/sh
case "$1" in
  list-panes) echo "4242 %7" ;;
  capture-pane) cat "$SCREEN" ;;
esac
EOF
# crontab -l: two rotation lines and one unrelated line
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
printf '5 * * * * x # box-a:orch-rotate\n15 * * * * x # box-a:dispatch-rotate\n0 3 * * * y # backup\n'
EOF
chmod +x "$T/stub/tmux" "$T/stub/crontab"
idle_screen() { printf 'last turn done\n❯ \n' >"$T/screen"; }
idle_screen

rotate_status() {
  SNIPPET="${PRE:-}"$'\n''do_spl_rotate_status' in_orc SPOOL_ROOT="$S" LEASE_PROC_ROOT="$P" \
    ROTATE_TMUX="$T/stub/tmux" SCREEN="$T/screen" SPOOL_BOX_ENV="$S/box.env" LEASE_MACHINE=box-a "$@" 2>&1
}

# check_rotate <label> <output> <rc>: the contract of case 1
check_rotate() {
  local label="$1" out="$2" rc="$3" ok=1 orch master failover
  orch="$(grep -E '^orch +c-900@box-a ' <<<"$out")"
  master="$(grep -E '^master +c-901@box-a ' <<<"$out")"
  failover="$(grep -E '^failover ' <<<"$out" | sed -n 1p)"
  [[ $rc -eq 0 ]] || { echo "  rc=$rc"; ok=0; }
  [[ "$(sed -n 1p <<<"$out")" =~ ^ROLE\ +ID\ +PID\ +AGE\ +PANE\ +FLAGS$ ]] || { echo "  header 1"; ok=0; }
  grep -qE '^ROLE +LAST-RID +LAST-PHASE +LAST-DONE +NEXT-SLOT +LAST-SKIP$' <<<"$out" || { echo "  header 2"; ok=0; }
  [[ "$orch" =~ ^orch\ +c-900@box-a\ +4242\ +10m\ +idle\ +--dangerously-skip-permissions\ --model\ opus ]] || { echo "  orch row: $orch"; ok=0; }
  [[ "$master" =~ ^master\ +c-901@box-a\ +none\ +-\ +-\ +-$ ]] || { echo "  master row: $master"; ok=0; }
  [[ "$failover" == *"not in $D/lease.conf" ]] || { echo "  failover row: $failover"; ok=0; }
  grep -qE '^orch +20261020T1005Z-orch +DONE OK +2026-10-20T10:07:01Z +[0-9T:-]+:05:00Z +2026-10-20T11:05:01Z young \(600s\)$' <<<"$out" || { echo "  orch rotation row"; ok=0; }
  grep -qE '^master +20261020T0915Z-master +ACK FAIL +- +[0-9T:-]+:15:00Z +-$' <<<"$out" || { echo "  master rotation row"; ok=0; }
  grep -qx 'rotate.hold: none' <<<"$out" || { echo "  hold"; ok=0; }
  grep -qx 'switches: ROTATE=1 ROTATE_ORCH=1 ROTATE_DISPATCH=1 (no rotate.conf)' <<<"$out" || { echo "  switches"; ok=0; }
  grep -qx "cron: 2 rotation line(s) installed; log $D/rotate.log" <<<"$out" || { echo "  cron"; ok=0; }
  if (( ok )); then pass "$label"; else fail "$label: $out"; fi
}

out=$(rotate_status); rc=$?
check_rotate "1. rotate status: headers, role rows, last rid/phase/done/skip, hold, switches, cron, exit 0" "$out" "$rc"

# the next slot is the next :05 (orch) / :15 (master) after now, within the hour
now=$(date -u +%s)
for r in orch:05 master:15; do
  slot="$(grep -E "^${r%%:*} " <<<"$out" | sed -n 2p | awk '{print $6}')"
  s=$(date -u -d "$slot" +%s 2>/dev/null || echo 0)
  if [[ "$slot" == *":${r#*:}:00Z" ]] && (( s > now - 5 && s <= now + 3600 )); then
    pass "1. ${r%%:*} next slot $slot is the next :${r#*:} within the hour"
  else fail "1. ${r%%:*} next slot '$slot' (now $now)"; fi
done

# 2. a stalled pane, rotate.hold, a rotate.conf switch
printf 'working\nYou have hit your limit: usage limit reached\n' >"$T/screen"
echo "c-900 by owner" >"$D/rotate.hold"
printf 'ROTATE_ORCH=0\n' >"$D/rotate.conf"
out=$(rotate_status); rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^orch +c-900@box-a +4242 +10m +stalled ' <<<"$out" &&
  grep -qE '^rotate.hold: c-900 by owner \([0-9]+s old\)$' <<<"$out" &&
  grep -qx "switches: ROTATE=1 ROTATE_ORCH=0 ROTATE_DISPATCH=1 ($D/rotate.conf)" <<<"$out"; then
  pass "2. usage-limit footer = stalled; rotate.hold with its age; rotate.conf switch shown"
else fail "2. stalled/hold/conf: rc=$rc out=$out"; fi
rm -f "$D/rotate.hold" "$D/rotate.conf"
idle_screen

mv "$D/rotate.log" "$T/rotate.log.keep"
out=$(rotate_status); rc=$?
if [[ $rc -eq 0 && "$(grep -cE '^(orch|master|failover) +- +- +[0-9T:-]+Z +-$' <<<"$out")" == 3 ]]; then
  pass "2. no rotate.log: every rotation row reads '-' and its slot, exit 0"
else fail "2. no rotate.log: rc=$rc out=$out"; fi
mv "$T/rotate.log.keep" "$D/rotate.log"

out=$(rotate_status ROTATE_POLL=x); rc=$?
if [[ $rc -eq 1 && "$out" == *"FATAL ROTATE_POLL must be a whole number"* && "$out" != *"ROLE "* ]]; then
  pass "2. a bad ROTATE_* knob: exit 1, FATAL, no table"
else fail "2. bad knob: rc=$rc out=$out"; fi

# ============================================================================
# 3. do_spl_local_hub_status
# ============================================================================
# curl: prints the code for the URL from $CURL_CODES ("<substring> <code>")
cat >"$T/stub/curl" <<'EOF'
#!/bin/bash
url="${*: -1}"
while read -r k c; do [[ "$url" == *"$k"* ]] && { printf '%s' "$c"; exit 0; }; done <"$CURL_CODES"
printf '000'; exit 7
EOF
# ss -Hltn "sport = :<port>": the listeners of <port> from $SS_DIR/ss.<port>
cat >"$T/stub/ss" <<'EOF'
#!/bin/bash
p="${*: -1}"; p="${p##*:}"
[[ -f "$SS_DIR/ss.$p" ]] && cat "$SS_DIR/ss.$p"
exit 0
EOF
chmod +x "$T/stub/curl" "$T/stub/ss"
H="$T/hub"; mkdir -p "$H"
ss_ok() {
  local p
  for p in 15432 14443 18080 13000; do echo "LISTEN 0 4096 127.0.0.1:$p 0.0.0.0:*" >"$H/ss.$p"; done
  printf 'healthz 200\n13000/ 200\n' >"$H/curl.codes"
  printf 'pg running\nhub running\nwui running\n' >"$H/services"
}
# the cnf, user switch and compose project are replaced: only the checks run
LH_PRE='spl_local_hub_cnf() { return 0; }
  spl_local_hub_is_user() { return 0; }
  spl_local_hub_env() { return 0; }
  do_gen_docker_env() { return 0; }
  lde_compose() { if [[ "$*" == *"{{.Service}} {{.State}}"* ]]; then cat "$SS_DIR/services"; else echo "SERVICE STATE STATUS"; fi; }
  unset -f do_spl_local_hub_ports_gate
  LDE_SMOKE_TENANT=t1 LDE_HUB_PORT=18080 LDE_WUI_PORT=13000 LDE_PG_PORT=15432 LDE_GCS_PORT=14443 LDE_COMPOSE_PROJECT=lh-test'
local_hub_status() {
  SNIPPET="$LH_PRE"$'\n'"${LH_EXTRA:-}"$'\n''do_spl_local_hub_status' in_orc SPOOL_ROOT="$S" \
    CURL_CODES="$H/curl.codes" SS_DIR="$H" LOCAL_HUB_SS="$T/stub/ss" 2>&1
}

check_hub_ok() {
  local label="$1" out="$2" rc="$3"
  if [[ $rc -eq 0 ]] && grep -qx 'OK all 3 services running' <<<"$out" && grep -qx 'OK hub -> 200' <<<"$out" &&
    grep -qx 'OK wui -> 200' <<<"$out" &&
    [[ "$(grep -cE '^OK port [0-9]+: loopback only \(127\.0\.0\.1:[0-9]+ \)$' <<<"$out")" == 4 ]] &&
    grep -qx 'WARN do_spl_local_hub_ports_gate is not on this tree: only the four local hub ports were checked' <<<"$out" &&
    grep -qx 'OK local hub lh-test: all PASS' <<<"$out" && ! grep -q '^ERROR' <<<"$out"; then
    pass "$label"
  else fail "$label: rc=$rc out=$out"; fi
}
ss_ok
out=$(local_hub_status); rc=$?
check_hub_ok "3. local hub all PASS: services, hub, wui, 4 loopback ports, ports gate WARN only, exit 0" "$out" "$rc"

# hub_fail <label> <ERROR line> <fails>: exit 1, the line, the FAIL count
hub_fail() {
  local out rc
  out=$(local_hub_status); rc=$?
  if [[ $rc -eq 1 ]] && grep -qxF "$2" <<<"$out" && grep -qx "ERROR local hub: $3 FAIL" <<<"$out" &&
    ! grep -q 'all PASS' <<<"$out"; then
    pass "3. $1 -> '$2', $3 FAIL, exit 1"
  else fail "3. $1: rc=$rc out=$out"; fi
  ss_ok
}
printf 'healthz 503\n13000/ 200\n' >"$H/curl.codes"; hub_fail "hub /healthz 503" 'ERROR hub -> 503' 1
printf 'healthz 200\n' >"$H/curl.codes"; hub_fail "wui no answer" 'ERROR wui -> 000' 1
printf 'LISTEN 0 4096 0.0.0.0:18080 0.0.0.0:*\nLISTEN 0 4096 [::1]:18080 [::]:*\n' >"$H/ss.18080"
hub_fail "hub port on 0.0.0.0" 'ERROR port 18080 listens beyond loopback: 0.0.0.0:18080' 1
rm -f "$H/ss.15432"; hub_fail "pg port with no listener" 'ERROR port 15432: nothing listens' 1
printf 'pg running\nhub restarting\nwui exited\n' >"$H/services"
hub_fail "a restarting and an exited service" 'ERROR not running: hub is restarting wui is exited' 1
: >"$H/services"; hub_fail "no service at all" 'ERROR no service of lh-test runs' 1
printf 'healthz 500\n' >"$H/curl.codes"; rm -f "$H/ss.13000"
hub_fail "hub 500 + wui down + wui port free: each counted" 'ERROR port 13000: nothing listens' 3

# the ports gate, when loaded, is one more check
LH_EXTRA='do_spl_local_hub_ports_gate() { echo "GATE ran"; return 1; }'
out=$(local_hub_status); rc=$?
if [[ $rc -eq 1 && "$out" == *"GATE ran"* && "$out" == *"ERROR local hub: 1 FAIL"* && "$out" != *"WARN do_spl_local_hub_ports_gate"* ]]; then
  pass "3. a loaded ports gate runs; its failure is one FAIL, no WARN"
else fail "3. ports gate: rc=$rc out=$out"; fi
LH_EXTRA=''

# ============================================================================
# 4. do_spl_dispatch_deploy_lag
# ============================================================================
deploy_lag() {
  SNIPPET="${DL_PRE:-}"$'\n''do_spl_dispatch_deploy_lag' in_orc SPOOL_ROOT="$S" DISPATCH_LAG_SHA=abc1234 "$@" 2>&1
}
OKCMD='echo "$ENV hub current served=abc1234 sha=abc1234 url=https://x.invalid/version"; echo "$ENV wui pending served=a sha=b n=1 age=3m (in grace)"'
check_lag_ok() {
  local label="$1" out="$2" rc="$3" want
  want="$(printf '%s\n' '| what | value | verdict |' '|---|---|---|' \
    '| deploy lag dev hub | current served=abc1234 sha=abc1234 | ok |' \
    '| deploy lag dev wui | pending served=a sha=b n=1 age=3m | ok |' \
    '| deploy lag prd hub | current served=abc1234 sha=abc1234 | ok |' \
    '| deploy lag prd wui | pending served=a sha=b n=1 age=3m | ok |')"
  if [[ $rc -eq 0 && "$out" == "$want" ]]; then pass "$label"; else fail "$label: rc=$rc out=$out"; fi
}
out=$(deploy_lag DISPATCH_LAG_CMD="$OKCMD"); rc=$?
check_lag_ok "4. deploy lag current/pending: header + 4 ok rows, url= dropped, '(in grace)' cut, exit 0" "$out" "$rc"

LAGCMD='if [ "$ENV" = prd ]; then echo "prd hub lagging served=ef48 sha=0e72 n=5 age=54m grace=30m a|b"; else echo "dev hub current"; fi; echo "$ENV wui current"'
out=$(deploy_lag DISPATCH_LAG_CMD="$LAGCMD" DISPATCH_LAG_GRACE=30); rc=$?
if [[ $rc -eq 1 && "$(grep -c 'GAP' <<<"$out")" == 1 ]] &&
  grep -qxF '| deploy lag prd hub | served=ef48 sha=0e72 n=5 age=54m grace=30m a/b | GAP trunk input not served after 30 min: 21_hub-deploy-catchup dispatches it; if it stays, the deploy is broken: gh run list --workflow 20_hub-build-deploy.yml |' <<<"$out" &&
  grep -qxF '| deploy lag dev hub | current | ok |' <<<"$out"; then
  pass "4. lagging = one GAP row ('|' made '/', the hub workflow named), exit 1"
else fail "4. lagging: rc=$rc out=$out"; fi
out=$(deploy_lag DISPATCH_LAG_CMD='echo "$ENV wui lagging n=2"' DISPATCH_LAG_ENVS=dev); rc=$?
if [[ $rc -eq 1 && "$out" == *"| deploy lag dev wui | n=2 | GAP "*"--workflow 30_wui-build-deploy.yml |"* && "$out" != *prd* ]]; then
  pass "4. a lagging wui names workflow 30; DISPATCH_LAG_ENVS=dev asks dev only"
else fail "4. wui lag: rc=$rc out=$out"; fi

out=$(deploy_lag DISPATCH_LAG_CMD='echo "$ENV hub unknown url=x reason=unreachable"; echo "$ENV wui current"; echo "qa hub lagging"; echo "$ENV db lagging"; echo garbage'); rc=$?
if [[ $rc -eq 0 && "$(grep -c '^| deploy lag' <<<"$out")" == 4 && "$out" != *GAP* ]] &&
  grep -qxF '| deploy lag dev hub | unknown reason=unreachable | cannot tell |' <<<"$out"; then
  pass "4. unknown = 'cannot tell', never a GAP; another env, component or junk line is ignored, exit 0"
else fail "4. unknown/ignored: rc=$rc out=$out"; fi
out=$(deploy_lag DISPATCH_LAG_CMD='true'); rc=$?
if [[ $rc -eq 0 ]] && grep -qxF '| deploy lag dev | no verdict | cannot tell |' <<<"$out" &&
  grep -qxF '| deploy lag prd | no verdict | cannot tell |' <<<"$out"; then
  pass "4. an empty probe = 'no verdict', cannot tell, exit 0"
else fail "4. empty probe: rc=$rc out=$out"; fi
DL_PRE='unset -f do_check_deploy_lag'
out=$(deploy_lag DISPATCH_LAG_CMD=); rc=$?
DL_PRE=''
if [[ $rc -eq 0 ]] && grep -qxF '| deploy lag dev | do_check_deploy_lag is not loaded | cannot tell |' <<<"$out"; then
  pass "4. no do_check_deploy_lag = cannot tell, exit 0"
else fail "4. not loaded: rc=$rc out=$out"; fi
out=$(deploy_lag DISPATCH_LAG_CMD='echo "$ENV hub current sha=$SHA grace=$GRACE_MINUTES"' DISPATCH_LAG_GRACE=45); rc=$?
if [[ $rc -eq 0 ]] && grep -qxF '| deploy lag prd hub | current sha=abc1234 grace=45 | ok |' <<<"$out"; then
  pass "4. ENV, SHA and GRACE_MINUTES reach the probe"
else fail "4. probe env: rc=$rc out=$out"; fi
out=$(unset DISPATCH_LAG_GRACE; deploy_lag DISPATCH_LAG_CMD='echo "$ENV hub current grace=$GRACE_MINUTES"'); rc=$?
if [[ $rc -eq 0 ]] && grep -qxF '| deploy lag prd hub | current grace=60 | ok |' <<<"$out"; then
  pass "4. DISPATCH_LAG_GRACE unset: the probe gets grace=60"
else fail "4. default grace: rc=$rc out=$out"; fi
AGE41CMD='if (( 41 < GRACE_MINUTES )); then v=pending; else v=lagging; fi; echo "$ENV hub $v n=1 age=41m"'
out=$(unset DISPATCH_LAG_GRACE; deploy_lag DISPATCH_LAG_CMD="$AGE41CMD"); rc=$?
if [[ $rc -eq 0 && "$out" != *GAP* ]] && grep -qxF '| deploy lag prd hub | pending n=1 age=41m | ok |' <<<"$out"; then
  pass "4. a 41-min-old input under the default grace is pending, no GAP (healthy p90 ~46 min)"
else fail "4. 41 min default grace: rc=$rc out=$out"; fi
out=$(deploy_lag DISPATCH_LAG_CMD="$AGE41CMD" DISPATCH_LAG_GRACE=30); rc=$?
if [[ $rc -eq 1 && "$(grep -c 'GAP trunk input not served after 30 min' <<<"$out")" == 2 ]]; then
  pass "4. control: DISPATCH_LAG_GRACE=30 still makes the 41-min input a GAP"
else fail "4. 41 min grace 30: rc=$rc out=$out"; fi
out=$(deploy_lag DISPATCH_LAG_CMD="$OKCMD" DISPATCH_DEPLOY_LAG=0); rc=$?
if [[ $rc -eq 0 && "$(grep -c '^| deploy lag' <<<"$out")" == 4 ]]; then
  pass "4. the action asks even with DISPATCH_DEPLOY_LAG=0 (that switch is the dispatch check's)"
else fail "4. DISPATCH_DEPLOY_LAG=0: rc=$rc out=$out"; fi

# ============================================================================
# 5. CONTROLS: a mutant of each action is caught by the same checks
# ============================================================================
# mutant <func> <sed-expr>: the function's own source, mutated, as a SNIPPET
mutant() {
  # shellcheck disable=SC2016 # expanded by the in_orc shell
  SNIPPET='declare -f "$MUT_FN" | sed -E "$MUT_SED"' in_orc MUT_FN="$1" MUT_SED="$2" 2>/dev/null
}
# ctl <label> <check> <args...>: the check must FAIL on the mutant's output
ctl() {
  local label="$1" before=$fails; shift
  "$@" >/dev/null
  if (( fails > before )); then fails=$before; pass "5. CONTROL caught: $label"
  else fail "5. CONTROL missed: $label"; fi
}
# each mutant must differ from the source, or the control proves nothing
mutated() { [[ -n "$1" && "$1" != "$(mutant "$2" 's/^$//')" ]] || fail "5. the mutant of $2 is unchanged"; }

PRE="$(mutant do_spl_rotate_status 's/ ROLE ID PID AGE PANE FLAGS/ ROLE ID PID AGE STATE FLAGS/')"
mutated "$PRE" do_spl_rotate_status
out=$(rotate_status); rc=$?; PRE=''
ctl "rotate status header renamed (PANE -> STATE)" check_rotate x "$out" "$rc"
PRE="$(mutant do_spl_rotate_status 's/state=stalled/state=busy/')"
mutated "$PRE" do_spl_rotate_status
printf 'working\nusage limit reached\n' >"$T/screen"
out=$(rotate_status); rc=$?; PRE=''
if grep -qE '^orch +c-900@box-a +4242 +10m +stalled ' <<<"$out"; then
  fail "5. CONTROL missed: a stalled pane reported busy"
else pass "5. CONTROL caught: a stalled pane reported busy"; fi
idle_screen

ss_ok
LH_EXTRA="$(mutant do_spl_local_hub_status 's/fails=\$\(\(fails \+ 1\)\)/:/g')"
mutated "$LH_EXTRA" do_spl_local_hub_status
printf 'healthz 503\n13000/ 200\n' >"$H/curl.codes"
ctl "local hub mutant that never counts a FAIL" hub_fail "hub 503 under the mutant" 'ERROR hub -> 503' 1
LH_EXTRA="$(mutant _slh_status_line 's/do_log "OK \$1 -> 200";/:;/')"
mutated "$LH_EXTRA" _slh_status_line
out=$(local_hub_status); rc=$?
ctl "local hub mutant that drops the OK status line" check_hub_ok x "$out" "$rc"
LH_EXTRA=''

DL_PRE="$(mutant do_spl_dispatch_deploy_lag 's/\(\( gaps \)\) && return 1/:/')"
mutated "$DL_PRE" do_spl_dispatch_deploy_lag
out=$(deploy_lag DISPATCH_LAG_CMD="$LAGCMD"); rc=$?; DL_PRE=''
if [[ $rc -eq 1 ]]; then fail "5. CONTROL missed: deploy lag mutant exits 0 on a GAP"
else pass "5. CONTROL caught: deploy lag mutant exits $rc on a GAP"; fi
DL_PRE="$(mutant do_spl_dispatch_deploy_lag 's/\| what \| value \| verdict \|/| what | value |/')"
mutated "$DL_PRE" do_spl_dispatch_deploy_lag
out=$(deploy_lag DISPATCH_LAG_CMD="$OKCMD"); rc=$?; DL_PRE=''
ctl "deploy lag table header broken" check_lag_ok x "$out" "$rc"

echo
if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
