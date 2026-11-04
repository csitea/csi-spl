#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Prune this repo's GitHub Actions caches (SPL-4790, owner t1
# @description 4b50446f: "A weekly prune of old Actions caches"). On 2026-11-04
# @description one Go race cache of wf 10 held 6.26 GiB of the repo's 10 GB
# @description store, and its restore filled a hosted runner's disk. Two rules,
# @description in this order:
# @description   1. a cache not used for CACHE_PRUNE_DAYS (last_accessed_at) goes
# @description   2. then the least recently used go, until the rest total at
# @description      most CACHE_PRUNE_MAX_GB
# @description One line per cache it deletes (id, key, MB, last access, ref, the
# @description rule), then one summary line. DRY_RUN=1 (the default) deletes
# @description nothing and says "would delete"; DRY_RUN=0 deletes. A cache
# @description regenerates on the next run that misses it, so a delete costs one
# @description cold build, never a red. Run weekly by 14_ci-cache-prune.yml.
# @param GH_CACHE_PRUNE_REPO (optional) - <owner>/<repo>, default: parsed from
# @param        the checkout's `origin` remote (no literal default)
# @param CACHE_PRUNE_DAYS (optional) - default 7
# @param CACHE_PRUNE_MAX_GB (optional) - default 8 (the store holds 10)
# @param CACHE_PRUNE_NOW (optional) - epoch seconds, default now (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_gh_prune_actions_caches
# @example DRY_RUN=0 CACHE_PRUNE_MAX_GB=6 ./run -a do_gh_prune_actions_caches
#------------------------------------------------------------------------------

_gpac_repo() {
  if [[ -n "${GH_CACHE_PRUNE_REPO:-}" ]]; then printf '%s\n' "$GH_CACHE_PRUNE_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# every cache, least recently used first: id<TAB>key<TAB>bytes<TAB>last<TAB>ref
_gpac_list() {  # <repo>
  local json
  json="$(gh api --paginate "repos/$1/actions/caches?per_page=100")" || return 1
  jq -r '.actions_caches[] | [.id, .key, .size_in_bytes, .last_accessed_at, .ref] | @tsv' <<<"$json" \
    | sort -t$'\t' -k4,4
}

# <repo> <dry> <rule> <id> <key> <bytes> <last> <ref> - 0 deleted (or would be)
_gpac_delete() {
  local repo="$1" dry="$2" rule="$3" id="$4" key="$5" bytes="$6" last="$7" ref="$8"
  local what="$id $key $((bytes / 1048576)) MB last=$last ref=$ref ($rule)"
  if [[ "$dry" != 0 ]]; then do_log "INFO DRY_RUN would delete $what"; return 0; fi
  gh api -X DELETE "repos/$repo/actions/caches/$id" >/dev/null \
    || { do_log "ERROR cannot delete $what"; return 1; }
  do_log "OK deleted $what"
}

do_gh_prune_actions_caches() {
  command -v gh >/dev/null 2>&1 || { do_log "FATAL gh not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq not found"; return 1; }
  local repo re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' dry="${DRY_RUN:-1}"
  local days="${CACHE_PRUNE_DAYS:-7}" max_gb="${CACHE_PRUNE_MAX_GB:-8}" now="${CACHE_PRUNE_NOW:-$(date +%s)}"
  [[ "$days" =~ ^[0-9]+$ && "$max_gb" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] \
    || { do_log "FATAL CACHE_PRUNE_DAYS, CACHE_PRUNE_MAX_GB and CACHE_PRUNE_NOW are whole numbers"; return 1; }
  repo="$(_gpac_repo)"
  [[ "$repo" =~ $re ]] || { do_log "FATAL no <owner>/<repo>: set GH_CACHE_PRUNE_REPO (no default); origin gave '$repo'"; return 1; }
  local rows; rows="$(_gpac_list "$repo")" || { do_log "FATAL cannot list the caches of $repo with gh"; return 1; }

  # ISO-8601 UTC sorts as text, so the cutoff is a string compare
  local cutoff max_b=$((max_gb * 1073741824)) total=0 id key bytes last ref
  cutoff="$(date -u -d "@$((now - days * 86400))" +%Y-%m-%dT%H:%M:%SZ)"
  local -a keep=()
  local n_del=0 b_del=0 bad=0
  while IFS=$'\t' read -r id key bytes last ref; do
    [[ -n "$id" ]] || continue
    if [[ "$last" < "$cutoff" ]]; then
      _gpac_delete "$repo" "$dry" "unused ${days}d" "$id" "$key" "$bytes" "$last" "$ref" || { bad=1; continue; }
      n_del=$((n_del + 1)); b_del=$((b_del + bytes))
    else
      keep+=("$id"$'\t'"$key"$'\t'"$bytes"$'\t'"$last"$'\t'"$ref"); total=$((total + bytes))
    fi
  done <<<"$rows"

  # least recently used first (the list is sorted), until the rest fit
  local row i=0 n2=0
  while ((total > max_b && i < ${#keep[@]})); do
    row="${keep[$i]}"; i=$((i + 1))
    IFS=$'\t' read -r id key bytes last ref <<<"$row"
    _gpac_delete "$repo" "$dry" "total over ${max_gb} GB" "$id" "$key" "$bytes" "$last" "$ref" || { bad=1; continue; }
    n_del=$((n_del + 1)); n2=$((n2 + 1)); b_del=$((b_del + bytes)); total=$((total - bytes))
  done

  local verb="deleted"; [[ "$dry" != 0 ]] && verb="DRY_RUN would delete"
  do_log "OK $repo: $verb $n_del caches ($((b_del / 1048576)) MB); kept $((${#keep[@]} - n2)) caches ($((total / 1048576)) MB, limit ${max_gb} GB, unused limit ${days}d)"
  ((bad)) && return 1
  return 0
}
