#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete Go build-cache entries older than GO_CACHE_MAX_AGE_MIN
# @description (default 1440, one day), then trim each cache to GO_CACHE_CAP_GB
# @description (default 8, each a gigabyte of 1024^3; 0 means no size cap) by
# @description deleting the oldest remaining depth-2 files. A full `go clean
# @description -cache` is not used: it would drop the newest bytes the cap
# @description keeps, and it is refused while that user runs go build, go test
# @description or go vet. The cache directory comes from `go env GOCACHE` run
# @description as that user, or from the env-var list GO_CACHE_USERS (users) /
# @description GO_CACHE_DIRS (directories, pruned as the current user). No home
# @description path is written here. The runner user's cache
# @description (GH_RUNNER_GO_CACHE_ROOT/go-build, default
# @description /mnt/data/gh-runner-go/go-build) is one of those: go env -w
# @description points GOCACHE there, and the runner user is in the default set.
# @description A directory is pruned only when it is a Go build cache: a
# @description regular README and real 00 and ff bucket directories. Anything
# @description else is left untouched and the action exits non-zero.
# @description Files are removed as the owning user (sudo -n when that is not
# @description us). DRY_RUN=1 (the default) prints counts and bytes only.
# @description Before and after, the cache size and the free space on the
# @description filesystem that holds it are printed.
# @description A cache whose user runs go is never pruned: while that user
# @description has a process whose program is go, compile, link, asm, cgo,
# @description vet, golangci-lint, gosec, staticcheck or govulncheck, the cache
# @description is a KEEP busy line and nothing in it is deleted, neither the
# @description age step nor the size cap. It is checked before the plan and
# @description again right before each delete (sat 2026-10-23: two pre-push
# @description api runs failed with go-build "no such file" while the cron
# @description trimmed the cache under them). gopls is not a build.
# @description GO_CACHE_GATE=1 (the cron) decides PER CACHE: a cache is
# @description pruned on the hourly minute (GO_CACHE_HOURLY_MINUTE, default 0)
# @description or when the filesystem that holds THAT cache is at or over
# @description GO_CACHE_PRUNE_AT_PCT (default 85). One CACHE line per cache
# @description names the user, path, filesystem, use % and the action.
# @description A user whose cache cannot be resolved is a WARN line, and the
# @description other caches are still pruned.
# @description Per-lane caches: a lane that builds with its own GOCACHE leaves
# @description <parent>/go-build-<lane id> next to the user's cache (sat
# @description 2026-10-19: go-build-c498, 565M, 3 days idle, never listed).
# @description Each such Go build cache whose lane is not live (the spool
# @description registry.tsv and the tmux windows) and that has no file newer
# @description than GO_CACHE_MAX_AGE_MIN is removed whole, as its owner. A
# @description live lane's cache is a KEEP line and never touched; a dir with
# @description no lane id in its name is left alone. Without a readable
# @description registry no lane cache is removed (a WARN).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GO_CACHE_MAX_AGE_MIN (optional) - age in minutes, default 1440
# @param GO_CACHE_CAP_GB (optional) - whole gigabytes (1024^3), default 8;
# @param   0 disables the size cap. The sweep's other marks are env defaults,
# @param   not cnf, so the default lives here.
# @param GO_CACHE_USERS (optional) - space-separated users; default the box
# @param   user, SPOOL_AGENT_USER, the spool-agents group and the CI runner
# @param   user(s) GH_RUNNER_USER (gh-runner-add's, default ghrunner) when
# @param   that user exists on the box
# @param GO_CACHE_DIRS (optional) - space-separated cache dirs (tests); when
# @param   set, GO_CACHE_USERS is not consulted
# @param SPOOL_TEST (optional) - 1 refuses to discover the live users
# @param GO_CACHE_GATE (optional) - 1 applies the hourly / percent gate
# @param GO_CACHE_PRUNE_AT_PCT (optional) - 0..100, default 85
# @param GO_CACHE_NOW_MIN / GO_CACHE_USED_PCT (optional) - test seams
# @param GO_CACHE_LANE_PARENTS (optional) - space-separated dirs scanned for
# @param   go-build-<lane> caches, removed as the current user (tests);
# @param   default the parent dir of each discovered user cache, none when
# @param   GO_CACHE_DIRS is set
# @param GO_CACHE_LIVE_IDS (optional) - the live lane ids (tests); default
# @param   $SPOOL_ROOT/registry.tsv column 1 and the tmux window names
# @param GO_CACHE_LOCK (optional) - 1 (default) or 0; the lock file is
# @param   GO_CACHE_LOCK_FILE, else the go-cache-prune state dir
# @param GO_CACHE_LOCK_WAIT (optional) - seconds to wait for a held lock,
# @param   default 0: the run stops at once with an INFO line. Over 0 (the
# @param   box disk sweep), a lock still held after the wait is a FAIL, rc 1
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

# go_cache_runner_users: the CI runner user(s) that exist on this box, one per
# line. GH_RUNNER_USER is the user gh-runner-add creates the runner as.
go_cache_runner_users() {
  local r
  set -f
  # shellcheck disable=SC2086 # space-separated user names
  for r in ${GH_RUNNER_USER:-ghrunner}; do
    getent passwd "$r" >/dev/null 2>&1 && printf '%s\n' "$r"
  done
  set +f
  return 0
}

# go_cache_discover_users: the box user, SPOOL_AGENT_USER, the spool group and
# the CI runner user(s), each once, space-separated. Empty when none resolve.
go_cache_discover_users() {
  local box="" members="" runners=""
  box="${SPOOL_BOX_USER:-}"
  if [[ -z "$box" && -n "${PROJ_PATH:-}" && -e "${PROJ_PATH}" ]]; then
    box="$(stat -c %U "$PROJ_PATH" 2>/dev/null || true)"
  fi
  members="$(getent group "${SPOOL_ROOT_GROUP:-spool-agents}" 2>/dev/null | awk -F: 'NR==1 { print $4 }' | tr ',' ' ' || true)"
  runners="$(go_cache_runner_users)"
  # shellcheck disable=SC2086 # the lists are space-separated user names
  printf '%s\n' $box ${SPOOL_AGENT_USER:-} $members $runners | awk 'NF && !seen[$0]++' | paste -sd' ' - || true
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

# go_cache_targets: one "<user>\t<dir>" line per cache that exists. A user
# whose cache cannot be resolved (no such user, no sudo, no go) is a WARN on
# stderr and is skipped; the other users' caches are still listed.
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
  elif [[ "${SPOOL_TEST:-}" == 1 ]]; then
    do_log "FATAL SPOOL_TEST=1 and no GO_CACHE_DIRS / GO_CACHE_USERS: a test must name its caches, never the live users'" >&2
    return 1
  else
    list="$(go_cache_discover_users)"
  fi
  set -f
  # shellcheck disable=SC2086 # space-separated user names
  for u in $list; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { set +f; do_log "FATAL refusing a user name that is not a single token: '$u'" >&2; return 1; }
    if ! d="$(go_cache_resolve "$u" 2>/dev/null)"; then
      do_log "WARN user=$u cache NOT pruned: cannot read its GOCACHE (go env as that user; no such user, no sudo -n, or no go)" >&2
      continue
    fi
    if go_cache_as "$u" test -d "$d" 2>/dev/null; then
      printf '%s\t%s\n' "$u" "$d"
    else
      do_log "INFO $u has no Go build cache yet" >&2
    fi
  done
  set +f
}

# go_cache_lock_or_stop: 0 proceed (lock held, or no lock in use), 2 another
# prune holds the lock (after GO_CACHE_LOCK_WAIT seconds) and this run must stop.
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
  if (( ${GO_CACHE_LOCK_WAIT:-0} > 0 )); then
    flock -w "$GO_CACHE_LOCK_WAIT" 9 && return 0
  else
    flock -n 9 && return 0
  fi
  return 2
}

# go_cache_check_inputs <dry> <gate> <age> <thr> <hour> <cap-gb>: 0 when every
# knob is valid, else logs the FATAL and returns 1.
go_cache_check_inputs() {
  local dry="$1" gate="$2" age="$3" thr="$4" hour="$5"
  local capgb="$6"
  do_require_bin find df du awk readlink || return 1
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$gate" == 0 || "$gate" == 1 ]] || { do_log "FATAL GO_CACHE_GATE must be 0 or 1, got: '$gate'"; return 1; }
  [[ "$age" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_MAX_AGE_MIN must be a whole number of minutes, got: '$age'"; return 1; }
  [[ "$capgb" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_CAP_GB must be a whole number of gigabytes, got: '$capgb'"; return 1; }
  [[ "$thr" =~ ^[0-9]+$ ]] && (( thr <= 100 )) || { do_log "FATAL GO_CACHE_PRUNE_AT_PCT must be 0..100, got: '$thr'"; return 1; }
  [[ "$hour" =~ ^[0-9]+$ ]] && (( 10#$hour <= 59 )) || { do_log "FATAL GO_CACHE_HOURLY_MINUTE must be 0..59, got: '$hour'"; return 1; }
  [[ "${GO_CACHE_LOCK:-1}" == 0 || "${GO_CACHE_LOCK:-1}" == 1 ]] || { do_log "FATAL GO_CACHE_LOCK must be 0 or 1"; return 1; }
  [[ "${GO_CACHE_LOCK_WAIT:-0}" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_LOCK_WAIT must be whole seconds, got: '${GO_CACHE_LOCK_WAIT}'"; return 1; }
}

# go_cache_due <user> <dir> <thr> <hour> <minute>: logs ONE line for this
# cache (user, path, filesystem, use %, action) and returns 0 prune now,
# 3 skip, 1 its filesystem cannot be read off the hourly tick (a WARN).
# The percent is the filesystem that holds THIS cache, not the first one.
go_cache_due() {
  local u="$1" d="$2" thr="$3" hour="$4" minute="$5" fs_line free="" pct="" mount="?" verdict due=0
  fs_line="$(go_cache_fs "$u" "$d" 2>/dev/null)" || fs_line=""
  [[ -n "$fs_line" ]] && go_cache_split_fs "$fs_line"
  [[ -n "${GO_CACHE_USED_PCT:-}" ]] && pct="$GO_CACHE_USED_PCT"
  # decided before do_log: ./run's do_log sets an unscoped 'action'
  if (( 10#$minute == 10#$hour )); then
    verdict=prune-hourly
  elif [[ ! "$pct" =~ ^[0-9]+$ ]]; then
    do_log "WARN CACHE user=$u path=$d fs=$mount used_pct=${pct:-?} threshold=$thr action=none: cannot read how full its filesystem is"
    return 1
  elif (( pct >= thr )); then
    verdict=prune
  else
    verdict=skip
    due=3
  fi
  do_log "CACHE user=$u path=$d fs=$mount used_pct=${pct:-?} threshold=$thr action=$verdict"
  return "$due"
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

# go_cache_go_busy <user>: 0 when one of that user's processes is a Go
# build: its program (argv[0], any path) is go, compile, link, asm, cgo, vet,
# golangci-lint, gosec, staticcheck or govulncheck. Those read and write the
# cache; a cache is never pruned while this is true. gopls is not counted:
# it runs for hours and builds nothing.
go_cache_go_busy() {
  local u="$1" prog _
  while read -r prog _; do
    [[ "${prog##*/}" =~ ^(go|compile|link|asm|cgo|vet|golangci-lint|gosec|staticcheck|govulncheck)$ ]] && return 0
  done < <(ps -u "$u" -o args= 2>/dev/null || true)
  return 1
}

# go_cache_keep_busy <user> <dir>: 0 (and one KEEP busy line) when that user
# runs a Go build right now, so nothing in the cache may be deleted.
go_cache_keep_busy() {
  go_cache_go_busy "$1" || return 1
  do_log "KEEP busy user=$1 path=$2: a go build, test, vet or lint of that user is running; nothing deleted this run"
}

# go_cache_cap_trim <user> <dir> <age-min> <dry>: one PLAN line for the size
# cap, then (dry 0) delete the oldest depth-2 files the age step is keeping
# until du -sb is at or under the cap. Adds those counts to removed_files /
# removed_bytes. Never runs `go clean -cache`. 1 when the list or the delete
# fails (nothing from this step is deleted if the list fails), 3 when the
# user started a go build after the plan (nothing deleted, KEEP busy).
go_cache_cap_trim() {
  local u="$1" d="$2" age="$3" dry="$4" gb cap total old_b excess list n=0 s=0 paths
  gb="${GO_CACHE_CAP_GB:-8}"
  cap=$(( gb * 1024 * 1024 * 1024 ))
  if (( cap > 0 )); then
    total="$(go_cache_bytes "$u" "$d")" || return 1
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    old_b="$(go_cache_old_stats "$u" "$d" "$age" | awk 'NR==1 { print $2 }')" || return 1
    [[ "$old_b" =~ ^[0-9]+$ ]] || return 1
    if (( old_b > total )); then old_b=$total; fi
    excess=$(( total - old_b - cap ))
    if (( excess > 0 )); then
      list="$(
        set -o pipefail
        go_cache_as "$u" find "$d" -xdev -mindepth 2 -type f ! -mmin "+${age}" -printf '%T@\t%s\t%p\n' |
          sort -n -s | awk -F '\t' -v excess="$excess" 's < excess { s += $2; print }'
      )" || { do_log "FATAL cannot list cache entries in $d for the size cap; nothing deleted there"; return 1; }
      n="$(awk -F '\t' 'NF >= 3 { c++ } END { print c + 0 }' <<<"$list")"
      s="$(awk -F '\t' 'NF >= 3 { b += $2 } END { print b + 0 }' <<<"$list")"
      paths="$(awk -F '\t' 'NF >= 3 { print $3 }' <<<"$list")"
      if (( n == 0 )); then
        do_log "WARN user=$u cache stays over the ${gb}G cap: no depth-2 file left to trim"
      fi
    fi
  fi
  printf 'PLAN user=%s files=%s bytes=%s cap_gb=%s dry_run=%s\n' "$u" "$n" "$s" "$gb" "$dry"
  if [[ "$dry" == 0 && "$n" != 0 ]]; then
    go_cache_keep_busy "$u" "$d" && return 3
    printf '%s\n' "$paths" | go_cache_as "$u" xargs -r -d $'\n' rm -f -- ||
      { do_log "FATAL size-cap delete failed in $d"; return 1; }
  fi
  removed_files=$(( removed_files + n ))
  removed_bytes=$(( removed_bytes + s ))
}

# go_cache_prune_one <user> <dir> <age> <dry>: check, measure, prune one cache
# and print its BEFORE / PLAN / AFTER lines. Adds to the caller's
# removed_files / removed_bytes and sets first_free, first_mount and last_free
# (the free space on first_mount only, never another filesystem's).
# 1 when that cache was left untouched (the FATAL is logged). 0 with a KEEP
# busy line, nothing deleted, while its user runs a Go build.
go_cache_prune_one() {
  local u="$1" d="$2" age="$3" dry="$4" real depth fs_line free pct mount stats files bytes before_b after_b crc=0
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
  go_cache_keep_busy "$u" "$d" && return 0
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
  go_cache_cap_trim "$u" "$real" "$age" "$dry" || crc=$?
  (( crc == 3 )) && return 0
  (( crc == 0 )) || return 1
  if [[ "$dry" == 0 && "$files" != 0 ]]; then
    go_cache_keep_busy "$u" "$d" && return 0
    go_cache_as "$u" find "$real" -xdev -mindepth 2 -type f -mmin "+${age}" -delete ||
      { do_log "FATAL delete failed in $real"; return 1; }
  fi
  after_b="$(go_cache_bytes "$u" "$real")" || after_b="?"
  fs_line="$(go_cache_fs "$u" "$real")" || fs_line="$free ? $mount"
  go_cache_split_fs "$fs_line"
  [[ "$mount" == "$first_mount" ]] && last_free="$free"
  printf 'AFTER user=%s bytes=%s fs_free=%s fs_used_pct=%s mount=%s\n' "$u" "$after_b" "$free" "$pct" "$mount"
  removed_files=$((removed_files + files))
  removed_bytes=$((removed_bytes + bytes))
}

# go_cache_lane_id <name>: the normalised lane id a go-build-<lane> dir name
# carries (go-build-c498 -> c-498, go-build-m-117 -> m-117), or empty (1).
go_cache_lane_id() {
  [[ "${1,,}" =~ ^go-build-([acgmq])-?([0-9]{3})([^0-9]|$) ]] && printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# go_cache_live_ids: the live lane ids, one per line (normalised). 1 when
# they cannot be read: then no lane cache may be removed.
go_cache_live_ids() {
  local ids reg w id
  if [[ -n "${GO_CACHE_LIVE_IDS+set}" ]]; then
    ids="$GO_CACHE_LIVE_IDS"
  else
    reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
    [[ -r "$reg" ]] || return 1
    ids="$(cut -f1 "$reg") $(tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(stat -c %u "$reg")/default}" \
      list-windows -a -F '#{window_name}' 2>/dev/null | tr -c 'A-Za-z0-9@\n-' ' ')"
  fi
  set -f
  # shellcheck disable=SC2086 # space-separated ids
  for w in $ids; do
    id="$(go_cache_lane_id "go-build-${w%%@*}")" && printf '%s\n' "$id"
  done
  set +f
  return 0
}

# go_cache_lane_parents <targets>: one "<user>\t<parent dir>" line per dir to
# scan for go-build-<lane> caches.
go_cache_lane_parents() {
  local u d
  if [[ -n "${GO_CACHE_LANE_PARENTS:-}" ]]; then
    u="$(id -un)"
    set -f
    # shellcheck disable=SC2086 # directories in this list have no spaces
    for d in ${GO_CACHE_LANE_PARENTS}; do printf '%s\t%s\n' "$u" "$d"; done
    set +f
    return 0
  fi
  [[ -z "${GO_CACHE_DIRS:-}" ]] || return 0
  while IFS=$'\t' read -r u d; do
    [[ -n "$u" && -n "$d" ]] && printf '%s\t%s\n' "$u" "$(dirname "$d")"
  done <<<"$1" | awk 'NF && !seen[$0]++'
}

# go_cache_prune_lane_one <user> <parent> <dir> <age> <dry> <live ids>: one
# KEEP or PLAN lane-cache line; removes the dir whole when its lane is not
# live and no file is newer than the age (dry 0). Adds to removed_files /
# removed_bytes. 1 when the removal failed.
go_cache_prune_lane_one() {
  local u="$1" p="$2" d="$3" age="$4" dry="$5" live="$6" name id real n b
  name="${d##*/}"
  id="$(go_cache_lane_id "$name")" || return 0
  real="$(go_cache_as "$u" readlink -f -- "$d" 2>/dev/null || true)"
  if [[ "$real" != "$(go_cache_as "$u" readlink -f -- "$p" 2>/dev/null)/$name" ]] || ! go_cache_is_cache "$u" "$real"; then
    do_log "KEEP not-a-go-cache $d"
    return 0
  fi
  if grep -qx -- "$id" <<<"$live"; then
    do_log "KEEP live-lane $id $d"
    return 0
  fi
  if [[ -n "$(go_cache_as "$u" find "$real" -xdev -type f -mmin "-${age}" -print -quit 2>/dev/null)" ]]; then
    do_log "KEEP recent $d"
    return 0
  fi
  read -r n b <<<"$(go_cache_as "$u" find "$real" -xdev -type f -printf '%s\n' | awk '{ n++; s += $1 } END { printf "%d %d\n", n + 0, s + 0 }')"
  printf 'PLAN lane-cache user=%s lane=%s files=%s bytes=%s path=%s dry_run=%s\n' "$u" "$id" "$n" "$b" "$real" "$dry"
  removed_files=$((removed_files + n))
  removed_bytes=$((removed_bytes + b))
  [[ "$dry" == 0 ]] || return 0
  go_cache_as "$u" rm -rf -- "$real" || { do_log "FATAL removing the lane cache $real failed"; return 1; }
}

# go_cache_prune_lanes <targets> <age> <dry>: the go-build-<lane> caches next
# to each user cache, through go_cache_prune_lane_one. 1 when a removal failed.
go_cache_prune_lanes() {
  local targets="$1" age="$2" dry="$3" parents live u p d rc=0
  parents="$(go_cache_lane_parents "$targets")"
  [[ -n "$parents" ]] || return 0
  if ! live="$(go_cache_live_ids)"; then
    do_log "WARN lane caches NOT pruned: cannot read the lane registry ${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
    return 0
  fi
  while IFS=$'\t' read -r -u 4 u p; do
    [[ -n "$u" && -n "$p" ]] || continue
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      go_cache_prune_lane_one "$u" "$p" "$d" "$age" "$dry" "$live" || rc=1
    done < <(go_cache_as "$u" find "$p" -mindepth 1 -maxdepth 1 -type d -name 'go-build-*' 2>/dev/null | sort)
  done 4<<<"$parents"
  return "$rc"
}

do_prune_go_build_cache() {
  local dry="${DRY_RUN:-1}" age="${GO_CACHE_MAX_AGE_MIN:-1440}" gate="${GO_CACHE_GATE:-0}"
  local capgb="${GO_CACHE_CAP_GB:-8}"
  local thr="${GO_CACHE_PRUNE_AT_PCT:-85}" hour="${GO_CACHE_HOURLY_MINUTE:-0}"
  local targets u d rc=0 removed_files=0 removed_bytes=0 minute="" pruned=0
  local first_free="" last_free="" first_mount="" lrc=0 grc=0

  go_cache_check_inputs "$dry" "$gate" "$age" "$thr" "$hour" "$capgb" || return 1

  go_cache_lock_or_stop || lrc=$?
  if (( lrc == 2 && ${GO_CACHE_LOCK_WAIT:-0} > 0 )); then
    do_log "FAIL another Go build-cache prune still holds the lock after ${GO_CACHE_LOCK_WAIT} s; nothing pruned"
    return 1
  elif (( lrc == 2 )); then
    do_log "INFO a Go build-cache prune is already running; this one does nothing"
    return 0
  fi

  targets="$(go_cache_targets)" || return 1
  if [[ -z "$targets" ]]; then
    do_log "OK no Go build cache to prune"
    return 0
  fi

  if [[ "$gate" == 1 ]]; then
    minute="${GO_CACHE_NOW_MIN:-$(date +%M)}"
    [[ "$minute" =~ ^[0-9]+$ ]] || { do_log "FATAL GO_CACHE_NOW_MIN is not a minute, got: '$minute'"; return 1; }
    [[ -z "${GO_CACHE_USED_PCT:-}" || "$GO_CACHE_USED_PCT" =~ ^[0-9]+$ ]] ||
      { do_log "FATAL filesystem use is not a percent, got: '$GO_CACHE_USED_PCT'"; return 1; }
  fi

  # fd 3, so nothing run as a cache's user can read the list off stdin
  while IFS=$'\t' read -r -u 3 u d; do
    [[ -n "$u" && -n "$d" ]] || continue
    if [[ "$gate" == 1 ]]; then
      grc=0
      go_cache_due "$u" "$d" "$thr" "$hour" "$minute" || grc=$?
      (( grc == 3 )) && continue
      (( grc == 0 )) || { rc=1; continue; }
    fi
    pruned=$((pruned + 1))
    go_cache_prune_one "$u" "$d" "$age" "$dry" || rc=1
  done 3<<<"$targets"
  if [[ "$gate" == 0 ]] || (( pruned > 0 )); then
    go_cache_prune_lanes "$targets" "$age" "$dry" || rc=1
  fi

  if (( rc == 0 && pruned == 0 )); then
    do_log "OK skip: no cache filesystem is at or over ${thr}% and minute ${minute} is not the hourly tick"
    return 0
  fi
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
