#!/usr/bin/env bash
# Aggregate test runner for csi-spl-api (specs 002 + 003): gofmt, go vet, go test -race,
# the reference-hygiene gate, the no-baked-hostname gate, the end-to-end smoke,
# the hub Postgres gate, and the hub GCS/fake-gcs blob gate.
# Usage: bash csi-spl-api/src/bash/tests/run-all-tests.sh
#
# SPL_API_TEST_TIER=fast (CLE-77824) is the pre-push hook's tier: it leaves out
# the four slow pieces -- build-stripped (two full builds), go test -race (the
# plain go test still runs), the hub Postgres gate (~384 s) and the hub GCS
# gate -- and names each one it leaves out. CI (workflow 10 and the workflow 20
# deploy gate) never sets it, so CI always runs the full suite.
#
# Perf edition 20261004 E05 (C2's practice): after vet, the independent pieces
# run SPL_API_TEST_JOBS at a time. Unset means all of them at once; 1 is the
# old serial loop, streamed live. Each piece's stdout and stderr are buffered
# and printed in suite order, so a log reads like a serial run and one piece's
# output is never mixed with another's. A failing piece still fails the suite.
# The Postgres gate and the GCS gate do not share a port: local Postgres
# listens on its temp unix socket only, the docker Postgres publishes an
# ephemeral port, and fake-gcs binds below the ephemeral range.
#
# Sourced with SPL_API_SUITE_LIB=1, this file defines spl_run_pieces and
# returns. The sibling run-all-tests-parallel.tst.sh is the only caller.
set -euo pipefail

# spl_run_pieces <jobs> <name> <fn> [<name> <fn> ...]
# Run each function <jobs> at a time. Print "== <name> ==" plus that
# function's output in argument order, then "FAILED: <name>" when it
# returns non-zero. Append "piece-secs: <name> <secs> rc=<rc>" so a log
# still carries each piece's duration after the buffer is printed.
# Return 1 when any piece fails, 2 when <jobs> is not a positive integer.
spl_run_pieces() {
  local njobs="$1"
  shift
  case "$njobs" in
    ''|*[!0-9]*|0) echo "SPL_API_TEST_JOBS must be a positive integer (got '$njobs')" >&2; return 2 ;;
  esac
  if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
    echo "spl_run_pieces: name/function pairs" >&2
    return 2
  fi
  local -a names=() fns=()
  while [ "$#" -ge 2 ]; do
    names+=("$1")
    fns+=("$2")
    shift 2
  done
  local n=${#names[@]} fails=0 i t0 rc
  if [ "$njobs" -eq 1 ]; then
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '== %s ==\n' "${names[$i]}"
      t0=$(date +%s)
      rc=0
      "${fns[$i]}" || rc=$?
      echo "piece-secs: ${names[$i]} $(( $(date +%s) - t0 )) rc=$rc"
      if [ "$rc" -ne 0 ]; then
        printf 'FAILED: %s\n' "${names[$i]}"
        fails=$((fails + 1))
      fi
      i=$((i + 1))
    done
    [ "$fails" -eq 0 ]
    return
  fi
  local work
  work=$(mktemp -d)
  # A subshell keeps this EXIT trap off the caller (the suite, or the test).
  (
    # p is assigned when the trap runs; kill splits the pid list on purpose.
    # shellcheck disable=SC2154,SC2086
    trap 'p=$(jobs -p || true); [ -z "$p" ] || kill $p 2>/dev/null || true; rm -rf "$work"' EXIT
    trap 'exit 130' INT TERM
    next=0
    running=0
    fails=0
    start() {
      local i="$1"
      (
        t0=$(date +%s)
        rc=0
        "${fns[$i]}" >"$work/$i.out" 2>&1 </dev/null || rc=$?
        echo "piece-secs: ${names[$i]} $(( $(date +%s) - t0 )) rc=$rc" >>"$work/$i.out"
        echo "$rc" >"$work/$i.rc.tmp"
        mv "$work/$i.rc.tmp" "$work/$i.rc"
      ) &
    }
    flush() {
      while [ "$next" -lt "$n" ] && [ -f "$work/$next.rc" ]; do
        printf '== %s ==\n' "${names[$next]}"
        cat "$work/$next.out"
        if [ "$(cat "$work/$next.rc")" -ne 0 ]; then
          printf 'FAILED: %s\n' "${names[$next]}"
          fails=$((fails + 1))
        fi
        next=$((next + 1))
      done
    }
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "$running" -ge "$njobs" ]; then
        wait -n || true
        running=$((running - 1))
        flush
      fi
      start "$i"
      running=$((running + 1))
      i=$((i + 1))
    done
    # Reap as each piece finishes and print in order, so a log is not
    # silent until the slowest piece ends.
    while [ "$running" -gt 0 ]; do
      wait -n || true
      running=$((running - 1))
      flush
    done
    [ "$fails" -eq 0 ]
  )
}

if [ "${SPL_API_SUITE_LIB:-}" = 1 ]; then
  return 0
fi

tier="${SPL_API_TEST_TIER:-full}"
case "$tier" in full|fast) ;; *) echo "SPL_API_TEST_TIER must be full or fast (got '$tier')" >&2; exit 2 ;; esac
slow() { echo "SKIP-TIER (fast tier; CI workflow 10/20 runs it): $1"; }

export GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path

# spec 072 A66: a fresh clone's module cache is cold; fill it once, then
# everything below runs offline as before.
# shellcheck source=../warm-go-mod-cache.sh
source "$HERE/../warm-go-mod-cache.sh"
spl_warm_go_mod_cache "$MOD"
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off

echo "== go toolchain selector =="
bash "$HERE/use-go-toolchain.tst.sh"
bash "$HERE/warm-go-mod-cache.tst.sh"
if [ "$tier" = full ]; then bash "$HERE/build-stripped.tst.sh"; else slow build-stripped.tst.sh; fi

echo "== gofmt =="
unformatted="$(cd "$MOD" && gofmt -l .)"
[ -z "$unformatted" ] || { echo "gofmt needed on:"; echo "$unformatted"; exit 1; }
echo "ok   - gofmt clean"

echo "== go vet =="
( cd "$MOD" && go vet ./... )
echo "ok   - go vet clean"

# Independent pieces (E05). Print order is this list. The parallel pin runs
# in the same pool so its few seconds hide under the long pieces.
piece_go_test() {
  if [ "$tier" = full ]; then
    ( cd "$MOD" && CGO_ENABLED=1 go test -race ./... )
  else
    ( cd "$MOD" && go test ./... )
    slow "go test -race"
  fi
}
piece_entrypoint() { bash "$HERE/hub-entrypoint.tst.sh"; }
piece_ref_hygiene() {
  bash "$HERE/no-ysg-box-ref.tst.sh"
  bash "$HERE/no-baked-host.tst.sh"
}
piece_payment() { bash "$HERE/no-payment-vendor-wui.tst.sh"; }
piece_baked_hostname() { bash "$HERE/no-baked-hostname.tst.sh"; }
piece_cookie() { bash "$HERE/cookie-secure-cnf.tst.sh"; }
piece_smoke() { bash "$HERE/spool-smoke.tst.sh"; }
piece_pg() {
  if [ "$tier" = full ]; then bash "$HERE/hub-pg.tst.sh"; else slow hub-pg.tst.sh; fi
}
piece_gcs() {
  if [ "$tier" = full ]; then bash "$HERE/hub-gcs.tst.sh"; else slow hub-gcs.tst.sh; fi
}
piece_parallel_pin() { bash "$HERE/run-all-tests-parallel.tst.sh"; }

if [ "$tier" = full ]; then
  go_piece_name="go test -race"
else
  go_piece_name="go test (no -race: fast tier)"
fi

pieces=(
  "$go_piece_name|piece_go_test"
  "standalone hub-init rules (047 W9, W18)|piece_entrypoint"
  "reference-hygiene gate|piece_ref_hygiene"
  "payment-vendor WUI gate|piece_payment"
  "no-baked-hostname gate (spec 007 T017)|piece_baked_hostname"
  "cookie Secure cnf gate (SPL-1285: dev+prd must run Secure cookies)|piece_cookie"
  "end-to-end smoke|piece_smoke"
  "hub Postgres gate: migrate, store/hub suites on Postgres, binary e2e (skips without Postgres)|piece_pg"
  "hub GCS gate: internal/blob against fake-gcs (skips without cached emulator image)|piece_gcs"
  "suite parallelism|piece_parallel_pin"
)
npieces=${#pieces[@]}
njobs="${SPL_API_TEST_JOBS:-$npieces}"
args=()
for piece in "${pieces[@]}"; do
  args+=("${piece%%|*}" "${piece#*|}")
done
spl_run_pieces "$njobs" "${args[@]}"

echo "ALL csi-spl-api TESTS PASSED (tier=$tier)"
