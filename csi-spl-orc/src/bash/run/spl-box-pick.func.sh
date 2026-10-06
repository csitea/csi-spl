#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the box a new agent lane should start on, by the
# @description fleet load target (owner HUM-10, t1 c13e8023 + t1 29b19f85).
# @description Each box has a band (low / high, % of cores = load5 / cpus * 100):
# @description its own per-box band when the hub names it (rdb 0134, `boxes`),
# @description else the fleet band. The pick, in the fill order: the first box
# @description below its LOW mark; else the first below its HIGH mark; every
# @description box at or above its HIGH -> "hold" (queue the lane, spawn
# @description nothing). So every box reaches its own min before any box goes
# @description past its min, and the lanes split in the proportion of the bands
# @description the admin set. The bands and the order are the hub's instance
# @description setting (`spool fleet-load get`; only the operator workspace's
# @description admin changes them). A hub that does not answer -> the defaults
# @description 50 / 75 and the cnf seed order env.box.fleet_load.box_order, with a
# @description WARN. A hub order that is empty -> the cnf seed. A box seen in the
# @description samples but in neither order comes after them, by name. The load
# @description is each box's latest box_stats row (rdb 0117) in the window; a box
# @description without one is skipped with a WARN. Prints the fleet band, one
# @description line per box with its band, then `pick=<box> reason=...` or
# @description `pick=hold reason=...`.
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
        | (($t.boxes // {})[$b]) as $own
        | (if $own != null then {low: $own.low, high: $own.high, src: "box"} else {low: $t.low, high: $t.high, src: "fleet"} end) as $band
        | if $r == null or ($r.cpus // 0) < 1 then {box: $b, miss: true}
          else ($r.load5 * 100 / $r.cpus) as $p
          | {box: $b, load5: $r.load5, cpus: $r.cpus, pct: $p, at: $r.at, band: $band,
             state: (if $p >= $band.high then "full" elif $p >= $band.low then "in band" else "under" end)}
          end] as $rows
    | ([$rows[] | select(.miss | not)]) as $seen
    | ((first($seen[] | select(.pct < .band.low)) | . + {why: "low"})
       // (first($seen[] | select(.pct < .band.high)) | . + {why: "high"})
       // null) as $pick
    | "fleet load target: \($t.low)..\($t.high) % of cores (source \($t.source // "hub")), \(($t.boxes // {}) | length) per-box band(s), order \($boxes | join(" ")) (\($ord.src)), samples \($since)",
      ($rows[] | if .miss then "WARN box \(.box): no load sample in the last \($since), skipped"
        else "BOX \(.box)  load5 \(.load5)  cpus \(.cpus)  \(.pct | floor)%  \(.state)  band \(.band.low)..\(.band.high) (\(.band.src))\(if $pick != null and .box == $pick.box then "  <- pick" else "" end)" end),
      (if $pick == null then
         "pick=hold reason=no box with a sample is below its high mark: queue the lane, spawn nothing"
       elif $pick.why == "low" then
         "pick=\($pick.box) reason=\($pick.box) is the first box in order below its low mark (\($pick.pct | floor)% < \($pick.band.low)%)"
       else
         "pick=\($pick.box) reason=\($pick.box) is the first box in order below its high mark (\($pick.pct | floor)% < \($pick.band.high)%), every box is at or above its low mark"
       end)' <<<"$1"
}
