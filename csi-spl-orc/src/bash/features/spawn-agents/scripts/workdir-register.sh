#!/usr/bin/env bash
# workdir-register.sh - the box's table of FINISHED lane working directories,
# which the disk guard deletes once they are old enough (owner HUM-10, t1
# 37349c9b msg ec060ebc, 2026-10-16: lanes "should not clean up straight away
# after themselves ... something might happen after the push, and the work
# needs to be fixed ... create some kind of a table for the guard to go and
# delete working directories older than 24 hours").
#
# The table: $SPOOL_ROOT/workdirs.tsv, one per box, next to registry.tsv: the
# spool root is the box's shared state dir every agent user may write (setgid
# + ACLs), it survives a reboot (/tmp does not), and the retire that fills the
# table already works there. One row per directory, tab-separated:
#   path  kind (worktree|scratch|var-tmp)  agent  box  branch  finished_at (UTC)
# A '#' line is a comment (the header). Every write holds <table>.lock (flock)
# and rewrites the file in place. A path is in the table at most once: adding
# it again replaces its row (the newest finished_at wins).
#
# Filled by agent-id-retire.sh (steps 7..9) in place of removing the lane's
# worktree, /tmp scratch and /var/tmp leftovers; read and emptied by the disk
# guard (csi-spl-utl: ./run -a do_sweep_workdirs). The allocator holds an id
# while a row names it (next-agent-id.sh rule 6), so a new lane never inherits
# an old lane's worktree.
#
# Usage:
#   workdir-register.sh add --kind K --agent ID [--box B] [--branch BR] [--at UTC] <path>
#   workdir-register.sh drop <path>
#   workdir-register.sh list                  the rows, header-less
# Env: WORKDIR_TABLE (default $SPOOL_ROOT/workdirs.tsv), SPOOL_ROOT (default
#   /var/spool-hub), SPOOL_NOW (the clock: --at defaults to it, else now).
# Exit 0 ok; 1 the lock stayed held; 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

table="${WORKDIR_TABLE:-${SPOOL_ROOT:-/var/spool-hub}/workdirs.tsv}"
HEADER=$'# path\tkind\tagent\tbox\tbranch\tfinished_at'
die() { echo "workdir-register: $*" >&2; exit 2; }

# ok_path <path>: absolute, no tab / newline, no . or .. segment, not /
ok_path() {
  [[ "$1" == /?* && "$1" != *$'\t'* && "$1" != *$'\n'* ]] || return 1
  [[ "/$1/" != */../* && "/$1/" != */./* ]]
}

# locked <cmd...>: run under the table's lock
locked() {
  mkdir -p "${table%/*}" 2>/dev/null
  (
    flock -w 30 9 || { echo "workdir-register: ${table}.lock stayed locked for 30 s" >&2; exit 1; }
    [ -e "$table" ] || { printf '%s\n' "$HEADER" >"$table" && chmod 0664 "$table" 2>/dev/null; }
    "$@"
  ) 9>>"$table.lock"
}

# rewrite <path> [row]: the table without <path>'s row, then [row], in place
rewrite() {
  local keep
  keep="$(awk -F'\t' -v p="$1" '/^#/ || $1 != p' "$table")"
  { [ -z "$keep" ] || printf '%s\n' "$keep"; [ -z "${2:-}" ] || printf '%s\n' "$2"; } >"$table"
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  add)
    kind="" agent="" box="" branch="" at="" path=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind|--agent|--box|--branch|--at)
          [ "$#" -ge 2 ] || die "$1 needs a value"
          case "$1" in --kind) kind="$2" ;; --agent) agent="$2" ;; --box) box="$2" ;; --branch) branch="$2" ;; --at) at="$2" ;; esac
          shift 2 ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$path" ] || die "one path only"; path="$1"; shift ;;
      esac
    done
    path="${path%/}"
    ok_path "$path" || die "needs an absolute path with no . / .. segment, got '${path}'"
    case "$kind" in worktree|scratch|var-tmp) ;; *) die "--kind must be worktree, scratch or var-tmp, got '${kind}'" ;; esac
    [[ "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die "--agent must be an agent id, got '${agent}'"
    box="${box:-$(hostname -s)}"
    for v in "$box" "$branch"; do [[ "$v" != *[[:space:]]* ]] || die "box and branch are one word each, got '${v}'"; done
    [ -n "$at" ] || at="$(date -u -d "${SPOOL_NOW:-now}" +%Y-%m-%dT%H:%M:%SZ)"
    [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "--at must be UTC like 2026-10-16T08:00:00Z, got '${at}'"
    locked rewrite "$path" "$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$path" "$kind" "$agent" "$box" "$branch" "$at")" || exit 1
    echo "workdir-register: listed ${kind} ${path} (${agent}, finished ${at}) in ${table}" ;;
  drop)
    [ "$#" -eq 1 ] || die "drop takes one path"
    p="${1%/}"; ok_path "$p" || die "needs an absolute path, got '${1}'"
    [ -e "$table" ] || exit 0
    locked rewrite "$p" || exit 1 ;;
  list)
    [ -r "$table" ] && awk '!/^#/ && NF' "$table"
    exit 0 ;;
  *) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
