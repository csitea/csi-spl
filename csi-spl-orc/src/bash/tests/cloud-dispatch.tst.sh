#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cloud_dispatch (spec 076 T004) routes <family> <verb> to
# do_<family>_<verb>_<provider>. Stub adapters only; no gcloud.
#   1. routing: each provider reaches its own adapter, and only that one
#   2. args reach the adapter untouched (spaces, empty, glob chars)
#   3. the adapter's exit code is the router's
#   4. no adapter for the provider: loud (stderr, names the function), no fallback
#   5. an invalid provider, and a bad call, fail before any adapter runs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# The stub adapters: each prints "<provider>" and its argv one per line as <...>.
STUBS='
for p in gcp none aws; do
  eval "do_fam_verb_$p() { echo $p; local a; for a in \"\$@\"; do echo \"<\$a>\"; done; }"
done
do_fam_rc_none() { return "$1"; }
do_fam_gcponly_gcp() { echo gcp-adapter-ran; }
'
# run_d [VAR=value]... -- <dispatch args>: stdout to $T/out, stderr to $T/err
run_d() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  # the dispatch args cross into in_orc's fresh bash %q-quoted, so each word lands as given
  SNIPPET="$STUBS"'eval "set -- $DARGS"; do_spl_cloud_dispatch "$@"' \
    in_orc DARGS="$(printf '%q ' "$@")" "${envs[@]}" >"$T/out" 2>"$T/err"
}

# --- 1. routing --------------------------------------------------------------------
for p in gcp none aws; do
  run_d SPOOL_CLOUD_PROVIDER="$p" -- fam verb
  [[ "$(cat "$T/out")" == "$p" ]] && pass "provider $p -> do_fam_verb_$p" ||
    fail "provider $p: want '$p', got '$(cat "$T/out")'"
done
run_d -- fam verb
[[ "$(cat "$T/out")" == gcp ]] && pass "no override: the cnf (ENV=dev) routes to gcp" ||
  fail "no override: want gcp, got '$(cat "$T/out")'"
printf 'env:\n  cloud:\n    provider: none\n' >"$T/none.yaml"
run_d SPL_CNF="$T/none.yaml" -- fam verb
[[ "$(cat "$T/out")" == none ]] && pass "merged cnf provider none -> do_fam_verb_none" ||
  fail "merged cnf none: got '$(cat "$T/out")'"

# --- 2. args untouched -----------------------------------------------------------------
run_d SPOOL_CLOUD_PROVIDER=none -- fam verb "a b" "" " lead" '*' 'x"y' '$HOME'
want=$'none\n<a b>\n<>\n< lead>\n<*>\n<x"y>\n<$HOME>'
[[ "$(cat "$T/out")" == "$want" ]] && pass "args with spaces, empty, glob and quotes reach the adapter untouched" ||
  fail "args: want '$want', got '$(cat "$T/out")'"

# --- 3. exit code ----------------------------------------------------------------------
for rc in 0 3 42; do
  run_d SPOOL_CLOUD_PROVIDER=none -- fam rc "$rc"; got=$?
  [[ "$got" == "$rc" ]] && pass "adapter exit $rc is the router's" || fail "adapter exit $rc: router returned $got"
done

# --- 4. missing adapter: loud, no fallback ------------------------------------------------
run_d SPOOL_CLOUD_PROVIDER=none -- fam gcponly; got=$?
[[ "$got" == 1 ]] && pass "missing adapter returns 1" || fail "missing adapter returned $got"
grep -q 'do_fam_gcponly_none' "$T/err" && pass "missing adapter: stderr names do_fam_gcponly_none" ||
  fail "missing adapter: stderr '$(cat "$T/err")'"
[[ ! -s "$T/out" ]] && pass "missing adapter on none: the gcp adapter did not run (no fallback)" ||
  fail "missing adapter: stdout '$(cat "$T/out")'"

# --- 5. invalid provider and bad calls ---------------------------------------------------
run_d SPOOL_CLOUD_PROVIDER=azure -- fam verb; got=$?
[[ "$got" == 1 && ! -s "$T/out" ]] && pass "provider azure: 1, no adapter ran" || fail "provider azure: rc $got, out '$(cat "$T/out")'"
grep -q "azure" "$T/err" && pass "provider azure: the FATAL is on stderr" || fail "provider azure: stderr '$(cat "$T/err")'"
for bad in "fam" "Fam verb" "fam ver-b" "fam verb;x"; do
  read -ra words <<<"$bad"
  run_d SPOOL_CLOUD_PROVIDER=none -- "${words[@]}"; got=$?
  [[ "$got" == 2 && ! -s "$T/out" ]] && pass "bad call '$bad' returns 2" || fail "bad call '$bad': rc $got"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
