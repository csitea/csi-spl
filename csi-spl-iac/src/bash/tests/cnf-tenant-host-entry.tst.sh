#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3568 (dispatch 5f0839c6): the pre-merge check that every WUI
#          entry point of the live cnf is mapped. The tenant-host reconcile's
#          spl_th_entry_check (csi-spl-orc, sourced, never copied) runs on the
#          live dev and prd cnf from the pre-push cnf part (_pp_cnf_entry_check
#          in _pp_part_cnf) and from this test, which CI's cnf job runs on
#          every push that touches csi-spl-cnf.
#          1. the live dev and prd cnf PASS
#          2. CONTROL: a scratch copy of the live dev cnf with one workspace
#             added to steps.052 and not to env.dns.mapped_tenants FAILS,
#             naming it; mapping it passes again
#          3. the real _pp_part_cnf (do_tpl_gen stubbed) FAILS on that tree
#          4. CONTROL: an orc file without spl_th_entry_check FAILS (a rename
#             never turns the check off); a tree with no all.env.yaml (no
#             spool cnf, a fixture) is skipped
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
ORC_FN="$APP_ROOT/csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
command -v yq >/dev/null || { echo "FAIL: no yq (mikefarah v4)"; exit 1; }
[[ -f "$ORC_FN" ]] || { echo "FAIL: no $ORC_FN"; exit 1; }
PLANT=zz-unmapped-spl3568

# mktree <dir> <orc file> -> a tree with the live cnf yaml files and the orc file
mktree() {
  mkdir -p "$1/csi-spl-cnf/csi-spl" "$1/csi-spl-orc/src/bash/run"
  cp "$APP_ROOT"/csi-spl-cnf/csi-spl/{all,dev,prd}.env.yaml "$1/csi-spl-cnf/csi-spl/"
  cp "$2" "$1/$_PP_TH_ENTRY_FN"
}

# --- 1. the live cnf ---------------------------------------------------------------
for e in dev prd; do
  # shellcheck source=/dev/null
  out=$( ( . "$ORC_FN"; ENV=$e spl_th_entry_check "$APP_ROOT/csi-spl-cnf/csi-spl/$e.env.yaml" ) 2>&1) &&
    pass "1. live $e cnf: every WUI entry point is in env.dns.mapped_tenants" || fail "1. live $e cnf: $out"
done
out=$(_pp_cnf_entry_check "$APP_ROOT" 2>&1) && pass "1. _pp_cnf_entry_check on this tree PASSES" || fail "1. _pp_cnf_entry_check on this tree: $out"

# --- 2. CONTROL: an unmapped 052 workspace in a scratch dev cnf ----------------------
R="$T/red"; mktree "$R" "$ORC_FN"
yq -i ".env.steps.\"052-gcs-workspace-docs\".workspaces += [\"$PLANT\"]" "$R/csi-spl-cnf/csi-spl/dev.env.yaml"
out=$(_pp_cnf_entry_check "$R" 2>&1); rc=$?
[[ $rc != 0 ]] && grep -q "FATAL WUI entry point(s) not in env.dns.mapped_tenants.*: $PLANT " <<<"$out" &&
  grep -q '^FAIL: tenant-host entry check dev ' <<<"$out" && ! grep -q 'entry check prd' <<<"$out" &&
  pass "2. CONTROL: an unmapped dev workspace FAILS (rc=$rc), naming $PLANT and dev only" || fail "2. unmapped workspace not caught rc=$rc: $out"
cmp -s "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml" "$R/csi-spl-cnf/csi-spl/dev.env.yaml" &&
  fail "2. the plant did not change the scratch copy" || pass "2. ... the plant edited the scratch copy, never the live cnf"
G="$T/green"; mktree "$G" "$ORC_FN"; cp "$R/csi-spl-cnf/csi-spl/dev.env.yaml" "$G/csi-spl-cnf/csi-spl/"
yq -i ".env.dns.mapped_tenants += [\"$PLANT\"]" "$G/csi-spl-cnf/csi-spl/dev.env.yaml"
out=$(_pp_cnf_entry_check "$G" 2>&1) && pass "2. CONTROL: once $PLANT is mapped the check passes" || fail "2. mapped plant still refused: $out"

# --- 3. the real cnf part runs it ----------------------------------------------------
TG="$T/tpl-gen"; mkdir -p "$TG/src/python/tpl-gen/.venv/bin"
printf '#!/bin/sh\n' >"$TG/src/python/tpl-gen/.venv/bin/python"; chmod +x "$TG/src/python/tpl-gen/.venv/bin/python"
part() { ( do_tpl_gen() { :; }; TPL_GEN_PATH="$TG" _pp_part_cnf "$1" ) 2>&1; }
out=$(part "$R"); rc=$?
[[ $rc != 0 ]] && grep -q '^FAIL: tenant-host entry check dev ' <<<"$out" &&
  pass "3. _pp_part_cnf FAILS on the unmapped workspace (rc=$rc)" || fail "3. _pp_part_cnf missed it rc=$rc: $out"
out=$(part "$G") && pass "3. _pp_part_cnf PASSES once it is mapped" || fail "3. _pp_part_cnf on the mapped tree: $out"
[[ " $(_pp_paths cnf) " == *" $_PP_TH_ENTRY_FN "* ]] && pass "3. the orc file keys the cnf part's cache" || fail "3. _pp_paths cnf lacks $_PP_TH_ENTRY_FN"

# --- 4. CONTROL: no function -> FAIL; no spool cnf -> skipped -------------------------
printf 'spl_th_other() { :; }\n' >"$T/renamed.func.sh"
N="$T/nofn"; mktree "$N" "$T/renamed.func.sh"
out=$(_pp_cnf_entry_check "$N" 2>&1); rc=$?
[[ $rc != 0 ]] && grep -q '^FAIL: tenant-host entry check dev ' <<<"$out" &&
  pass "4. CONTROL: an orc file without spl_th_entry_check FAILS (rc=$rc)" || fail "4. a missing function passed rc=$rc: $out"
F="$T/fixture"; mkdir -p "$F/csi-spl-cnf/csi-spl"; echo 'a: 1' >"$F/csi-spl-cnf/csi-spl/dev.env.yaml"
out=$(_pp_cnf_entry_check "$F" 2>&1) && [[ -z "$out" ]] && pass "4. a tree with no all.env.yaml (fixture) is skipped" || fail "4. fixture: $out"

[[ "$fails" -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
