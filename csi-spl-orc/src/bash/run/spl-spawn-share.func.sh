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
# @description Bands by phase (spec 166 row B2; owner HUM-10, t1 c0b0d572 msg
# @description 421e479a, poll d102c775 Q2 B): do_spl_rhythm_phase says day or
# @description night, and the live lanes are judged against that phase's bands
# @description (SPL_SPAWN_BANDS_DAY / _NIGHT). Every computed share is also a
# @description sample in <asks dir>/share.24h.tsv (at most one per
# @description SPAWN_SHARE_SAMPLE_MIN); the report prints the last 24 h share of
# @description those samples against the owner's 24 h bands (SPL_SPAWN_BANDS).
# @description At night a refactor or bug class whose 24 h share has reached its
# @description 24 h top is marked capped: the placer stops preferring it.
# @param SPAWN_SHARE_FORMAT (optional) - md (default), line (one line, the GC summary's) or json
# @param SPAWN_SHARE_SAMPLE_MIN (optional) - minutes between two 24 h samples, default 10
# @param RHYTHM_NOW RHYTHM_CNF (optional) - as do_spl_rhythm_phase (the phase, and the samples' clock)
# @param SPAWN_SHARE_BANDS (optional, tests) - one bands JSON for every phase, in place of SPL_SPAWN_BANDS_DAY / _NIGHT
# @param SPAWN_SHARE_LANES_CMD (optional, tests) - prints the lane map's JSON ({lanes: [...]}) instead of do_spl_lane_map
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_spawn_share
# @example SPAWN_SHARE_FORMAT=json ./run -a do_spl_spawn_share

# The bands: class lower upper (percent of the known live lanes). The rule's
# one home is fleet-rules-index.md; these numbers are its code.
# SPL_SPAWN_BANDS is the owner's 24 h band (msg 8cb6cc7d); the live lanes are
# judged against the phase's band (spec 166 section 3.1).
SPL_SPAWN_BANDS='{"refactor": [20, 30], "bug": [20, 30], "feature": [40, 100]}'
SPL_SPAWN_BANDS_DAY='{"refactor": [10, 20], "bug": [15, 20], "feature": [60, 100]}'
SPL_SPAWN_BANDS_NIGHT='{"refactor": [40, 60], "bug": [30, 40], "feature": [0, 100]}'

declare -F do_spl_rhythm_phase >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rhythm-phase.func.sh"

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
# The inputs go to jq as files, never as arguments: the hub's asks list (all
# states, a week of closed rows) is far over one argument's size limit
# (MAX_ARG_STRLEN, 128 KiB; 779 KB on sat 2026-10-14, "Argument list too long").
spl_spawn_share() {
  local lanes tmpdir rc=0
  lanes="$(spl_spawn_share_lanes)" || return 1
  tmpdir="$(mktemp -d)" || return 1
  printf '%s' "$lanes" >"$tmpdir/lanes.json" || rc=1
  ((rc == 0)) && { spl_asks_hub list --fleet "$LANE_FLEET" --role orch --all >"$tmpdir/asks.json" 2>"${ASKS_ERR:-/dev/null}" || rc=1; }
  ((rc == 0)) && { spl_spawn_share_briefs "$lanes" >"$tmpdir/briefs.json" || rc=1; }
  ((rc == 0)) && { spl_spawn_share_bypass_log >"$tmpdir/log.json" || rc=1; }
  ((rc == 0)) && { spl_spawn_share_jq "$tmpdir" >"$tmpdir/share.json"; rc=$?; }
  ((rc == 0)) && { spl_spawn_share_sample "$tmpdir/share.json"; cat "$tmpdir/share.json"; }
  rm -rf "$tmpdir"
  return "$rc"
}

# The phase (do_spl_rhythm_phase) and its bands: "<day|night> <bands JSON>".
# A phase that cannot be read is day, with a WARN.
spl_spawn_share_phase() {
  local p b
  p="$(do_spl_rhythm_phase 2>/dev/null)"
  [[ "$p" == day || "$p" == night ]] || { do_log "WARN the rhythm phase could not be read: the day bands" >&2; p=day; }
  if [[ "$p" == night ]]; then b="$SPL_SPAWN_BANDS_NIGHT"; else b="$SPL_SPAWN_BANDS_DAY"; fi
  printf '%s %s' "$p" "$(jq -c . <<<"${SPAWN_SHARE_BANDS:-$b}")"
}

# The samples' clock, epoch seconds (RHYTHM_NOW in tests).
spl_spawn_share_now() {
  date -d "${RHYTHM_NOW:-now}" +%s 2>/dev/null || date +%s
}

# The 24 h samples as JSON [{t, phase, known, refactor, bug, feature}], the
# 24 h up to now only.
spl_spawn_share_hist() {
  local f now
  f="$(spool_asks_dir)/share.24h.tsv"; now="$(spl_spawn_share_now)"
  [[ -s "$f" ]] || { printf '[]'; return 0; }
  jq -R -s -c --argjson since "$((now - 86400))" --argjson now "$now" '[split("\n")[] | select(length > 0) | split("\t")
    | select(length == 6 and (.[0] | test("^[0-9]+$")))
    | {t: (.[0] | tonumber), phase: .[1], known: (.[2] | tonumber),
       refactor: (.[3] | tonumber), bug: (.[4] | tonumber), feature: (.[5] | tonumber)}
    | select(.t > $since and .t <= $now)]' "$f"
}

# Appends the share in FILE to the 24 h samples when the last sample is
# SPAWN_SHARE_SAMPLE_MIN old or more and the share has lanes with a class;
# keeps the last 24 h. A sample that cannot be written is skipped.
spl_spawn_share_sample() {  # SHARE_FILE
  local f now line
  spl_spawn_share_sample_due || return 0
  f="$(spool_asks_dir)/share.24h.tsv" || return 0
  now="$(spl_spawn_share_now)"
  line="$(jq -r --arg t "$now" 'select(.known > 0)
    | [$t, .phase, .known, .by.refactor.n, .by.bug.n, .by.feature.n] | map(tostring) | join("\t")' "$1" 2>/dev/null)"
  [[ -n "$line" ]] || return 0
  if { awk -F'\t' -v s="$((now - 86400))" '$1 > s' "$f" 2>/dev/null; printf '%s\n' "$line"; } >"$f.$$"; then
    mv -f "$f.$$" "$f"
  else rm -f "$f.$$"; fi
  return 0
}

# 0 when the last 24 h sample is SPAWN_SHARE_SAMPLE_MIN old or more (or none).
spl_spawn_share_sample_due() {
  local last
  last="$(tail -1 "$(spool_asks_dir)/share.24h.tsv" 2>/dev/null | cut -f1)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( $(spl_spawn_share_now) - last >= ${SPAWN_SHARE_SAMPLE_MIN:-10} * 60 ))
}

# The share from the input files in DIR (lanes, asks, briefs, log .json; the
# 24 h samples hist.json, read here when absent).
spl_spawn_share_jq() {  # DIR
  local phase bands
  read -r phase bands < <(spl_spawn_share_phase)
  [[ -s "$1/hist.json" ]] || spl_spawn_share_hist >"$1/hist.json" || printf '[]' >"$1/hist.json"
  jq -e -c -n --slurpfile lanes "$1/lanes.json" --slurpfile asks "$1/asks.json" --argjson bands "$bands" \
    --arg phase "$phase" --argjson owner "$SPL_SPAWN_BANDS" --slurpfile hist "$1/hist.json" \
    --slurpfile briefs "$1/briefs.json" --slurpfile log "$1/log.json" '
    def cls: if . == "ci" then "bug" else . end;
    def verdict($none; $p; $b): if $none then "no data" elif $p < $b[0] then "UNDER" elif $p > $b[1] then "OVER" else "ok" end;
    $lanes[0] as $lanes | $asks[0] as $asks | $briefs[0] as $briefs | $log[0] as $log | $hist[0] as $hist
    | ($hist | map(.known) | add // 0) as $hk
    | {samples: ($hist | length), by: ($owner | with_entries(.key as $c | .value as $b
        | (if $hk > 0 then (($hist | map(.[$c]) | add) * 100 / $hk | floor) else null end) as $p
        | .value = {pct: $p, lo: $b[0], hi: $b[1], verdict: verdict($hk == 0; $p; $b)}))} as $h24
    | ([$asks.asks[] | select(.state == "done" and ((.reason // "") | test("^placed: ")) and (.class // "") != "")
      | {key: (.reason | sub("^placed: "; "") | split(" ")[0]), value: (.class | cls)}] | from_entries) as $placed
    | [$lanes[] | (.agent_id + "@" + .agent_box) as $id
       | {id: $id, class: ($placed[$id] // ($briefs[$id] // "" | cls) | if . == "" then "unknown" else . end)}] as $l
    | ([$l[] | select(.class != "unknown")] | length) as $known
    | {phase: $phase, known: $known, unknown: ([$l[] | select(.class == "unknown")] | length), lanes: $l, h24: $h24,
       by: ($bands | with_entries(.key as $c | .value as $b
            | ([$l[] | select(.class == $c)] | length) as $n
            | (if $known > 0 then ($n * 100 / $known | floor) else 0 end) as $p
            | .value = {n: $n, pct: $p, lo: $b[0], hi: $b[1], verdict: verdict($known == 0; $p; $b),
                capped: ($phase == "night" and $c != "feature" and ($h24.by[$c].pct // -1) >= $h24.by[$c].hi)})),
       bypasses: ([$asks.asks[] | select((.flag // "") == "bypass")
                   | {ask: .ask_id, msg: .flag_msg, by: .flag_by, at: .flag_at, state: .state,
                      lane: (if .state == "done" then (.reason // "" | sub("^placed: "; "")) else "" end), summary: .summary}]
                  + [$log[] | .ask as $a | ([$asks.asks[] | select(.ask_id == $a)] | .[0]) as $h
                     | select(($h.flag // "") != "bypass")
                     | if $h then . + {state: $h.state, lane: (if $h.state == "done" then ($h.reason // "" | sub("^placed: "; "")) else "" end)} else . end]
                  | sort_by(.at))}'
}

# The live lanes of the fleet map as a JSON array ({agent_id, agent_box}),
# by the lane map's own recent rule (spl_lane_table_recent, SPL-2836): a row
# 0..LANE_RECENT_S (2 h) old, a live role seat (no Class: brief, so it only
# adds to unknown), or a row with no age while the input's .hub is not ok (a
# missing .hub reads as not ok). Hub rows nobody refreshed for days and
# leftover local worktrees are not live lanes.
spl_spawn_share_lanes() {
  local out
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  if [[ -n "${SPAWN_SHARE_LANES_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_SHARE_LANES_CMD 2>/dev/null)"
  else
    out="$(LANE_FORMAT=json LANE_ALL=1 timeout "${SPAWN_SHARE_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1)"
  fi
  jq -e -c --argjson max "${LANE_RECENT_S:-7200}" --arg seat "^${SPL_ROLE_SEAT_RX}$" '
    (.hub // "") as $h
    | [.lanes[] | select(.state == "live" and (.agent_id // "") != "")
       | select((.agent_id | test($seat)) or (.age_s >= 0 and .age_s < $max) or (.age_s < 0 and $h != "ok"))
       | {agent_id, agent_box}]' <<<"$out" 2>/dev/null
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
    + ([.by | to_entries[] | "\(.key) \(.value.n) \(.value.pct)% (band \(.value.lo)-\(if .value.hi >= 100 then "" else "\(.value.hi)" end)%: \(.value.verdict)\(if .value.capped then ", 24 h top reached" else "" end))"] | join(", "))
    + "; \(.bypasses | length) bypass(es)"
    + (if .phase then "; phase \(.phase); last 24 h (\(.h24.samples) sample(s)): "
         + ([.h24.by | to_entries[] | "\(.key) \(if .value.pct == null then "-" else "\(.value.pct)%" end) (band \(.value.lo)-\(if .value.hi >= 100 then "" else "\(.value.hi)" end)%: \(.value.verdict))"] | join(", "))
       else "" end)' <<<"$1"
}

# The owner's report, markdown (how-to-post.md: no fence).
spl_spawn_share_md() {  # SHARE
  jq -r '
    def band: "\(.lo)-\(if .hi >= 100 then "" else "\(.hi)" end)%";
    "**Work share of the live lanes** (\(.known) with a class, \(.unknown) placed before the class existed, left out; phase **\(.phase // "day")**, its bands; rule: fleet-rules-index.md, owner msg 8cb6cc7d, spec 166)\n",
    "| class | live lanes | share | band | verdict |", "|---|---|---|---|---|",
    (.by | to_entries[] | "| \(.key) | \(.value.n) | \(.value.pct)% | \(.value | band) | \(.value.verdict)\(if .value.capped then ", 24 h top reached: not preferred tonight" else "" end) |"),
    "",
    (if .h24 then "**Last 24 h** (\(.h24.samples) sample(s) of the live share, against the owner'"'"'s 24 h bands):\n",
      "| class | 24 h share | band | verdict |", "|---|---|---|---|",
      (.h24.by | to_entries[] | "| \(.key) | \(if .value.pct == null then "-" else "\(.value.pct)%" end) | \(.value | band) | \(.value.verdict) |"), ""
     else empty end),
    (if .unknown == 0 then "**No class:** none." else "**No class** (placed before the class existed, or outside the queue: an unrecorded placement once the old lanes are gone): \([.lanes[] | select(.class == "unknown") | .id] | join(", "))." end),
    "",
    (if (.bypasses | length) == 0 then "**Bypasses:** none recorded."
     else "**Bypasses** (a feature placed outside the bands, only on the owner'"'"'s explicit ask):\n",
          "| owner msg | ask | lane | set by | when |", "|---|---|---|---|---|",
          (.bypasses[] | "| \(.msg[0:8]) | \(.ask[0:8]) | \(if .lane == "" then .state else .lane end) | \(.by) | \(.at) |")
     end)' <<<"$1"
}
