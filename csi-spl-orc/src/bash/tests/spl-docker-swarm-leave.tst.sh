#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_docker_swarm_leave (SPL-1960, security round 1 row 3) on a
#          docker stub and an ss stub whose state lives in files.
#   1. refusals: DRY_RUN=2
#   2. DRY_RUN is the default: prints the measures, would leave, no leave run
#   3. in use: a service, a second node, a swarm network, a secret -> each
#      refused by name, no leave
#   4. DRY_RUN=0: leave --force, state inactive, ports closed; a second run
#      has nothing to do
#   5. CONTROL: a leave that leaves the manager port listening fails the apply
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

F="$T/fake"; mkdir -p "$F" "$T/stub"
reset_fake() {
  echo active >"$F/state"; echo 1 >"$F/nodes"; : >"$F/services"; : >"$F/secrets"; : >"$F/configs"
  printf 'ingress\n' >"$F/nets"; printf 'LISTEN 0 4096 *:2377 *:*\nLISTEN 0 4096 *:7946 *:*\n' >"$F/listen"
}
cat >"$T/stub/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
case "$1 $2" in
  "info --format") case "$3" in *LocalNodeState*) cat "$FAKE/state" ;; *Nodes*) cat "$FAKE/nodes" ;; esac ;;
  "service ls") cat "$FAKE/services" ;;
  "secret ls") cat "$FAKE/secrets" ;;
  "config ls") cat "$FAKE/configs" ;;
  "network ls") cat "$FAKE/nets" ;;
  "swarm leave") echo inactive >"$FAKE/state"; [[ "${FAKE_KEEP_LISTEN:-0}" == 1 ]] || : >"$FAKE/listen" ;;
esac
STUB
printf '#!/usr/bin/env bash\ncat "$FAKE/listen"\n' >"$T/stub/ss"
chmod +x "$T/stub/docker" "$T/stub/ss"
sl() { SNIPPET=do_spl_docker_swarm_leave in_orc FAKE="$F" "$@" >"$T/o" 2>&1; }

# --- 1. refusals -------------------------------------------------------------------------------
reset_fake
sl DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"

# --- 2. DRY_RUN default ------------------------------------------------------------------------
: >"$T/calls.log"
sl; rc=$?
[[ $rc -eq 0 ]] && grep -qx "swarm state=active nodes=1 services=0 secrets=0 configs=0 swarm networks besides ingress=none" "$T/o" &&
  grep -q "listening now: \*:2377 \*:7946" "$T/o" && grep -q "DRY_RUN would: docker swarm leave --force" "$T/o" &&
  ! grep -q "swarm leave" "$T/calls.log" && [[ "$(cat "$F/state")" == active ]] &&
  pass "dry run: measures printed, would leave, nothing run" || fail "dry run: rc=$rc $(cat "$T/o")"

# --- 3. in use ---------------------------------------------------------------------------------
check_used() {
  local what="$1" want="$2"
  : >"$T/calls.log"
  sl DRY_RUN=0 && fail "$what: leaves a used swarm" ||
    { grep -q "$want" "$T/o" && grep -q "FAIL docker swarm is in use" "$T/o" && ! grep -q "swarm leave" "$T/calls.log" &&
      pass "$what: refused by name, no leave" || fail "$what: $(cat "$T/o")"; }
  reset_fake
}
printf 'abc123\n' >"$F/services"; check_used "a service" "REFUSED: 1 swarm service(s)"
echo 2 >"$F/nodes"; check_used "a second node" "REFUSED: 2 nodes"
printf 'ingress\nappnet\n' >"$F/nets"; check_used "a swarm network" "REFUSED: swarm networks in use: appnet"
printf 's1\n' >"$F/secrets"; check_used "a secret" "REFUSED: swarm secrets (1)"

# --- 4. DRY_RUN=0 ------------------------------------------------------------------------------
sl DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK docker swarm left: state inactive" "$T/o" && grep -q "swarm leave --force" "$T/calls.log" &&
  [[ "$(cat "$F/state")" == inactive && ! -s $F/listen ]] && pass "applied: left, inactive, ports closed" || fail "apply: rc=$rc $(cat "$T/o")"
sl DRY_RUN=0
grep -q "not in a swarm, nothing to do" "$T/o" && pass "second run: nothing to do" || fail "rerun: $(cat "$T/o")"

# --- 5. CONTROL --------------------------------------------------------------------------------
reset_fake
sl DRY_RUN=0 FAKE_KEEP_LISTEN=1 && fail "CONTROL: a leave that keeps :2377 open passes" ||
  { grep -q "FAIL after the leave: state=inactive listening=\*:2377" "$T/o" &&
    pass "CONTROL: a leave that keeps :2377 open fails the apply" || fail "CONTROL: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
