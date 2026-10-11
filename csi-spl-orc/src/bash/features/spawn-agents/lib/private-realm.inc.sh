#!/usr/bin/env bash
# private-realm.inc.sh (spec 129 G1, phase A0) — which lanes are PRIVATE: a
# lane whose brief comes from a topic of a customer workspace, or whose
# checkout is a customer's private repo. A private lane never gets a worktree
# of this (public) repository and never pushes to it. The decision keys on
# where the work came from (topic, checkout), never on what it says.
#
# THE LIST (box-local, never in git, never in the hub database: spec 129 Q2):
#   ${SPOOL_PRIVATE_REALMS:-$SPOOL_ROOT/private-realms.conf}, mode 0640, group
#   spool-agents. One record per line, '#' starts a comment:
#     workspace <workspace_id> <topic> [<topic>...]
#     checkout  <workspace_id> <absolute dir of a private repo checkout>
#   <topic> is a topic uuid or its first 8 hex chars; it is matched on those 8.
#   Written only through `./run -a do_spl_private_realm` (csi-spl-orc), which
#   prints its path and line count, never its content.
#
# THE LANE'S REALM (the box-local half of its lane map row):
#   $SPOOL_ROOT/<ID>/lane.realm, one line `realm=public` or
#   `realm=private:<workspace_id>`, written at spawn. The hub row carries only
#   `realm=private` as its scope: the workspace id names a customer.
#
# Readers: spawn-core.inc.sh (records the realm, refuses the worktree),
# hooks/pre-push and hooks/pre-push-trampoline (refuse the push).

# The list file.
pr_file() { printf '%s\n' "${SPOOL_PRIVATE_REALMS:-${SPOOL_ROOT:-/var/spool-hub}/private-realms.conf}"; }

# The records of the list, comments and blank lines dropped. Exit 2 when the
# file exists but cannot be read: a caller must then refuse, never assume public.
pr_records() {
  local f; f="$(pr_file)"
  [ -e "$f" ] || return 0
  [ -r "$f" ] || return 2
  sed -e 's/#.*//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' "$f" | grep -v '^$'
  return 0
}

# private:<ws> for the first listed topic whose 8-hex prefix appears as a word
# in the given text (a task id such as dispatch-<8hex>-a0, a topic uuid, a
# WUI link); exit 1 when none does, 2 when the list is unreadable.
pr_realm_of_text() {  # <text>
  local recs toks kind ws rest t
  recs="$(pr_records)" || return 2
  [ -n "$recs" ] || return 1
  toks=" $(printf '%s' "$1" | grep -oiE '(^|[^0-9a-f])[0-9a-f]{8}([^0-9a-f]|$)' | grep -oiE '[0-9a-f]{8}' | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ')"
  while read -r kind ws rest; do
    [ "$kind" = workspace ] || continue
    for t in $rest; do
      t="$(printf '%s' "${t:0:8}" | tr 'A-F' 'a-f')"
      case "$toks" in *" $t "*) printf 'private:%s\n' "$ws"; return 0 ;; esac
    done
  done <<<"$recs"
  return 1
}

# private:<ws> when the dir is (inside) a listed private checkout; exit 1 when
# not, 2 when the list is unreadable.
pr_realm_of_path() {  # <dir>
  local recs d kind ws p
  recs="$(pr_records)" || return 2
  [ -n "$recs" ] && [ -n "$1" ] || return 1
  d="$(readlink -m "$1")"
  while read -r kind ws p; do
    [ "$kind" = checkout ] && [ -n "$p" ] || continue
    p="$(readlink -m "$p")"
    case "$d/" in "$p"/*) printf 'private:%s\n' "$ws"; return 0 ;; esac
  done <<<"$recs"
  return 1
}

# The realm of a lane about to be spawned: from its topic, its brief and its
# work dir. Prints realm=public or realm=private:<ws>; exit 2 (with the
# reason on stderr) when the list cannot be read.
pr_resolve() {  # <topic> <brief file or ""> <workdir>
  local r rc text="$1"
  [ -n "$2" ] && [ -r "$2" ] && text="$text
$(cat "$2")"
  r="$(pr_realm_of_text "$text")"; rc=$?
  [ "$rc" -eq 1 ] && { r="$(pr_realm_of_path "$3")"; rc=$?; }
  case "$rc" in
    0) printf 'realm=%s\n' "$r" ;;
    1) printf 'realm=public\n' ;;
    *) echo "private-realm: $(pr_file) exists but is not readable here; cannot tell a private lane from a public one" >&2; return 2 ;;
  esac
}

# The realm file of a lane.
pr_lane_file() { printf '%s/%s/lane.realm\n' "${SPOOL_ROOT:-/var/spool-hub}" "$1"; }

# The recorded realm of a lane: its lane.realm line, realm=public without one.
pr_lane_realm() {  # <ID>
  local l
  l="$(grep -m1 '^realm=' "$(pr_lane_file "$1")" 2>/dev/null)"
  printf '%s\n' "${l:-realm=public}"
}

# Is the dir in a checkout of THIS repository (the public one)? It is when
# its toplevel, or the main checkout of its git common dir, holds the fleet
# pre-push hook: no private repo carries it.
pr_is_public_repo() {  # <dir>
  local rel="csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push" top common
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -f "$top/$rel" ] && return 0
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$common" ] && [ -f "$(dirname "$common")/$rel" ]
}

# The worktree <ID> holds in a repo (<repo>-wt/<ID>), if any.
pr_worktree_of() {  # <repo dir> <ID>
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep -E -m1 "/[^/]+-wt/$2\$"
}
