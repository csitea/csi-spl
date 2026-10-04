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
#   A setup that did not happen (an export or copy cut short, a plant that
#   changed nothing) FAILS as a setup failure, never as a sweep verdict: on
#   2026-10-02 a full /tmp truncated the control copies, the plants landed
#   nowhere and CONTROL c/d read "sweep did NOT fail" (run 37031322430).
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

# export <dir> -> the tracked tree, as actions/checkout would see it; rc 0 only
# when every tracked file (or symlink) present in the checkout arrived
export_tree() {
  mkdir -p "$1" || return 1
  git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$1" || return 1
  # the working copy of the cnf, so an uncommitted change is what gets tested
  cp "$APP_ROOT/$CNF" "$1/$CNF" || return 1
  local want got
  want=$(git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && xargs -0 -r sh -c 'for f; do { [ -L "$f" ] || [ -f "$f" ]; } && echo; done' _) | wc -l)
  got=$(find "$1" \( -type f -o -type l \) | wc -l)
  [[ "$got" -eq "$want" ]] || { echo "    | the export holds $got of $want files"; return 1; }
}
# sweep <dir> -> output on stdout, rc as the step's exit code
sweep() { (cd "$1" && bash "$T/sweep.sh" 2>&1); }

owner=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$APP_ROOT/$CNF")
[[ -n "$owner" ]] && pass "$CNF sets env.gcp.gcp_account_owner_email" || fail "$CNF has no gcp_account_owner_email value"

# --- 1. the real tree ---------------------------------------------------------
export_tree "$T/real" && pass "exported the whole tracked tree" \
  || { fail "SETUP: the tree export is incomplete (disk full? TMPDIR=${TMPDIR:-/tmp}), so no verdict below would mean anything"; exit 1; }
out=$(sweep "$T/real"); rc=$?
echo "$out" | sed 's/^/    | /'
[[ $rc -eq 0 ]] && pass "the real tree passes the sweep (rc 0)" || fail "the real tree fails the sweep (rc=$rc)"
grep -q '^allowed - owner mail address or domain' <<<"$out" \
  && pass "the owner-approved key is what the sweep allowed" || fail "the sweep allowed nothing: the allow-list is not exercised"

# --- 2. CONTROL: every other placement still fails ------------------------------
at="@"; dom="gm""ail.com"
other="someone.else${at}${dom}"
ctl() { # <label> <setup command run inside the copy>
  local label="$1" dir="$T/ctl-$2" err; shift 2
  # the plant must have landed, or a passing sweep below proves nothing
  # (err is kept in memory: a file for it would sit on the same full disk)
  if ! err=$(cp -a "$T/real" "$dir" 2>&1 && cd "$dir" && eval "$*" 2>&1) \
     || diff -rq "$T/real" "$dir" >/dev/null 2>&1; then
    fail "CONTROL $label -> SETUP failed, the plant did not land (disk full? TMPDIR=${TMPDIR:-/tmp}): ${err%%$'\n'*}"
    rm -rf "$dir"; return
  fi
  out=$(sweep "$dir"); rc=$?
  rm -rf "$dir"
  if [[ $rc -ne 0 ]] && grep -q '::error::hygiene: owner mail address or domain' <<<"$out"; then
    pass "CONTROL $label -> sweep fails (rc=$rc): $(grep '::error::hygiene: owner mail' <<<"$out" | sed -n 1p)"
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
