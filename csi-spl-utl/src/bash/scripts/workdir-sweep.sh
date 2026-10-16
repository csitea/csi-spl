#!/usr/bin/env bash
# workdir-sweep.sh - the disk guard's half of the deferred lane cleanup: remove
# the finished lanes' working directories listed in the box's table
# ($SPOOL_ROOT/workdirs.tsv, written by workdir-register.sh from the retire)
# once they are old enough. Owner HUM-10, t1 37349c9b msg ec060ebc
# (2026-10-16): lanes keep their work after the push, "something might happen
# after the push, and the work needs to be fixed"; the guard deletes
# "working directories older than 24 hours".
#
# A row's directory is removed only when ALL hold:
#   - its finished_at is older than WORKDIR_SWEEP_AGE_H (24) hours, or, at
#     the CRITICAL disk level (the lowest free % of the mounts at or under
#     WORKDIR_SWEEP_CRIT_FREE_PCT, 8), WORKDIR_SWEEP_CRIT_AGE_H (6) hours;
#   - no process has its cwd or an open fd under it (every process's /proc,
#     read via sudo -n; a scan that cannot read them all removes nothing);
#   - worktree: it is a LINKED worktree still on the row's branch and clean
#     (git status empty). It goes through `git worktree remove` (never
#     --force, never rm -rf), as its owner; then `git branch -d` (a merged
#     branch only: an unmerged one stays, with its commits);
#   - scratch: a real dir <WORKDIR_SWEEP_TMP>/claude-<uid>/<name>;
#     var-tmp: a top-level entry of WORKDIR_SWEEP_VARTMP_ROOT; either is
#     removed as its owner (sudo -n -u), never one owned by root.
# Otherwise the row stays and one KEEP line says why. A removed or vanished
# directory's row is dropped; so is a worktree now on another branch (a new
# lane holds it). Rows go oldest first.
#
#   DRY_RUN=1 (default) | 0
#   WORKDIR_TABLE              default $SPOOL_ROOT/workdirs.tsv
#   WORKDIR_SWEEP_AGE_H        default 24
#   WORKDIR_SWEEP_CRIT_AGE_H   default 6
#   WORKDIR_SWEEP_CRIT_FREE_PCT default 8 (the critical level: free % <= it)
#   WORKDIR_SWEEP_FREE_PCT     the measured free % (the box sweep passes its
#                              own; tests plant one); default: measured over
#                              WORKDIR_SWEEP_MOUNTS ("/ /mnt/data /tmp")
#   WORKDIR_SWEEP_TMP          default /tmp
#   WORKDIR_SWEEP_VARTMP_ROOT  default /var/tmp
#   WORKDIR_SWEEP_SUDO         1 (default) | 0: only this user's processes and dirs
#   WORKDIR_REGISTER           the table writer (default the orc's workdir-register.sh)
#   SPOOL_NOW                  the clock (tests)
#
# One PLAN|REMOVE / KEEP / DROP line per row, an ALERT line at the critical
# level, a DONE line. Exit 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dry="${DRY_RUN:-1}"
table="${WORKDIR_TABLE:-${SPOOL_ROOT:-/var/spool-hub}/workdirs.tsv}"
age_h="${WORKDIR_SWEEP_AGE_H:-24}" crit_age_h="${WORKDIR_SWEEP_CRIT_AGE_H:-6}"
crit_pct="${WORKDIR_SWEEP_CRIT_FREE_PCT:-8}"
tmp_root="${WORKDIR_SWEEP_TMP:-/tmp}" vartmp_root="${WORKDIR_SWEEP_VARTMP_ROOT:-/var/tmp}"
use_sudo="${WORKDIR_SWEEP_SUDO:-1}"
register="${WORKDIR_REGISTER:-$self_dir/../../../../csi-spl-orc/src/bash/features/spawn-agents/scripts/workdir-register.sh}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
# as_owner <owner> <cmd...>: run as the dir's owner (git and rm alike)
as_owner() { if [[ "$1" == "$(id -un)" ]]; then shift; "$@"; else local o="$1"; shift; sudo -n -u "$o" -- "$@"; fi; }
g() { as_owner "$1" env GIT_TERMINAL_PROMPT=0 timeout 60 git -c safe.directory='*' -C "$2" "${@:3}"; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "WORKDIR_SWEEP_SUDO must be 0 or 1, got '$use_sudo'"
for v in "$age_h" "$crit_age_h" "$crit_pct"; do
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 )) || refuse "the age and free % limits must be whole numbers >= 1, got '$v'"
done
(( crit_age_h <= age_h )) || refuse "WORKDIR_SWEEP_CRIT_AGE_H ($crit_age_h) must not exceed WORKDIR_SWEEP_AGE_H ($age_h)"
[[ -f "$register" ]] || refuse "no table writer $register"
[[ -e "$table" ]] || { say "OK no table $table: nothing to sweep"; exit 0; }
[[ -r "$table" ]] || refuse "cannot read the table $table"

# free_pct - "<lowest free %> <its mount>"
free_pct() {
  if [[ -n "${WORKDIR_SWEEP_FREE_PCT:-}" ]]; then echo "$WORKDIR_SWEEP_FREE_PCT planted"; return; fi
  local m
  for m in ${WORKDIR_SWEEP_MOUNTS:-/ /mnt/data /tmp}; do
    [[ -d "$m" ]] && df -P "$m" | awk -v m="$m" 'NR==2 && $2 > 0 { printf "%d %s\n", 100 * $4 / $2, m }'
  done | sort -n | sed -n 1p
}
read -r fpct fmount <<<"$(free_pct)"
[[ "$fpct" =~ ^[0-9]+$ ]] || { say "WARN cannot measure the free space: the normal ${age_h} h limit holds"; fpct=100 fmount=unmeasured; }
level=normal limit_h="$age_h"
if (( fpct <= crit_pct )); then
  level=crit limit_h="$crit_age_h"
fi

[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"
held="$(mktemp)"; trap 'rm -f "$held"' EXIT
as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) \
  -printf '%l\n' 2>/dev/null | sort -u >"$held"
is_held() { grep -qxF -e "$1" "$held" || grep -qF -e "$1/" "$held"; }

now="$(date -u -d "${SPOOL_NOW:-now}" +%s)"
say "START table=$table dry_run=$dry level=$level free=${fpct}% ($fmount) limit_h=$limit_h rows=$(awk '!/^#/ && NF' "$table" | wc -l)"
[[ "$level" == crit ]] && say "ALERT critical disk: ${fpct}% free ($fmount) <= ${crit_pct}%: lane workdirs older than ${crit_age_h} h (not ${age_h} h) are removed, oldest first"

drop() { [[ "$dry" == 1 ]] && { say "PLAN drop-row $2 $1"; return; }; bash "$register" drop "$1" && say "DROP $2 $1"; }

# worktree_why <path> <owner> <branch>: empty when it may go, else the reason
worktree_why() {
  local p="$1" o="$2" br="$3" gd cd cur
  gd="$(g "$o" "$p" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "not-a-git-worktree"; return; }
  cd="$(g "$o" "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [[ -n "$cd" && "$gd" != "$cd" ]] || { echo "main-checkout (never removed)"; return; }
  [[ "$(g "$o" "$p" rev-parse --show-toplevel 2>/dev/null)" == "$p" ]] || { echo "not-the-worktree-top"; return; }
  cur="$(g "$o" "$p" symbolic-ref -q --short HEAD 2>/dev/null)"
  [[ -z "$br" || "$cur" == "$br" ]] || { echo "reused (now on ${cur:-a detached HEAD}, listed on $br)"; return; }
  [[ -z "$(g "$o" "$p" status --porcelain --untracked-files=all 2>/dev/null)" ]] || echo "dirty (git status not empty; branch ${cur:-?} not removed)"
}

n_rm=0 kb_rm=0 n_keep=0
# Fields joined by \x1f, not a tab: a tab is IFS white space, so read would
# fold an empty branch and shift finished_at into its place.
while IFS=$'\x1f' read -r -u 3 p kind agent box br at; do
  [[ -n "$p" ]] || continue
  t="$(date -u -d "$at" +%s 2>/dev/null)" || { say "KEEP bad-finished-at '$at' $p"; n_keep=$((n_keep + 1)); continue; }
  age=$(( (now - t) / 3600 ))
  if [[ ! -e "$p" && ! -L "$p" ]]; then drop "$p" "gone"; continue; fi
  if (( now - t < limit_h * 3600 )); then say "KEEP fresh ${age}h<${limit_h}h $kind $p ($agent)"; n_keep=$((n_keep + 1)); continue; fi
  why="" owner="$(stat -c %U -- "$p" 2>/dev/null)" || why="unreadable"
  if [[ -z "$why" ]]; then
    if [[ -L "$p" ]]; then why="symlink"
    elif [[ "$owner" == root ]]; then why="root-owned"
    elif [[ "$use_sudo" == 0 && "$owner" != "$(id -un)" ]]; then why="not-ours (owner $owner)"
    elif is_held "$p"; then why="in-use (a process has its cwd or an open file under it)"
    else
      case "$kind" in
        worktree) why="$(worktree_why "$p" "$owner" "$br")"
                  [[ "$why" == reused* ]] && { drop "$p" "$why"; continue; } ;;
        scratch)  [[ "${p%/*}" =~ ^"${tmp_root%/}"/claude-[0-9]+$ && -d "$p" ]] || why="not-a-scratch-dir (not ${tmp_root%/}/claude-<uid>/<name>)" ;;
        var-tmp)  [[ "${p%/*}" == "${vartmp_root%/}" && "${p##*/}" != .* ]] || why="not-a-var-tmp-entry (not a top-level entry of ${vartmp_root%/})" ;;
        *)        why="unknown-kind '$kind'" ;;
      esac
    fi
  fi
  if [[ -n "$why" ]]; then say "KEEP $why $kind $p ($agent, ${age}h)"; n_keep=$((n_keep + 1)); continue; fi
  kb="$(as_root du -sk -- "$p" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $kind $p ($agent, ${age}h)${br:+ branch $br}"
  else
    if [[ "$kind" == worktree ]]; then
      cd_="$(g "$owner" "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      g "$owner" "${cd_%/.git}" worktree remove "$p" >/dev/null 2>&1 || { say "KEEP git-worktree-remove-refused worktree $p ($agent)"; n_keep=$((n_keep + 1)); continue; }
      [[ -z "$br" ]] || g "$owner" "${cd_%/.git}" branch -d "$br" >/dev/null 2>&1 || say "INFO branch $br kept: git branch -d refused (not merged)"
    else
      as_owner "$owner" chmod -R u+w -- "$p" 2>/dev/null; as_owner "$owner" rm -rf -- "$p"
      [[ -e "$p" ]] && { say "WARN could not remove $p (owner $owner)"; n_keep=$((n_keep + 1)); continue; }
    fi
    say "REMOVE ${kb}KB $kind $p ($agent, ${age}h)${br:+ branch $br}"
    bash "$register" drop "$p" || say "WARN the row of $p was not dropped"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done 3< <(awk -F'\t' -v OFS='\x1f' '!/^#/ && NF { print $6, $1, $2, $3, $4, $5, $6 }' "$table" | sort -t$'\x1f' -k1,1 | cut -d$'\x1f' -f2-)
say "DONE level=$level $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep"
