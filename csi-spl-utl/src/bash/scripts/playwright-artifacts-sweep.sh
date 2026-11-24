#!/usr/bin/env bash
# playwright-artifacts-sweep.sh - remove the idle /tmp/playwright-artifacts-*
# dirs a browser MCP seat left behind (SPL-6407). The firefox / playwright MCP
# writes every download and page snapshot there; nothing removes them when the
# seat ends, so a private document a seat fetched stays in /tmp.
#
# A dir directly under PW_ART_ROOT named playwright-artifacts-* is removed only
# when ALL hold:
#   - a real dir: not a symlink, not root-owned (and ours with PW_ART_SUDO=0);
#   - idle: nothing in it (the dir itself included) changed for PW_ART_AGE_H
#     hours;
#   - not held: no process has its cwd or an open file under it (/proc via
#     sudo -n; a scan that reads nothing removes nothing), checked again just
#     before the removal.
# It goes as its owner (rm -rf of that one dir). Anything else: one KEEP line
# with the reason. DEFAULT-OFF: no cron and no sweep step runs it.
#
#   DRY_RUN=1 (default) | 0
#   PW_ART_ROOT    where the dirs are (default /tmp)
#   PW_ART_AGE_H   idle hours before removal (default 24, a whole number >= 1)
#   PW_ART_SUDO    1 (default) | 0: only this user's processes and dirs
#
# Lines: PLAN remove|DO remove <MB>MB <path> idle=<h>h;
#        KEEP <reason> <MB|->MB <path>;
#        DONE would-remove|removed=<n> (<MB> MB) kept=<n>.
# Exit: 0 done; 1 a removal failed; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
root="${PW_ART_ROOT:-/tmp}"
age_h="${PW_ART_AGE_H:-24}"
use_sudo="${PW_ART_SUDO:-1}"
n_rm=0 mb_rm=0 n_keep=0 fail=0 why="" idle_h=0

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
as_owner() { if [[ "$1" == "$(id -un)" ]]; then shift; "$@"; else local o="$1"; shift; sudo -n -u "$o" -- "$@"; fi; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "PW_ART_SUDO must be 0 or 1, got '$use_sudo'"
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h >= 1 )) || refuse "PW_ART_AGE_H must be a whole number >= 1, got '$age_h'"
[[ -d "$root" && ! -L "$root" ]] || refuse "PW_ART_ROOT $root is no dir"
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"

held="$(mktemp)"; trap 'rm -f "$held"' EXIT
# scan_held: every process's cwd and open files, into held; rc 1 when empty
scan_held() {
  as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) \
    -printf '%l\n' 2>/dev/null | sort -u >"$held"
  [[ -s "$held" ]]
}
is_held() { grep -qxF -e "$1" "$held" || grep -qF -e "$1/" "$held"; }
scan_held || refuse "the /proc scan read nothing"

# dir_why <path> <owner>: sets why (the KEEP reason, empty when it may go)
# and idle_h (whole hours since the newest change in it)
dir_why() {
  local p="$1" o="$2" newest
  why="" idle_h=0
  [[ "$o" == root ]] && { why="root-owned"; return; }
  [[ "$use_sudo" == 0 && "$o" != "$(id -un)" ]] && { why="not-ours"; return; }
  newest="$(as_owner "$o" find "$p" -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)"
  [[ -n "$newest" ]] || { why="unreadable"; return; }
  idle_h=$(( ($(date +%s) - ${newest%.*}) / 3600 ))
  (( idle_h >= age_h )) || { why="fresh"; return; }
  is_held "$p" && { why="in-use"; return; }
}

# settle <path>: one PLAN / DO / KEEP line and the counts
settle() {
  local p="$1" o="" mb="-"
  why=""
  if [[ -L "$p" ]]; then why="symlink"
  elif [[ ! -d "$p" ]]; then why="not-dir"
  elif ! o="$(stat -c %U -- "$p" 2>/dev/null)"; then why="unreadable"
  else dir_why "$p" "$o"; fi
  case "$why" in
    symlink|not-dir|unreadable|not-ours) ;;
    *) mb="$(as_root du -sm -- "$p" 2>/dev/null | cut -f1)"; mb="${mb:-0}" ;;
  esac
  if [[ -n "$why" ]]; then say "KEEP $why ${mb}MB $p"; n_keep=$((n_keep + 1)); return; fi
  if [[ "$dry" == 1 ]]; then say "PLAN remove ${mb}MB $p idle=${idle_h}h"
  elif ! scan_held || is_held "$p"; then say "KEEP in-use ${mb}MB $p (held when its turn came)"; n_keep=$((n_keep + 1)); return
  elif as_owner "$o" rm -rf -- "$p" && [[ ! -e "$p" ]]; then say "DO remove ${mb}MB $p idle=${idle_h}h"
  else say "WARN could not remove $p"; fail=1; return; fi
  n_rm=$((n_rm + 1)); mb_rm=$((mb_rm + mb))
}

say "START root=$root age_h=$age_h dry_run=$dry"
shopt -s nullglob
for p in "$root"/playwright-artifacts-*; do settle "$p"; done
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm (${mb_rm} MB) kept=$n_keep dry_run=$dry"
exit "$fail"
