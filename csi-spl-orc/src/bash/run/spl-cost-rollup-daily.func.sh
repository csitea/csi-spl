#!/bin/bash
#------------------------------------------------------------------------------
# @description The nightly cost rollup of one box (spec 123 sections 4.5 and
# @description 4.6, build lane 4): for one UTC day (default yesterday) it asks
# @description the cost-source factory (lib spl-cost-source.func.sh) for every
# @description source named in cnf env.cost.sources, runs each, and posts
# @description each box source's rows and its one cost_coverage row to the
# @description ENV hub's operator ingest as source <name>.<box> (a re-post is
# @description an UPSERT: running it twice changes nothing). A source that
# @description writes its own rows (gcp: the billing export, re-read over the
# @description trailing env.cost.reread_days window) is run and reported. It
# @description names no source itself: a new source is a function and a cnf
# @description entry. A source that fails, or is listed but not registered,
# @description is posted `missing` with the reason, never 0, and the others
# @description still run. Stdout and the log carry counts and states, never a
# @description cost or a token total (HUM-10 only, msg 02803231). Last, it
# @description prunes the lease tick's day logs (dispatch/agent-run-<day>.log,
# @description ~0.5 MB a day) older than cnf env.cost.day_log_keep_days.
# @description Backfill (SPL-2086): with no DAY given it first posts, oldest
# @description first, every box source day of the env.cost.backfill_days
# @description (default 7) days before yesterday that this box's post ledger
# @description (COST_DAY_DIR/posted-<ENV>.tsv) holds no ok or partial post
# @description of, so one failed night is no permanent hole. The hub has no
# @description per-day coverage read for the box's service account (GET
# @description /v1/tenant/costs needs a member and answers amounts), so the
# @description box keeps its own record. One log line per day and source:
# @description posted / already present / failed (reason). The hub login
# @description (the SA key activation) is tried 3 times, waits 10 and 30 s.
# @description DRY_RUN=1 (default): read every source, post nothing, prune
# @description nothing, and the gcp source reads without writing.
# @param ENV - required: dev or prd, the hub written
# @param DAY (optional) - UTC day YYYY-MM-DD, default yesterday (UTC); a DAY
# @param   given posts that day only, no backfill
# @param DRY_RUN (optional) - 1 (default) or 0
# @param COST_SOURCES (optional) - space-separated source names, replaces the cnf list
# @param COST_BOX (optional) - the box tag of the posted sources, default the desk box
# @param COST_METERED_IDS (optional) - file of hub-metered message ids the
# @param   fleet_tokens source skips (spec 121 usage_events, not built yet)
# @param COST_TODAY (optional) - the UTC day taken as today (tests), default now
# @param COST_LOGIN_BACKOFF (optional) - the waits in s between login tries, default "10 30 90"
# @example ENV=prd ./run -a do_spl_cost_rollup_daily
# @example ENV=prd DAY=2026-10-09 DRY_RUN=0 ./run -a do_spl_cost_rollup_daily
#------------------------------------------------------------------------------
do_spl_cost_rollup_daily() {
  do_require_bin jq yq || return 1
  spl_require_cloud_env || return 1
  local day="${DAY:-$(date -u -d "${COST_TODAY:-now} -1 day" +%F)}" dry="${DRY_RUN:-1}" box run tmp name st why lines
  local -a names=()
  local n_ok=0 n_partial=0 n_missing=0 n_self=0 n_failed=0
  spl_cost_day_ok "$day" || return 1
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_spl_cloud_cnf || return 1
  mapfile -t names < <(spl_cost_sources "$SPL_CNF")
  (( ${#names[@]} > 0 )) || { do_log "FATAL no cost source to run (env.cost.sources)"; return 1; }
  box="$(spl_cost_box)" || return 1
  run="cost-rollup-$box-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if [[ "$dry" == 0 ]]; then spl_cost_login_retry || return 1; fi
  tmp="$(umask 077 && mktemp -d)" || return 1
  do_log "INFO cost rollup ENV=$ENV day=$day box=$box sources=${names[*]} DRY_RUN=$dry run=$run"
  SPL_COST_BACKFILL_FAILED=0
  if [[ -z "${DAY:-}" ]]; then
    spl_cost_backfill "$day" "$box" "$run" "$dry" "$tmp" "${names[@]}"
  else
    do_log "INFO backfill: off, DAY=$day was given (that day only)"
  fi
  for name in "${names[@]}"; do
    spl_cost_source_run "$name" "$day" "$tmp/$name"
    if [[ -s "$tmp/$name.self" ]]; then
      n_self=$((n_self + 1))
      do_log "INFO $name $day: $(head -n 1 "$tmp/$name.self")"
      [[ "$dry" == 0 ]] && spl_cost_ledger_add "$day" "$name.$box" self "$run"
      continue
    fi
    IFS=$'\t' read -r st why <"$tmp/$name.cov"
    lines="$(grep -c . "$tmp/$name.lines")"
    case "$st" in ok) n_ok=$((n_ok + 1)) ;; partial) n_partial=$((n_partial + 1)) ;; *) n_missing=$((n_missing + 1)) ;; esac
    do_log "INFO $name.$box $day state=$st lines=$lines${why:+ reason: $why}"
    [[ "$dry" == 0 ]] || continue
    spl_cost_post_logged "$name.$box" "$day" "$run" "$tmp/$name" "$st" || n_failed=$((n_failed + 1))
  done
  rm -rf "$tmp"
  spl_cost_prune_day_logs "$day" "$(yq -r '.env.cost.day_log_keep_days // ""' "$SPL_CNF")" "$dry"
  st=ok
  (( n_partial + n_missing > 0 )) && st=partial
  n_failed=$((n_failed + SPL_COST_BACKFILL_FAILED))
  do_log "INFO SUMMARY day=$day box=$box sources=${#names[@]} ok=$n_ok partial=$n_partial missing=$n_missing self=$n_self post_failed=$n_failed day_state=$st"
  if (( n_failed > 0 )); then do_log "FATAL $n_failed source day(s) were not posted to the $ENV hub"; return 1; fi
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN read ${#names[@]} source(s), posted nothing. DRY_RUN=0 posts them."; return 0; fi
  do_log "OK the $day cost rollup of $box is in the $ENV hub (run $run)"
}

# spl_cost_prune_day_logs DAY KEEP DRY: remove the lease tick's day logs
# ($SPOOL_ROOT/dispatch/agent-run-<day>.log) of the days before the KEEP days
# ending DAY (DRY 1: count them only). The day is read from the file name,
# never the mtime; a newer day (today's log) always stays. KEEP is at least 2:
# the agent-hours read of DAY needs the day before. Never fails the rollup.
spl_cost_prune_day_logs() {
  local day="$1" keep="$2" dry="$3" root="${SPOOL_ROOT:-/var/spool-hub}" cut f d n=0 kept=0
  if [[ ! "$keep" =~ ^[0-9]+$ ]] || (( keep < 2 )); then
    do_log "WARNING env.cost.day_log_keep_days must be 2 or more, got '$keep': no day log pruned"
    return 0
  fi
  cut="$(date -u -d "$day -$((keep - 1)) day" +%F)"
  for f in "$root"/dispatch/agent-run-*.log; do
    [[ -e "$f" ]] || continue
    d="${f##*/agent-run-}"; d="${d%.log}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    if [[ "$d" < "$cut" ]]; then
      n=$((n + 1))
      [[ "$dry" == 0 ]] && { rm -f -- "$f" || do_log "WARNING cannot remove $f"; }
    else
      kept=$((kept + 1))
    fi
  done
  do_log "INFO day logs: $([[ "$dry" == 0 ]] && echo removed || echo 'DRY_RUN would remove') $n before $cut (keep $keep days), kept $kept"
}

# spl_cost_login_retry: spl_cost_hub_login (the SA key activation and the hub
# door) tried 3 times, waiting COST_LOGIN_BACKOFF (default "10 30 90") seconds
# between tries; the FATAL names the try count. Service accounts only: there
# is no fallback to the owner account (repo CLAUDE.md, owner rule 2026-09-19).
spl_cost_login_retry() {
  local tries=3 try wait
  local -a waits=()
  read -r -a waits <<<"${COST_LOGIN_BACKOFF:-10 30 90}"
  for ((try = 1; try <= tries; try++)); do
    if spl_cost_hub_login; then
      (( try > 1 )) && do_log "INFO the $ENV hub login worked on try $try/$tries"
      return 0
    fi
    (( try < tries )) || break
    wait="${waits[try - 1]:-90}"
    do_log "WARNING the $ENV hub login (the SA key activation) failed on try $try/$tries, next try in ${wait} s"
    sleep "$wait"
  done
  do_log "FATAL the $ENV hub login (the SA key activation) failed after $tries tries: nothing posted (no owner-account fallback)"
  return 1
}

# spl_cost_ledger: this box's record of its posted source days for ENV, TSV
# day source state run_id posted_at (COST_DAY_DIR, default SPOOL_ROOT/cost).
spl_cost_ledger() {
  printf '%s/posted-%s.tsv\n' "${COST_DAY_DIR:-${SPOOL_ROOT:-/var/spool-hub}/cost}" "$ENV"
}

# spl_cost_ledger_add DAY SOURCE STATE RUN: record one posted source day.
spl_cost_ledger_add() {
  local f
  f="$(spl_cost_ledger)"
  mkdir -p "${f%/*}" && printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(date -u +%FT%TZ)" >>"$f" ||
    do_log "WARNING cannot write the post ledger $f: $2 $1 will be posted again by the next backfill"
}

# spl_cost_ledger_has DAY SOURCE: print the state the ledger holds for SOURCE
# on DAY when it counts as present (ok, partial; self on any day: a source that
# writes its own rows re-reads its own window), else return 1. A `missing`
# post is not present: the next night tries the day again.
spl_cost_ledger_has() {
  local f
  f="$(spl_cost_ledger)"
  [[ -r "$f" ]] || return 1
  awk -F'\t' -v d="$1" -v s="$2" '$2 == s && ($3 == "self" || ($1 == d && ($3 == "ok" || $3 == "partial"))) { st = $3 }
    END { if (st == "") exit 1; print st }' "$f"
}

# spl_cost_post_logged SOURCE DAY RUN OUT STATE: spl_cost_post plus the one
# per-day line (posted / failed (reason)) and, once posted, the ledger row.
spl_cost_post_logged() {
  local why
  SPL_HUB_OP_STATUS=""
  if spl_cost_post "$1" "$2" "$3" "$4"; then
    spl_cost_ledger_add "$2" "$1" "$5" "$3"
    do_log "INFO day $2 $1: posted (state=$5)"
    return 0
  fi
  why="the hub call failed"
  [[ -n "$SPL_HUB_OP_STATUS" ]] && why="the hub answered http $SPL_HUB_OP_STATUS"
  do_log "INFO day $2 $1: failed ($why)"
  return 1
}

# spl_cost_backfill DAY BOX RUN DRY TMP NAME...: the box source days of the
# env.cost.backfill_days days before DAY that the ledger holds no ok or
# partial post of, read and posted oldest first (DRY 1: listed only). A day
# already present is never re-posted, so a re-read that now fails (a pruned
# day log) cannot turn a posted day `missing`. Counts the failed posts in
# SPL_COST_BACKFILL_FAILED; the rollup still posts DAY.
spl_cost_backfill() {
  local day="$1" box="$2" run="$3" dry="$4" tmp="$5" n i d name st why have
  local n_post=0 n_have=0 n_fail=0
  shift 5
  n="$(yq -r '.env.cost.backfill_days // 7' "$SPL_CNF")"
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n > 62 )); then
    do_log "WARNING env.cost.backfill_days must be 0..62, got '$n': no backfill"
    return 0
  fi
  for ((i = n; i >= 1; i--)); do
    d="$(date -u -d "$day -$i day" +%F)"
    for name in "$@"; do
      if have="$(spl_cost_ledger_has "$d" "$name.$box")"; then
        n_have=$((n_have + 1)); do_log "INFO day $d $name.$box: already present (ledger state=$have)"; continue
      fi
      if [[ "$dry" == 1 ]]; then
        n_post=$((n_post + 1)); do_log "INFO day $d $name.$box: DRY_RUN would post (not in the ledger)"; continue
      fi
      spl_cost_source_run "$name" "$d" "$tmp/bf-$name"
      if [[ -s "$tmp/bf-$name.self" ]]; then
        spl_cost_ledger_add "$d" "$name.$box" self "$run"
        n_have=$((n_have + 1)); do_log "INFO day $d $name: posted by the source itself: $(head -n 1 "$tmp/bf-$name.self")"; continue
      fi
      IFS=$'\t' read -r st why <"$tmp/bf-$name.cov"
      if spl_cost_post_logged "$name.$box" "$d" "$run" "$tmp/bf-$name" "$st"; then n_post=$((n_post + 1)); else n_fail=$((n_fail + 1)); fi
    done
  done
  SPL_COST_BACKFILL_FAILED="$n_fail"
  do_log "INFO backfill: $n day(s) before $day, $([[ "$dry" == 1 ]] && echo 'DRY_RUN would post' || echo posted) $n_post, already present $n_have, failed $n_fail"
}
