#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: make each Docker Hub image named on the command line present in the
# local docker under its canonical name, without an anonymous Docker Hub pull.
# The self-hosted runners share one egress IP, and anonymous Docker Hub pulls
# from it hit `toomanyrequests` (wf 20 run 37992239649, 2026-10-09) and
# auth.docker.io timeouts (wf 50 run 37995252968). Google's public Docker Hub
# mirror mirror.gcr.io serves the same tags with no such limit.
#
# Per image:
#   1. already present            -> used, no network (the tags are pinned)
#   2. pull mirror.gcr.io/<img>   -> 3 tries, then `docker tag` it to <img>,
#                                    so tests and compose find the usual name
#   3. pull <img> from Docker Hub -> the last resort, one try
# Exit: 0 every image present, 1 one could not be had, 2 bad input.
# Env: DOCKER_MIRROR (mirror.gcr.io), DOCKER_PULL_SLEEP (10, the retry step s)
#------------------------------------------------------------------------------
set -uo pipefail

(($#)) || { echo "usage: $0 <image:tag>..." >&2; exit 2; }
mirror="${DOCKER_MIRROR:-mirror.gcr.io}"
step="${DOCKER_PULL_SLEEP:-10}"

have() { docker image inspect "$1" >/dev/null 2>&1; }

rc=0
for img in "$@"; do
  [[ "$img" == *:* ]] || { echo "FAIL $img: pin a tag" >&2; exit 2; }
  if have "$img"; then echo "using the cached $img"; continue; fi
  src="$mirror/${img#docker.io/}"
  for i in 1 2 3; do
    docker pull -q "$src" >/dev/null && docker tag "$src" "$img" && break
    sleep $((i * step))
  done
  if have "$img"; then echo "pulled $img via $mirror"; continue; fi
  echo "::warning::$src failed 3x; trying Docker Hub"
  docker pull -q "$img" >/dev/null && have "$img" && { echo "pulled $img from Docker Hub"; continue; }
  echo "FAIL cannot pull $img (mirror $mirror nor Docker Hub)" >&2
  rc=1
done
exit "$rc"
