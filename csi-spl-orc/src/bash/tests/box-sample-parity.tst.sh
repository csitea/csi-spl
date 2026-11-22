#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the Go box collector of "Refresh now" (spec 071 7.6.3, SPL-6239 row
#   T2, csi-spl-api internal/hubclient/box_sample.go) reads the same sample as
#   the 5-minute tick's bash collector (spl_lane_box_sample and
#   spl_lane_box_disks, csi-spl-orc/src/bash/run/spl-lane-map.func.sh).
#   The same fixtures (LANE_LOADAVG, LANE_MEMINFO, LANE_NPROC, LANE_DF_CMD)
#   go through both; the two objects must be equal except for the named
#   differences:
#     - agents_live is left out: the tick counts live tmux panes, the Go
#       collector the roster agents the AgentRunReport says run (spec 7.6.3);
#     - numbers compare as values: jq keeps the tick's literal 2.50, Go
#       writes 2.5 (the hub decodes both to the same float64);
#     - `at` is left out: only the Go struct carries it (zero), the hub sets it;
#     - a mount whose df Used is 0: the tick sends used_kb 0, Go omits it
#       (store.BoxDisk UsedKB omitempty), which the store reads as "not sent".
#   The Go half is TestBoxSampleParityOut, run with `go test`.
# Red control (spec 7.8): change the Go mount filter: the objects differ.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
API="$APP_ROOT/csi-spl-api/src/go/spool-hub-api"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || true
GO="$(command -v go || true)"
[[ -n "$GO" ]] || { echo "SKIP: no go toolchain (the Go half cannot run)"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# bash_sample <dir>: the tick's object from the fixtures in <dir>
bash_sample() {
  env LANE_BOX=sat LANE_LOADAVG="$1/loadavg" LANE_MEMINFO="$1/meminfo" LANE_NPROC=8 LANE_DF_CMD="cat $1/df" bash -c '
    set -uo pipefail
    do_log() { :; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-map.func.sh"
    spl_lane_box_sample "[\"c-001\",\"c-150\"]"'
}

# go_sample <dir>: the Go collector's object from the same fixtures
go_sample() {
  (cd "$API" && env LANE_BOX=sat LANE_LOADAVG="$1/loadavg" LANE_MEMINFO="$1/meminfo" LANE_NPROC=8 LANE_DF_CMD="cat $1/df" \
    BOX_SAMPLE_PARITY_OUT="$1/go.json" GOTOOLCHAIN=local GOFLAGS=-mod=mod \
    "$GO" test -count=1 -run '^TestBoxSampleParityOut$' ./internal/hubclient/ >"$1/go.log" 2>&1) &&
    cat "$1/go.json"
}

# compare <name> <dir>: equal once the named differences are taken out
compare() {
  local b g
  b="$(bash_sample "$2")" || { fail "$1: the bash collector failed"; return; }
  g="$(go_sample "$2")" || { fail "$1: the Go collector failed: $(tail -5 "$2/go.log")"; return; }
  # numbers as values: jq keeps the tick's literal (2.50), Go writes 2.5
  b="$(jq -S -c 'del(.agents_live) | .disks |= map(if .used_kb == 0 then del(.used_kb) else . end) | walk(if type == "number" then . + 0 else . end)' <<<"$b")"
  g="$(jq -S -c 'del(.agents_live, .at, .writer_box) | walk(if type == "number" then . + 0 else . end)' <<<"$g")"
  [[ "$b" == "$g" ]] && pass "$1: the Go sample is the tick's ($b)" || fail "$1: bash $b != go $g"
}

# 1. the tick's own fixtures (box-stats-cron.tst.sh) and more mount shapes:
#    a space in a mount, a repeat, a dash row, a relative mount, a Used that
#    is not a number, a Used of 0; a meminfo key twice (the last one wins)
mkdir -p "$T/a"
printf '2.50 1.75 0.47 3/900 12345\n' >"$T/a/loadavg"
printf 'MemTotal: 16000000 kB\nMemAvailable: 1 kB\nMemAvailable: 6000000 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n' >"$T/a/meminfo"
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/sda1 100 55 40 58% /' \
  '/dev/sdb1 900 400 500 45% /mnt/my  data' '/dev/sda1 100 55 40 58% /' 'srv:/x - - - - /net' \
  'none 10 1 9 10% relative' '/dev/sdc1 50 ? 20 - /odd' '/dev/sdd1 70 0 70 0% /empty' >"$T/a/df"
compare "1. tick fixtures" "$T/a"
grep -q '"used_kb":0' <<<"$(bash_sample "$T/a")" && ! grep -q '"used_kb":0' "$T/a/go.json" &&
  pass "1. named difference: /empty (Used 0) carries used_kb 0 from the tick, none from Go" || fail "1. the Used-0 difference is not as named"

# 2. no swap keys, 20 mounts (the first 16 go), a load of 0
mkdir -p "$T/b"
printf '0.00 0.01 10.20 1/1 1\n' >"$T/b/loadavg"
printf 'MemTotal: 4000 kB\nMemAvailable: 3000 kB\n' >"$T/b/meminfo"
seq 1 20 | awk '{print "/dev/x" $1, 10, 1, 9, "10%", "/m" $1}' | sed '1i head' >"$T/b/df"
compare "2. no swap, 20 mounts" "$T/b"
[[ "$(jq '.disks | length' "$T/b/go.json")" == 16 ]] && pass "2. 16 mounts kept (the hub's cap)" || fail "2. cap: $(cat "$T/b/go.json")"

# 3. df prints nothing usable: both send disks []
mkdir -p "$T/c"
cp "$T/b/loadavg" "$T/b/meminfo" "$T/c/"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n' >"$T/c/df"
compare "3. empty df" "$T/c"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
