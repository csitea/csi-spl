#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the box a new agent lane should start on, by the
# @description fleet load target (owner HUM-10, t1 c13e8023): the first box in
# @description the fill order whose load is below its HIGH mark, as % of cores
# @description (load5 / cpus * 100); every box at or above HIGH -> "hold" (queue
# @description the lane, spawn nothing). The band (low / high) and the order are
# @description the hub's instance setting (rdb 0119, `spool fleet-load get`;
# @description only the operator workspace's admin changes them). A hub that
# @description does not answer -> the defaults 50 / 75 and the cnf seed order
# @description env.box.fleet_load.box_order, with a WARN. A hub order that is
# @description empty -> the cnf seed. A box seen in the samples but in neither
# @description order comes after them, by name. The load is each box's latest
# @description box_stats row (rdb 0117) in the window; a box without one is
# @description skipped with a WARN. Prints the band, one line per box, then
# @description `pick=<box> reason=...` or `pick=hold reason=...`.
# @param BOX_PICK_SINCE (optional) - the sample window, default 15m (3 lane-map ticks)
# @param BOX_PICK_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param ENV (optional) - dev or prd: the hub to read, default LANE_ENV / lease.conf LEASE_ENV
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `fleet-load get` or `box-stats list ...`
# @example ./run -a do_spl_box_pick
# @example BOX_PICK_SINCE=30m ./run -a do_spl_box_pick
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_spl_box_pick() {
  do_require_bin yq || return 1
  local since="${BOX_PICK_SINCE:-15m}" org_app cnf target stats seed
  [[ "$since" =~ ^[0-9]+[smhd]$ ]] || { do_log "FATAL BOX_PICK_SINCE must be a duration (15m, 1h), got '$since'"; return 1; }
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  cnf="${BOX_PICK_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  seed="$(yq -o=json -I=0 '.env.box.fleet_load.box_order // []' "$cnf")" || { do_log "FATAL cnf env.box.fleet_load.box_order does not read"; return 1; }
  jq -e 'type == "array" and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$"))' >/dev/null 2>&1 <<<"$seed" ||
    { do_log "FATAL cnf env.box.fleet_load.box_order must be a list of box ids, got $seed"; return 1; }
  [[ -n "${ENV:-}" ]] && export LANE_ENV="$ENV"  # spl_lane_init reads it
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL the box loads live on the hub: set LANE_FLEET (or LEASE_FLEET in lease.conf)"; return 1; }

  target="$(spl_lane_spool fleet-load get 2>&1)"
  if ! jq -e '(.low | type == "number") and (.high | type == "number") and (.box_order | type == "array")' >/dev/null 2>&1 <<<"$target"; then
    do_log "WARN the hub did not answer the fleet load target ($(tail -1 <<<"$target" | head -c 200)): the defaults 50 / 75 and the cnf order" >&2
    target='{"low":50,"high":75,"box_order":[],"source":"built-in default"}'
  fi
  stats="$(spl_lane_spool box-stats list --since "$since" 2>&1)"
  jq -e '.rows | type == "array"' >/dev/null 2>&1 <<<"$stats" ||
    { do_log "FATAL the hub did not answer the box stats read: $(tail -1 <<<"$stats" | head -c 200)"; return 1; }
  spl_box_pick_decide "$target" "$stats" "$seed" "$since"
}

# spl_box_pick_decide TARGET STATS SEED SINCE -> the band line, one line per
# box in fill order, a WARN per box with no sample, then the pick line.
spl_box_pick_decide() {
  jq -r --argjson seed "$3" --arg since "$4" --slurpfile st <(printf '%s' "$2") '
    . as $t
    | (if ($t.box_order | length) > 0 then {o: $t.box_order, src: "hub"} else {o: $seed, src: "cnf seed"} end) as $ord
    | ($st[0].rows | group_by(.box) | map(max_by(.at)) | map({key: .box, value: .}) | from_entries) as $last
    | ($ord.o + (($last | keys) - $ord.o | sort)) as $boxes
    | [$boxes[] as $b | ($last[$b]) as $r
        | if $r == null or ($r.cpus // 0) < 1 then {box: $b, miss: true}
          else ($r.load5 * 100 / $r.cpus) as $p
          | {box: $b, load5: $r.load5, cpus: $r.cpus, pct: $p, at: $r.at,
             state: (if $p >= $t.high then "full" elif $p >= $t.low then "in band" else "under" end)}
          end] as $rows
    | (first($rows[] | select((.miss | not) and .pct < $t.high)) // null) as $pick
    | "fleet load target: \($t.low)..\($t.high) % of cores (source \($t.source // "hub")), order \($boxes | join(" ")) (\($ord.src)), samples \($since)",
      ($rows[] | if .miss then "WARN box \(.box): no load sample in the last \($since), skipped"
        else "BOX \(.box)  load5 \(.load5)  cpus \(.cpus)  \(.pct | floor)%  \(.state)\(if $pick != null and .box == $pick.box then "  <- pick" else "" end)" end),
      (if $pick != null then
         "pick=\($pick.box) reason=\($pick.box) is the first box in order below its high mark (\($pick.pct | floor)% < \($t.high)%)"
       else
         "pick=hold reason=no box with a sample is below its high mark (\($t.high)%): queue the lane, spawn nothing"
       end)' <<<"$1"
}
