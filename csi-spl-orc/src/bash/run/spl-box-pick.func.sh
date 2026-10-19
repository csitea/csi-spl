#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the box a new agent lane should start on, by the
# @description fleet load target (owner HUM-10, t1 c13e8023 + t1 29b19f85).
# @description Each box has a band (low / high, % of cores = load5 / cpus * 100):
# @description its own per-box band when the hub names it (rdb 0134, `boxes`),
# @description else the fleet band. The pick, in the fill order: the first box
# @description below its LOW mark; else the first below its HIGH mark; else
# @description (every box at or above its HIGH) the box least far past its band,
# @description load% / high, while that box is below its OVERFLOW mark (high *
# @description BOX_PICK_OVERFLOW / 100): a weight, so an overloaded box hands its
# @description lanes to the one with room (spec 101 R1); every box at or above
# @description its OVERFLOW -> "hold" (queue the lane, spawn
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
# @description A DEGRADED box is never picked (t1 3cfc236e, the 2026-10-11
# @description lesson): its hub beats in the last window_min are under
# @description min_beat_pct % of the expected 1 per beat_s, or its last beat is
# @description over max_gap_s old (cnf env.box.health, the rule and its numbers
# @description in lib/bash/funcs/spl-box-health.func.sh). Every box with a load
# @description sample degraded -> the pick as before, with a WARN. No beats
# @description answer -> no box is judged, with a WARN.
# @description A box running CI takes FEWER lanes (owner HUM-10, t1 f67e3656 msg
# @description 565d9bbb): with a runner job active (its BOX-0 row's ci=<N>, this
# @description box's own Runner.Worker count) its band is the lower cnf
# @description env.box.ci_busy band and, at or over max_agents live agents, it
# @description is not picked at all: the lane goes to another box or holds. Its
# @description line says "ci busy: N jobs, cap M". The rule and its numbers:
# @description lib/bash/funcs/spl-box-ci.func.sh. A spawn with its own id (the
# @description rotation, a restore) never asks this pick.
# @description With BOX_PICK_KIND (spawn-window.sh sets it, SPL-1649) a box
# @description measured without that vendor's CLI is not picked: this box by
# @description spool_vendor_clis, another by the cli= of its BOX-0 row; a box
# @description nobody measured stays in. Its line says "no <kind> CLI". No box
# @description left -> `pick=nokind reason=...` (spawn nothing, exit 13 there).
# @description With BOX_PICK_KIND a box whose weekly usage of that vendor is at
# @description or over cnf env.box.quota.weekly_max_pct (90) is not picked
# @description (SPL-2035): this box by its agent panes' banner or, for claude,
# @description the CLI's limit entry in the agent user's transcripts (SPL-2196:
# @description 100 until its reset, a pane shows the banner only on the failed
# @description turn), another by the wk= of its BOX-0 row
# @description (lib/bash/funcs/spl-box-quota.func.sh). Its
# @description line says "<kind> weekly N% >= M%: not picked". Every box with
# @description room over it -> `pick=hold reason=waiting: <kind> weekly >= M%
# @description on <boxes>` (queued, never a silent fallback). No reading, or a
# @description row an hour old, is unknown, not 0: the box stays in and an INFO
# @description line names the picked box's unknown usage.
# @description A CORDONED box is never picked (sat alone panel row 01, SPL-2629):
# @description do_spl_box_cordon's live marker <spool root>/dispatch/cordon/<box>
# @description (spl-box-cordon.func.sh). Its line says "CORDONED (until <UTC>)";
# @description the every-box-degraded fallback does not take it either; every
# @description box with a sample cordoned -> pick=hold.
# @param BOX_PICK_SINCE (optional) - the sample window, default 15m (3 lane-map ticks)
# @param BOX_PICK_OVERFLOW (optional) - the overflow mark as % of each box's high mark, default 200 (100 = hold at high)
# @param BOX_PICK_KIND (optional) - claude|grok|agy|qwen|mistral: leave out the boxes measured without its CLI or at its weekly limit
# @param BOX_QUOTA_WEEKLY_MAX_PCT (optional) - overrides cnf env.box.quota.weekly_max_pct, default 90
# @param BOX_PICK_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPOOL_ROOT (optional) - the cordon markers' root, default /var/spool-hub
# @param ENV (optional) - dev or prd: the hub to read, default LANE_ENV / lease.conf LEASE_ENV
# @param BOX_HEALTH_<KEY> (optional) - overrides cnf env.box.health.<key> (WINDOW_MIN, MIN_BEAT_PCT, BEAT_S, MAX_GAP_S)
# @param BOX_CI_<KEY> (optional) - overrides cnf env.box.ci_busy.<key> (MAX_AGENTS, LOW_PCT, HIGH_PCT, MAX_AGE_S)
# @param LANE_CI_CMD (optional, tests) - prints this box's active runner jobs instead of counting Runner.Worker
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `fleet-load get`, `box-stats list ...`, `box-beat list ...` or `lane --fleet ...`
# @example ./run -a do_spl_box_pick
# @example BOX_PICK_SINCE=30m ./run -a do_spl_box_pick
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
declare -F spl_box_health_verdicts >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-health.func.sh"
declare -F spl_box_ci_jobs >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-ci.func.sh"
declare -F spl_box_quota_from_rows >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-quota.func.sh"
declare -F spl_box_cordon_active >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-box-cordon.func.sh"

do_spl_box_pick() {
  do_require_bin yq || return 1
  local since="${BOX_PICK_SINCE:-15m}" overflow="${BOX_PICK_OVERFLOW:-200}" org_app cnf target stats seed health cicnf ci rows
  [[ "$since" =~ ^[0-9]+[smhd]$ ]] || { do_log "FATAL BOX_PICK_SINCE must be a duration (15m, 1h), got '$since'"; return 1; }
  [[ "$overflow" =~ ^[0-9]+$ ]] && ((overflow >= 100)) ||
    { do_log "FATAL BOX_PICK_OVERFLOW must be a whole % of the high mark, at least 100, got '$overflow'"; return 1; }
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
  spl_box_health_cnf "$cnf"
  health="$(spl_box_health_verdicts "$(spl_lane_spool box-beat list --since "$(spl_box_health_since)" 2>&1)" 0)" || {
    do_log "WARN the hub did not answer the box beats read: no box is judged unhealthy" >&2; health='{}'; }
  cicnf="$(spl_box_ci_cnf "$cnf")"
  rows="$(spl_lane_hub --fleet "$LANE_FLEET" 2>/dev/null)"
  ci="$(spl_box_ci_from_rows "$rows" "$LANE_BOX_ROW_ID" \
    "$(jq -r .max_age_s <<<"$cicnf")" "$LANE_BOX" "$(spl_box_ci_jobs)")"
  spl_box_pick_decide "$target" "$stats" "$seed" "$since" "$overflow" "$health" "$ci" "$cicnf" \
    "$(spl_box_pick_nokind "$rows" "${BOX_PICK_KIND:-}")" "${BOX_PICK_KIND:-}" \
    "$(spl_box_pick_quota "$rows" "${BOX_PICK_KIND:-}")" "$(spl_box_quota_max "$cnf")" "$(spl_box_cordon_active)"
}

# spl_box_pick_quota ROWS KIND -> KIND's weekly usage per box, {"<box>": pct}
# (spl_box_quota_from_rows; this box read live). KIND "" -> {}.
spl_box_pick_quota() {
  [[ -n "${2:-}" ]] || { echo '{}'; return 0; }
  spl_box_quota_from_rows "$1" "$LANE_BOX_ROW_ID" "${LANE_BOX_ROW_MAX_S:-3600}" "$2" "$LANE_BOX" "$(spl_box_quota_here)"
}

# spl_box_pick_nokind ROWS KIND -> the boxes measured without KIND's CLI, as
# a JSON array: another box by the cli= of its latest BOX-0 row younger than
# LANE_BOX_ROW_MAX_S (no cli= = unknown, left out), this box by
# spool_vendor_clis (unknown = left out). KIND "" -> [].
spl_box_pick_nokind() {
  [[ -n "${2:-}" ]] || { echo '[]'; return 0; }
  local here_clis="?"
  declare -F spool_vendor_clis >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  here_clis="$(spool_vendor_clis 2>/dev/null)" || here_clis="?"
  jq -c --arg id "$LANE_BOX_ROW_ID" --argjson max "${LANE_BOX_ROW_MAX_S:-3600}" --arg here "$LANE_BOX" \
    --arg hc "$here_clis" --arg k "$2" '
    def lacks: (split(",") | index($k)) == null;
    [(.lanes // [])[] | select(.agent_id == $id and .state == "live" and (.age_s // -1) >= 0 and .age_s < $max)]
    | group_by(.agent_box) | map(min_by(.age_s))
    | [.[] | select(.agent_box != $here) | {b: .agent_box, c: ([(.scope // "") | capture("(^| )cli=(?<v>[^ ]*)")][0].v)}
       | select(.c != null and (.c | lacks)) | .b]
    + (if $hc != "?" and ($hc | lacks) then [$here] else [] end)' <<<"${1:-{\}}" 2>/dev/null || echo '[]'
}

# spl_box_pick_decide TARGET STATS SEED SINCE [OVERFLOW] [HEALTH] [CI] [CICNF] [NOKIND] [KIND] [QUOTA] [WKMAX] [CORDON]
# -> the band line, one line per box in fill order, a WARN per box with no
# sample, then the pick line. HEALTH is spl_box_health_verdicts' object: a
# "degraded" box is left out of the pick unless every box with a sample is. CI
# is {"<box>": jobs} (spl_box_ci_from_rows), CICNF spl_box_ci_cnf's settings:
# a box with jobs > 0 gets the lower band, and at or over max_agents live
# agents (its sample's agents_live) it is left out of the pick. NOKIND
# (spl_box_pick_nokind) lists the boxes without KIND's CLI: never picked.
# QUOTA ({"<box>": pct}, spl_box_pick_quota) at or over WKMAX: never picked.
# CORDON ({"<box>": until_epoch}, spl_box_cordon_active): never picked, before
# the every-box-degraded fallback, so the fallback cannot take it either.
spl_box_pick_decide() {
  jq -r --argjson seed "$3" --arg since "$4" --argjson over "${5:-200}" --argjson hl "${6:-{\}}" \
    --argjson ci "${7:-{\}}" --argjson cc "${8:-{\"max_agents\":12,\"low\":25,\"high\":50\}}" \
    --argjson nk "${9:-[]}" --arg kind "${10:-}" --argjson wq "${11:-{\}}" --argjson wmax "${12:-90}" \
    --argjson cd "${13:-{\}}" \
    --slurpfile st <(printf '%s' "$2") '
    . as $t
    | (if ($t.box_order | length) > 0 then {o: $t.box_order, src: "hub"} else {o: $seed, src: "cnf seed"} end) as $ord
    | ($st[0].rows | group_by(.box) | map(max_by(.at)) | map({key: .box, value: .}) | from_entries) as $last
    | ($ord.o + (($last | keys) - $ord.o | sort)) as $boxes
    | [$boxes[] as $b | ($last[$b]) as $r
        | (($t.boxes // {})[$b]) as $own
        | (if $own != null then {low: $own.low, high: $own.high, src: "box"} else {low: $t.low, high: $t.high, src: "fleet"} end) as $b0
        | ($ci[$b] // 0) as $jobs
        | (if $jobs > 0 then {low: ([$b0.low, $cc.low] | min), high: ([$b0.high, $cc.high] | min), src: "\($b0.src), ci busy"} else $b0 end) as $band
        | if $r == null or ($r.cpus // 0) < 1 then {box: $b, miss: true}
          else ($r.load5 * 100 / $r.cpus) as $p
          | {box: $b, load5: $r.load5, cpus: $r.cpus, pct: $p, at: $r.at, band: $band,
             state: (if $p >= $band.high then "full" elif $p >= $band.low then "in band" else "under" end),
             cord: ($cd[$b] != null), until: $cd[$b],
             sick: ($hl[$b].state == "degraded"), why: ($hl[$b].why // ""),
             jobs: $jobs, agents: $r.agents_live, capped: ($jobs > 0 and ($r.agents_live // 0) >= $cc.max_agents),
             nokind: ($nk | index($b) != null), wk: $wq[$b],
             wkover: ($kind != "" and $wq[$b] != null and $wq[$b] >= $wmax)}
          end] as $rows
    | ([$rows[] | select(.miss | not)]) as $all
    | [$all[] | select(.cord | not)] as $open
    | ([$open[] | select(.sick | not)] | if length == 0 then $open else . end | map(select(.capped | not))) as $seen0
    | [$seen0[] | select(.nokind | not)] as $kinded
    | [$kinded[] | select(.wkover | not)] as $seen
    | ((first($seen[] | select(.pct < .band.low)) | . + {why: "low"})
       // (first($seen[] | select(.pct < .band.high)) | . + {why: "high"})
       // ([$seen[] | select(.pct < .band.high * $over / 100)] | min_by(.pct / .band.high) | if . == null then null else . + {why: "over"} end)
       // null) as $pick
    | "fleet load target: \($t.low)..\($t.high) % of cores (source \($t.source // "hub")), \(($t.boxes // {}) | length) per-box band(s), order \($boxes | join(" ")) (\($ord.src)), samples \($since)",
      ($rows[] | if .miss then "WARN box \(.box): no load sample in the last \($since), skipped"
        else "BOX \(.box)  load5 \(.load5)  cpus \(.cpus)  \(.pct | floor)%  \(.state)  band \(.band.low)..\(.band.high) (\(.band.src))\(if .cord then "  CORDONED (until \(.until | todate))" else "" end)\(if .sick then "  DEGRADED (\(.why))" else "" end)\(if .jobs > 0 then "  ci busy: \(.jobs) jobs, cap \($cc.max_agents) (agents \(.agents // "?"))\(if .capped then ", AT CAP: not picked" else "" end)" else "" end)\(if .nokind then "  no \($kind) CLI: not picked" else "" end)\(
          if $kind == "" or .nokind then "" elif .wk == null then "  \($kind) weekly unknown" elif .wkover then "  \($kind) weekly \(.wk)% >= \($wmax)%: not picked" else "  \($kind) weekly \(.wk)%" end)\(if $pick != null and .box == $pick.box then "  <- pick" else "" end)" end),
      (if ($open | length) > 0 and all($open[]; .sick) then "WARN every box with a load sample is degraded: the pick ignores the beats" else empty end),
      (if $pick != null and $kind != "" and $pick.wk == null then "INFO \($pick.box): \($kind) weekly usage unknown (no banner read, or its BOX-0 row is an hour old): placed anyway" else empty end),
      (if $pick == null and ($all | length) > 0 and ($open | length) == 0 then
         "pick=hold reason=every box with a sample is CORDONED (\([$all[].box] | join(" "))): queue the lane, spawn nothing"
       elif $pick == null and ($seen0 | length) > 0 and ($kinded | length) == 0 then
         "pick=nokind reason=no box with room has a \($kind) CLI for the agent user (measured without it: \($nk | join(" "))): spawn nothing"
       elif $pick == null and ($kinded | length) > 0 and ($seen | length) == 0 then
         "pick=hold reason=waiting: \($kind) weekly >= \($wmax)% on \([$kinded[].box] | join(", ")): queue the lane, spawn nothing"
       elif $pick == null then
         "pick=hold reason=no box with a sample is below its overflow mark (\($over)% of its high)\(if any($all[]; .capped) then " or under its CI-busy agent cap" else "" end): queue the lane, spawn nothing"
       elif $pick.why == "over" then
         "pick=\($pick.box) reason=every box is at or above its high mark; \($pick.box) is the least past its band (\($pick.pct | floor)% on high \($pick.band.high)%, overflow \($pick.band.high * $over / 100 | floor)%)"
       elif $pick.why == "low" then
         "pick=\($pick.box) reason=\($pick.box) is the first box in order below its low mark (\($pick.pct | floor)% < \($pick.band.low)%)"
       else
         "pick=\($pick.box) reason=\($pick.box) is the first box in order below its high mark (\($pick.pct | floor)% < \($pick.band.high)%), every box is at or above its low mark"
       end)' <<<"$1"
}
