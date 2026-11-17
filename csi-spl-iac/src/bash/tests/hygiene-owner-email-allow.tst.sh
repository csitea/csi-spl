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
tmp_dir  # T, removed on exit and when killed (SPL-5302)

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
# sweep <dir> -> the step's output in $T/sweep.out, rc as its exit code. Not
# out=$(sweep ...) (SPL-5834, as SPL-5827 did for hygiene-box-users-allow):
# on CI's bash 5.3 the step's own shell, TERMed in its sweeps, could spin in
# its `wait` printing without end, so a test reading that $(...) never ran its
# TERM trap and was KILLed after the grace (wf 10 run 44146018540). The step
# runs in the background and the test `wait`s on its pid, which a trapped
# signal interrupts; the trap then ignores HUP/INT/TERM (timeout's second TERM
# to the group cannot kill the EXIT rm) and KILLs the step with its sweep jobs
# (kill_tree: STOP, then its children, then KILL). The step's TMPDIR is
# inside T, so a KILLed step's mktemp dir goes with T.
sweep_pid=""
mkdir -p "$T/step-tmp"
sweep() {
  (cd "$1" && TMPDIR="$T/step-tmp" exec bash "$T/sweep.sh") >"$T/sweep.out" 2>&1 &
  sweep_pid=$!
  wait "$sweep_pid"; local rc=$?
  sweep_pid=""
  return "$rc"
}
kill_tree() { # <pid>: the step and every process under it
  local c
  kill -STOP "$1" 2>/dev/null || return 0
  for c in $(pgrep -P "$1"); do kill_tree "$c"; done
  kill -KILL "$1" 2>/dev/null
}
stop_sweep() { trap '' HUP INT TERM; [[ -z "$sweep_pid" ]] || kill_tree "$sweep_pid"; }
trap 'stop_sweep; exit 129' HUP; trap 'stop_sweep; exit 130' INT; trap 'stop_sweep; exit 143' TERM

owner=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$APP_ROOT/$CNF")
[[ -n "$owner" ]] && pass "$CNF sets env.gcp.gcp_account_owner_email" || fail "$CNF has no gcp_account_owner_email value"

# --- 1. the real tree ---------------------------------------------------------
export_tree "$T/real" && pass "exported the whole tracked tree" \
  || { fail "SETUP: the tree export is incomplete (disk full? TMPDIR=${TMPDIR:-/tmp}), so no verdict below would mean anything"; exit 1; }
sweep "$T/real"; rc=$?; out=$(<"$T/sweep.out")
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
  sweep "$dir"; rc=$?; out=$(<"$T/sweep.out")
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
