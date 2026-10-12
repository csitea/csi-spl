#!/usr/bin/env bash
# lane-issue.inc.sh — every lane carries an issue, and its docs stay current
# (owner HUM-10, t1 5ea2e615 msgs 5b6f2aa7, 5c4c410e, 346238a8: "the concrete
# decision on what needs to be done and the tracking of the statuses must be
# reflected in the issues ... making sure that the documentation is kept up to
# date as well"). The rule's one home: spool-install/assets/claude/claude-md/
# 27-lane-issue-and-docs.md; how it is enforced: csi-spl-doc/doc/md/lane-issue-and-docs.md.
#
# Offline helpers only (no hub call): the hub legs are do_spl_lane_issue
# (csi-spl-orc/src/bash/run/spl-lane-issue.func.sh). Callers:
#   spawn-core.inc.sh        li_key_from_brief: a lane without a key does not start
#   kill-your-self-report.sh li_gate: /exit-clean refuses a wip issue with no
#                            landed sha and no end reason, and a behaviour
#                            change with no doc change and no `Docs: none (<why>)`
#
# Files, per lane, in <spool root>/<id>/lifetime/:
#   issue      the key, one line (written at placement)
#   issue-end  <status>\t<reason>\t<utc>: the lane ended without landing

# An issue key: the tenant prefix and a number, e.g. SPL-123.
LI_KEY_RE='[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*'

# li_key_from_brief FILE -> the key on the brief's first `Issue: <KEY>` line.
li_key_from_brief() {
  [ -r "${1:-}" ] || return 1
  sed -nE "s/^[-*_ >]*Issue[*_ ]*:[*_\` ]*(${LI_KEY_RE})([^0-9].*)?\$/\1/p" "$1" | sed -n 1p | grep . || return 1
}

# li_key_of_agent SPOOL_ROOT ID -> the lane's key: lifetime/issue, else its
# recorded brief's Issue: line. Nothing = a lane placed before this rule.
li_key_of_agent() {
  local life="$1/$2/lifetime" k=""
  [ -r "$life/issue" ] && k="$(grep -m1 -oE "^${LI_KEY_RE}\$" "$life/issue")"
  [ -n "$k" ] || k="$(li_key_from_brief "$life/brief.md")"
  [ -n "$k" ] && printf '%s\n' "$k"
}

# li_git WORKDIR ARGS: read-only git as whichever user runs the gate (the
# agent user reads the box user's worktree: safe.directory, never a write).
li_git() { local w="$1"; shift; git -c safe.directory='*' -C "$w" "$@"; }

# li_trunk WORKDIR -> origin/<trunk> as of the last fetch.
li_trunk() {
  li_git "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null ||
    { li_git "$1" rev-parse -q --verify origin/master >/dev/null && echo origin/master; }
}

# li_landed WORKDIR KEY -> the trunk commits that close KEY by the landed-fix
# rule (newest first). The rule is c-341's, parsed in one place,
# csi-spl-orc/src/bash/scripts/issue-close-landed.py --keys: the key in a
# fix|feat|perf|refactor subject scope, `feat(orc, SPL-12): ...`, or a
# `Closes: SPL-12` trailer; docs/test/chore/ci subjects and reverts never close.
LI_CLOSE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts" && pwd)/issue-close-landed.py"
li_landed() {
  local h
  while read -r h; do
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
      python3 "$LI_CLOSE_PY" --keys "$1" "$h" 2>/dev/null | grep -qx "$2" && printf '%s\n' "$h"
  done < <(li_cites "$1" "$2")
}

# li_cites WORKDIR KEY -> the trunk commits that name KEY in the subject scope
# (any type, docs and test too) or a Closes: trailer: the lane's work, which
# the docs verdict reads; li_landed keeps the ones that close it.
li_cites() {
  local t h subj k="(^|[^A-Za-z0-9-])$2([^0-9]|\$)"
  t="$(li_trunk "$1")" || return 1
  while read -r h subj; do
    if [[ "$subj" =~ ^[a-z]+\(([^\)]*)\)!?: ]] && [[ "${BASH_REMATCH[1]}" =~ $k ]]; then
      printf '%s\n' "$h"
    elif li_git "$1" log -1 --format='%(trailers:key=Closes,valueonly)' "$h" | grep -qE "$k"; then
      printf '%s\n' "$h"
    fi
  done < <(li_git "$1" log "$t" --format='%H %s' -E --grep="$k" 2>/dev/null)
}

# li_is_code PATH: a path whose change changes behaviour (code under api, orc,
# iac or wui); tests, markdown and fixtures do not.
li_is_code() {
  [[ "$1" =~ ^csi-spl-(api|orc|iac|wui)/ ]] || return 1
  [[ "$1" =~ (^|/)(tests?|e2e|fixtures?|testdata)/ || "$1" =~ (_test\.go|\.tst\.sh|\.test\.(m?js|ts)|\.spec\.ts|\.md)$ ]] && return 1
  return 0
}

# li_docs_verdict WORKDIR SHA... -> "ok <why>" or "missing <first code path>".
# Docs are current when the commits change no code, or one of them touches
# csi-spl-doc/, or one carries a `Docs: none (<why>)` trailer.
li_docs_verdict() {
  local w="$1" s p code=""; shift
  [ $# -gt 0 ] || { echo "ok no commits"; return 0; }
  for s in "$@"; do
    if li_git "$w" log -1 --format=%B "$s" | grep -qiE '^Docs:[[:space:]]*none[[:space:]]*\([^)]*[^[:space:])][^)]*\)'; then
      echo "ok Docs: none trailer in ${s:0:12}"; return 0
    fi
    while IFS= read -r p; do
      [[ "$p" == csi-spl-doc/* ]] && { echo "ok doc change in ${s:0:12}"; return 0; }
      [ -z "$code" ] && li_is_code "$p" && code="$p"
    done < <(li_git "$w" diff-tree --no-commit-id --name-only -r "$s" 2>/dev/null)
  done
  [ -n "$code" ] && { echo "missing $code"; return 0; }
  echo "ok no behaviour change"
}

# li_end_cmd ID -> the command that ends a lane's issue without landing.
li_end_cmd() {
  printf "cd csi-spl-orc && sudo -u %s env AGENT_ID=%s LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON='<why>' DRY_RUN=0 ./run -a do_spl_lane_issue" "${SPOOL_BOX_USER:-<box user>}" "$1"
}

# li_gate SPOOL_ROOT ID WORKDIR: 0 = the lane may exit; 3 = refused, one line
# on stderr naming what is missing and the command that fixes it.
li_gate() {
  local root="$1" id="$2" w="$3" key end v
  local -a shas=()
  key="$(li_key_of_agent "$root" "$id")"
  # No key: a lane placed before the rule; not checked, and silent (the
  # ACCEPTED line stays the gate's one line).
  [ -n "$key" ] || return 0
  end="$root/$id/lifetime/issue-end"
  local -a cites=()
  mapfile -t shas < <(li_landed "$w" "$key")
  if [ "${#shas[@]}" -eq 0 ]; then
    if [ -s "$end" ]; then
      echo "issue gate: $key ended without landing: $(cut -f1,2 "$end" | tr '\t' ' ')" >&2
      return 0
    fi
    echo "exit-clean refused: issue $key is still wip: no commit on $(li_trunk "$w" || echo origin/master) closes it (a fix|feat|perf|refactor subject with $key in its scope, or a 'Closes: $key' trailer; fetch first) and no end reason; land a commit citing $key, or end it: $(li_end_cmd "$id")" >&2
    return 3
  fi
  mapfile -t cites < <(li_cites "$w" "$key")
  v="$(li_docs_verdict "$w" "${cites[@]}")"
  if [[ "$v" == missing* ]]; then
    echo "exit-clean refused: $key changes behaviour (${v#missing }) with no csi-spl-doc/ change and no 'Docs: none (<why>)' trailer in its ${#cites[@]} commit(s); land a doc change citing $key, or a commit citing $key whose message carries 'Docs: none (<why>)'" >&2
    return 3
  fi
  echo "issue gate: $key landed in ${#shas[@]} commit(s), newest ${shas[0]:0:12}; docs: ${v#ok }" >&2
  return 0
}
