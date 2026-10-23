#!/bin/bash
#------------------------------------------------------------------------------
# Weekly quota (SPL-2035, c-001 spawn-share msg 46b6330a): the box pick
# placed three claude lanes on a box whose agent user's claude login was at
# 95-96 % of its weekly limit (the GC report of 2026-10-15T18:00Z); a lane that hits the
# limit mid-task stalls with a half-done worktree. So a new lane skips a box
# whose usage for the lane's vendor is at or over a threshold:
#   - the number is the one the GC report reads, the vendor's own banner in
#     the agent panes: claude "You've used 96% of your weekly limit · resets
#     Oct 17, 11am (Europe/Helsinki)" ("hit your weekly limit" = 100), grok
#     "Weekly limit left: 4%" (= 96 used), or grok's limit screen, which
#     draws no footer: "You hit your weekly limit." framed by its "┃" (= 100;
#     the newer of footer and screen wins). No new probe: the box reads the
#     footer (last 12 lines) of its agent panes (c- claude, g- grok), keeps the
#     highest reading per vendor; a claude reading whose reset time has
#     passed says nothing (spl_box_quota_parse);
#   - it tells the fleet: spl_lane_box_report puts wk=<vendor>:<pct>,... into
#     its BOX-0 row scope (every LANE_BOX_ROW_S, 300 s);
#   - do_spl_box_pick reads it (spl_box_quota_from_rows; its own box live)
#     and, for BOX_PICK_KIND, never picks a box at or over weekly_max_pct.
#     Every box with room over it -> pick=hold "waiting: <kind> weekly >= N%
#     on <boxes>" (the lane stays queued, no fallback). No reading (no
#     banner, the probe failed, a BOX-0 row LANE_BOX_ROW_MAX_S = 1 h old or
#     older) is UNKNOWN, never 0: the box stays in and the pick says so.
# Settings: cnf env.box.quota.weekly_max_pct, env BOX_QUOTA_WEEKLY_MAX_PCT
# overrides, default 90.
#------------------------------------------------------------------------------

# spl_box_quota_parse VENDOR [NOW]: a pane's footer on stdin -> the used % of
# VENDOR's weekly limit from its newest banner line, or nothing. The claude
# banner starts its line: an agent quoting it mid-sentence is no reading.
spl_box_quota_parse() {
  local now="${2:-$(date +%s)}" line pct when tz at
  case "$1" in
    claude)
      line="$(grep -E "^[[:space:]]*(⎿[[:space:]]+)?You('ve| have) (used [0-9]{1,3}% of|hit) your weekly limit( |$)" | tail -1)"
      [[ -n "$line" ]] || return 0
      if [[ "$line" =~ used\ ([0-9]{1,3})% ]]; then pct="${BASH_REMATCH[1]}"; else pct=100; fi
      if [[ "$line" =~ resets\ ([A-Za-z0-9\ ,:]*[a-z0-9])(\ \(([A-Za-z_/+-]+)\))? ]]; then
        when="${BASH_REMATCH[1]//,/}" tz="${BASH_REMATCH[3]:-UTC}"
        at="$(TZ="$tz" date -d "$when" +%s 2>/dev/null)"
        # a time alone ("resets 8pm") is the next one; a date in the past: reset, stale
        [[ "$when" =~ ^[0-9] && "$at" =~ ^[0-9]+$ ]] && (( at <= now )) && at=$(( at + 86400 ))
        [[ "$at" =~ ^[0-9]+$ ]] && (( at <= now )) && return 0
      fi ;;
    grok)
      # start-check's grok pattern starts its line (after the frame): a quote
      # mid-sentence is no reading, nor is a bare "weekly limit"
      line="$(grep -oE 'Weekly limit left: [0-9]{1,3}%|^[[:space:]]*(┃[[:space:]]*)?[Yy]ou hit your weekly limit' | tail -1)"
      [[ -n "$line" ]] || return 0
      if [[ "$line" =~ left:\ ([0-9]{1,3})% ]]; then pct=$(( 100 - BASH_REMATCH[1] )); else pct=100; fi ;;
    *) return 0 ;;
  esac
  (( pct > 100 )) && pct=100
  echo "$pct"
}

# spl_box_quota_log_scan DIR MIN: the claude CLI's own record of the limit
# (SPL-2196). The banner shows only on the turn that failed: a rotated or
# idle seat shows none, and a box at its limit read unknown (c-001 msg
# 5c025d6e; 16 claude panes, no banner: msg 414e2481). The CLI
# also writes it into the session transcript as a "<synthetic>" assistant
# entry. Prints the newest such "You've hit your weekly limit · resets ..."
# text in DIR's transcripts of the last MIN minutes, or nothing when a real
# model answer is newer (the limit was lifted). Runs as the agent user
# (spl_box_quota_log).
spl_box_quota_log_scan() {
  local d="$1" min="$2" last ts
  [ -d "$d" ] || return 0
  last="$(find "$d" -name '*.jsonl' -mmin "-$min" -print0 2>/dev/null | xargs -0 -r grep -h -F 'hit your weekly limit' 2>/dev/null |
    grep -F '"model":"<synthetic>"' | jq -r 'select(.type == "assistant")
      | "\(.timestamp)\t\(.message.content[0].text // "" | split("\n")[0])"' 2>/dev/null | sort | tail -n 1)"
  [ -n "$last" ] || return 0
  ts="${last%%$'\t'*}"
  find "$d" -name '*.jsonl' -newermt "$ts" -print0 2>/dev/null | xargs -0 -r grep -h -F '"type":"assistant"' 2>/dev/null |
    grep -v -F '"model":"<synthetic>"' | grep -oE '"timestamp":"[^"]+"' | cut -d'"' -f4 |
    awk -v t="$ts" '$0 > t { f = 1 } END { exit !f }' && return 0
  printf '%s\n' "${last#*$'\t'}"
}

# spl_box_quota_log [NOW]: claude's weekly usage from the agent user's
# transcripts (spl_box_quota_log_scan, then spl_box_quota_parse): 100 until
# the reset time, or nothing. LANE_QUOTA_LOG_MIN (default 1440) bounds the
# scan. Seam (tests): LANE_QUOTA_LOG_DIR scans that dir as this user; a test
# that fakes the panes (LANE_PANES_CMD) without it reads nothing.
spl_box_quota_log() {
  local now="${1:-$(date +%s)}" min="${LANE_QUOTA_LOG_MIN:-1440}"
  [[ "$min" =~ ^[0-9]+$ ]] || min=1440
  if [[ -n "${LANE_QUOTA_LOG_DIR:-}" ]]; then
    spl_box_quota_log_scan "$LANE_QUOTA_LOG_DIR" "$min" | spl_box_quota_parse claude "$now"; return 0
  fi
  [[ -z "${LANE_PANES_CMD:-}" ]] || return 0
  declare -F spool_agent_exec >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  (
    [ -n "${SPOOL_AGENT_USER:-}" ] || SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
    SPOOL_RUN_AS_AGENT="${SPOOL_RUN_AS_AGENT:-su-dash}"
    spool_agent_exec "$(declare -f spl_box_quota_log_scan); spl_box_quota_log_scan \"\$HOME/.claude/projects\" $min" </dev/null 2>/dev/null
  ) | spl_box_quota_parse claude "$now"
}

# spl_box_quota_here: THIS box's weekly usage, "claude:96,grok:4" (the
# vendors read), "" when nothing shows one. Reads the box user's tmux
# (spl_lane_tm) and claude's transcripts (spl_box_quota_log): the higher
# claude reading wins. Seam (tests): LANE_QUOTA_CMD prints the answer; a
# test that fakes the panes (LANE_PANES_CMD) reads only LANE_QUOTA_LOG_DIR.
spl_box_quota_here() {
  if [[ -n "${LANE_QUOTA_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LANE_QUOTA_CMD 2>/dev/null; return 0
  fi
  local now dead pane name id v pct out="" log
  local -A best=()
  now="$(date +%s)"
  log="$(spl_box_quota_log "$now")"
  [[ "$log" =~ ^[0-9]+$ ]] && best[claude]="$log"
  if [[ -n "${LANE_PANES_CMD:-}" ]]; then echo "${best[claude]:+claude:${best[claude]}}"; return 0; fi
  declare -F spool_id_of_window_var >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  spl_lane_tm
  while read -r dead pane name; do
    [[ "$dead" == 0 ]] || continue
    spool_id_of_window_var id "$name"
    case "$id" in c-*|CLE-*) v=claude ;; g-*|GRK-*) v=grok ;; *) continue ;; esac
    pct="$(timeout 5 "${LANE_TM[@]}" capture-pane -p -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 12 | spl_box_quota_parse "$v" "$now")"
    [[ "$pct" =~ ^[0-9]+$ ]] && (( pct > ${best[$v]:--1} )) && best[$v]="$pct"
  done < <(timeout 10 "${LANE_TM[@]}" list-panes -a -F '#{pane_dead} #{pane_id} #{window_name}' 2>/dev/null)
  for v in "${!best[@]}"; do out+="${out:+,}$v:${best[$v]}"; done
  echo "$out"
}

# spl_box_quota_max [CNF]: the threshold, a whole % (default 90).
spl_box_quota_max() {
  local v="${BOX_QUOTA_WEEKLY_MAX_PCT:-}"
  [[ -z "$v" && -r "${1:-}" ]] && command -v yq >/dev/null && v="$(yq '.env.box.quota.weekly_max_pct // ""' "$1" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=90
  echo "$v"
}

# spl_box_quota_from_rows LANES_JSON ROW_ID MAX_AGE_S KIND [HERE HERE_WK]:
# KIND's weekly usage per box as {"<box>": pct}, from each box's freshest
# BOX-0 row (live, younger than MAX_AGE_S) scope field wk=; HERE_WK (this
# box's spl_box_quota_here) replaces this box's row. A box without a reading
# is absent: unknown.
spl_box_quota_from_rows() {
  jq -c --arg id "$2" --argjson max "$3" --arg k "$4" --arg here "${5:-}" --arg hw "${6:-}" '
    def pct: split(",") | map(capture("^(?<v>[a-z]+):(?<p>[0-9]{1,3})$")) | map(select(.v == $k))[0].p // null
      | if . == null then null else tonumber end;
    [(.lanes // [])[] | select(.agent_id == $id and .state == "live" and (.age_s // -1) >= 0 and .age_s < $max)]
    | group_by(.agent_box) | map(min_by(.age_s))
    | map({key: .agent_box, value: ((.scope // "") | [capture("(^| )wk=(?<w>[^ ]*)")][0].w // "" | pct)})
    | from_entries
    | if $here != "" then .[$here] = ($hw | pct) else . end
    | with_entries(select(.value != null))' <<<"${1:-{\}}" 2>/dev/null || echo '{}'
}
