#!/bin/bash
#------------------------------------------------------------------------------
# @description Move the self-hosted GitHub runners' Go caches off the root
# @description disk: GOCACHE (<root>/go-build) and GOPATH + GOMODCACHE
# @description (<root>/go) go under GH_RUNNER_GO_CACHE_ROOT, a dir owned by
# @description the runner user (GH_RUNNER_USER), on a bigger disk.
# @description For EVERY runner configured in GH_RUNNER_ROOT: the three
# @description lines go into its .env and its service is restarted, each one
# @description only while it runs no job (no Runner.Worker in its unit's
# @description cgroup); a busy runner is waited for (GH_RUNNER_IDLE_WAIT_S)
# @description and, when it never goes idle, left as it was (re-run later).
# @description The runner user's `go env -w` gets the same paths, so the Go
# @description build-cache prune cron (`go env GOCACHE` as that user) prunes
# @description the NEW cache. The old GOPATH (modules) is copied over once;
# @description the old build cache is dropped, and the old GOPATH too, but
# @description only once every runner runs on the new paths.
# @description Idempotent: a runner whose .env already carries the paths is
# @description kept. Dry run (the plan, sizes, df) unless DRY_RUN=0.
# @param GH_RUNNER_GO_CACHE_ROOT (optional) - default /mnt/data/gh-runner-go
# @param GH_RUNNER_USER (optional) - the runner user, default ghrunner
# @param GH_RUNNER_ROOT (optional) - runner dirs, default /srv/gh-runner
# @param GH_RUNNER_HOME (optional) - the user's home, default /var/lib/<user>
# @param GH_RUNNER_IDLE_WAIT_S (optional) - wait for busy runners, default 1800
# @param GH_RUNNER_IDLE_POLL_S (optional) - seconds between checks, default 15
# @param GH_RUNNER_GO_BIN (optional) - the go binary, default /usr/local/go/bin/go
# @param GH_RUNNER_CGROUP_FS (optional) - default /sys/fs/cgroup (a test seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_setup_ghrunner_go_cache
# @example DRY_RUN=0 ./run -a do_setup_ghrunner_go_cache
# @example GH_RUNNER_GO_CACHE_ROOT=<data-disk>/gh-runner-go DRY_RUN=0 ./run -a do_setup_ghrunner_go_cache
#------------------------------------------------------------------------------
declare -F ghr_go_env_lines >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/gh-runner-add.func.sh"

# ghgc_runners - "<name> <dir>" per runner configured in GHGC_RUNNER_ROOT
ghgc_runners() {
  local name
  while read -r name; do
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    sudo test -s "$GHGC_RUNNER_ROOT/$name/.runner" && printf '%s %s\n' "$name" "$GHGC_RUNNER_ROOT/$name"
  done < <(sudo find "$GHGC_RUNNER_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null | sort)
}

# ghgc_busy <dir> - 0 when the runner runs a job: a Runner.Worker in its
# unit's cgroup. A runner whose unit cannot be read counts as busy.
ghgc_busy() {
  local unit cg pids
  unit="$(sudo cat "$1/.service" 2>/dev/null)"
  [[ "$unit" =~ ^actions\.runner\.[A-Za-z0-9._@-]+\.service$ ]] || return 0
  cg="$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null)"
  [[ "$cg" == /* ]] || return 0
  pids="$(find "$GHGC_CGROUP_FS$cg" -name cgroup.procs -exec cat {} + 2>/dev/null | paste -sd, -)"
  [[ -n "$pids" ]] || return 1
  ps -o comm= -p "$pids" 2>/dev/null | grep -x 'Runner.Worker' >/dev/null
}

# ghgc_env_want <dir> - the runner's .env with the Go cache lines replaced
ghgc_env_want() {
  { sudo cat "$1/.env" 2>/dev/null | grep -vE '^(GOCACHE|GOPATH|GOMODCACHE)=' || true
    ghr_go_env_lines "$GHGC_ROOT"; } | awk 'NF'
}

# ghgc_switch_one <name> <dir> - 0 switched (or already on the new paths), 2
# busy (left as it was), 1 failed
ghgc_switch_one() {
  local name="$1" dir="$2" want
  want="$(ghgc_env_want "$dir")"
  [[ "$(sudo cat "$dir/.env" 2>/dev/null)" == "$want" ]] && return 0
  ghgc_busy "$dir" && return 2
  sudo -u "$GHGC_USER" tee "$dir/.env" >/dev/null <<<"$want" || { do_log "FATAL cannot write $dir/.env"; return 1; }
  ghr_in "$dir" root ./svc.sh stop >/dev/null 2>&1
  ghr_in "$dir" root ./svc.sh start >/dev/null || { do_log "FATAL $name's service did not start"; return 1; }
  do_log "OK $name: .env carries the Go cache in $GHGC_ROOT, restarted while idle"
}

# ghgc_switch_all - every runner switched, a busy one retried until
# GHGC_WAIT_S; 0 when all are on the new paths
ghgc_switch_all() {
  local name dir rc pending waited=0 failed=0
  while :; do
    pending=0
    while read -r name dir; do
      rc=0; ghgc_switch_one "$name" "$dir" || rc=$?
      (( rc == 1 )) && failed=1
      (( rc == 2 )) && pending=$((pending + 1)) && do_log "INFO $name runs a job - waiting for it to go idle"
    done < <(ghgc_runners)
    (( pending == 0 || failed == 1 || waited >= GHGC_WAIT_S )) && break
    sleep "$GHGC_POLL_S"; waited=$((waited + GHGC_POLL_S))
  done
  (( failed == 0 )) || return 1
  (( pending == 0 )) || { do_log "FAIL $pending runner(s) stayed busy for ${GHGC_WAIT_S}s and still use the old cache - re-run later"; return 1; }
}

# ghgc_go_as <cmd...> - run as the runner user with its own HOME, no Go env
ghgc_go_as() {
  sudo -u "$GHGC_USER" env -u GOCACHE -u GOPATH -u GOMODCACHE HOME="$GHGC_HOME" "$@"
}

# ghgc_seed - copy the old GOPATH (modules) into an empty new one, once
ghgc_seed() {
  local old="$GHGC_HOME/go" new="$GHGC_ROOT/go"
  [[ "$old" != "$new" ]] && sudo test -d "$old" && ! sudo test -L "$old" || return 0
  [[ -z "$(sudo find "$new" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 0
  sudo -u "$GHGC_USER" cp -a "$old/." "$new/" || { do_log "FATAL cannot copy $old to $new"; return 1; }
  do_log "OK copied the old GOPATH $old into $new"
}

# ghgc_drop_old - the old build cache and GOPATH, once every runner switched
ghgc_drop_old() {
  local d
  for d in "$GHGC_HOME/.cache/go-build" "$GHGC_HOME/go"; do
    [[ "$d" == "$GHGC_ROOT"/* ]] && continue
    sudo test -d "$d" && ! sudo test -L "$d" || continue
    sudo -u "$GHGC_USER" chmod -R u+w "$d" && sudo -u "$GHGC_USER" rm -rf "$d" \
      || { do_log "FATAL cannot drop the old $d"; return 1; }
    do_log "OK dropped the old $d"
  done
}

# ghgc_report - sizes and free space, before or after
ghgc_report() {
  local d
  for d in "$GHGC_HOME/.cache/go-build" "$GHGC_HOME/go" "$GHGC_ROOT/go-build" "$GHGC_ROOT/go"; do
    sudo test -d "$d" && do_log "INFO $1 $(sudo du -sh "$d" 2>/dev/null | cut -f1) $d"
  done
  do_log "INFO $1 df: $(df -hP "$GHGC_HOME" "$(dirname "$GHGC_ROOT")" 2>/dev/null | awk 'NR>1 {printf "%s %s used %s free; ", $6, $5, $4}')"
}

# ghgc_check_inputs - the knobs; 1 with the FATAL logged
ghgc_check_inputs() {
  [[ "$GHGC_DRY" == 0 || "$GHGC_DRY" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$GHGC_DRY'"; return 1; }
  [[ "$GHGC_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$GHGC_ROOT" != *..* && "$GHGC_ROOT" != */ ]] \
    || { do_log "FATAL GH_RUNNER_GO_CACHE_ROOT must be an absolute path, got: '$GHGC_ROOT'"; return 1; }
  [[ "$GHGC_HOME" =~ ^/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ && "$GHGC_HOME" != *..* ]] \
    || { do_log "FATAL GH_RUNNER_HOME must be an absolute path two levels deep, got: '$GHGC_HOME'"; return 1; }
  [[ "$GHGC_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$GHGC_USER" != root ]] || { do_log "FATAL bad GH_RUNNER_USER: '$GHGC_USER'"; return 1; }
  [[ "$GHGC_WAIT_S" =~ ^[0-9]+$ && "$GHGC_POLL_S" =~ ^[1-9][0-9]*$ ]] \
    || { do_log "FATAL GH_RUNNER_IDLE_WAIT_S / GH_RUNNER_IDLE_POLL_S must be whole seconds"; return 1; }
  id -u "$GHGC_USER" >/dev/null 2>&1 || { do_log "FATAL no runner user $GHGC_USER on this box"; return 1; }
}

do_setup_ghrunner_go_cache() {
  do_require_bin sudo systemctl find du df || return 1
  GHGC_ROOT="${GH_RUNNER_GO_CACHE_ROOT:-/mnt/data/gh-runner-go}" GHGC_DRY="${DRY_RUN:-1}"
  GHGC_USER="${GH_RUNNER_USER:-ghrunner}" GHGC_RUNNER_ROOT="${GH_RUNNER_ROOT:-/srv/gh-runner}"
  GHGC_HOME="${GH_RUNNER_HOME:-/var/lib/$GHGC_USER}" GHGC_GO="${GH_RUNNER_GO_BIN:-/usr/local/go/bin/go}"
  GHGC_WAIT_S="${GH_RUNNER_IDLE_WAIT_S:-1800}" GHGC_POLL_S="${GH_RUNNER_IDLE_POLL_S:-15}"
  GHGC_CGROUP_FS="${GH_RUNNER_CGROUP_FS:-/sys/fs/cgroup}"
  ghgc_check_inputs || return 1
  local runners name dir state
  runners="$(ghgc_runners)"
  [[ -n "$runners" ]] || { do_log "FATAL no configured runner in $GHGC_RUNNER_ROOT"; return 1; }
  ghgc_report BEFORE
  while read -r name dir; do
    state="new-paths"
    [[ "$(sudo cat "$dir/.env" 2>/dev/null)" == "$(ghgc_env_want "$dir")" ]] && state=kept
    [[ "$state" == kept ]] || { ghgc_busy "$dir" && state="$state,busy-wait" || state="$state,idle-restart"; }
    do_log "INFO $name: $state ($(sudo cat "$dir/.env" 2>/dev/null | grep -E '^GOCACHE=' || echo 'GOCACHE unset'))"
  done <<<"$runners"
  if [[ "$GHGC_DRY" == 1 ]]; then
    do_log "INFO DRY_RUN would: make $GHGC_ROOT/{go-build,go} as $GHGC_USER, go env -w them, copy $GHGC_HOME/go once, switch every runner's .env (restart while idle), then drop $GHGC_HOME/.cache/go-build and $GHGC_HOME/go"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0."
    return 0
  fi
  ghr_go_dirs "$GHGC_USER" "$GHGC_ROOT" && ghgc_seed || return 1
  ghgc_go_as "$GHGC_GO" env -w "GOCACHE=$GHGC_ROOT/go-build" "GOPATH=$GHGC_ROOT/go" "GOMODCACHE=$GHGC_ROOT/go/pkg/mod" \
    || { do_log "FATAL go env -w as $GHGC_USER failed"; return 1; }
  [[ "$(ghgc_go_as "$GHGC_GO" env GOCACHE 2>/dev/null)" == "$GHGC_ROOT/go-build" ]] \
    || { do_log "FATAL $GHGC_USER's go env GOCACHE does not read back $GHGC_ROOT/go-build"; return 1; }
  ghgc_switch_all || return 1
  ghgc_drop_old || return 1
  ghgc_report AFTER
  do_log "OK every runner's Go cache is in $GHGC_ROOT; the prune cron follows $GHGC_USER's go env"
}
