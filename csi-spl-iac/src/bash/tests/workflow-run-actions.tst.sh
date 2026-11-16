#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Every `./run -a do_<name>` in .github/workflows/*.yml maps to a file the
# loader finds: a `<sub-project>/src/bash/run/**/<a-b>.func.sh` (or `a_b`)
# that defines `do_<name>()` (SPL-5658, ci-failures-50-2026-11-15.md T5/S4).
# Before this test only a CI run compared the two names: d6bcf4309's
# 10_ci-quality.yml called `do_check_wui_lang_review`, whose code is in
# check-pre-push-lang-review.func.sh, and 5 runs went red on it.
#
# WORKFLOW_RUN_ACTIONS_DIR=<dir> checks the *.yml of that dir instead of the
# tree's (the red control: a workflow file taken from an old sha).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="${WORKFLOW_RUN_ACTIONS_DIR:-$APP_ROOT/.github/workflows}"

fails=0

# wra_defined <root> <do_name>: 0 when a sub-project of <root> has a
# src/bash/run/**/<a[-_]b>.func.sh that defines <do_name>().
wra_defined() {
  local root="$1" n="$2" g f body
  g="${n#do_}" && g="${g//_/[-_]}"
  for f in "$root"/csi-spl-*/src/bash/run/**/$g.func.sh; do
    body=""
    read -r -d '' body <"$f" || true
    [[ "$body" =~ (^|$'\n')[[:space:]]*(function[[:space:]]+)?${n}[[:space:]]*\(\) ]] && return 0
  done
  return 1
}

# wra_unmapped <root> <wf_dir>: prints `<file>: <do_name>` for every
# `run -a do_*` name of <wf_dir>/*.yml that wra_defined cannot find.
wra_unmapped() {
  local root="$1" dir="$2" f n
  shopt -s globstar nullglob
  for f in "$dir"/*.yml; do
    while IFS= read -r n; do
      wra_defined "$root" "$n" || echo "${f##*/}: $n"
    done < <(grep -oE 'run -a do_[a-z0-9_]+' "$f" | sed 's/^run -a //' | sort -u)
  done
  shopt -u globstar nullglob
}

shopt -s nullglob
wf_files=("$WF_DIR"/*.yml)
shopt -u nullglob
((${#wf_files[@]} > 0)) || { fail "no *.yml under $WF_DIR"; exit 1; }
total=$(cat "${wf_files[@]}" | grep -oE 'run -a do_[a-z0-9_]+' | sort -u | wc -l)
((total > 0)) || fail "no ./run -a do_* line under $WF_DIR (the grep is broken)"

bad=$(wra_unmapped "$APP_ROOT" "$WF_DIR")
if [[ -z "$bad" ]]; then
  pass "all $total workflow ./run -a do_* names map to a .func.sh that defines them"
else
  fail "workflow ./run -a names with no defining <sub-project>/src/bash/run/<name>.func.sh:"
  sed 's/^/  /' <<<"$bad"
fi

# --- control: a planted workflow naming an action nobody defines is caught ---
CTL=$(mktemp -d)
trap 'rm -rf "$CTL"' EXIT
printf 'jobs:\n  x:\n    steps:\n      - run: ./run -a do_check_dist_hygiene\n      - run: ./run -a do_wra_no_such_action_planted\n' >"$CTL/planted.yml"
ctl=$(wra_unmapped "$APP_ROOT" "$CTL")
if [[ "$ctl" == "planted.yml: do_wra_no_such_action_planted" ]]; then
  pass "CONTROL: a workflow naming an undefined action is reported, a defined one is not"
else
  fail "CONTROL: planted workflow gave '$ctl'"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-run-actions.tst.sh assertions"
exit "$fails"
