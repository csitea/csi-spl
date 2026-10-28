#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The gate on the NEXT runner image (SPL-3431, CI failures panel
# csi-spl-doc/doc/md/ci-failures-100-2026-10-25.md row I4, smell S2): on
# 2026-10-25 `ubuntu-latest` moved to ubuntu-26.04 and the orc suite went red
# for 2 h 08 min (16 jobs, 7 runs), because nothing had run it there first.
# wf 13 runs the whole wf 10 gate, by workflow_call, on the image named by
# the repo variable SPOOL_CI_NEXT_RUNNER, once a day and on a push to a
# throwaway `ci-next-image/**` branch, so the image reds before the move.
#
# What it asserts on .github/workflows/13_ci-next-image.yml:
#   1. a schedule (cron) trigger, and a push trigger for ci-next-image/** only
#      (never master: the master push is wf 10's own);
#   2. its one job calls ./.github/workflows/10_ci-quality.yml, not a
#      hand-kept copy of its jobs, with `runner` read from
#      vars.SPOOL_CI_NEXT_RUNNER;
#   3. it passes `secrets: inherit` (the hygiene sweep of wf 10 reds without
#      the private overlay secret, run 40623348179);
#   4. it never reads SPOOL_CI_RUNNER (that is the gate's own image) and its
#      token is read-only.
#   CONTROLS: a workflow with no cron, one that pushes on master, one that
#   copies jobs instead of calling wf 10, one with no secrets, one that reads SPOOL_CI_RUNNER and
#   one with a write token are each refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="${WF_NEXT:-$APP_ROOT/.github/workflows/13_ci-next-image.yml}"

fails=0

# push_block <file>: the lines of the `on: push:` trigger.
push_block() { awk '/^  push:/{p=1; next} p && /^  [a-z_]+:/{p=0} p' "$1"; }

# check_wf <file>: print one line per broken rule, nothing when it holds.
check_wf() {
  local f="$1"
  [[ -f "$f" ]] || { echo "no workflow at $f"; return; }
  grep -qE '^[[:space:]]*-[[:space:]]*cron:' "$f" || echo "no schedule cron"
  local push; push=$(push_block "$f")
  [[ "$push" == *'ci-next-image/**'* ]] || echo "no push trigger for ci-next-image/**"
  grep -qwE 'master|main' <<<"$push" && echo "pushes on trunk (wf 10 gates the master push)"
  grep -qE '^[[:space:]]+uses:[[:space:]]*\./\.github/workflows/10_ci-quality\.yml[[:space:]]*$' "$f" \
    || echo "does not call ./.github/workflows/10_ci-quality.yml"
  grep -qE '^[[:space:]]+secrets:[[:space:]]*inherit[[:space:]]*$' "$f" \
    || echo "no secrets: inherit (wf 10's hygiene sweep needs the private overlay)"
  grep -qE '^[[:space:]]+runs-on:' "$f" && echo "carries its own runs-on job (a copy of wf 10, not a call)"
  grep -qE '^[[:space:]]+runner:.*vars\.SPOOL_CI_NEXT_RUNNER' "$f" \
    || echo "runner not read from vars.SPOOL_CI_NEXT_RUNNER"
  grep -qE 'vars\.SPOOL_CI_RUNNER\b' "$f" && echo "reads SPOOL_CI_RUNNER (the gate's own image)"
  grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write' "$f" && echo "asks for a write token"
}

bad=$(check_wf "$WF")
if [[ -z "$bad" ]]; then
  pass "wf 13: daily + ci-next-image/** push, calls wf 10 with runner = SPOOL_CI_NEXT_RUNNER, read-only"
else
  fail "wf 13 breaks the next-image rule:"; sed 's/^/      /' <<<"$bad"
fi

# --- controls: each plant must be refused ------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat >"$T/good.yml" <<'YML'
on:
  schedule:
    - cron: "17 5 * * *"
  push:
    branches: ["ci-next-image/**"]
permissions:
  contents: read
jobs:
  gate:
    uses: ./.github/workflows/10_ci-quality.yml
    secrets: inherit
    with:
      runner: ${{ vars.SPOOL_CI_NEXT_RUNNER }}
YML
good=$(check_wf "$T/good.yml")
[[ -z "$good" ]] && pass "CONTROL: the minimal good workflow passes" \
  || fail "CONTROL: the minimal good workflow was refused: $good"
plant() { # plant <name> <sed expr> <expected substring>
  sed "$2" "$T/good.yml" >"$T/$1.yml"
  local got; got=$(check_wf "$T/$1.yml")
  if [[ "$got" == *"$3"* ]]; then pass "CONTROL: $1 is refused ($3)"
  else fail "CONTROL: $1 was not refused"; fi
}
plant no-cron '/cron:/d' "no schedule cron"
plant trunk-push 's#"ci-next-image/\*\*"#"ci-next-image/**", master#' "pushes on trunk"
plant copied-jobs 's#uses: ./.github/workflows/10_ci-quality.yml#runs-on: ubuntu-latest#' "does not call"
plant no-secrets '/secrets: inherit/d' "no secrets: inherit"
plant gate-image 's#SPOOL_CI_NEXT_RUNNER#SPOOL_CI_RUNNER#' "reads SPOOL_CI_RUNNER"
plant write-token 's#contents: read#contents: write#' "write token"

[[ "$fails" -eq 0 ]] && { echo "ci-next-image: all checks passed"; exit 0; }
echo "ci-next-image: $fails check(s) failed"; exit 1
