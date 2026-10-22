#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every docker compose service sits on a declared bridge network,
#          never on compose's implicit `default` (owner security scan, revised
#          list, action 3: "Define a custom bridge network and attach all
#          services"; SPL-2155, epic SPL-2151). Doc:
#          csi-spl-doc/doc/md/security-baselines.md section 6.
#   1. every tracked compose file (git ls-files '*compose*.y*ml') belongs to
#      one STACK below (the files compose loads together); a new file that
#      belongs to none fails, so it cannot slip past the check
#   2. in each stack, merged as compose merges -f files: every service has
#      `network_mode: none` or a non-empty `networks:`, each network it names
#      is declared at the top level with driver bridge (or external: a
#      network the Makefile creates with --driver bridge), and no stack
#      declares a network called `default`
#   3. the standalone stack (docker-compose.yml) publishes host ports from
#      `web` only: pg, s3 and the hub are reached by service name on the
#      bridge, never from the host. The one exception is a service of the
#      `dev` profile (local dev mode, spec 148: Mailpit) whose every port
#      binds 127.0.0.1
#   4. `docker compose config` parses docker-compose.yml with its defaults and
#      the rendered model holds the same (SKIP without docker)
#   CONTROLS: a planted stack with a service with no networks:, one on an
#   undeclared network, one on a declared non-bridge network and a stack
#   declaring `default` each fail the same check; a ports: on pg fails 3,
#   and so do a dev-profile service on 0.0.0.0 and a loopback one outside dev
# Hermetic for 1-3: yq + jq over the files, no docker, no network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v yq >/dev/null || { fail "yq is not installed"; exit 1; }
command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

D=csi-spl-orc/src/docker
# <stack name> <file>...: lde = lde_compose (lde-cnf.func.sh) + its
# LDE_COMPOSE_EXTRA_FILES (local hub); tf-infra = make do-setup-app-inf
STACKS=(
  "standalone docker-compose.yml"
  "lde $D/docker-compose-infra.yaml $D/docker-compose-rdb.yaml $D/docker-compose-api.yaml $D/docker-compose-wui.yaml $D/docker-compose-local-hub.yaml $D/docker-compose-local-hub-backup.yaml $D/docker-compose-local-hub-vault.yaml"
  "tf-infra $D/docker-compose-tf-infra.yaml"
)

# merge_stack <root> <file>...: one JSON model, objects deep-merged in -f order
merge_stack() {
  local root="$1" f; shift
  for f in "$@"; do yq -o json '.' "$root/$f" || return 1; done | jq -s 'reduce .[] as $x ({}; . * $x)'
}

# check_model <label> <json file>: one "BAD <label> <svc>: <why>" or
# "OK <label> <svc> ..." line per service, plus BAD for a `default` network
check_model() {
  jq -r --arg l "$1" '
    (.networks // {}) as $nets
    | (if $nets | has("default") then "BAD \($l) -: declares a network called default" else empty end),
      ((.services // {}) | to_entries[] | .key as $s | .value as $v
       | ($v.networks // null | if type == "object" then keys elif type == "array" then . else [] end) as $on
       | if $v.network_mode == "none" then "OK \($l) \($s) network_mode none"
         elif $v.network_mode != null then "BAD \($l) \($s): network_mode \($v.network_mode)"
         elif ($on | length) == 0 then "BAD \($l) \($s): no networks: (lands on the implicit default)"
         else ($on[] as $n
               | if ($nets | has($n) | not) then "BAD \($l) \($s): network \($n) is not declared"
                 elif ($nets[$n].external // false) == true then "OK \($l) \($s) on external \($n)"
                 elif ($nets[$n].driver // "") != "bridge" then "BAD \($l) \($s): network \($n) is not driver bridge"
                 else "OK \($l) \($s) on bridge \($n)" end)
         end)' "$2"
}

# host_ports <json file>: "<service>" per service that publishes a port
host_ports() { jq -r '(.services // {}) | to_entries[] | select((.value.ports // []) | length > 0) | .key' "$1"; }
# public_ports <json file>: the same, less a dev-profile service whose every
# port binds 127.0.0.1 (a short "127.0.0.1:..." string or a long host_ip)
public_ports() {
  jq -r '(.services // {}) | to_entries[] | select((.value.ports // []) | length > 0)
    | select((((.value.profiles // []) | index("dev")) != null
              and ((.value.ports | map(if type == "string" then startswith("127.0.0.1:") else .host_ip == "127.0.0.1" end)) | all)) | not)
    | .key' "$1"
}

tally() {
  local verdict rest
  while read -r verdict rest; do
    if [[ "$verdict" == OK ]]; then pass "$rest"; else fail "$rest"; fi
  done
}

# --- 1. every tracked compose file is in a stack -----------------------------------
mapfile -t files < <(git -C "$APP_ROOT" ls-files | grep -E '(^|/)[^/]*compose[^/]*\.ya?ml$')
[[ "${#files[@]}" -gt 0 ]] && pass "${#files[@]} compose files tracked" || fail "no compose file found under $APP_ROOT"
listed=" ${STACKS[*]} "
for f in "${files[@]}"; do
  [[ "$listed" == *" $f "* ]] && pass "$f is in a stack" || fail "$f is in no stack of this test: add it to STACKS"
done

# --- 2. per stack: every service on a declared bridge network ----------------------
for st in "${STACKS[@]}"; do
  read -r -a parts <<<"$st"
  if merge_stack "$APP_ROOT" "${parts[@]:1}" >"$T/${parts[0]}.json" 2>"$T/err"; then
    tally < <(check_model "${parts[0]}" "$T/${parts[0]}.json")
  else
    fail "${parts[0]}: does not parse: $(tail -1 "$T/err")"
  fi
done

# --- 3. standalone: only web publishes host ports (dev profile: loopback only) -----
got=$(public_ports "$T/standalone.json" | tr '\n' ' ')
[[ "$got" == "web " ]] && pass "standalone: only web publishes host ports (dev profile on 127.0.0.1 aside)" || fail "standalone: services publishing host ports: '$got' (want 'web')"

# --- 4. docker compose renders the same model --------------------------------------
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  if (cd "$APP_ROOT" && env -i PATH="$PATH" HOME="$T" docker compose -f docker-compose.yml config --format json) >"$T/rendered.json" 2>"$T/err"; then
    pass "docker compose config parses docker-compose.yml"
    tally < <(check_model rendered "$T/rendered.json")
    got=$(host_ports "$T/rendered.json" | tr '\n' ' ')
    [[ "$got" == "web " ]] && pass "rendered: only web publishes host ports" || fail "rendered: host ports from '$got'"
    jq -e '.networks | keys | map(select(. == "default")) | length == 0' "$T/rendered.json" >/dev/null \
      && pass "rendered: no default network in the model" || fail "rendered: a default network is in the model"
  else
    fail "docker compose config: $(tail -2 "$T/err")"
  fi
else
  echo "SKIP: docker compose not available: section 4"
fi

# --- CONTROLS: the same checks fail a planted stack --------------------------------
cat >"$T/plant-a.yaml" <<'EOF'
networks:
  front: { driver: bridge }
  odd: { driver: macvlan }
services:
  fine: { image: alpine, networks: [front] }
  none-ok: { image: alpine, network_mode: none }
  no-net: { image: alpine }
  undeclared: { image: alpine, networks: [ghost] }
EOF
cat >"$T/plant-b.yaml" <<'EOF'
networks:
  default: { driver: bridge }
services:
  not-bridge: { image: alpine, networks: { odd: {} } }
  host-mode: { image: alpine, network_mode: host }
  pg: { image: alpine, networks: [front], ports: ["5432:5432"] }
EOF
merge_stack "$T" plant-a.yaml plant-b.yaml >"$T/plant.json" || fail "control: plant does not merge"
out=$(check_model plant "$T/plant.json")
for s in no-net undeclared not-bridge host-mode -; do
  grep -q "^BAD plant $s:" <<<"$out" && pass "control: $s fails the check" || fail "control: $s passed: $out"
done
for s in fine none-ok; do
  grep -q "^OK plant $s " <<<"$out" && pass "control: $s passes" || fail "control: $s failed: $out"
done
[[ "$(host_ports "$T/plant.json" | tr '\n' ' ')" == "pg " ]] && pass "control: a ports: on pg is seen" || fail "control: ports on pg not seen"
cat >"$T/plant-c.yaml" <<'EOF'
services:
  dev-open: { image: alpine, profiles: [dev], ports: ["0.0.0.0:1025:1025"] }
  dev-loop: { image: alpine, profiles: [dev], ports: ["127.0.0.1:8025:8025", {target: 1025, published: "1025", host_ip: 127.0.0.1}] }
  loop-no-profile: { image: alpine, ports: ["127.0.0.1:5432:5432"] }
EOF
yq -o json '.' "$T/plant-c.yaml" >"$T/plant-c.json" 2>/dev/null || fail "control: plant-c does not parse"
[[ "$(public_ports "$T/plant-c.json" | sort | tr '\n' ' ')" == "dev-open loop-no-profile " ]] \
  && pass "control: a dev service on 0.0.0.0 and a loopback one outside dev are seen, a loopback dev one is not" \
  || fail "control: public_ports gave '$(public_ports "$T/plant-c.json" | tr '\n' ' ')'"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
