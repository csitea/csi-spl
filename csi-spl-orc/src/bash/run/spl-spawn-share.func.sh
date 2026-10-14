#!/bin/bash
# @description The share of the live lanes per work class, against the owner's
# @description bands (SPL-1817; owner HUM-10 t1 3209f8b8, binding msg
# @description 8cb6cc7d: "20% to 30% refactoring, 20% to 30% bug fixing ...
# @description the rest will be new feature implementation ... You have to keep
# @description track for me"). The rule's one home is
# @description csi-spl-doc/doc/md/fleet-rules-index.md. Prints a markdown report
# @description the dispatcher posts for the owner: the live lanes by class with
# @description their %, the band verdict per class, the lanes whose class is
# @description unknown (placed before the class existed: left out of the
# @description denominator), and every recorded feature bypass (the owner msg
# @description id, the ask, the lane, who set it, when).
# @description A live lane's class: its spawn-queue row (closed "placed:
# @description <ID>@<box>", the hub keeps it a week), else a `Class: <class>`
# @description line in its brief (<spool root>/<ID>/lifetime/brief.md, this
# @description box only). ci (a CI-red fix on trunk) counts as bug.
# @param SPAWN_SHARE_FORMAT (optional) - md (default), line (one line, the GC summary's) or json
# @param SPAWN_SHARE_LANES_CMD (optional, tests) - prints the lane map's JSON ({lanes: [...]}) instead of do_spl_lane_map
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_spawn_share
# @example SPAWN_SHARE_FORMAT=json ./run -a do_spl_spawn_share

# The bands: class lower upper (percent of the known live lanes). The rule's
# one home is fleet-rules-index.md; these numbers are its code.
SPL_SPAWN_BANDS='{"refactor": [20, 30], "bug": [20, 30], "feature": [40, 100]}'

do_spl_spawn_share() {
  local fmt="${SPAWN_SHARE_FORMAT:-md}" share
  [[ "$fmt" =~ ^(md|line|json)$ ]] || { do_log "FATAL SPAWN_SHARE_FORMAT must be md, line or json"; return 1; }
  spl_spawn_q_init || return 1
  share="$(spl_spawn_share)" || { do_log "FATAL the live share could not be read (hub or lane map)"; return 1; }
  if [[ "$fmt" == json ]]; then printf '%s\n' "$share"; return 0; fi
  if [[ "$fmt" == line ]]; then spl_spawn_share_line "$share"; return 0; fi
  spl_spawn_share_md "$share"
}

# The share as JSON: {known, unknown, by: {refactor|bug|feature: {n, pct,
# lo, hi, verdict}}, lanes: [{id, class}], bypasses: [...]}.
spl_spawn_share() {
  local lanes asks
  lanes="$(spl_spawn_share_lanes)" || return 1
  asks="$(spl_asks_hub list --fleet "$LANE_FLEET" --role orch --all 2>"${ASKS_ERR:-/dev/null}")" || return 1
  jq -e -c -n --argjson lanes "$lanes" --argjson asks "$asks" --argjson bands "$SPL_SPAWN_BANDS" \
    --argjson briefs "$(spl_spawn_share_briefs "$lanes")" --argjson log "$(spl_spawn_share_bypass_log)" '
    def cls: if . == "ci" then "bug" else . end;
    ([$asks.asks[] | select(.state == "done" and ((.reason // "") | test("^placed: ")) and (.class // "") != "")
      | {key: (.reason | sub("^placed: "; "") | split(" ")[0]), value: (.class | cls)}] | from_entries) as $placed
    | [$lanes[] | (.agent_id + "@" + .agent_box) as $id
       | {id: $id, class: ($placed[$id] // ($briefs[$id] // "" | cls) | if . == "" then "unknown" else . end)}] as $l
    | ([$l[] | select(.class != "unknown")] | length) as $known
    | {known: $known, unknown: ([$l[] | select(.class == "unknown")] | length), lanes: $l,
       by: ($bands | with_entries(.key as $c | .value as $b
            | ([$l[] | select(.class == $c)] | length) as $n
            | (if $known > 0 then ($n * 100 / $known | floor) else 0 end) as $p
            | .value = {n: $n, pct: $p, lo: $b[0], hi: $b[1],
                verdict: (if $known == 0 then "no data" elif $p < $b[0] then "UNDER" elif $p > $b[1] then "OVER" else "ok" end)})),
       bypasses: ([$asks.asks[] | select((.flag // "") == "bypass")
                   | {ask: .ask_id, msg: .flag_msg, by: .flag_by, at: .flag_at, state: .state,
                      lane: (if .state == "done" then (.reason // "" | sub("^placed: "; "")) else "" end), summary: .summary}]
                  + [$log[] | select(.ask as $a | [$asks.asks[] | .ask_id] | index($a) | not)]
                  | sort_by(.at))}'
}

# The live lanes of the fleet map as a JSON array ({agent_id, agent_box}).
spl_spawn_share_lanes() {
  local out
  if [[ -n "${SPAWN_SHARE_LANES_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_SHARE_LANES_CMD 2>/dev/null)"
  else
    out="$(LANE_FORMAT=json LANE_ALL=1 timeout "${SPAWN_SHARE_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1)"
  fi
  jq -e -c '[.lanes[] | select(.state == "live" and (.agent_id // "") != "") | {agent_id, agent_box}]' <<<"$out" 2>/dev/null
}

# {"<ID>@<box>": "<class>"} from the `Class:` line of the briefs on this box.
spl_spawn_share_briefs() {  # LANES
  local id c out='{}'
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    c="$(grep -m1 -oiE '^Class: *(ci|refactor|bug|feature)\b' "$SPOOL_ROOT/$id/lifetime/brief.md" 2>/dev/null | sed -E 's/^[Cc]lass: *//' | tr 'A-Z' 'a-z')"
    [[ -n "$c" ]] && out="$(jq -c --arg k "$id@$ASKS_BOX" --arg v "$c" '. + {($k): $v}' <<<"$out")"
  done < <(jq -r --arg b "$ASKS_BOX" '.[] | select(.agent_box == $b) | .agent_id' <<<"$1")
  printf '%s' "$out"
}

# The local bypass log (it outlives the hub's week of closed rows) as JSON.
spl_spawn_share_bypass_log() {
  local f
  f="$(spool_asks_dir)/bypass.tsv"
  [[ -s "$f" ]] || { printf '[]'; return 0; }
  jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
    | {at: .[0], ask: .[1], msg: .[2], by: .[3], state: "logged", lane: "", summary: (.[4] // "")}]' "$f"
}

# Record a bypass in the local log: AT ASK MSG BY SUMMARY.
spl_spawn_share_bypass_record() {
  local d
  d="$(spool_asks_dir)" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(tr '\t\n' '  ' <<<"$5" | cut -c1-200)" >>"$d/bypass.tsv"
}

# One line for the queue view and the logs.
spl_spawn_share_line() {  # SHARE
  jq -r '"share of \(.known) known live lanes (\(.unknown) unknown, left out): "
    + ([.by | to_entries[] | "\(.key) \(.value.n) \(.value.pct)% (band \(.value.lo)-\(if .value.hi >= 100 then "" else "\(.value.hi)" end)%: \(.value.verdict))"] | join(", "))
    + "; \(.bypasses | length) bypass(es)"' <<<"$1"
}

# The owner's report, markdown (how-to-post.md: no fence).
spl_spawn_share_md() {  # SHARE
  jq -r '
    "**Work share of the live lanes** (\(.known) with a class, \(.unknown) placed before the class existed, left out; rule: fleet-rules-index.md, owner msg 8cb6cc7d)\n",
    "| class | live lanes | share | band | verdict |", "|---|---|---|---|---|",
    (.by | to_entries[] | "| \(.key) | \(.value.n) | \(.value.pct)% | \(.value.lo)-\(if .value.hi >= 100 then "" else "\(.value.hi)" end)% | \(.value.verdict) |"),
    "",
    (if .unknown == 0 then "**No class:** none." else "**No class** (placed before the class existed, or outside the queue: an unrecorded placement once the old lanes are gone): \([.lanes[] | select(.class == "unknown") | .id] | join(", "))." end),
    "",
    (if (.bypasses | length) == 0 then "**Bypasses:** none recorded."
     else "**Bypasses** (a feature placed outside the bands, only on the owner'"'"'s explicit ask):\n",
          "| owner msg | ask | lane | set by | when |", "|---|---|---|---|---|",
          (.bypasses[] | "| \(.msg[0:8]) | \(.ask[0:8]) | \(if .lane == "" then .state else .lane end) | \(.by) | \(.at) |")
     end)' <<<"$1"
}
