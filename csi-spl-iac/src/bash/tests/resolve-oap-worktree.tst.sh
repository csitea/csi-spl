#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 T069 -- do_resolve_oap yields ORG=csi APP=spl PROJ=iac in
#          the canonical layout AND in an agent worktree
#          (<ORG>-<APP>-wt/<ID>/<ORG>-<APP>-iac), where deriving from the
#          parent dirs gave ORG=csi-spl-wt APP=<ID>.
#
#          CONTROL: a stale ORG/APP from another project in the environment is
#          still replaced by the derived value (the resolver's contract).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# resolve <proj_path> <app_path> [ORG] [APP] -> "ORG APP PROJ"
resolve() {
  ( unset ORG APP PROJ
    [[ -n "${3:-}" ]] && export ORG="$3"
    [[ -n "${4:-}" ]] && export APP="$4"
    PROJ_PATH="$1" APP_PATH="$2"
    source "$PROJ_ROOT/lib/bash/funcs/resolve-oap.func.sh"
    do_resolve_oap ORG && do_resolve_oap APP && do_resolve_oap PROJ
    echo "$ORG $APP $PROJ" )
}

got=$(resolve /opt/csi/csi-spl/csi-spl-iac /opt/csi/csi-spl)
[[ "$got" == "csi spl iac" ]] && pass "canonical layout -> csi spl iac" || fail "canonical layout -> $got"

got=$(resolve /opt/csi/csi-spl-wt/CLE-3344/csi-spl-iac /opt/csi/csi-spl-wt/CLE-3344)
[[ "$got" == "csi spl iac" ]] && pass "worktree layout -> csi spl iac" || fail "worktree layout -> $got"

got=$(resolve /opt/csi/csi-spl-wt/CLE-3344/csi-spl-iac /opt/csi/csi-spl-wt/CLE-3344 pas psf)
[[ "$got" == "csi spl iac" ]] && pass "control: stale ORG/APP from another project are replaced" || fail "control: stale ORG/APP -> $got"

got=$(resolve "$PROJ_ROOT" "$(dirname "$PROJ_ROOT")")
[[ "$got" == "csi spl iac" ]] && pass "this tree ($PROJ_ROOT) -> csi spl iac" || fail "this tree -> $got"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
