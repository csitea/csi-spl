#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the root docker-compose.yml pulls the published images by default
#          and builds them only behind `--build` (spec 072 A1b, T016).
#   1. no .env: hub-init, hub and web run <repo>/spool-{hub,web}:<tag>@sha256:<d>
#      with the repo ghcr.io/csitea, a stable-<date> tag (wf 56 publishes
#      stable-* only) and a digest per image (SPL-2153: pinned, the hub's two
#      the same, the web's its own), and each still carries its build, so
#      `SPOOL_IMAGE_TAG=local ... --build` builds them from this checkout
#   2. .env.example names SPOOL_IMAGE_REPO and SPOOL_IMAGE_TAG with the same
#      defaults as the compose file
#   3. SPOOL_IMAGE_REPO / SPOOL_IMAGE_TAG move all three images, and a set
#      SPOOL_IMAGE_TAG drops the digest (a chosen tag never pulls a stale one)
#   4. a pulled web image takes the public URL, tenant and lobby from its env
#      at start (072 A3), not from build args
#   CONTROL: the old local-only name spool-hub:local is gone from the config
# Hermetic: `docker compose config` only, no pull, no network, no daemon.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { fail "docker compose is not installed"; exit 1; }

# cfg [VAR=value ...] -> the resolved config as JSON, from a clean env (an
# operator's own SPOOL_* would otherwise leak in) and no .env file
cfg() {
  (cd "$APP_ROOT" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} "$@" \
    docker compose --env-file /dev/null -f docker-compose.yml config --format json)
}

# --- 1. the defaults ---------------------------------------------------------------
c=$(cfg 2>&1) || { fail "docker compose config: $c"; exit 1; }
tag=$(jq -r '.services.hub.image | sub("@.*"; "") | sub(".*:"; "")' <<<"$c")
[[ "$tag" =~ ^stable-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && pass "default tag $tag is a stable-<date> release" || fail "default tag '$tag' is not stable-<date>"
dig_hub=$(jq -r '.services.hub.image | sub(".*@"; "")' <<<"$c")
dig_web=$(jq -r '.services.web.image | sub(".*@"; "")' <<<"$c")
[[ "$dig_hub" =~ ^sha256:[0-9a-f]{64}$ && "$dig_web" =~ ^sha256:[0-9a-f]{64}$ && "$dig_hub" != "$dig_web" ]] \
  && pass "hub and web are pinned by their own sha256 digest" || fail "digests: hub '$dig_hub' web '$dig_web'"
for s in hub-init:hub:$dig_hub hub:hub:$dig_hub web:web:$dig_web; do
  IFS=: read -r svc img d1 d2 <<<"$s"
  got=$(jq -r --arg s "$svc" '.services[$s].image' <<<"$c")
  [[ "$got" == "ghcr.io/csitea/spool-$img:$tag@$d1:$d2" ]] && pass "$svc pulls $got" || fail "$svc image '$got', want ghcr.io/csitea/spool-$img:$tag@$d1:$d2"
  jq -e --arg s "$svc" '.services[$s].build.dockerfile | length > 0' <<<"$c" >/dev/null \
    && pass "$svc keeps its build (the --build switch)" || fail "$svc lost its build: --build cannot build it"
  pp=$(jq -r --arg s "$svc" '.services[$s].pull_policy // "default"' <<<"$c")
  [[ "$pp" == default || "$pp" == missing ]] && pass "$svc pull_policy $pp: pull first" || fail "$svc pull_policy '$pp' does not pull by default"
done

# --- 2. .env.example names the same defaults ------------------------------------------
ex="$APP_ROOT/.env.example"
grep -qxF '# SPOOL_IMAGE_TAG='"$tag" "$ex" && pass ".env.example: SPOOL_IMAGE_TAG=$tag" || fail ".env.example does not name SPOOL_IMAGE_TAG=$tag"
grep -qxF '# SPOOL_IMAGE_REPO=ghcr.io/csitea' "$ex" && pass ".env.example: SPOOL_IMAGE_REPO=ghcr.io/csitea" || fail ".env.example does not name SPOOL_IMAGE_REPO=ghcr.io/csitea"

# --- 3. the two variables move every image ----------------------------------------------
c3=$(cfg SPOOL_IMAGE_REPO=registry.example.org/acme SPOOL_IMAGE_TAG=stable-2099-01-01 2>&1)
imgs=$(jq -r '[.services["hub-init","hub","web"].image] | join(" ")' <<<"$c3")
[[ "$imgs" == "registry.example.org/acme/spool-hub:stable-2099-01-01 registry.example.org/acme/spool-hub:stable-2099-01-01 registry.example.org/acme/spool-web:stable-2099-01-01" ]] \
  && pass "SPOOL_IMAGE_REPO + SPOOL_IMAGE_TAG move all three images" || fail "override: $imgs"

# --- 4. the web container's runtime values ---------------------------------------------
c4=$(cfg SPOOL_PUBLIC_URL=https://chat.example.org SPOOL_TENANT=acme SPOOL_LOBBY_TASK_ID=11111111-1111-4111-8111-111111111111 2>&1)
w=$(jq -r '.services.web.environment | "\(.SPOOL_PUBLIC_URL) \(.SPOOL_TENANT) \(.SPOOL_LOBBY_TASK_ID)"' <<<"$c4")
[[ "$w" == "https://chat.example.org acme 11111111-1111-4111-8111-111111111111" ]] \
  && pass "web env carries SPOOL_PUBLIC_URL, SPOOL_TENANT, SPOOL_LOBBY_TASK_ID" || fail "web env: $w"
w=$(jq -r '.services.web.environment.SPOOL_PUBLIC_URL' <<<"$c")
[[ "$w" == "http://localhost:8080" ]] && pass "web env default SPOOL_PUBLIC_URL $w" || fail "web env default SPOOL_PUBLIC_URL '$w'"

# --- 5. the build switch: a local tag, no digest (a build cannot tag one) -----------
c5=$(cfg SPOOL_IMAGE_TAG=local 2>&1)
imgs=$(jq -r '[.services["hub-init","hub","web"].image] | join(" ")' <<<"$c5")
[[ "$imgs" == "ghcr.io/csitea/spool-hub:local ghcr.io/csitea/spool-hub:local ghcr.io/csitea/spool-web:local" ]] \
  && pass "SPOOL_IMAGE_TAG=local: buildable names, no digest" || fail "SPOOL_IMAGE_TAG=local: $imgs"

# --- CONTROL ------------------------------------------------------------------------------
grep -qE 'spool-(hub|web):local' <<<"$c" && fail "control: the local-only image name is still in the config" || pass "control: no spool-{hub,web}:local left"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
