#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: fill the Go module cache with `go mod download` in the current
# directory, with retries. The CI steps after it build offline (GOPROXY=off),
# so one failed download reddens the whole job with no test run. Two wf 10
# master runs went red on that step alone, on a proxy.golang.org HTTP/2
# stream error ("stream error: stream ID 369; INTERNAL_ERROR; received from
# peer"): 40690641180 (2026-10-28, orc hermetic 1/3, caarlos0/env/v10) and
# 40510609134 (2026-10-27, golang.org/x/image); the push run on the same sha
# was green both times.
#
# Up to 3 tries, `sleep $((i * step))` between them; each failed try prints a
# ::warning:: line with its number. Extra arguments go to `go mod download`
# unchanged.
# Exit: 0 a try succeeded, 1 all 3 failed (a hard failure still goes red).
# Env: GO_MOD_DOWNLOAD_SLEEP (10, the retry step s)
#------------------------------------------------------------------------------
set -uo pipefail

step="${GO_MOD_DOWNLOAD_SLEEP:-10}"

for i in 1 2 3; do
  go mod download "$@" && exit 0
  echo "::warning::go mod download failed (try $i of 3)"
  ((i < 3)) && sleep $((i * step))
done
echo "FAIL go mod download failed 3x" >&2
exit 1
