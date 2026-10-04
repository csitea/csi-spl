#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 10 ci distribution-hygiene sweep allows the satellite's two OS
#          user names ONLY as the keys steps.060-gcp-vm-satellite
#          box_owner_user / box_agent_user in csi-spl-cnf/csi-spl/*.env.{yaml,json}
#          (spec 069 Y8, "users into csi-spl-cnf"), and still fails on every
#          other placement of either name.
#          Runs the workflow's OWN "Sweep" step (extracted with yq), not a copy,
#          over a git-ls-files export of the tree:
#   1. the real tree passes, and the two keys are what the OS-user sweep allowed
#   2. CONTROL: each planted variant fails the OS-user sweep --
#        a. the agent user's name under ANOTHER key of the cnf yaml
#        b. a comment trailing the allowed owner key's line
#        c. the allowed key's line in a NON-cnf yaml
#        d. the owner user's name in an ordinary file
#   The names are read from the cnf at run time, so this file carries neither.
#   A plant that did not land FAILS as a setup failure, never as a verdict
#   (hygiene-owner-email-allow.tst.sh, run 37031322430).
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
CNF="csi-spl-cnf/csi-spl/prd.env.yaml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LABEL='literal OS user / box / AD id'

fails=0

command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
git -C "$APP_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git checkout (the sweep runs over git ls-files)"; exit 1; }

yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" >"$T/sweep.sh"
[[ -s "$T/sweep.sh" ]] && grep -q 'allow_user_line=' "$T/sweep.sh" \
  && pass "extracted the workflow's Sweep step, with its user allow-list" || fail "no Sweep step / allow_user_line in $WF"

export_tree() {
  mkdir -p "$1" || return 1
  git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$1" || return 1
  # the working copies of the cnf, so an uncommitted change is what gets tested
  cp "$APP_ROOT/$CNF" "$1/$CNF" && cp "$APP_ROOT/${CNF%.yaml}.json" "$1/${CNF%.yaml}.json" || return 1
  local want got
  want=$(git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && xargs -0 -r sh -c 'for f; do { [ -L "$f" ] || [ -f "$f" ]; } && echo; done' _) | wc -l)
  got=$(find "$1" \( -type f -o -type l \) | wc -l)
  [[ "$got" -eq "$want" ]] || { echo "    | the export holds $got of $want files"; return 1; }
}
sweep() { (cd "$1" && bash "$T/sweep.sh" 2>&1); }

owner=$(yq -r '.env.steps."060-gcp-vm-satellite".box_owner_user // ""' "$APP_ROOT/$CNF")
agent=$(yq -r '.env.steps."060-gcp-vm-satellite".box_agent_user // ""' "$APP_ROOT/$CNF")
[[ -n "$owner" && -n "$agent" ]] && pass "$CNF sets box_owner_user and box_agent_user" || fail "$CNF lacks the satellite users"

# --- 1. the real tree ---------------------------------------------------------
export_tree "$T/real" && pass "exported the whole tracked tree" \
  || { fail "SETUP: the tree export is incomplete (disk full? TMPDIR=${TMPDIR:-/tmp})"; exit 1; }
out=$(sweep "$T/real"); rc=$?
echo "$out" | sed 's/^/    | /'
[[ $rc -eq 0 ]] && pass "the real tree passes the sweep (rc 0)" || fail "the real tree fails the sweep (rc=$rc)"
grep -q "^allowed - $LABEL: 4 line(s) = the owner-approved box_owner_user / box_agent_user keys" <<<"$out" \
  && pass "the OS-user sweep allowed exactly the 4 key lines (yaml + json, 2 each)" || fail "the user allow-list is not exercised as 4 lines"

# --- 2. CONTROL: every other placement still fails ------------------------------
ctl() { # <label> <id> <setup command run inside the copy>
  local label="$1" dir="$T/ctl-$2" err; shift 2
  if ! err=$(cp -a "$T/real" "$dir" 2>&1 && cd "$dir" && eval "$*" 2>&1) \
     || diff -rq "$T/real" "$dir" >/dev/null 2>&1; then
    fail "CONTROL $label -> SETUP failed, the plant did not land: ${err%%$'\n'*}"
    rm -rf "$dir"; return
  fi
  out=$(sweep "$dir"); rc=$?
  rm -rf "$dir"
  if [[ $rc -ne 0 ]] && grep -qF "::error::hygiene: $LABEL" <<<"$out"; then
    pass "CONTROL $label -> sweep fails (rc=$rc): $(grep -F "::error::hygiene: $LABEL" <<<"$out" | sed -n 1p)"
  else
    fail "CONTROL $label -> sweep did NOT fail (rc=$rc)"
    echo "$out" | sed 's/^/    | /'
  fi
}
ctl "a. the agent user under another cnf key" a \
  "yq -i '.env.steps.\"060-gcp-vm-satellite\".box_admin_user = \"$agent\"' $CNF"
ctl "b. a comment trailing the allowed key's line" b \
  "sed -i 's|^\\( *box_owner_user: .*\\)\$|\\1 # also $agent|' $CNF"
ctl "c. the allowed key's line in a non-cnf yaml" c \
  "printf 'box_owner_user: %s\n' '$owner' >csi-spl-iac/cnf/stray.env.yaml"
ctl "d. the owner user in an ordinary file" d \
  "printf 'run as %s\n' '$owner' >>csi-spl-iac/README.md"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
