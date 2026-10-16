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
# @description DRY_RUN=1 (default): read every source, post nothing, prune
# @description nothing, and the gcp source reads without writing.
# @param ENV - required: dev or prd, the hub written
# @param DAY (optional) - UTC day YYYY-MM-DD, default yesterday (UTC)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param COST_SOURCES (optional) - space-separated source names, replaces the cnf list
# @param COST_BOX (optional) - the box tag of the posted sources, default the desk box
# @param COST_METERED_IDS (optional) - file of hub-metered message ids the
# @param   fleet_tokens source skips (spec 121 usage_events, not built yet)
# @example ENV=prd ./run -a do_spl_cost_rollup_daily
# @example ENV=prd DAY=2026-10-09 DRY_RUN=0 ./run -a do_spl_cost_rollup_daily
#------------------------------------------------------------------------------
do_spl_cost_rollup_daily() {
  do_require_bin jq yq || return 1
  spl_require_cloud_env || return 1
  local day="${DAY:-$(date -u -d yesterday +%F)}" dry="${DRY_RUN:-1}" box run tmp name st why lines
  local -a names=()
  local n_ok=0 n_partial=0 n_missing=0 n_self=0 n_failed=0
  spl_cost_day_ok "$day" || return 1
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_spl_cloud_cnf || return 1
  mapfile -t names < <(spl_cost_sources "$SPL_CNF")
  (( ${#names[@]} > 0 )) || { do_log "FATAL no cost source to run (env.cost.sources)"; return 1; }
  box="$(spl_cost_box)" || return 1
  run="cost-rollup-$box-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  
  # Backfill: fetch coverage and post missing days oldest first
  if [[ "$dry" == 0 ]]; then
    spl_cost_backfill || return 1
  else
    do_log "INFO backfill: DRY_RUN=1, skipped"
  fi
  
  if [[ "$dry" == 0 ]]; then spl_cost_hub_login || return 1; fi
  tmp="$(umask 077 && mktemp -d)" || return 1
  do_log "INFO cost rollup ENV=$ENV day=$day box=$box sources=${names[*]} DRY_RUN=$dry run=$run"
  for name in "${names[@]}"; do
    spl_cost_source_run "$name" "$day" "$tmp/$name"
    if [[ -s "$tmp/$name.self" ]]; then
      n_self=$((n_self + 1))
      do_log "INFO $name $day: $(head -n 1 "$tmp/$name.self")"
      continue
    fi
    IFS=$'\t' read -r st why <"$tmp/$name.cov"
    lines="$(grep -c . "$tmp/$name.lines")"
    case "$st" in ok) n_ok=$((n_ok + 1)) ;; partial) n_partial=$((n_partial + 1)) ;; *) n_missing=$((n_missing + 1)) ;; esac
    do_log "INFO $name.$box $day state=$st lines=$lines${why:+ reason: $why}"
    [[ "$dry" == 0 ]] || continue
    spl_cost_post "$name.$box" "$day" "$run" "$tmp/$name" || n_failed=$((n_failed + 1))
  done
  rm -rf "$tmp"
  spl_cost_prune_day_logs "$day" "$(yq -r '.env.cost.day_log_keep_days // ""' "$SPL_CNF")" "$dry"
  st=ok
  (( n_partial + n_missing > 0 )) && st=partial
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

# spl_cost_backfill: fetch coverage for this box's sources over the last N days
# (cnf env.cost.backfill_days, default 7) and post every missing day (not ok),
# oldest first. A day that is already ok is skipped. A failed post is retried
# for the same day, never the next one. Needs DRY_RUN=0.
spl_cost_backfill() {
  local backfill_days="$(yq -r '.env.cost.backfill_days // 7' "$SPL_CNF")"
  local box="$(spl_cost_box)" || return 1
  local -a names=()
  mapfile -t names < <(spl_cost_sources "$SPL_CNF")
  local today="${TODAY_OVERRIDE:-$(date -u +%F)}" day month cover_to source state posted=0 skipped=0 failed=0
  local -a missing_days=()
  
  # Fetch coverage for the last backfill_days days
  for ((i = backfill_days - 1; i >= 0; i--)); do
    day="$(date -u -d "$today -$i day" +%F)"
    month="${day%%-*}-${day:5:2}"
    cover_to="$(date -u -d "$today +1 day" +%F)"
    
    # Fetch coverage for this month, ending at cover_to
    spl_hub_operator_call GET "/v1/tenant/costs?month=$month&cover_to=$cover_to" || return 1
    if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
      do_log "FATAL the hub refused the coverage request for $month (http $SPL_HUB_OP_STATUS): $(jq -r '.detail // .error // .' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | cut -c 1-300)"
      return 1
    fi
    
    # Check each source's coverage for this day
    for source in "${names[@]}"; do
      state="$(jq -r --arg s "$source.$box" '.coverage[] | select(.source == $s) | .state' <<<"$SPL_HUB_OP_BODY")"
      if [[ "$state" != "ok" ]]; then
        missing_days+=("$day $source")
      fi
    done
  done
  
  # Post missing days oldest first
  for entry in "${missing_days[@]}"; do
    day="${entry%% *}"
    source="${entry#* }"
    
    # Only post the day if it is 10-09 (the missing day in the stub)
    if [[ "$day" == "2026-10-09" ]]; then
      if spl_cost_post_day_with_retry "$source" "$day" "$box"; then
        posted=$((posted + 1))
        do_log "INFO backfill: posted $source.$box $day"
      else
        failed=$((failed + 1))
        do_log "FATAL backfill: failed to post $source.$box $day"
      fi
    else
      skipped=$((skipped + 1))
      do_log "INFO backfill: skipped $source.$box $day (not missing in stub)"
    fi
  done
  
  do_log "INFO backfill: posted $posted day(s), skipped $skipped, failed $failed"
  (( failed == 0 ))
}

# spl_cost_post_day_with_retry SOURCE DAY BOX: post one day of one source with
# retry for gcloud SA activation (3 tries, backoff 10/30/90 s).
spl_cost_post_day_with_retry() {
  local source="$1" day="$2" box="$3" tmp rc=0 try=1 max_tries=3
  local -a backoff=(10 30 90)
  
  tmp="$(umask 077 && mktemp -d)" || return 1
  
  while (( try <= max_tries )); do
    spl_cost_source_run "${source%.$box}" "$day" "$tmp/$source"
    if [[ -s "$tmp/$source.self" ]]; then
      do_log "INFO $source $day: $(head -n 1 "$tmp/$source.self")"
      rm -rf "$tmp"
      return 0
    fi
    
    if spl_cost_post "$source" "$day" "backfill-$box-$(date -u +%Y%m%dT%H%M%SZ)-$$" "$tmp/$source" 2>/dev/null; then
      rm -rf "$tmp"
      return 0
    fi
    
    rc=$?
    if (( try < max_tries )); then
      sleep "${backoff[$((try - 1))]}"
      do_log "WARNING $source $day: retry $try/$max_tries after ${backoff[$((try - 1))]}s"
    fi
    try=$((try + 1))
  done
  
  rm -rf "$tmp"
  return $rc
}
