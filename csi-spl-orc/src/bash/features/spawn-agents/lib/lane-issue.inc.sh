#!/usr/bin/env bash
# lane-issue.inc.sh — every lane carries an issue, and its docs stay current
# (owner HUM-10, t1 5ea2e615 msgs 5b6f2aa7, 5c4c410e, 346238a8: "the concrete
# decision on what needs to be done and the tracking of the statuses must be
# reflected in the issues ... making sure that the documentation is kept up to
# date as well"). The rule's one home: spool-install/assets/claude/claude-md/
# 27-lane-issue-and-docs.md; how it is enforced: csi-spl-doc/doc/md/lane-issue-and-docs.md.
#
# Offline helpers, but for one hub read: li_hub_status asks
# do_spl_issue_status (csi-spl-orc/src/bash/run/spl-issue-status.func.sh) for
# the key's status when a lane landed nothing. The hub writes are
# do_spl_lane_issue (csi-spl-orc/src/bash/run/spl-lane-issue.func.sh). Callers:
#   spawn-core.inc.sh        li_key_from_brief: a lane without a key does not start
#   kill-your-self-report.sh li_gate: /exit-clean refuses a wip issue with no
#                            landed sha, no end reason and no done on the
#                            hub, and a behaviour
#                            change with no doc change and no `Docs: none (<why>)`
#
# Files, per lane, in <spool root>/<id>/lifetime/:
#   issue      the key, one line (written at placement)
#   issue-end  <status>\t<reason>\t<utc>: the lane ended without landing;
#              done\t<why>\t<utc>\t<repo>\t<sha>: its work landed in another
#              repo, checked on that repo's origin trunk (SPL-2229)

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

# No issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msgs
# ef77b762, 5863d0d6, 2026-10-17: "You shouldn't be creating issues without
# epics, nor issues without a git spec"). A level-2 issue names a spec folder
# that exists on origin/master and has a level-1 epic above it. Callers:
# do_spl_lane_issue, do_spl_issue_create, do_spl_spawn_enqueue.
LI_EPIC_SPEC_RULE='no issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6)'
LI_SPEC_RE='csi-spl-doc/specs/[0-9]{3}-[a-z0-9]([a-z0-9-]*[a-z0-9])?'
# The repo whose origin trunk holds the specs: this file's checkout.
LI_SPEC_REPO_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." 2>/dev/null && pwd)"

# li_epic_from_brief FILE -> the key on the brief's first `Epic: <KEY>` line.
li_epic_from_brief() {
  [ -r "${1:-}" ] || return 1
  sed -nE "s/^[-*_ >]*Epic[*_ ]*:[*_\` ]*(${LI_KEY_RE})([^0-9].*)?\$/\1/p" "$1" | sed -n 1p | grep . || return 1
}

# li_spec_from_file FILE -> the spec folder it names: a `Spec:` line first,
# else the first csi-spl-doc/specs/NNN-<slug> anywhere in it. One match only:
# grep -m1 stops after a LINE, -o prints every match on it (sed -n 1p).
li_spec_from_file() {
  local s
  [ -r "${1:-}" ] || return 1
  s="$(grep -m1 -iE '^[-*_ >]*Spec[*_ ]*:' "$1" | grep -oE "$LI_SPEC_RE" | sed -n 1p)"
  [ -n "$s" ] || s="$(grep -oE "$LI_SPEC_RE" "$1" | sed -n 1p)"
  [ -n "$s" ] && printf '%s\n' "$s"
}

# li_spec_on_master SPEC -> 0 when the folder is a tree on the specs repo's
# origin trunk (LI_SPEC_REPO, default this checkout); a miss fetches once.
li_spec_on_master() {
  local r="${LI_SPEC_REPO:-$LI_SPEC_REPO_DEFAULT}" t
  [[ "$1" =~ ^${LI_SPEC_RE}$ ]] || return 1
  t="$(li_trunk "$r")" || return 1
  [ "$(li_git "$r" cat-file -t "$t:$1" 2>/dev/null)" = tree ] && return 0
  timeout "${LI_SPEC_FETCH_TIMEOUT:-30}" git -c safe.directory='*' -C "$r" fetch -q origin "${t#origin/}" </dev/null >/dev/null 2>&1
  [ "$(li_git "$r" cat-file -t "$t:$1" 2>/dev/null)" = tree ]
}

# li_spec_pinned_epic SPEC -> the epic the spec names in its first 40 lines
# ("Epic SPL-74"), the pin spec-import-issues.py _pinned_epic reads.
li_spec_pinned_epic() {
  local r="${LI_SPEC_REPO:-$LI_SPEC_REPO_DEFAULT}" t
  t="$(li_trunk "$r")" || return 1
  li_git "$r" show "$t:$1/spec.md" 2>/dev/null | head -40 |
    grep -oE "(^|[^A-Za-z])Epic:?[[:space:]]+${LI_KEY_RE}" | sed -n 1p | grep -oE "${LI_KEY_RE}\$"
}

# li_epic_spec SPEC EPIC -> "<spec>\t<epic>": SPEC must be a folder on the
# origin trunk; EPIC is the given one, else the spec's pin, else empty (the
# caller looks up the spec's "Spec NNN - ..." epic on the hub, or refuses).
# One FATAL line and rc 1 when the spec is missing or not on the trunk.
li_epic_spec() {
  local spec="$1" epic="$2"
  if [ -z "$spec" ]; then
    do_log "FATAL ${LI_REFUSED:-refused, nothing filed}: $LI_EPIC_SPEC_RULE: no spec folder named. Add a 'Spec: csi-spl-doc/specs/<NNN-slug>' line (a folder on origin/master) and an 'Epic: SPL-<n>' line" >&2
    return 1
  fi
  if ! li_spec_on_master "$spec"; then
    do_log "FATAL ${LI_REFUSED:-refused, nothing filed}: $LI_EPIC_SPEC_RULE: $spec is not a folder on origin/master. Land the spec first, or name an existing one" >&2
    return 1
  fi
  [ -n "$epic" ] || epic="$(li_spec_pinned_epic "$spec")"
  printf '%s\t%s\n' "$spec" "$epic"
}

# li_brief_epic_spec BRIEF -> "<spec>\t<epic>" for a brief that files an
# issue; the epic must be on the brief or pinned in its spec (an enqueue does
# not ask the hub). A brief with an `Issue:` key passes: that issue exists.
li_brief_epic_spec() {
  local out
  li_key_from_brief "$1" >/dev/null && return 0
  out="$(li_epic_spec "$(li_spec_from_file "$1")" "$(li_epic_from_brief "$1")")" || return 1
  if [ -z "${out#*$'\t'}" ]; then
    do_log "FATAL ${LI_REFUSED:-refused, nothing filed}: $LI_EPIC_SPEC_RULE: brief $1 names no epic. Add an 'Epic: SPL-<n>' line (the level-1 epic of ${out%%$'\t'*})" >&2
    return 1
  fi
  printf '%s\n' "$out"
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
# csi-spl-doc/, or one carries a `Docs: none (<why>)` trailer. The trailer is
# read whole: its reason may wrap onto the next lines (indented or not), up to
# a blank line or the next `Key:` line (66d208922, SPL-2656).
li_docs_verdict() {
  local w="$1" s p code=""; shift
  [ $# -gt 0 ] || { echo "ok no commits"; return 0; }
  for s in "$@"; do
    if li_git "$w" log -1 --format=%B "$s" |
      awk 'f && (/^[[:space:]]*$/ || /^[A-Za-z0-9-]+:/) { print j; f = 0 }
           f { sub(/^[[:space:]]+/, ""); j = j " " $0; next }
           tolower($0) ~ /^docs:/ { j = $0; f = 1 }
           END { if (f) print j }' |
      grep -iE '^Docs:[[:space:]]*none[[:space:]]*\([^)]*[^[:space:])][^)]*\)' >/dev/null; then
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

# li_hub_status KEY -> the key's status on the hub, best effort: nothing when
# the read fails or takes over LI_HUB_TIMEOUT (default 20) seconds. The read is
# do_spl_issue_status in this tree's orc, as the desk user (li_desk_user: the
# desk's keys are theirs); LI_HUB_STATUS_CMD replaces it (tests: a stub, no network), called
# with the key and expected to print the same `issue-status<TAB>KEY<TAB>status`.
# A test sandbox (SPOOL_TEST=1) with no stub reads nothing.
LI_ORC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
li_hub_status() {
  li_hub_read "$1" | li_status_of "$1"
}

# li_desk_user -> the OS user whose HOME holds the desks and their keys (spec
# 069 section 8.3): SPOOL_DESK_USER (a script loads it from box.env), else
# spl_desk_user's box config read when a ./run action sourced this, else
# SPOOL_BOX_USER, as before the key. Empty when none is known.
li_desk_user() {
  local u="${SPOOL_DESK_USER:-}"
  [ -n "$u" ] || ! declare -F spl_desk_user >/dev/null || u="$(spl_desk_user)"
  printf '%s' "${u:-${SPOOL_BOX_USER:-}}"
}

# li_desk_hop ARRAY: set ARRAY to the prefix that runs a command as the desk
# user with its HOME (`sudo -n -u <desk user> env HOME=<its home>`), or to
# nothing when the caller is the desk user or none is known. The hop of every
# ./run action here that signs to the hub with the desk.
li_desk_hop() {
  local -n _li_hop="$1"
  local u
  _li_hop=()
  u="$(li_desk_user)"
  [ -n "$u" ] && [ "$(id -un)" != "$u" ] || return 0
  _li_hop=(sudo -n -u "$u" env HOME="$(getent passwd "$u" | cut -d: -f6)")
}

# li_status_of KEY < ANSWER -> the status on its `issue-status` line, or nothing.
li_status_of() {
  awk -F'\t' -v k="$1" '$1 == "issue-status" && $2 == k && $3 ~ /^[a-z_]+$/ { s = $3 } END { if (s != "") print s }'
}

# li_hub_read KEY -> do_spl_issue_status's whole answer, its refusal line
# too (the hub's "not_found" for an archived or deleted issue); nothing when
# there is no hub to ask. The one hub read of li_hub_status and li_epic_closed.
li_hub_read() {
  local key="$1"
  local -a cmd=()
  if [ -n "${LI_HUB_STATUS_CMD:-}" ]; then
    timeout "${LI_HUB_TIMEOUT:-20}" "$LI_HUB_STATUS_CMD" "$key" 2>&1 </dev/null
    return 0
  fi
  [ "${SPOOL_TEST:-}" != 1 ] && [ -x "$LI_ORC/run" ] || return 0
  li_desk_hop cmd
  (cd "$LI_ORC" && timeout "${LI_HUB_TIMEOUT:-20}" "${cmd[@]}" env ISSUE_REF="$key" \
    SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" ./run -a do_spl_issue_status 2>&1 </dev/null)
  return 0
}

# An issue goes under an open epic only: the hub answers "unknown_parent"
# for an epic that is archived or deleted, and the epic close of SPL-1729
# archives it (SPL-2508: SPL-2372 auto-closed at 00:25Z on 2026-10-18, and
# every queued brief naming it failed at launch, spawn-window exit 12, each
# 10 min). li_epic_closed EPIC -> one reason on stdout when the hub says
# EPIC is done, diss or not a live issue; nothing when it is open or the hub
# did not answer (an outage refuses nothing; the launch still reports it).
# An epic the SPL-1729 close archived (the hub's get answers auto_closed,
# SPL-2607) adds a 2nd TSV field `auto-closed`: a placer may reopen it
# (li_epic_reopen, SPL-2558); a close by a person or an agent has none.
li_epic_closed() {
  local out st mark
  out="$(li_hub_read "$1")"
  st="$(li_status_of "$1" <<<"$out")"
  mark="$(awk -F'\t' -v k="$1" '$1 == "issue-status" && $2 == k { m = $4 } END { if (m == "auto-closed") print "\tauto-closed" }' <<<"$out")"
  case "$st" in
    done|diss) printf '%s is %s on the hub%s\n' "$1" "$st" "$mark" ;;
    "") grep -q 'not_found' <<<"$out" && printf '%s is not a live issue on the hub (archived, deleted or never filed)\n' "$1" ;;
  esac
  return 0
}

# li_brief_epic_closed BRIEF -> one line naming the brief, its epic and the
# fix when the epic the lane would be filed under is closed (li_epic_closed);
# nothing for an open epic, a brief with an `Issue:` key or no epic; the
# `auto-closed` field of li_epic_closed passes through as a 2nd TSV field.
# Callers: do_spl_spawn_enqueue (refuses the ask) and do_spl_spawn_place
# (reopens an auto-closed epic and launches, else hands it to the
# orchestrator instead of launching it).
li_brief_epic_closed() {
  local out epic why mark=""
  out="$(li_brief_epic_spec "$1" 2>/dev/null)" || return 0
  epic="${out#*$'\t'}"
  [ -n "$out" ] && [ -n "$epic" ] || return 0
  why="$(li_epic_closed "$epic")"
  [ -n "$why" ] || return 0
  [[ "$why" != *$'\t'auto-closed ]] || { why="${why%$'\t'auto-closed}"; mark=$'\t'auto-closed; }
  printf "brief %s names epic %s, but %s: point its 'Epic:' line at an open epic, or reopen %s (SPL-2508)%s\n" "$1" "$epic" "$why" "$epic" "$mark"
  return 0
}

# li_epic_reopen EPIC COMMENT: unarchive EPIC, set it wip and comment why, as
# the desk spl_desk_issue_run acts for (the caller resolves it). Callers:
# do_spl_issue_close_landed (a move closed an epic a brief on this box names)
# and do_spl_spawn_place (its head brief names an auto-closed epic, SPL-2558).
# Exit 1 at the first failed call.
li_epic_reopen() {
  spl_desk_issue_run unarchive --ref "$1" >/dev/null &&
    spl_desk_issue_run update --ref "$1" --status wip >/dev/null &&
    spl_desk_issue_run comment --ref "$1" --body "$2" >/dev/null
}

# li_end_cmd ID -> the command that ends a lane's issue without landing.
li_end_cmd() {
  printf "cd csi-spl-orc && sudo -u %s env AGENT_ID=%s LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON='<why>' DRY_RUN=0 ./run -a do_spl_lane_issue" "$(u="$(li_desk_user)"; printf '%s' "${u:-<box user>}")" "$1"
}

# li_landed_cmd ID -> the command for a lane whose work landed in another
# repo (no csi-spl commit can close its key): do_spl_lane_issue checks the
# sha on that repo's origin trunk, then sets the issue done (SPL-2229).
li_landed_cmd() {
  printf "cd csi-spl-orc && sudo -u %s env AGENT_ID=%s LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_LANDED_REPO=<cnf repo name> LANE_LANDED_SHA=<sha> DRY_RUN=0 ./run -a do_spl_lane_issue" "$(u="$(li_desk_user)"; printf '%s' "${u:-<box user>}")" "$1"
}

# li_end_record KEY END_FILE ID: the gate's verdict on an issue-end record. A
# done record passes only with the repo + sha its check wrote (SPL-2229).
li_end_record() {
  local st repo sha
  IFS=$'\t' read -r st _ _ repo sha <"$2"
  if [ "$st" != "done" ]; then
    echo "issue gate: $1 ended without landing: $(cut -f1,2 "$2" | tr '\t' ' ')" >&2
    return 0
  fi
  if [ -n "$repo" ] && [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "issue gate: $1 landed in another repo: $repo ${sha:0:12} (checked on its origin trunk)" >&2
    return 0
  fi
  echo "exit-clean refused: $2 says done but names no repo + sha; set it with the check: $(li_landed_cmd "$3")" >&2
  return 3
}

# li_gate SPOOL_ROOT ID WORKDIR: 0 = the lane may exit; 3 = refused, one line
# on stderr naming what is missing and the command that fixes it. With no
# landed commit and no end reason it asks the hub last: an issue the
# orchestrator already set done there (an apply-only lane, no code commit)
# passes; any other status, or no answer, is refused as before (SPL-1813).
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
    [ -s "$end" ] && { li_end_record "$key" "$end" "$id"; return; }
    if [ "$(li_hub_status "$key")" = "done" ]; then
      echo "issue gate: $key done on the hub (no landed commit)" >&2
      return 0
    fi
    echo "exit-clean refused: issue $key is still wip: no commit on $(li_trunk "$w" || echo origin/master) closes it (a fix|feat|perf|refactor subject with $key in its scope, or a 'Closes: $key' trailer; fetch first) and no end reason; land a commit citing $key, or end it: $(li_end_cmd "$id"); work landed in another repo: $(li_landed_cmd "$id")" >&2
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
