#!/usr/bin/env bash
# owner-orders.inc.sh — the brief copy-in of spec 168 (part b, build row B2;
# owner HUM-10 poll 10af03a3 answer A): the owner's explicit orders on the
# paths a lane works in are copied, word for word, into its brief by code, so
# no lane, orchestrator or relay has to remember them.
#
# The one reader is the ledger action do_spl_owner_order
# (csi-spl-orc/src/bash/run/spl-owner-order.func.sh), sourced in a subshell:
# no ./run log, whose stdout would otherwise carry the order lines. Its exit
# codes are the contract: 0 nothing covered, 3 covered, anything else REFUSE
# (fail closed: a broken ledger never reads as "no order").
#
# Which orders (spec 168 section 4):
#   - per `Repo: <key>` line of the text: `match` with every repo-relative
#     path the text names; a text that names no path gets all the active
#     orders of that repo (`list`)
#   - no `Repo:` line at all: the active orders of every ledger on this box
# Callers:
#   spawn-window.sh  sw_owner_orders: appended to the brief before the seed
#   spool-send.sh    a --kind task body with a `Repo:` line
# Seams: OWNER_ORDER_DIR (default $SPOOL_ROOT/owner-orders), OO_FUNC (the
# action file).

OO_HEADING='## Owner orders on these paths (copied by the spawn from the ledger; obey them word for word)'
OO_FUNC="${OO_FUNC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../run" 2>/dev/null && pwd)/spl-owner-order.func.sh}"

# oo_text_repos <file>: the repo keys of its `Repo: <key>` lines, one per line
oo_text_repos() {
  grep -oE '^[*_ ]*Repo:[*_ ]*[A-Za-z0-9][A-Za-z0-9._-]*' "$1" 2>/dev/null |
    sed -E 's/^[*_ ]*Repo:[*_ ]*//' | awk '!seen[$0]++'
}

# oo_text_paths <file>: the repo-relative paths it names (a word with a slash,
# not absolute, not a URL, no ..), one per line
oo_text_paths() {
  grep -oE '(^|[^A-Za-z0-9_./~:@-])[A-Za-z0-9_.-]*[A-Za-z][A-Za-z0-9_.-]*(/[A-Za-z0-9_.*-]+)+/?' "$1" 2>/dev/null |
    sed -E 's/^[^A-Za-z0-9_.-]//; s#/+$##; s/[.]+$//' | grep -vE '(^|/)\.\.(/|$)' | awk 'NF && !seen[$0]++'
}

# _oo_action [VAR=value...]: do_spl_owner_order in a subshell; its id lines
# go nowhere, its FATAL lines to stderr
_oo_action() {
  # shellcheck disable=SC2016 # the inner script expands its own args
  env "$@" bash -c '
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || { echo "FATAL $b is required" >&2; return 1; }; done; }
    . "$1" || exit 1
    do_spl_owner_order' oo-action "$OO_FUNC" >/dev/null
}

# _oo_collect <text file> <dir> <json out>: every order the text gets, as JSON
# lines in <json out>. rc 0, or 1 with the reason on stderr.
_oo_collect() {
  local text="$1" dir="$2" out="$3" pf repo rc f
  local -a repos=() base=(-u ORDER_PATHS -u ORDER_REPO_DIR -u ORDER_NOW ORDER_ALL=0 OWNER_ORDER_DIR="$dir" ORDER_OUT="$out")
  mapfile -t repos < <(oo_text_repos "$text")
  if ((${#repos[@]} == 0)); then
    for f in "$dir"/*.jsonl; do
      [ -e "$f" ] || continue
      repo="$(basename "$f" .jsonl)"; rc=0
      _oo_action "${base[@]}" ORDER_CMD=list ORDER_REPO="$repo" || rc=$?
      [ "$rc" = 0 ] || { echo "owner-orders: the $repo ledger ($f) refused (list exit $rc)" >&2; return 1; }
    done
    return 0
  fi
  pf="$(mktemp)" || return 1
  oo_text_paths "$text" >"$pf"
  for repo in "${repos[@]}"; do
    rc=0
    if [ -s "$pf" ]; then _oo_action "${base[@]}" ORDER_CMD=match ORDER_REPO="$repo" ORDER_PATHS_FILE="$pf" || rc=$?
    else _oo_action "${base[@]}" ORDER_CMD=list ORDER_REPO="$repo" || rc=$?; fi
    case "$rc" in 0|3) ;; *) rm -f "$pf"; echo "owner-orders: the $repo ledger ($dir/$repo.jsonl) refused (exit $rc)" >&2; return 1 ;; esac
  done
  rm -f "$pf"
}

# oo_section <text file> <section out>: writes the section the text gets (or
# nothing) to <section out> and sets OO_COUNT (orders) and OO_ALREADY (1 when
# the text already carries the section: nothing is added twice). rc 0, or 1
# = REFUSE (the reason on stderr): the spawn or the send must not go on.
# _oo_any_ledger <text file> <dir>: 0 when a ledger the text reads exists
# (one per `Repo:` line, else any *.jsonl in <dir>)
_oo_any_ledger() {
  local repo f
  local -a repos=()
  mapfile -t repos < <(oo_text_repos "$1")
  if ((${#repos[@]} == 0)); then
    for f in "$2"/*.jsonl; do [ -e "$f" ] && return 0; done
    return 1
  fi
  for repo in "${repos[@]}"; do [ -e "$2/$repo.jsonl" ] && return 0; done
  return 1
}

# shellcheck disable=SC2034 # OO_COUNT and OO_ALREADY are read by the callers
oo_section() {
  local text="$1" sec="$2" dir="${OWNER_ORDER_DIR:-${SPOOL_ROOT:-/var/spool-hub}/owner-orders}" js
  OO_COUNT=0; OO_ALREADY=0
  : >"$sec" || { echo "owner-orders: cannot write $sec" >&2; return 1; }
  if grep -qxF "$OO_HEADING" "$text" 2>/dev/null; then OO_ALREADY=1; return 0; fi
  # No ledger the text could read: no order applies (a missing ledger folds
  # to no order in the action too), and the action is not needed.
  _oo_any_ledger "$text" "$dir" || return 0
  command -v jq >/dev/null || { echo "owner-orders: jq is required" >&2; return 1; }
  [ -r "$OO_FUNC" ] || { echo "owner-orders: no ledger action $OO_FUNC" >&2; return 1; }
  js="$(mktemp)" || return 1
  _oo_collect "$text" "$dir" "$js" || { rm -f "$js"; return 1; }
  OO_COUNT="$(jq -s 'unique_by(.order) | length' "$js")" || { rm -f "$js"; echo "owner-orders: the matched orders did not parse" >&2; return 1; }
  if [ "$OO_COUNT" -gt 0 ]; then
    { printf '\n%s\n\n' "$OO_HEADING"
      jq -r -s 'unique_by(.order) | sort_by(.ts) | .[]
        | "- \(.order) (\(.ts), \(.owner), repo \(.repo), gate \(.gate), source \(.source)), paths \(.paths | join(",")):\n"
          + (.text | split("\n") | map("  > " + .) | join("\n"))' "$js"; } >"$sec" ||
      { rm -f "$js"; echo "owner-orders: cannot write $sec" >&2; return 1; }
  fi
  rm -f "$js"
}
