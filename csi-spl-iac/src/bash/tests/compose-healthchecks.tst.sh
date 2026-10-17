#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the standalone stack (root docker-compose.yml) checks the health of
#          every service and starts each one only after what it needs is ready
#          (owner security scan, revised list, action 4: "Add healthchecks to
#          hub-init and web"; SPL-2156, epic SPL-2151). Doc:
#          csi-spl-doc/doc/md/security-baselines.md section 7.
#   1. every long-running service (restart is not "no") and the one shot
#      hub-init have a healthcheck with a test (not NONE, not disabled)
#   2. every depends_on waits for the right state: a one shot (restart "no")
#      with service_completed_successfully, any other with service_healthy
#   3. hub-init's check reads the readiness file hub-entrypoint.sh writes
#      (init.ready in its state dir); web's probes its own port 80
#   CONTROLS: a planted file with a web with no healthcheck, a hub-init whose
#   check is disabled and a depends_on hub-init service_started fail the same
#   checks
# Hermetic: yq + jq over the files, no docker, no network. The live proof is
# `docker compose up` (wf 50): docker compose ps shows each one (healthy).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v yq >/dev/null || { fail "yq is not installed"; exit 1; }
command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
COMPOSE="$APP_ROOT/docker-compose.yml"
EP="$APP_ROOT/csi-spl-api/src/docker/hub-entrypoint.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# check_file <path>: one "BAD <svc>: <why>" or "OK <svc> <what>" line per check
check_file() {
  local json
  json=$(yq -o json '.' "$1" 2>&1) || { echo "BAD -: does not parse: $json"; return; }
  jq -r '
    (.services // {}) as $s
    | ($s | to_entries[]
        | select((.value.restart // "") != "no" or .key == "hub-init")
        | .key as $k | .value.healthcheck as $h
        | if $h == null then "BAD \($k): no healthcheck"
          elif ($h.disable // false) then "BAD \($k): healthcheck disabled"
          elif (($h.test // []) | if type == "array" then (length == 0 or .[0] == "NONE") else (. == "") end)
            then "BAD \($k): healthcheck has no test"
          else "OK \($k) has a healthcheck" end),
      ($s | to_entries[] | .key as $k
        | (.value.depends_on // {})
        | (if type == "array" then map({key: ., value: {}}) else to_entries end)[]
        | .key as $d | (.value.condition // "service_started") as $c
        | (if (($s[$d].restart // "") == "no") then "service_completed_successfully" else "service_healthy" end) as $want
        | if $c == $want then "OK \($k) waits for \($d) \($c)"
          else "BAD \($k): depends_on \($d) is \($c), want \($want)" end)
  ' <<<"$json"
}

# --- 1 + 2. the standalone compose file -----------------------------------------------
[[ -f "$COMPOSE" ]] || { fail "no $COMPOSE"; exit 1; }
while read -r verdict rest; do
  if [[ "$verdict" == OK ]]; then pass "$rest"; else fail "$rest"; fi
done < <(check_file "$COMPOSE")
for s in hub-init web; do
  yq -e ".services[\"$s\"].healthcheck.test" "$COMPOSE" >/dev/null 2>&1 &&
    pass "$s has a healthcheck test" || fail "$s has no healthcheck test"
done

# --- 3. what the two checks probe -----------------------------------------------------
hc_init=$(yq -r '.services["hub-init"].healthcheck.test | join(" ")' "$COMPOSE" 2>/dev/null)
state=$(sed -n 's/^state="\${SPOOL_STATE_DIR:-\([^}]*\)}"$/\1/p' "$EP")
[[ -n "$state" ]] && pass "hub-entrypoint.sh state dir default: $state" || fail "no state dir default in $EP"
grep -q '>"$state/init.ready"' "$EP" && grep -q 'rm -f "$state/init.ready"' "$EP" &&
  pass "hub-entrypoint.sh removes init.ready first and writes it last" || fail "hub-entrypoint.sh does not manage init.ready"
[[ -n "$state" && "$hc_init" == *"$state/init.ready"* ]] &&
  pass "hub-init's check reads $state/init.ready" || fail "hub-init's check '$hc_init' does not read $state/init.ready"
hc_web=$(yq -r '.services.web.healthcheck.test | join(" ")' "$COMPOSE" 2>/dev/null)
web_port=$(yq -r '.services.web.ports[0]' "$COMPOSE")
[[ "$web_port" == *":80" && "$hc_web" == *"http://127.0.0.1:80/"* ]] &&
  pass "web's check probes its own port 80 ($web_port)" || fail "web's check '$hc_web' does not probe port 80 (ports: $web_port)"

# --- CONTROLS ---------------------------------------------------------------------------
cat >"$T/compose-plant.yaml" <<'PLANT'
services:
  hub-init:
    image: alpine
    restart: "no"
    healthcheck:
      disable: true
  hub:
    image: alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "true"]
    depends_on:
      hub-init:
        condition: service_started
  web:
    image: alpine
    restart: unless-stopped
    depends_on:
      hub:
        condition: service_healthy
PLANT
out=$(check_file "$T/compose-plant.yaml")
grep -q '^BAD web: no healthcheck' <<<"$out" && pass "control: a web with no healthcheck fails" || fail "control: web passed: $out"
grep -q '^BAD hub-init: healthcheck disabled' <<<"$out" && pass "control: a disabled hub-init check fails" || fail "control: hub-init passed: $out"
grep -q '^BAD hub: depends_on hub-init is service_started' <<<"$out" && pass "control: waiting for a one shot to merely start fails" || fail "control: depends_on passed: $out"
grep -q '^OK web waits for hub service_healthy' <<<"$out" && pass "control: service_healthy on a long-running service passes" || fail "control: good depends_on failed: $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
exit 1
