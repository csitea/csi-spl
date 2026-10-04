#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete Go build-cache entries older than GO_CACHE_MAX_AGE_MIN
# @description (default 1440, one day) for each agent user. The cache directory
# @description comes from `go env GOCACHE` run as that user, or from the
# @description env-var list GO_CACHE_USERS (users) / GO_CACHE_DIRS (directories,
# @description pruned as the current user). No home path is written here.
# @description A directory is pruned only when it is a Go build cache: a
# @description regular README and real 00 and ff bucket directories. Anything
# @description else is left untouched and the action exits non-zero.
# @description Files are removed as the owning user (sudo -n when that is not
# @description us). DRY_RUN=1 (the default) prints counts and bytes only.
# @description Before and after, the cache size and the free space on the
# @description filesystem that holds it are printed.
# @description GO_CACHE_GATE=1 (the cron) prunes only on the hourly minute
# @description (GO_CACHE_HOURLY_MINUTE, default 0) or when that filesystem is
# @description at or over GO_CACHE_PRUNE_AT_PCT (default 85).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GO_CACHE_MAX_AGE_MIN (optional) - age in minutes, default 1440
# @param GO_CACHE_USERS (optional) - space-separated users; default the box
# @param   user, SPOOL_AGENT_USER and the spool-agents group
# @param GO_CACHE_DIRS (optional) - space-separated cache dirs (tests); when
# @param   set, GO_CACHE_USERS is not consulted
# @param GO_CACHE_GATE (optional) - 1 applies the hourly / percent gate
# @param GO_CACHE_PRUNE_AT_PCT (optional) - 0..100, default 85
# @param GO_CACHE_NOW_MIN / GO_CACHE_USED_PCT (optional) - test seams
# @param GO_CACHE_LOCK (optional) - 1 (default) or 0; the lock file is
# @param   GO_CACHE_LOCK_FILE, else the go-cache-prune state dir
# @example ./run -a do_prune_go_build_cache
# @example DRY_RUN=0 ./run -a do_prune_go_build_cache
# @example GO_CACHE_GATE=1 DRY_RUN=0 ./run -a do_prune_go_build_cache
#------------------------------------------------------------------------------

# go_cache_as <user> <cmd...>: run as that user. sudo -n when it is not us.
go_cache_as() {
  local u="$1"
  shift
  if [[ -z "$u" || "$u" == "$(id -un)" ]]; then
    "$@"
  else
    sudo -n -u "$u" -H -- "$@"
  fi
}

# go_cache_discover_users: the box user, SPOOL_AGENT_USER and the spool group,
# each once, space-separated. Empty when none of those resolve.
go_cache_discover_users() {
  local box="" members=""
  box="${SPOOL_BOX_USER:-}"
  if [[ -z "$box" && -n "${PROJ_PATH:-}" && -e "${PROJ_PATH}" ]]; then
    box="$(stat -c %U "$PROJ_PATH" 2>/dev/null || true)"
  fi
  members="$(getent group "${SPOOL_ROOT_GROUP:-spool-agents}" 2>/dev/null | awk -F: 'NR==1 { print $4 }' | tr ',' ' ' || true)"
  # shellcheck disable=SC2086 # the lists are space-separated user names
  printf '%s\n' $box ${SPOOL_AGENT_USER:-} $members | awk 'NF && !seen[$0]++' | paste -sd' ' - || true
}

# go_cache_resolve <user>: absolute GOCACHE, one line. Refuses a path that is
# not a single absolute path of ordinary characters.
go_cache_resolve() {
  local u="$1" out
  out="$(go_cache_as "$u" bash -lc 'export PATH="/usr/local/go/bin:${PATH}"; go env GOCACHE' | tail -n 1)" || return 1
  [[ "$out" =~ ^/[A-Za-z0-9._/-]+$ && "$out" != *..* && "$out" != / ]] || return 1
  printf '%s\n' "$out"
}

# go_cache_is_cache <user> <dir>: 0 when dir is a Go build cache.
go_cache_is_cache() {
  local u="$1" d="$2"
  go_cache_as "$u" bash -c '
    d=$1
    [ -f "$d/README" ] && [ ! -L "$d/README" ] &&
      [ -d "$d/00" ] && [ ! -L "$d/00" ] &&
      [ -d "$d/ff" ] && [ ! -L "$d/ff" ]
  ' bash "$d"
}

# go_cache_fs <user> <dir>: "<free-bytes> <used-pct> <mount>" from df.
go_cache_fs() {
  local u="$1" d="$2"
  go_cache_as "$u" df -B1 -P "$d" | awk 'NR==2 {
    pct = $5
    sub(/%$/, "", pct)
    m = $6
    for (i = 7; i <= NF; i++) m = m " " $i
    printf "%s %s %s\n", $4, pct, m
  }'
}

# go_cache_bytes <user> <dir>: du -sb, the first field.
go_cache_bytes() {
  local u="$1" d="$2"
  go_cache_as "$u" du -sb "$d" | awk 'NR==1 { print $1 }'
}

# go_cache_old_stats <user> <dir> <age-min>: "<files> <bytes>" of files at
# depth >= 2 older than the age. Listing only; nothing is removed.
go_cache_old_stats() {
  local u="$1" d="$2" age="$3"
  go_cache_as "$u" find "$d" -xdev -mindepth 2 -type f -mmin "+${age}" -printf '%s\n' |
    awk '{ n++; s += $1 } END { printf "%d %d\n", n + 0, s + 0 }'
}

# go_cache_targets: one "<user>\t<dir>" line per cache that exists. A resolve
# failure returns 1 and the caller deletes nothing.
go_cache_targets() {
  local u d list
  if [[ -n "${GO_CACHE_DIRS:-}" ]]; then
    u="$(id -un)"
    set -f
    # shellcheck disable=SC2086 # directories in this list have no spaces
    for d in ${GO_CACHE_DIRS}; do
      printf '%s\t%s\n' "$u" "$d"
    done
    set +f
    return 0
  fi
  if [[ -n "${GO_CACHE_USERS+x}" ]]; then
    list="${GO_CACHE_USERS}"
  else
    list="$(go_cache_discover_users)"
  fi
  set -f
  # shellcheck disable=SC2086 # space-separated user names
  for u in $list; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { set +f; do_log "FATAL refusing a user name that is not a single token: '$u'"; return 1; }
    d="$(go_cache_resolve "$u")" || { set +f; do_log "FATAL cannot read GOCACHE for $u (go env, as that user)"; return 1; }
    if go_cache_as "$u" test -d "$d"; then
      printf '%s\t%s\n' "$u" "$d"
    else
      do_log "INFO $u has no Go build cache yet"
    fi
  done
  set +f
}

# go_cache_lock_or_stop: 0 proceed (lock held, or no lock in use), 2 another
# prune holds the lock and this run must stop.
go_cache_lock_or_stop() {
  local lock app org
  [[ "${GO_CACHE_LOCK:-1}" == 1 ]] || return 0
  command -v flock >/dev/null 2>&1 || return 0
  if [[ -n "${GO_CACHE_LOCK_FILE:-}" ]]; then
    lock="$GO_CACHE_LOCK_FILE"
  else
    app="$(basename "${PROJ_PATH:-csi-spl-orc}")"
    app="${app%-orc}"
    org="${app%%-*}"
    lock="/var/${org}/${app}/go-cache-prune/prune.lock"
  fi
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  exec 9>>"$lock" || return 0
  flock -n 9 && return 0
  return 2
}

# go_cache_check_inputs <dry> <gate> <age> <thr> <hour>: 0 when every knob is
# valid, else logs the FATAL and returns 1.
go_cache_check_inputs() {
  local dry="$1" gate="$2" age="$3" thr="$4" hour="$5"
  do_require_bin find df du awk readlink || return 1
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$gate" == 0 || "$gate" == 1 ]] || { do_log "FATAL GO_CACHE_GATE must be 0 or 1, got: '$gate'"; return 1; }
  [[ "$age" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_MAX_AGE_MIN must be a whole number of minutes, got: '$age'"; return 1; }
  [[ "$thr" =~ ^[0-9]+$ ]] && (( thr <= 100 )) || { do_log "FATAL GO_CACHE_PRUNE_AT_PCT must be 0..100, got: '$thr'"; return 1; }
  [[ "$hour" =~ ^[0-9]+$ ]] && (( 10#$hour <= 59 )) || { do_log "FATAL GO_CACHE_HOURLY_MINUTE must be 0..59, got: '$hour'"; return 1; }
  [[ "${GO_CACHE_LOCK:-1}" == 0 || "${GO_CACHE_LOCK:-1}" == 1 ]] || { do_log "FATAL GO_CACHE_LOCK must be 0 or 1"; return 1; }
}

# go_cache_gate <targets> <thr> <hour>: 0 prune now, 3 skip (logged), 1 FATAL.
# Due on the hourly minute, or when the first cache's filesystem is >= thr.
go_cache_gate() {
  local targets="$1" thr="$2" hour="$3" minute u d pct_now due=0
  minute="${GO_CACHE_NOW_MIN:-$(date +%M)}"
  [[ "$minute" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_NOW_MIN is not a minute, got: '$minute'"; return 1; }
  u="${targets%%$'\t'*}"
  d="${targets#*$'\t'}"
  d="${d%%$'\n'*}"
  if [[ -n "${GO_CACHE_USED_PCT:-}" ]]; then
    pct_now="$GO_CACHE_USED_PCT"
  else
    pct_now="$(go_cache_fs "$u" "$d" | awk '{ print $2 }')" || pct_now=""
  fi
  if [[ -n "$pct_now" && ! "$pct_now" =~ ^[0-9]+$ ]]; then
    do_log "FATAL filesystem use is not a percent, got: '$pct_now'"
    return 1
  fi
  if (( 10#$minute == 10#$hour )); then
    due=1
  elif [[ -z "$pct_now" ]]; then
    do_log "FATAL cannot read how full the cache filesystem is, and this is not the hourly tick"
    return 1
  elif (( pct_now >= thr )); then
    due=1
  fi
  if (( due == 0 )); then
    do_log "OK skip: filesystem ${pct_now}% is under ${thr}% and minute ${minute} is not the hourly tick"
    return 3
  fi
  return 0
}

# go_cache_split_fs <fs-line>: sets the caller's free, pct and mount from a
# go_cache_fs line.
go_cache_split_fs() {
  free="${1%% *}"
  mount="${1#* }"
  mount="${mount#* }"
  pct="${1#* }"
  pct="${pct%% *}"
}

# go_cache_prune_one <user> <dir> <age> <dry>: check, measure, prune one cache
# and print its BEFORE / PLAN / AFTER lines. Adds to the caller's
# removed_files / removed_bytes and sets first_free, first_mount, last_free.
# 1 when that cache was left untouched (the FATAL is logged).
go_cache_prune_one() {
  local u="$1" d="$2" age="$3" dry="$4" real depth fs_line free pct mount stats files bytes before_b after_b
  real="$(go_cache_as "$u" readlink -f -- "$d" 2>/dev/null || true)"
  depth=0
  [[ -n "$real" ]] && depth="$(awk -F/ '{ print NF }' <<<"$real")"
  if [[ "$real" != /* || "$real" == / || "$real" == *..* || "$depth" -lt 4 ]]; then
    do_log "FATAL refusing to prune '$d' (resolved path is empty, root, or too shallow); nothing deleted there"
    return 1
  fi
  if ! go_cache_is_cache "$u" "$real"; then
    do_log "FATAL $real is not a Go build cache (want a README file and real 00 and ff directories); nothing deleted"
    return 1
  fi
  before_b="$(go_cache_bytes "$u" "$real")" || { do_log "FATAL cannot measure $real"; return 1; }
  [[ "$before_b" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot measure $real"; return 1; }
  fs_line="$(go_cache_fs "$u" "$real")" || { do_log "FATAL cannot read the filesystem of $real"; return 1; }
  go_cache_split_fs "$fs_line"
  [[ "$free" =~ ^[0-9]+$ && "$pct" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot read the filesystem of $real"; return 1; }
  [[ -z "$first_free" ]] && { first_free="$free"; first_mount="$mount"; }
  printf 'BEFORE user=%s bytes=%s fs_free=%s fs_used_pct=%s mount=%s\n' "$u" "$before_b" "$free" "$pct" "$mount"
  stats="$(go_cache_old_stats "$u" "$real" "$age")" || { do_log "FATAL cannot list old entries in $real; nothing deleted there"; return 1; }
  read -r files bytes <<<"$stats"
  [[ "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot list old entries in $real; nothing deleted there"; return 1; }
  printf 'PLAN user=%s files=%s bytes=%s age_min=%s dry_run=%s\n' "$u" "$files" "$bytes" "$age" "$dry"
  if [[ "$dry" == 0 && "$files" != 0 ]]; then
    go_cache_as "$u" find "$real" -xdev -mindepth 2 -type f -mmin "+${age}" -delete ||
      { do_log "FATAL delete failed in $real"; return 1; }
  fi
  after_b="$(go_cache_bytes "$u" "$real")" || after_b="?"
  fs_line="$(go_cache_fs "$u" "$real")" || fs_line="$free ? $mount"
  go_cache_split_fs "$fs_line"
  last_free="$free"
  printf 'AFTER user=%s bytes=%s fs_free=%s fs_used_pct=%s mount=%s\n' "$u" "$after_b" "$free" "$pct" "$mount"
  removed_files=$((removed_files + files))
  removed_bytes=$((removed_bytes + bytes))
}

do_prune_go_build_cache() {
  local dry="${DRY_RUN:-1}" age="${GO_CACHE_MAX_AGE_MIN:-1440}" gate="${GO_CACHE_GATE:-0}"
  local thr="${GO_CACHE_PRUNE_AT_PCT:-85}" hour="${GO_CACHE_HOURLY_MINUTE:-0}"
  local targets u d rc=0 removed_files=0 removed_bytes=0
  local first_free="" last_free="" first_mount="" lrc=0 grc=0

  go_cache_check_inputs "$dry" "$gate" "$age" "$thr" "$hour" || return 1

  go_cache_lock_or_stop || lrc=$?
  if (( lrc == 2 )); then
    do_log "INFO a Go build-cache prune is already running; this one does nothing"
    return 0
  fi

  targets="$(go_cache_targets)" || return 1
  if [[ -z "$targets" ]]; then
    do_log "OK no Go build cache to prune"
    return 0
  fi

  if [[ "$gate" == 1 ]]; then
    go_cache_gate "$targets" "$thr" "$hour" || grc=$?
    (( grc == 3 )) && return 0
    (( grc == 0 )) || return 1
  fi

  while IFS=$'\t' read -r u d; do
    [[ -n "$u" && -n "$d" ]] || continue
    go_cache_prune_one "$u" "$d" "$age" "$dry" || rc=1
  done <<<"$targets"

  if (( rc != 0 )); then
    do_log "FAIL go build cache prune left at least one cache untouched"
    return "$rc"
  fi
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN go build cache: ${removed_files} file(s), ${removed_bytes} bytes would be removed; fs_free ${first_free:-?} unchanged on ${first_mount:-?}"
  else
    do_log "OK go build cache: removed ${removed_files} file(s), ${removed_bytes} bytes; fs_free ${first_free:-?} -> ${last_free:-?} on ${first_mount:-?}"
  fi
}
