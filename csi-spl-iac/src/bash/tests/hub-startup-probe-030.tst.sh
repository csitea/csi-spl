#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: CLE-35076 -- 030's startup probe asks at once and every second, so a
#          new hub instance is marked ready ~1 s after it listens instead of at
#          the fixed 2 s first probe; the total budget stays >= 120 s; Cloud
#          Run's timeout <= period rule holds. CONTROL: the previous block
#          (2 s delay, 5 s period) fails the readiness rule.
#          Session affinity follows the instance count: off while cnf runs
#          ONE instance (the GAESA cookie on every API call buys nothing),
#          on as soon as it runs more.
#          SPL-1129: GOMAXPROCS = cloud_run.cpu and GOMEMLIMIT 80..100 % of
#          cloud_run.memory in both rendered 030 tfvars.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
TF="$PROJ_ROOT/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf"

# probe <tf text> -> "delay timeout period threshold" of the startup_probe block
probe() {
  awk '/startup_probe[[:space:]]*\{/{on=1} on&&/initial_delay_seconds/{d=$3} on&&/timeout_seconds/{t=$3} on&&/period_seconds/{p=$3} on&&/failure_threshold/{f=$3; print d, t, p, f; exit}' <<<"$1"
}
# check <label> <d t p f> -> 0 when it meets the rule
check() {
  local d t p f; read -r d t p f <<<"$2"
  (( d == 0 && p <= 1 && t <= p && f * p >= 120 ))
}

got="$(probe "$(cat "$TF")")"
[[ -n "$got" ]] && pass "030 has a startup_probe ($got)" || fail "no startup_probe block in $TF"
check live "$got" && pass "startup probe: no initial delay, every 1 s, timeout <= period, budget >= 120 s" || fail "startup probe '$got' breaks the rule"
old='startup_probe {
        initial_delay_seconds = 2
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 24
      }'
check control "$(probe "$old")" && fail "CONTROL the old 2 s / 5 s probe passed the rule" || pass "CONTROL the old 2 s / 5 s probe fails the rule"

# session affinity: the expression in 030, evaluated for the cnf instance count
aff="$(sed -nE 's/^[[:space:]]*session_affinity[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$TF")"
[[ "$aff" == "var.max_instances > 1" ]] && pass "session_affinity = var.max_instances > 1" || fail "session_affinity is '$aff'"
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"
m="$(yq -r '.env.hub.cloud_run.max_instances' "$CNF/all.env.yaml")"
for env in dev prd; do
  o="$(yq -r '.env.hub.cloud_run.max_instances // ""' "$CNF/$env.env.yaml")"
  [[ -n "$o" && "$o" != null ]] && m="$m/$env:$o"
done
[[ "$m" == 1 ]] && pass "cnf max_instances is 1 (OQ-05), so the cookie is gone today" || fail "cnf max_instances changed: re-read this test"

# SPL-1129: the Go runtime is sized to the instance, in the rendered 030 tfvars
cpu="$(yq -r '.env.hub.cloud_run.cpu' "$CNF/all.env.yaml")"
mem="$(yq -r '.env.hub.cloud_run.memory' "$CNF/all.env.yaml")"
for env in dev prd; do
  line="$(grep -E '^environment_variables ' "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars")"
  p="$(sed -nE 's/.*"SPOOL_HUB_GOMAXPROCS": "([0-9]+)".*/\1/p' <<<"$line")"
  l="$(sed -nE 's/.*"SPOOL_HUB_GOMEMLIMIT": "([0-9]+)MiB".*/\1/p' <<<"$line")"
  [[ -n "$p" && "$p" == "$cpu" ]] && pass "$env GOMAXPROCS $p = cloud_run.cpu $cpu" || fail "$env GOMAXPROCS '$p' != cloud_run.cpu '$cpu'"
  [[ "$mem" =~ ^([0-9]+)Mi$ ]] && cap="${BASH_REMATCH[1]}" || cap=0
  [[ -n "$l" ]] && (( l < cap && l * 100 >= cap * 80 )) && pass "$env GOMEMLIMIT ${l}MiB is 80..100 % of ${mem}" || fail "$env GOMEMLIMIT '${l}MiB' vs cloud_run.memory '$mem'"
done

[[ $fails -eq 0 ]] && echo "PASS: all hub-startup-probe-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
