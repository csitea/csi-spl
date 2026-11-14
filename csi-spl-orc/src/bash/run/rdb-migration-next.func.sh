#!/bin/bash
#------------------------------------------------------------------------------
# @description Claim the number of the next hub migration
# @description (csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_<name>.sql), so two
# @description lanes never write the same NNNN and renumber after a rebase
# @description (5 renumber commits 2026-11-08..13, SPL-5515). The lock is the
# @description remote, as in do_release_version: the claim is the ref
# @description refs/rdb-claims/NNNN pushed to RDB_CLAIM_REMOTE. Each claim is
# @description its own commit object (an empty tree, a message naming the
# @description claimer and a nonce), so a second push of the same NNNN is
# @description REJECTED by git and the loser takes the next number.
# @description   next = max(head NNNN on <remote>/<trunk>, highest claim) + 1
# @description A claim is never released: an abandoned one leaves a hole that
# @description migrate.go does not mind (it applies files in name order), and
# @description lint-migration lets a new file skip only numbers claimed there.
# @description Prints the bare NNNN on stdout (logs go to stderr). Dry run
# @description unless DRY_RUN=0: a dry run prints what it WOULD claim and pushes nothing.
# @param RDB_CLAIM_REMOTE (optional) - the remote holding trunk and the claims, default origin
# @param RDB_CLAIM_TRUNK (optional) - the trunk branch, default master
# @param AGENT_ID (optional) - recorded in the claim, with the current branch
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_rdb_migration_next
# @example DRY_RUN=0 AGENT_ID=c-123 ./run -a do_rdb_migration_next
#------------------------------------------------------------------------------
_RDB_MIG_DIR="csi-spl-rdb/src/sql/postgres/spool-hub"

do_rdb_migration_next() {
  do_require_bin git || return 1
  local dry=1 remote="${RDB_CLAIM_REMOTE:-origin}" trunk="${RDB_CLAIM_TRUNK:-master}" head claims n try rc
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  for ((try = 1; try <= 20; try++)); do
    git -C "$APP_PATH" fetch -q "$remote" "+refs/heads/$trunk:refs/remotes/$remote/$trunk" ||
      { do_log "FATAL cannot fetch $trunk from $remote" >&2; return 1; }
    head="$(_rdb_head "$APP_PATH" "refs/remotes/$remote/$trunk")"
    claims="$(_rdb_claims "$APP_PATH" "$remote")" || { do_log "FATAL cannot list refs/rdb-claims/* on $remote" >&2; return 1; }
    n="$(_rdb_next "$head" "$claims")"
    if ((dry)); then
      do_log "OK DRY_RUN would claim $n on $remote (head of $trunk: $(printf '%04d' "$head"), highest claim: $(_rdb_top "$claims")). Re-run with DRY_RUN=0 to claim it." >&2
      echo "$n"; return 0
    fi
    _rdb_claim_push "$APP_PATH" "$remote" "$n"; rc=$?
    case "$rc" in
      0) do_log "OK claimed migration $n on $remote (refs/rdb-claims/$n): name the new file $_RDB_MIG_DIR/${n}_<name>.sql" >&2
         echo "$n"; return 0 ;;
      2) do_log "INFO $n was claimed by another lane meanwhile, taking the next one" >&2 ;;
      *) do_log "FATAL the claim of $n was refused: $_RDB_CLAIM_ERR" >&2; return 1 ;;
    esac
  done
  do_log "FATAL no claim after 20 lost races" >&2
  return 1
}

# _rdb_head <dir> <ref> -> the highest NNNN of the migrations at <ref>, 0 if none
_rdb_head() {
  local n head=0
  while IFS= read -r n; do
    n="${n##*/}"
    [[ "$n" =~ ^([0-9]{4})_ ]] && ((10#${BASH_REMATCH[1]} > head)) && head=$((10#${BASH_REMATCH[1]}))
  done < <(git -C "$1" ls-tree --name-only "$2" -- "$_RDB_MIG_DIR/" 2>/dev/null)
  echo "$head"
}

# _rdb_claims <dir> <remote> -> the claimed NNNN on <remote>, one per line; rc 1 unreadable
_rdb_claims() {
  local out
  out="$(git -C "$1" ls-remote "$2" 'refs/rdb-claims/*' 2>/dev/null)" || return 1
  sed -nE 's#.*[[:space:]]refs/rdb-claims/([0-9]{4})$#\1#p' <<<"$out"
}

# _rdb_top <claims> -> the highest claim, or "none"
_rdb_top() { local t; t="$(sed '/^$/d' <<<"$1" | sort -n | tail -n 1)"; echo "${t:-none}"; }

# _rdb_next <head> <claims> -> max(head, highest claim) + 1, as NNNN
_rdb_next() {
  local top m="$1"
  top="$(_rdb_top "$2")"
  [[ "$top" != none ]] && ((10#$top > m)) && m=$((10#$top))
  printf '%04d\n' "$((m + 1))"
}

# _rdb_claim_push <dir> <remote> <NNNN> -> rc 0 claimed, 2 taken (a lost race),
# 1 refused for another reason (_RDB_CLAIM_ERR says why). The object is unique
# (claimer, branch, time, nonce): an equal object would push as "up to date".
# The pre-push hook lets a claim-only push through ungated: it carries no file.
_rdb_claim_push() {
  local dir="$1" remote="$2" n="$3" tree obj br
  _RDB_CLAIM_ERR=""
  br="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)"
  tree="$(git -C "$dir" mktree </dev/null)" || { _RDB_CLAIM_ERR="git mktree failed"; return 1; }
  obj="$(git -C "$dir" commit-tree "$tree" -m "rdb-claim $n" -m "agent: ${AGENT_ID:-unknown}
branch: $br
at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
nonce: $$-$RANDOM$RANDOM")" || { _RDB_CLAIM_ERR="git commit-tree failed"; return 1; }
  if _RDB_CLAIM_ERR="$(git -C "$dir" push -q "$remote" "$obj:refs/rdb-claims/$n" 2>&1)"; then return 0; fi
  local seen
  seen="$(git -C "$dir" ls-remote "$remote" "refs/rdb-claims/$n" 2>/dev/null)"
  grep -q "refs/rdb-claims/$n$" <<<"$seen" && return 2
  return 1
}
