#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 10 ci distribution-hygiene sweep allows the owner's address ONLY
#          as the owner-approved key env.gcp.gcp_account_owner_email in
#          csi-spl-cnf/csi-spl/*.env.{yaml,json} (owner decision 2026-09-19),
#          and still fails on every other personal address.
#          Runs the workflow's OWN "Sweep" step (extracted with yq), not a copy,
#          over a git-ls-files export of the tree:
#   1. the real tree passes, and the allowed key is what it allowed
#   2. CONTROL: each planted variant fails the sweep --
#        a. another personal address in an ordinary file
#        b. the owner's address under ANOTHER key of all.env.yaml
#        c. the owner's address trailed by a comment on the allowed key's line
#        d. the owner's address as the key's line in a NON-cnf yaml
#   The owner's address is read from the yaml at run time and the planted
#   address is assembled at run time, so this file carries neither literal.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
CNF="csi-spl-cnf/csi-spl/all.env.yaml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
git -C "$APP_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git checkout (the sweep runs over git ls-files)"; exit 1; }

yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" >"$T/sweep.sh"
[[ -s "$T/sweep.sh" ]] && grep -q 'allow_line=' "$T/sweep.sh" \
  && pass "extracted the workflow's Sweep step, with its allow-list" || fail "no Sweep step / allow-list in $WF"

# export <dir> -> the tracked tree, as actions/checkout would see it
export_tree() {
  mkdir -p "$1"
  git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$1"
  # the working copy of the cnf, so an uncommitted change is what gets tested
  cp "$APP_ROOT/$CNF" "$1/$CNF"
}
# sweep <dir> -> output on stdout, rc as the step's exit code
sweep() { (cd "$1" && bash "$T/sweep.sh" 2>&1); }

owner=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$APP_ROOT/$CNF")
[[ -n "$owner" ]] && pass "$CNF sets env.gcp.gcp_account_owner_email" || fail "$CNF has no gcp_account_owner_email value"

# --- 1. the real tree ---------------------------------------------------------
export_tree "$T/real"
out=$(sweep "$T/real"); rc=$?
echo "$out" | sed 's/^/    | /'
[[ $rc -eq 0 ]] && pass "the real tree passes the sweep (rc 0)" || fail "the real tree fails the sweep (rc=$rc)"
grep -q '^allowed - owner mail address or domain' <<<"$out" \
  && pass "the owner-approved key is what the sweep allowed" || fail "the sweep allowed nothing: the allow-list is not exercised"

# --- 2. CONTROL: every other placement still fails ------------------------------
at="@"; dom="gm""ail.com"
other="someone.else${at}${dom}"
ctl() { # <label> <setup command run inside the copy>
  local label="$1" dir="$T/ctl-$2"; shift 2
  cp -a "$T/real" "$dir"
  (cd "$dir" && eval "$*")
  out=$(sweep "$dir"); rc=$?
  if [[ $rc -ne 0 ]] && grep -q '::error::hygiene: owner mail address or domain' <<<"$out"; then
    pass "CONTROL $label -> sweep fails (rc=$rc): $(grep '::error::hygiene: owner mail' <<<"$out" | head -1)"
  else
    fail "CONTROL $label -> sweep did NOT fail (rc=$rc)"
    echo "$out" | sed 's/^/    | /'
  fi
}
ctl "a. another personal address in an ordinary file" a \
  "printf 'contact: %s\n' '$other' >>csi-spl-iac/README.md"
ctl "b. the owner's address under another cnf key" b \
  "yq -i '.env.gcp.gcp_billing_contact = \"$owner\"' $CNF"
ctl "c. a comment trailing the allowed key's line" c \
  "sed -i 's|^\\( *gcp_account_owner_email: .*\\)\$|\\1 # also $other|' $CNF"
ctl "d. the allowed key's line in a non-cnf yaml" d \
  "printf 'env:\n  gcp:\n    gcp_account_owner_email: %s\n' '$other' >csi-spl-iac/cnf/stray.env.yaml"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
