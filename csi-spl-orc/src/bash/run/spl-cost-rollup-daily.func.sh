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
# @description cost or a token total (HUM-10 only, msg 02803231).
# @description DRY_RUN=1 (default): read every source, post nothing, and the
# @description gcp source reads without writing.
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
  st=ok
  (( n_partial + n_missing > 0 )) && st=partial
  do_log "INFO SUMMARY day=$day box=$box sources=${#names[@]} ok=$n_ok partial=$n_partial missing=$n_missing self=$n_self post_failed=$n_failed day_state=$st"
  if (( n_failed > 0 )); then do_log "FATAL $n_failed source day(s) were not posted to the $ENV hub"; return 1; fi
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN read ${#names[@]} source(s), posted nothing. DRY_RUN=0 posts them."; return 0; fi
  do_log "OK the $day cost rollup of $box is in the $ENV hub (run $run)"
}
