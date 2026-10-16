#!/bin/bash
#------------------------------------------------------------------------------
# Box health from the hub's box beats (spec 102 10.2, rdb 0147): the simple
# load balancing of t1 3cfc236e, from the lessons of 2026-10-11 (one box's
# uplink degraded 01:50-05:20Z, 1-3 s RTT: its beats fell from 60 to 1..23 per
# 10 min while the other box held 59..62). Two readers, ONE rule:
#   - do_spl_box_pick never places a lane on a DEGRADED box;
#   - the fleet lease (spl_fleet_role_tick) ranks a degraded or RECOVERING box
#     last for both roles, and gives it its configured rank back only after
#     the hold-down.
# The rule, at a checkpoint t: the box is bad when its beats in (t - window, t]
# are under min_beat_pct % of window / beat_s, or its last beat at or before t
# is more than max_gap_s old. DEGRADED = bad now; RECOVERING = good now but bad
# at some checkpoint in the last hold (one checkpoint a minute); HEALTHY else.
# For the hold a checkpoint also covers every instant since the one before it
# (its step, 60 s, not before now - hold): it is bad when the largest gap
# ending in that span is over max_gap_s. The grid moves with "now" by seconds
# each tick; judged only AT the checkpoint, a bad stretch shorter than the
# step was hit on some ticks and missed on others, and the box flapped
# benched/back (SPL-2029: a 169.5 s gap 07:33:44-07:36:33Z 2026-10-15, bad for
# 49.5 s, 7 flips in 22 min).
# The checkpoints are "now" plus the whole minutes (epoch seconds divisible by
# 60) of the hold, not now - k * 60 (SPL-2257): with a grid that moved by
# seconds each read, a 10-min count that dipped under min_beat_pct for less
# than the step was bad on some reads and good on others, so two boxes reading
# seconds apart disagreed (prd 2026-10-16: tnk read sat recovering at
# 19:08:15Z, sat read itself healthy at 19:08:32Z and took both roles back,
# tnk took them again at 19:11:44Z) and one box's own bench flipped ("back after 30
# healthy min" 2.5 min after a bench). On whole minutes a past checkpoint is
# judged the same by every read until it leaves the hold. "healthy for" counts
# from the last bad instant: the bad checkpoint, or the end of the long gap.
# A box with no beat in the whole read (hold + window) is not judged: a box
# that does not beat (no watchdog, or a desk-only box) keeps its place.
# "now" is the newest beat in the read, the hub's own clock: every box reading
# the same beats reaches the same verdict, whatever its own clock says.
# Measured on prd box_beats 2026-10-10T00:00Z..2026-10-11T01:30Z (n = 153
# ten-minute windows per box): healthy windows held 56..62 beats, max gap
# 32 s; the 21 degraded windows 01:50..05:20Z held 1..23 beats, max gap
# 72..1301 s. So half the expected count splits them with room on both sides.
# Thresholds (cnf env.box.health, env BOX_HEALTH_<KEY> overrides, these
# defaults when neither reads): window_min 10, min_beat_pct 50 (30 of the 60
# beats expected), beat_s 10 (the watchdog tick), max_gap_s 120 (box_down_min
# 2, the fence's own limit), hold_min 30.
#------------------------------------------------------------------------------

# spl_box_health_cnf [CNF]: sets BH_WINDOW_S BH_MIN_PCT BH_BEAT_S BH_MAX_GAP_S
# BH_HOLD_S. CNF default BOX_HEALTH_CNF, else <app>/<org>-<app>-cnf/<org>-<app>/all.env.yaml.
spl_box_health_cnf() {
  local cnf="${1:-${BOX_HEALTH_CNF:-}}" k v ev
  if [[ -z "$cnf" && "$(basename "${PROJ_PATH:-}")" =~ ^([a-z]+-[a-z]+)-orc$ ]]; then
    cnf="${APP_PATH:-$(dirname "$PROJ_PATH")}/${BASH_REMATCH[1]}-cnf/${BASH_REMATCH[1]}/all.env.yaml"
  fi
  local -A def=([window_min]=10 [min_beat_pct]=50 [beat_s]=10 [max_gap_s]=120 [hold_min]=30) got=()
  for k in "${!def[@]}"; do
    ev="BOX_HEALTH_${k^^}"
    v="${!ev:-}"
    [[ -z "$v" && -r "$cnf" ]] && command -v yq >/dev/null && v="$(yq ".env.box.health.$k // \"\"" "$cnf" 2>/dev/null)"
    [[ "$v" =~ ^[0-9]+$ ]] || v="${def[$k]}"
    got[$k]="$v"
  done
  (( got[beat_s] >= 1 && got[window_min] >= 1 )) || { got[beat_s]=10; got[window_min]=10; }
  BH_WINDOW_S=$(( got[window_min] * 60 )) BH_MIN_PCT="${got[min_beat_pct]}" BH_BEAT_S="${got[beat_s]}"
  BH_MAX_GAP_S="${got[max_gap_s]}" BH_HOLD_S=$(( got[hold_min] * 60 ))
}

# The read window for spl_box_health_verdicts: hold + window, as a duration.
spl_box_health_since() { echo "$(( (BH_HOLD_S + BH_WINDOW_S) / 60 + 1 ))m"; }

# spl_box_health_verdicts BEATS_JSON [HOLD_S] -> one JSON object,
# {<box>: {state, n, need, age, why}}, from a `box-beat list` answer
# ({rows: [{box, beat_at}]}). HOLD_S default BH_HOLD_S; 0 = judge now only.
# Fails (rc 1, no output) when the answer has no rows array.
spl_box_health_verdicts() {
  jq -e 'type == "object" and (.rows | type == "array")' >/dev/null 2>&1 <<<"$1" || return 1
  jq -c --argjson w "$BH_WINDOW_S" --argjson pct "$BH_MIN_PCT" --argjson bs "$BH_BEAT_S" \
    --argjson gap "$BH_MAX_GAP_S" --argjson hold "${2:-$BH_HOLD_S}" '
    def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch null);
    ($w / $bs * $pct / 100) as $need
    | [.rows[] | select(type == "object" and (.box | type) == "string")
        | {box, t: (.beat_at | tostring | epoch)} | select(.t != null)] as $r
    | if ($r | length) == 0 then {} else
      ($r | map(.t) | max) as $now
      | $r | group_by(.box) | map({key: .[0].box, value: (map(.t) | sort)}) | from_entries
      | ($now - $hold) as $from
      | ([$now] + [range(0; ($hold / 60 | floor) + 1) | (($now / 60 | floor) - .) * 60
          | select(. >= $from and . < $now)]) as $cks
      | with_entries(.value as $ts
        | ([range(1; $ts | length) | {b: $ts[.], g: ($ts[.] - $ts[. - 1])}]) as $gaps
        | [$cks[] as $c
            | ([$ts[] | select(. > $c - $w and . <= $c)] | length) as $n
            | ([$ts[] | select(. <= $c)] | max) as $l
            | ($n < $need or $l == null or ($c - $l) > $gap) as $badat
            | ([$gaps[] | select(.b > ([$c - 60, $from] | max) and .b <= $c and .g > $gap) | .b] | max) as $sb
            | {c: $c, n: $n, age: (if $l == null then null else $c - $l end),
               badat: $badat, t: (if $badat then $c elif $sb != null then $sb else null end)}] as $cp
        | $cp[0] as $at
        | ([$cp[] | .t | select(. != null)] | max) as $lb
        | .value = {n: $at.n, need: $need, age: $at.age,
            state: (if $at.badat then "degraded" elif $lb != null then "recovering" else "healthy" end),
            why: (if $at.badat then "\($at.n) beats in \($w / 60)m < \($need), last beat \($at.age // "none")s ago (max \($gap)s)"
                  elif $lb != null then "healthy for \($now - $lb)s < hold \($hold)s"
                  else "\($at.n) beats in \($w / 60)m, last \($at.age)s ago" end)})
      end' <<<"$1"
}
