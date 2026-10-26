#!/usr/bin/env bash
# docker-volume-prune.func.sh — remove the anonymous docker volumes the test
# containers left behind, and optionally the old build cache.
#
# Tracked by SPL-3087 (spec 102, epic SPL-2402). do_docker_test_container_prune
# (SPL-2450) removes the labelled test containers; nothing reclaimed the
# anonymous volumes those containers leave behind (sat /mnt/data at 92-93%,
# 7.5 GB of unused volumes, 2026-10-23).
#
# A volume is REMOVED (`docker volume rm <name>`, never -f, DRY_RUN=0 only)
# when ALL of these hold:
#   1. its name is anonymous: 64 lower-case hex characters (a named volume,
#      e.g. a compose project's pg-data, is never touched);
#   2. docker lists it as dangling (`docker volume ls -f dangling=true`);
#   3. no container, running or stopped, mounts it (checked again with
#      `docker inspect` of every container, so a stopped test DB keeps it);
#   4. it was created more than DOCKER_VOLUME_PRUNE_MIN_AGE_MIN (default 60)
#      min ago, so a test DB being started right now is never hit.
# Never `docker volume prune`, never `docker system prune`.
#
# Build cache, only with DOCKER_VOLUME_PRUNE_BUILD_CACHE=1: DRY_RUN=0 runs
# `docker builder prune -f --filter until=<age>m`; DRY_RUN=1 prints that plan.
#
# DRY_RUN=1 (default) prints each volume it would remove with its size, then
# the count and the total, and changes nothing.
#
# Exit: 0 nothing failed, whether or not a volume was (or would be) removed
# (the summary line says how many); 1 a removal or the build-cache prune
# failed; 2 docker unusable or a bad setting.
#
# Environment variables:
#   DRY_RUN: 1 (default) plans only; 0 removes.
#   DOCKER_VOLUME_PRUNE_DOCKER: docker command (default docker).
#   DOCKER_VOLUME_PRUNE_MIN_AGE_MIN: age limit in minutes (default 60).
#   DOCKER_VOLUME_PRUNE_BUILD_CACHE: 1 also prunes build cache older than
#     the age limit (default 0).
#   DOCKER_VOLUME_PRUNE_NOW: current epoch override (tests).
#
# @example cd csi-spl-utl && DRY_RUN=1 ./run -a do_docker_volume_prune
# @example cd csi-spl-utl && DRY_RUN=0 ./run -a do_docker_volume_prune
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# _dvp_size_bytes <docker size>: "869.2MB" -> bytes; 0 for what it cannot read.
_dvp_size_bytes() {
  local s="$1" n u
  [[ "$s" =~ ^([0-9.]+)([kKMGT]?B)$ ]] || { echo 0; return 0; }
  n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
  case "$u" in
    B) u=1 ;; kB | KB) u=1000 ;; MB) u=1000000 ;; GB) u=1000000000 ;; TB) u=1000000000000 ;;
  esac
  awk -v n="$n" -v u="$u" 'BEGIN { printf "%.0f\n", n * u }'
}

# _dvp_human <bytes>: 1234567890 -> 1.23 GB.
_dvp_human() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1e9) printf "%.2f GB\n", b / 1e9
    else if (b >= 1e6) printf "%.1f MB\n", b / 1e6
    else printf "%d B\n", b }'
}

# _dvp_used <docker cmd...>: the volume names any container (running or
# stopped) mounts, one per line. Fails when docker fails.
_dvp_used() {
  local ids
  ids="$("$@" ps -aq --no-trunc)" || return 1
  [[ -z "$ids" ]] && return 0
  # shellcheck disable=SC2086  # one argument per container id
  "$@" inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' $ids
}

# The steps below read and set the locals of do_docker_volume_prune by bash
# dynamic scope: dry, min_age, now, dk; dangling, used, sizes (_dvp_list);
# in_use, size (_dvp_mark); prune, n_named, n_used, n_young (_dvp_select);
# failed (_dvp_remove, _dvp_build_cache).

# _dvp_list: the dangling volumes, the mounted ones and the sizes; 2 when
# docker is unusable.
_dvp_list() {
  if ! dangling="$("${dk[@]}" volume ls -q -f dangling=true 2>&1)"; then
    do_log "FATAL docker volume ls failed: ${dangling:0:200}"
    return 2
  fi
  if ! used="$(_dvp_used "${dk[@]}" 2>&1)"; then
    do_log "FATAL docker ps / inspect failed: ${used:0:200}"
    return 2
  fi
  # sizes: best effort, a volume with no size reads 0
  sizes="$("${dk[@]}" system df -v --format '{{range .Volumes}}{{.Name}} {{.Size}};{{end}}' 2>/dev/null | tr ';' '\n')" || sizes=""
}

# _dvp_mark: the in-use and size maps from the listings.
_dvp_mark() {
  local name s
  while IFS= read -r name; do [[ -n "$name" ]] && in_use["$name"]=1; done <<<"$used"
  while read -r name s; do [[ -n "$name" ]] && size["$name"]="$s"; done <<<"$sizes"
}

# _dvp_select: the anonymous, unmounted, old enough dangling volumes into prune.
_dvp_select() {
  local name created epoch age_min
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! [[ "$name" =~ ^[0-9a-f]{64}$ ]]; then n_named=$((n_named + 1)); continue; fi
    if [[ -n "${in_use[$name]:-}" ]]; then
      do_log "INFO keep ${name:0:12}: a container mounts it"
      n_used=$((n_used + 1))
      continue
    fi
    created="$("${dk[@]}" volume inspect --format '{{.CreatedAt}}' "$name" 2>/dev/null)" || created=""
    epoch="$(date -d "$created" +%s 2>/dev/null || true)"
    if [[ -z "$epoch" ]]; then
      do_log "WARN ${name:0:12}: cannot read its creation time '$created': left alone"
      continue
    fi
    age_min=$(((now - epoch) / 60))
    if ((age_min <= min_age)); then n_young=$((n_young + 1)); continue; fi
    prune+=("$name $age_min $epoch $created")
  done <<<"$dangling"
}

# _dvp_remove: remove (or plan) each prune row, then the summary line.
_dvp_remove() {
  local row name age_min epoch created s out bytes total=0 n_done=0 oldest="" newest="" old_e="" new_e="" verb="removed"
  [[ "$dry" != 0 ]] && verb="would remove"
  for row in "${prune[@]}"; do
    read -r name age_min epoch created <<<"$row"
    s="${size[$name]:-?}"
    bytes="$(_dvp_size_bytes "$s")"
    if [[ "$dry" != 0 ]]; then
      do_log "INFO PLAN remove volume $name ($s, ${age_min} min old, created $created)"
    elif out="$("${dk[@]}" volume rm "$name" 2>&1)"; then
      do_log "INFO removed volume $name ($s, ${age_min} min old)"
    else
      do_log "WARN cannot remove volume $name: ${out:0:200}"
      failed=$((failed + 1))
      continue
    fi
    n_done=$((n_done + 1)) total=$((total + bytes))
    if [[ -z "$old_e" ]] || ((epoch < old_e)); then old_e="$epoch" oldest="$created"; fi
    if [[ -z "$new_e" ]] || ((epoch > new_e)); then new_e="$epoch" newest="$created"; fi
  done

  do_log "INFO docker-volume-prune: $verb $n_done anonymous dangling volume(s) older than ${min_age} min, total $(_dvp_human "$total")${oldest:+, oldest $oldest, newest $newest}; kept $n_named named, $n_used mounted, $n_young younger; failed $failed"
}

# _dvp_build_cache: DOCKER_VOLUME_PRUNE_BUILD_CACHE=1 only, the old build cache.
_dvp_build_cache() {
  local out
  [[ "${DOCKER_VOLUME_PRUNE_BUILD_CACHE:-0}" == 1 ]] || return 0
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN docker builder prune -f --filter until=${min_age}m"
  elif out="$("${dk[@]}" builder prune -f --filter "until=${min_age}m" 2>&1)"; then
    do_log "INFO build cache older than ${min_age} min pruned: $(tail -1 <<<"$out")"
  else
    do_log "WARN docker builder prune failed: ${out:0:200}"
    failed=$((failed + 1))
  fi
}

do_docker_volume_prune() {
  local dry="${DRY_RUN:-1}" min_age="${DOCKER_VOLUME_PRUNE_MIN_AGE_MIN:-60}" now
  local -a dk
  read -ra dk <<<"${DOCKER_VOLUME_PRUNE_DOCKER:-docker}"
  [[ "$min_age" =~ ^[0-9]+$ ]] || { do_log "FATAL DOCKER_VOLUME_PRUNE_MIN_AGE_MIN '$min_age' is not a number"; return 2; }
  now="${DOCKER_VOLUME_PRUNE_NOW:-$(date +%s)}"

  local dangling used sizes
  _dvp_list || return 2
  local -A in_use=() size=()
  _dvp_mark
  local -a prune=()
  local n_named=0 n_used=0 n_young=0 failed=0
  _dvp_select
  _dvp_remove
  _dvp_build_cache

  ((failed > 0)) && return 1
  return 0
}
