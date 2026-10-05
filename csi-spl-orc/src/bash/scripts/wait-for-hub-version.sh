#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: refuse to put a WUI live ahead of the hub it was rolled with.
#
# CLE-35057 (prd, 2026-09-27): the WUI workflow deploys on every push in ~4
# min; the hub workflow deploys only on a hub.image.tag bump and after a
# ~6.5 min suite. So a roll's WUI went live 4-6 min before its hub, and a
# hub job that failed or was skipped left the new WUI on the old hub for
# good. The hub bakes the repo's .version into GET /version, so "the hub
# this WUI needs" is: that env's hub reports a version >= this commit's
# .version.
#
# Polls <HUB_URL>/version every INTERVAL_S seconds until the hub's version is
# >= WANT_VERSION, then exits 0. After TIMEOUT_S seconds it exits 1 and the
# WUI is NOT deployed (a red run says why). A newer hub passes: a later roll
# carries everything an earlier WUI needs.
#
# Env:
#   HUB_URL      - required: the env's hub base (https://<api_fqdn>); any
#                  scheme curl reads, so the test serves file://
#   WANT_VERSION - required: MAJOR.MINOR.PATCH (the repo's .version)
#   RELEASE_CYCLE - optional, default 1: the release cycle of the newest
#                  v-tag (spl_release_cycle_now). WANT_VERSION (.version) is a
#                  cycle-1 floor; past 9.9.9 the odometer restarts at 1.0.1 of
#                  cycle 2 (spl-release-version.func.sh, CYCLES), so a hub
#                  showing 1.0.8 there is LATER than the floor 1.1.3. From
#                  cycle 2 on every hub version is past the floor: any
#                  well-formed /version passes (an unreachable hub still not).
#   TIMEOUT_S    - optional, default 1800
#   INTERVAL_S   - optional, default 20
# Exit: 0 hub is new enough, 1 timed out (hub behind or unreachable),
#       2 bad input.
#------------------------------------------------------------------------------
set -uo pipefail

hub="${HUB_URL:-}"
want="${WANT_VERSION:-}"
timeout_s="${TIMEOUT_S:-1800}"
interval_s="${INTERVAL_S:-20}"
cycle="${RELEASE_CYCLE:-1}"
semver='^[0-9]+\.[0-9]+\.[0-9]+$'

[[ -n "$hub" ]] || { echo "::error::HUB_URL must be set (no default)"; exit 2; }
[[ "$want" =~ $semver ]] || { echo "::error::WANT_VERSION must be MAJOR.MINOR.PATCH, got '$want'"; exit 2; }
[[ "$cycle" =~ ^[1-9][0-9]*$ ]] || { echo "::error::RELEASE_CYCLE must be a cycle number >= 1, got '$cycle'"; exit 2; }
[[ "$timeout_s" =~ ^[0-9]+$ && "$interval_s" =~ ^[0-9]+$ ]] || { echo "::error::TIMEOUT_S and INTERVAL_S must be whole seconds"; exit 2; }

# version_ge A B: A >= B, numerically per field. Past cycle 1 the floor B is
# behind every version (see RELEASE_CYCLE), so any A passes.
version_ge() {
  ((cycle > 1)) && return 0
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    (( 10#${a[$i]} > 10#${b[$i]} )) && return 0
    (( 10#${a[$i]} < 10#${b[$i]} )) && return 1
  done
  return 0
}

hub_version() {
  curl -fsS --max-time 10 "${hub%/}/version" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

start=$(date +%s)
got=""
while :; do
  got="$(hub_version)"
  if [[ "$got" =~ $semver ]] && version_ge "$got" "$want"; then
    if ((cycle > 1)); then
      echo "ok - hub ${hub%/} runs ${got} in release cycle ${cycle}, past the cycle-1 floor ${want}: the WUI may go live"
    else
      echo "ok - hub ${hub%/} runs ${got} >= ${want}: the WUI may go live"
    fi
    exit 0
  fi
  elapsed=$(( $(date +%s) - start ))
  if (( elapsed >= timeout_s )); then
    echo "::error::hub ${hub%/} runs '${got:-unreachable}', this WUI needs >= ${want}; waited ${elapsed}s. NOT deploying the WUI ahead of its hub - roll the hub (workflow 20), then re-run this job."
    exit 1
  fi
  echo "waiting - hub ${hub%/} runs '${got:-unreachable}', need >= ${want} (${elapsed}s of ${timeout_s}s)"
  sleep "$interval_s"
done
