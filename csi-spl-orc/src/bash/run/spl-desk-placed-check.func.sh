#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_placed_check: a post that says a lane is "placed" is sent only once
# the fleet lane map shows that lane live (SPL-3524, fix D of
# csi-spl-doc/doc/md/grok-dispatch-grade-2026-10-25.md section 5; owner HUM-10
# picked it in t1 99ffa592, answer msg ce2045be). The grade lost points on
# lanes said placed that were then never placed: a queued ask is not a lane.
# A line of the body that says `placed` (not `not placed`, not a `>` quote,
# not inside a ``` fence) names the lane on that same line by its agent id
# (`c-123`, or `c-123@<box>`; role seats c-001..c-003 are skipped), and each
# named lane is a live row of the fleet lane map (lane-map.sh --json --all,
# every machine). Refused (FATAL, nothing sent): a placed line naming no lane,
# a lane with no live row, and a lane map that cannot be read or whose hub did
# not answer (other machines unread: not proven). The rule's one home:
# csi-spl-doc/doc/help/how-to-post.md rule 19.
# Env: SPL_DESK_LANE_MAP_CMD (tests) replaces the lane map read: a command
# that prints the lane map JSON.
#------------------------------------------------------------------------------

# spl_desk_placed_check <body>: 0 when no line says placed, or every lane the
# placed lines name is live; else one FATAL per missing lane and 1.
spl_desk_placed_check() {
  local lines ids="" id out rc=0 missing=()
  lines="$(_spl_desk_placed_lines "$1")"
  [[ -n "$lines" ]] || return 0
  _spl_desk_placed_ids "$lines" || return 1
  # shellcheck disable=SC2086 # ids is a space-separated list of agent ids
  out="$(set -o pipefail; _spl_desk_placed_map | _spl_desk_placed_missing $ids)" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL nothing was sent: the post says $ids placed, but the fleet lane map was not read from the hub (${out:-rc $rc}), so no lane is shown live. Retry, or say asked / queued until lane-map.sh shows it live (how-to-post.md rule 19)"
    return 1
  fi
  [[ -z "$out" ]] && return 0
  read -r -a missing <<<"$out"
  for id in "${missing[@]}"; do
    do_log "FATAL placed lane $id is not live: lane-map.sh --all has no live row for it"
  done
  do_log "FATAL nothing was sent: a lane is placed only once the lane map shows it live. Wait for it, or say asked / queued (how-to-post.md rule 19, SPL-3524)"
  return 1
}

# _spl_desk_placed_lines <body>: the lines that claim a placement: `placed`
# as a word, outside ``` fences and `>` quotes, once `not / never / n't`
# (with up to two words between it and `placed`) is dropped.
_spl_desk_placed_lines() {
  local line claim fence=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then fence=$((1 - fence)); continue; fi
    (( fence )) && continue
    [[ "$line" =~ ^[[:space:]]*\> ]] && continue
    claim="$(sed -E "s/(not|never|n't)( +[A-Za-z]+){0,2} +placed//Ig" <<<"$line")"
    grep -qiE '(^|[^A-Za-z])placed([^A-Za-z]|$)' <<<"$claim" && printf '%s\n' "$line"
  done <<<"$1"
  return 0
}

# _spl_desk_placed_ids <placed lines>: the lane ids they name, space-separated
# into the caller's ids (no $(...): its FATALs go to the log), role seats
# dropped; 1 with a FATAL per line that names no lane.
_spl_desk_placed_ids() {
  local line w found=() n bad=0
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  while IFS= read -r line; do
    n=0
    for w in $(grep -oE "(^|[^A-Za-z0-9-])${SPOOL_AGENT_ID_NEW_RX}(@[a-z0-9][a-z0-9-]*)?" <<<"$line" | sed -E 's/^[^a-z]//'); do
      spl_is_role_seat "$w" && continue
      [[ "${w%%@*}" == ?-000 ]] && continue
      n=$((n + 1))
      [[ " ${found[*]} " == *" $w "* ]] || found+=("$w")
    done
    (( n )) && continue
    do_log "FATAL the post says placed but names no lane on that line: '$line'"
    bad=1
  done <<<"$1"
  if (( bad )); then
    do_log "FATAL nothing was sent: name the placed lane by its agent id on the same line (c-123 or c-123@<box>), or say asked / queued (how-to-post.md rule 19, SPL-3524)"
    return 1
  fi
  ids="${found[*]}"
}

# _spl_desk_placed_map: the fleet lane map JSON with every row (lane-map.sh
# --json --all), or SPL_DESK_LANE_MAP_CMD's output.
_spl_desk_placed_map() {
  if [[ -n "${SPL_DESK_LANE_MAP_CMD:-}" ]]; then
    bash -c "$SPL_DESK_LANE_MAP_CMD"
    return
  fi
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/lane-map.sh" --json --all 2>/dev/null
}

# _spl_desk_placed_missing <id[@box]>...: reads the lane map JSON on stdin
# (stdin, never argv: the fleet map is over 128 KB, one argv word's limit) and
# prints the ids with no live row (an @box must match the row's box). 1 with
# the reason when the JSON does not parse or its hub did not answer.
_spl_desk_placed_missing() {
  python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except ValueError:
    print("the lane map is no JSON"); sys.exit(1)
if m.get("hub") != "ok":
    print("hub %r" % m.get("hub")); sys.exit(1)
live = {(r.get("agent_id"), r.get("agent_box")) for r in m.get("lanes") or [] if r.get("state") == "live"}
miss = [w for w in sys.argv[1:]
        if not any(a == w.partition("@")[0] and (not w.partition("@")[2] or b == w.partition("@")[2]) for a, b in live)]
print(" ".join(miss))' "$@"
}
