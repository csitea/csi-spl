#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description A security baseline grows only with a ticket id (SPL-2153,
# @description owner security scan action 10): every finding a scanner gate
# @description lets through is listed in one of the files below, and a NEW
# @description entry there must name the issue that triaged it (SPL-<n>).
# @description It compares each file at the anchor (the commit before the gate
# @description existed, so the legacy entries stay as they are) with HEAD,
# @description hunk by hunk:
# @description   - an entry line in the hunk that is new (not a moved line,
# @description     not a count that went DOWN) needs an SPL-<n> on one of
# @description     the hunk's added lines: the entry's own trailing comment
# @description     or a comment line right beside it;
# @description   - comment-only and shrinking hunks pass;
# @description   - the checkov baseline is JSON, which has no comment: its
# @description     new entries need an SPL-<n> in the message of a commit
# @description     that touched it since the anchor.
# @description Files: the gosec, semgrep, eslint-security and shellcheck count
# @description baselines, .trivyignore.yaml, .gitleaks.toml, osv-scanner.toml,
# @description .hadolint.yaml, .zap/rules.tsv and the checkov baseline.
# @description Read only: git show/log, no network. Exit 1 names each hunk.
# @description The compare: csi-spl-iac/src/bash/scripts/baseline-growth.py.
# @param BASELINE_GROWTH_TREE (optional) - checkout root, default $APP_PATH
# @param BASELINE_GROWTH_ANCHOR (optional) - the commit to compare from, default _BG_ANCHOR
# @param BASELINE_GROWTH_HEAD (optional) - the commit to check, default HEAD
# @param BASELINE_GROWTH_FILES (optional) - space-separated paths, default _BG_FILES
# @example ./run -a do_check_baseline_growth
#------------------------------------------------------------------------------

# origin/master when the gate was written: every entry already in a baseline
# file there is grandfathered; everything added after it carries its ticket.
_BG_ANCHOR=ffc79e6b937d689a308d9762471d8403ab4e8e66
_BG_FILES=".gosec-baseline.txt .semgrep-baseline.txt .eslint-security-baseline.txt
.shellcheck-warning-baseline.txt .trivyignore.yaml .gitleaks.toml osv-scanner.toml
.hadolint.yaml .zap/rules.tsv csi-spl-iac/src/terraform/.checkov.baseline"
_BG_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../scripts/baseline-growth.py"

do_check_baseline_growth() {
  local tree="${BASELINE_GROWTH_TREE:-$APP_PATH}" anchor="${BASELINE_GROWTH_ANCHOR:-$_BG_ANCHOR}"
  local head="${BASELINE_GROWTH_HEAD:-HEAD}" files="${BASELINE_GROWTH_FILES:-$_BG_FILES}" out rc=0
  git -C "$tree" rev-parse -q --verify "$anchor^{commit}" >/dev/null 2>&1 ||
    { do_log "FATAL baseline-growth: anchor $anchor is not in $tree (a shallow clone? fetch-depth: 0)"; return 1; }
  git -C "$tree" merge-base --is-ancestor "$anchor" "$head" 2>/dev/null ||
    { do_log "FATAL baseline-growth: anchor $anchor is not an ancestor of $head"; return 1; }
  # shellcheck disable=SC2086  # files is a space-separated list
  out=$(python3 "$_BG_SCRIPT" "$tree" "$anchor" "$head" $files) || rc=$?
  [[ "$rc" -eq 0 ]] || { do_log "FATAL baseline-growth: the compare failed (exit $rc): $out"; return 1; }
  printf '%s\n' "$out"
  if grep -q '^NO-TICKET ' <<<"$out"; then
    do_log "FATAL baseline-growth: a security baseline grew without a ticket id: put SPL-<n> on the new line (# SPL-<n> ...) or on a comment line beside it"
    return 1
  fi
  do_log "INFO baseline-growth: every entry added since ${anchor:0:9} names its ticket"
}
