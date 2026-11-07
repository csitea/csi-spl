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
#     older with no reset ahead) is UNKNOWN, never 0: the box stays in and the
#     pick says so;
#   - a banner shows only for a moment, so every read is kept (SPL-4608,
#     spl_box_quota_keep): the pick and wk= answer from the last measured %
#     until its reset passes (spl_box_quota_known), or until a login or limit
#     change says it no longer holds (SPL-4702 and SPL-4932, spl_box_quota_keep).
# Settings: cnf env.box.quota.weekly_max_pct, env BOX_QUOTA_WEEKLY_MAX_PCT
# overrides, default 90.
#------------------------------------------------------------------------------

# spl_box_quota_reset_at WHEN TZ NOW: the banner's reset ("Oct 17 11am", or a
# time alone "8pm") as an epoch; a date with its year is read as given. The
# banner names none (SPL-4155): read as NOW's year, "resets Jan 2" on Dec 30
# was 363 days past and a box at its limit read free. A weekly reset is never
# more than a week ahead, so a date is the latest of next, this or last
# year's that is at most 8 days after NOW (Dec 30 + "Jan 2" -> next year;
# Jan 1 + "Dec 30" -> last year, stale).
spl_box_quota_reset_at() {
  local when="$1" tz="$2" now="$3" day rest y at off
  [[ "$when" =~ ^([A-Za-z]+\ [0-9]{1,2})(\ (.*))?$ ]] && day="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[3]}"
  if [[ -z "${day:-}" || "$rest" =~ ^[0-9]{4} ]]; then
    TZ="$tz" date -d "$when" +%s 2>/dev/null; return 0
  fi
  y="$(TZ="$tz" date -d "@$now" +%Y)"
  for off in 1 0 -1; do
    at="$(TZ="$tz" date -d "$day $(( y + off )) $rest" +%s 2>/dev/null)" || continue
    (( at <= now + 8 * 86400 )) && { echo "$at"; return 0; }
  done
}

# spl_box_quota_parse VENDOR [NOW]: a pane's footer on stdin -> the used % of
# VENDOR's weekly limit from its newest banner line, or nothing. The claude
# banner starts its line: an agent quoting it mid-sentence is no reading.
# BOX_QUOTA_RESET=1 (the weekly limit alert, SPL-3849) appends the reset as
# "@<epoch>" when the banner names one ("96@1760688000"); unset, the % alone.
spl_box_quota_parse() {
  local now="${2:-$(date +%s)}" line pct when tz at
  case "$1" in
    claude)
      line="$(grep -E "^[[:space:]]*(⎿[[:space:]]+)?You('ve| have) (used [0-9]{1,3}% of|hit) your weekly limit( |$)" | tail -1)"
      [[ -n "$line" ]] || return 0
      if [[ "$line" =~ used\ ([0-9]{1,3})% ]]; then pct="${BASH_REMATCH[1]}"; else pct=100; fi
      if [[ "$line" =~ resets\ ([A-Za-z0-9\ ,:]*[a-z0-9])(\ \(([A-Za-z_/+-]+)\))? ]]; then
        when="${BASH_REMATCH[1]//,/}" tz="${BASH_REMATCH[3]:-UTC}"
        at="$(spl_box_quota_reset_at "$when" "$tz" "$now")"
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
  [[ "${BOX_QUOTA_RESET:-0}" == 1 && "${at:-}" =~ ^[0-9]+$ ]] && pct+="@$at"
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
  spl_box_quota_agent_scan spl_box_quota_log_scan "$min" | spl_box_quota_parse claude "$now"
}

# spl_box_quota_agent_scan FUNC ARG: FUNC <claude projects dir> ARG, run as the
# agent user (whose transcripts they are). Seam (tests): LANE_QUOTA_LOG_DIR
# runs it on that dir as this user; a test that fakes the panes
# (LANE_PANES_CMD) or the reading (LANE_QUOTA_CMD) without it runs nothing.
spl_box_quota_agent_scan() {
  if [[ -n "${LANE_QUOTA_LOG_DIR:-}" ]]; then "$1" "$LANE_QUOTA_LOG_DIR" "$2"; return; fi
  [[ -z "${LANE_PANES_CMD:-}${LANE_QUOTA_CMD:-}" ]] || return 1
  declare -F spool_agent_exec >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  (
    [ -n "${SPOOL_AGENT_USER:-}" ] || SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
    SPOOL_RUN_AS_AGENT="${SPOOL_RUN_AS_AGENT:-su-dash}"
    spool_agent_exec "$(declare -f "$1"); $1 \"\$HOME/.claude/projects\" $(printf '%q' "$2")" </dev/null 2>/dev/null
  )
}

# spl_box_quota_turn_scan DIR SINCE: exit 0 when DIR's transcripts hold a
# real model answer (an assistant entry not "<synthetic>") newer than the
# epoch SINCE: the login answered after that moment, so it was not at its
# limit then (SPL-4702).
spl_box_quota_turn_scan() {
  local d="$1" since="$2" iso
  [ -d "$d" ] || return 1
  iso="$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%S)" || return 1
  find "$d" -name '*.jsonl' -newermt "@$since" -print0 2>/dev/null | xargs -0 -r grep -h -F '"type":"assistant"' 2>/dev/null |
    grep -v -F '"model":"<synthetic>"' | grep -oE '"timestamp":"[^"]+"' | cut -d'"' -f4 |
    awk -v t="$iso" '$0 > t { f = 1 } END { exit !f }'
}

# spl_box_quota_lifted SINCE: exit 0 when claude was measured WITH quota after
# the epoch SINCE (SPL-4702: the login was swapped at 08:56Z, sat kept its
# 07:57Z 100 % until the reset four days later). Either the login probe of
# do_spl_agent_login_check ("<epoch> ok ...", LANE_QUOTA_PROBE_FILE, default
# <LOGIN_STATE_DIR>/probe) said ok after SINCE, or a real answer in the agent
# user's transcripts is newer than SINCE. A probe that says limited, or no
# answer since, lifts nothing: a real limit holds until its reset.
spl_box_quota_lifted() {
  local since="$1" pf at verdict
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  pf="${LANE_QUOTA_PROBE_FILE:-${LOGIN_STATE_DIR:-/var/csi/csi-spl/agent-login-check}/probe}"
  if [[ -z "${LANE_QUOTA_CMD:-}${LANE_PANES_CMD:-}" || -n "${LANE_QUOTA_PROBE_FILE:-}" ]] && read -r at verdict _ 2>/dev/null <"$pf" &&
    [[ "$at" =~ ^[0-9]+$ && "$verdict" == ok ]] && (( at > since )); then
    return 0
  fi
  spl_box_quota_agent_scan spl_box_quota_turn_scan "$since"
}

# spl_box_quota_cache_read [NOW]: the claude CLI's own cached usage (SPL-3849
# send-back, c-002@sat msg 90123310): banner and transcript show only AT the
# limit, so a box below it read "no reading" every tick. The CLI keeps its
# last fetch of the weekly used % in ~/.claude.json, cachedUsageUtilization
# (seven_day.utilization, resets_at, fetchedAtMs, accountUuid). ~/.claude.json
# on stdin -> "<pct>" ("<pct>@<reset epoch>" with BOX_QUOTA_RESET=1), or nothing when the cache is of another
# login than oauthAccount's, older than LANE_QUOTA_CACHE_MAX_S (default 21600:
# the CLI refetches it only now and then, measured 1.4..2 h old) or its reset
# has passed.
spl_box_quota_cache_read() {
  local now="${1:-$(date +%s)}" max="${LANE_QUOTA_CACHE_MAX_S:-21600}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=21600
  jq -r --argjson now "$now" --argjson max "$max" '
    (.cachedUsageUtilization // {}) as $c | ($c.utilization.seven_day // {}) as $w
    | select($c.accountUuid != null and $c.accountUuid == .oauthAccount.accountUuid)
    | select(($c.fetchedAtMs | type) == "number" and ($now - $c.fetchedAtMs / 1000) < $max)
    | select(($w.utilization | type) == "number" and ($w.resets_at | type) == "string")
    | ($w.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) as $at
    | select($at > $now)
    | "\([$w.utilization | floor, 100] | min)@\($at)"' 2>/dev/null |
    if [[ "${BOX_QUOTA_RESET:-0}" == 1 ]]; then cat; else sed 's/@.*//'; fi
}

# spl_box_quota_cache [NOW]: spl_box_quota_cache_read of the agent user's
# ~/.claude.json.
spl_box_quota_cache() {
  local now="${1:-$(date +%s)}"
  spl_box_quota_claude_json | spl_box_quota_cache_read "$now"
}

# spl_box_quota_claude_json: the login and cached usage fields of the agent
# user's ~/.claude.json, read as that user. Seam (tests): LANE_QUOTA_CLAUDE_JSON
# reads that file as this user; a test that fakes the panes (LANE_PANES_CMD) or
# the reading (LANE_QUOTA_CMD) without it reads nothing.
spl_box_quota_claude_json() {
  if [[ -n "${LANE_QUOTA_CLAUDE_JSON:-}" ]]; then
    cat "$LANE_QUOTA_CLAUDE_JSON"; return 0
  fi
  [[ -z "${LANE_PANES_CMD:-}${LANE_QUOTA_CMD:-}" ]] || return 0
  declare -F spool_agent_exec >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  (
    [ -n "${SPOOL_AGENT_USER:-}" ] || SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
    SPOOL_RUN_AS_AGENT="${SPOOL_RUN_AS_AGENT:-su-dash}"
    spool_agent_exec 'jq -c "{cachedUsageUtilization: {accountUuid: .cachedUsageUtilization.accountUuid, fetchedAtMs: .cachedUsageUtilization.fetchedAtMs, utilization: {seven_day: .cachedUsageUtilization.utilization.seven_day}}, oauthAccount: {accountUuid: .oauthAccount.accountUuid}}" "$HOME/.claude.json"' </dev/null 2>/dev/null
  )
}

# spl_box_quota_here: THIS box's weekly usage as it shows NOW, "claude:96,grok:4"
# (the vendors read), "" when nothing shows one; with BOX_QUOTA_RESET=1 a known
# reset follows its % ("claude:96@1760688000"). Every read is also kept for
# spl_box_quota_known, so the alert's own call feeds the pick.
spl_box_quota_here() {
  local out
  out="$(BOX_QUOTA_RESET=1 spl_box_quota_live)"
  spl_box_quota_keep "$out" >/dev/null
  if [[ "${BOX_QUOTA_RESET:-0}" == 1 ]]; then echo "$out"; else sed -E 's/@[0-9]+//g' <<<"$out"; fi
}

# spl_box_quota_known: THIS box's last measured weekly usage, always with its
# reset when one is known ("claude:95@1760688000,grok:91"): a read now, merged
# with the kept ones (spl_box_quota_keep). "" = never measured, or expired.
spl_box_quota_known() {
  spl_box_quota_keep "$(BOX_QUOTA_RESET=1 spl_box_quota_live)"
}

# spl_box_quota_keep_file: the kept readings' file, one per box user (the pick
# hops to the desk user, the crons run as it). Seam (tests): LANE_QUOTA_STATE;
# a test that fakes the reading without it keeps nothing.
spl_box_quota_keep_file() {
  if [[ -n "${LANE_QUOTA_STATE:-}" ]]; then echo "$LANE_QUOTA_STATE"; return 0; fi
  [[ -z "${LANE_QUOTA_CMD:-}${LANE_PANES_CMD:-}" ]] || return 0
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/weekly-quota-reading.tsv"
}

# spl_box_quota_outdated PCT SEEN LOGIN ACCOUNT JSON NOW: exit 0 when a kept
# claude row (PCT, read at SEEN, under LOGIN) no longer says anything about
# ACCOUNT, the login now (SPL-4932: the owner raised the limit and swapped the
# login, sat held new lanes for hours on a kept 97 until it was removed by
# hand). JSON is spl_box_quota_claude_json's. Either
#   - the row names another login: any %, that login's usage is not this one's;
#   - a row that names none (kept before SPL-4932): the CLI fetched after the
#     row was read, under another tag than oauthAccount. The CLI tags a fetch
#     with its process's own account, so a process still on the old identity
#     tags the new login's number with the old account (sat, 13:58:09Z), and
#     spl_box_quota_cache_read rightly ignores that number;
#   - the same login fetched LESS after the row was read and the row is under
#     100: usage only climbs inside a week, so the limit moved. An old cache
#     (fetched before SEEN) never gets here, and neither does a kept 100, which
#     is the CLI's own limit banner: spl_box_quota_lifted answers for that one.
# An unknown ACCOUNT (no ~/.claude.json, no login) lifts nothing.
spl_box_quota_outdated() {
  local pct="$1" seen="$2" login="$3" acct="$4" json="$5" now="$6" tag="" at="" cur
  [[ -n "$pct" && -n "$acct" ]] || return 1
  [[ -n "$login" && "$login" != "$acct" ]] && return 0
  read -r tag at < <(jq -r '.cachedUsageUtilization | [(.accountUuid // "-"), ((.fetchedAtMs // 0) / 1000 | floor)] | @tsv' <<<"$json" 2>/dev/null) || true
  [[ "$at" =~ ^[0-9]+$ ]] && (( at > seen )) || return 1
  if [[ "$tag" != "$acct" ]]; then [[ -z "$login" && "$tag" != - ]]; return; fi
  # no age limit here: a fetch newer than the row says so however old it is
  cur="$(BOX_QUOTA_RESET=0 LANE_QUOTA_CACHE_MAX_S="$now" spl_box_quota_cache_read "$now" <<<"$json")"
  [[ "$cur" =~ ^[0-9]+$ ]] && (( pct < 100 && cur < pct ))
}

# spl_box_quota_keep READING: merge READING into the kept file, print the
# result as READING's form. Best effort: a file that cannot be written leaves
# the answer of this call right and the next call starts from the old file.
spl_box_quota_keep() {
  local f rows now tmp lifted="" pct="" seen="" login="" json="" acct=""
  f="$(spl_box_quota_keep_file)"
  [[ -n "$f" ]] || { echo "$1"; return 0; }
  now="$(date +%s)"
  read -r pct seen login < <(awk -F'\t' '$1 == "claude" && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $4, $5; exit }' "$f" 2>/dev/null) || true
  if [[ -n "$pct" || "$1" == *claude:* ]]; then
    json="$(spl_box_quota_claude_json)"
    acct="$(jq -r '.oauthAccount.accountUuid // empty' <<<"$json" 2>/dev/null)"
  fi
  if spl_box_quota_outdated "$pct" "$seen" "$login" "$acct" "$json" "$now"; then lifted=claude
  elif [[ -n "$pct" ]] && (( pct >= 100 )) && spl_box_quota_lifted "$seen"; then lifted=claude
  fi
  rows="$(cat "$f" 2>/dev/null | spl_box_quota_merge "$1" "$now" "${LANE_QUOTA_KEEP_S:-86400}" "$lifted" "$acct" | sort)"
  tmp="$f.tmp.$$"
  if mkdir -p "$(dirname "$f")" 2>/dev/null && { [[ -z "$rows" ]] || printf '%s\n' "$rows"; } 2>/dev/null >"$tmp"; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  [[ -n "$rows" ]] || return 0
  awk -F'\t' '{ printf "%s%s:%s%s", (NR > 1 ? "," : ""), $1, $2, ($3 != "" ? "@" $3 : "") } END { print "" }' <<<"$rows"
}

# spl_box_quota_merge READING NOW KEEP_S [LIFTED [ACCOUNT]]: the kept rows on stdin (kind
# TAB pct TAB reset epoch or empty TAB read at, a claude row then TAB the login it was
# read under: ACCOUNT, or its old one when ACCOUNT is unknown), the new rows on stdout. A reset that
# passed drops its row; a row with no reset (grok names none) lasts KEEP_S,
# since nothing says when its week ends and a box held on it would never be
# measured again. A new reading replaces a kept one, except inside one reset
# week (the two resets under a day apart, a banner rounds it): there usage only
# climbs, so an older CLI cache read after a banner cannot lower it. LIFTED
# (kinds, comma-separated; spl_box_quota_lifted, spl_box_quota_outdated) drops
# those kept rows first: the new reading stands alone.
spl_box_quota_merge() {
  awk -F'\t' -v OFS='\t' -v live="$1" -v now="$2" -v keep="$3" -v lifted="${4:-}" -v acct="${5:-}" '
    function gone(k) { return (at[k] != "" ? at[k] <= now : now - seen[k] >= keep) }
    NF >= 4 && $1 ~ /^[a-z]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]*$/ && $4 ~ /^[0-9]+$/ {
      pct[$1] = $2; at[$1] = $3; seen[$1] = $4; login[$1] = $5
    }
    END {
      for (k in pct) if (gone(k) || index("," lifted ",", "," k ",")) delete pct[k]
      n = split(live, v, ",")
      for (i = 1; i <= n; i++) {
        if (v[i] !~ /^[a-z]+:[0-9]+(@[0-9]+)?$/) continue
        split(v[i], kv, ":"); k = kv[1]; m = split(kv[2], pa, "@"); p = pa[1]; a = (m > 1 ? pa[2] : "")
        t = now
        if (k in pct && at[k] != "") {
          d = (a == "" ? 0 : a - at[k]); if (d < 0) d = -d
          if (d < 86400) { if (a == "") a = at[k]; if (pct[k] + 0 > p + 0) { p = pct[k]; t = seen[k] } }
        }
        pct[k] = p; at[k] = a; seen[k] = t
      }
      if (acct != "") login["claude"] = acct
      for (k in pct) if (!gone(k)) {
        if (login[k] != "") print k, pct[k], at[k], seen[k], login[k]
        else print k, pct[k], at[k], seen[k]
      }
    }'
}

# spl_box_quota_live: the read itself, as spl_box_quota_here prints it. Reads
# the box user's tmux (spl_lane_tm), claude's transcripts (spl_box_quota_log)
# and claude's cached usage (spl_box_quota_cache): the highest claude reading
# wins. Seam (tests): LANE_QUOTA_CMD prints the answer; a test that fakes the
# panes (LANE_PANES_CMD) reads only LANE_QUOTA_LOG_DIR.
spl_box_quota_live() {
  if [[ -n "${LANE_QUOTA_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LANE_QUOTA_CMD 2>/dev/null; return 0
  fi
  local now dead pane name id v pct out="" log
  local -A best=() at=()
  now="$(date +%s)"
  log="$(spl_box_quota_log "$now")"
  [[ "$log" =~ ^([0-9]+)(@[0-9]+)?$ ]] && best[claude]="${BASH_REMATCH[1]}" at[claude]="${BASH_REMATCH[2]}"
  log="$(spl_box_quota_cache "$now")"
  [[ "$log" =~ ^([0-9]+)(@[0-9]+)?$ ]] && (( BASH_REMATCH[1] > ${best[claude]:--1} )) &&
    best[claude]="${BASH_REMATCH[1]}" at[claude]="${BASH_REMATCH[2]}"
  if [[ -n "${LANE_PANES_CMD:-}" ]]; then echo "${best[claude]:+claude:${best[claude]}${at[claude]}}"; return 0; fi
  declare -F spool_id_of_window_var >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  spl_lane_tm
  while read -r dead pane name; do
    [[ "$dead" == 0 ]] || continue
    spool_id_of_window_var id "$name"
    case "$id" in c-*|CLE-*) v=claude ;; g-*|GRK-*) v=grok ;; *) continue ;; esac
    pct="$(timeout 5 "${LANE_TM[@]}" capture-pane -p -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 12 | spl_box_quota_parse "$v" "$now")"
    [[ "$pct" =~ ^([0-9]+)(@[0-9]+)?$ ]] && (( BASH_REMATCH[1] > ${best[$v]:--1} )) &&
      best[$v]="${BASH_REMATCH[1]}" at[$v]="${BASH_REMATCH[2]}"
  done < <(timeout 10 "${LANE_TM[@]}" list-panes -a -F '#{pane_dead} #{pane_id} #{window_name}' 2>/dev/null)
  for v in "${!best[@]}"; do out+="${out:+,}$v:${best[$v]}${at[$v]:-}"; done
  echo "$out"
}

# spl_box_quota_max [CNF]: the threshold, a whole % (default 90).
spl_box_quota_max() {
  local v="${BOX_QUOTA_WEEKLY_MAX_PCT:-}"
  [[ -z "$v" && -r "${1:-}" ]] && command -v yq >/dev/null && v="$(yq '.env.box.quota.weekly_max_pct // ""' "$1" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=90
  echo "$v"
}

# spl_box_quota_seat_max [CNF]: the weekly mark of a logged review seat (SPL-4966;
# spec 146, what-broke-20261106 section 7 item 3), a whole %: cnf
# env.box.quota.review_seat_max_pct, env BOX_QUOTA_REVIEW_SEAT_MAX_PCT overrides.
# A seat is read only and finishes work already written, so it passes the hold
# between weekly_max_pct and this mark. Why 95: usage rose 1.4 points an hour on
# 11-06 (81 at 02:25, 97 at 13:55; n=1 day), so 95 leaves about 3.5 h. That is no
# guarantee: after a reading of 90+ the next one came 0.83..5.92 h later (sat, n=6),
# so 3 of those 6 gaps fit and a seat can still reach the limit. Then the vendor
# refuses the turn, the CLI's banner reads 100, nothing more is placed and the seat
# stalls like any lane. Never over 99, whatever the cnf says: a login at 100 answers
# no turn. Never under weekly_max_pct; unset or not a number = weekly_max_pct: no pass.
spl_box_quota_seat_max() {
  local v="${BOX_QUOTA_REVIEW_SEAT_MAX_PCT:-}" max
  max="$(spl_box_quota_max "${1:-}")"
  [[ -z "$v" && -r "${1:-}" ]] && command -v yq >/dev/null && v="$(yq '.env.box.quota.review_seat_max_pct // ""' "$1" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$max"
  (( v > 99 )) && v=99
  (( v < max )) && v="$max"
  echo "$v"
}

# spl_box_quota_from_rows LANES_JSON ROW_ID MAX_AGE_S KIND [HERE HERE_WK]:
# KIND's weekly usage per box as {"<box>": pct}, from each box's freshest live
# BOX-0 row, scope field wk=<kind>:<pct>[@<reset epoch>],...; HERE_WK (this
# box's spl_box_quota_known) replaces this box's row. A box without a reading
# is absent: unknown. So is a reading whose reset passed, and one with no reset
# on a row MAX_AGE_S old or older; a reset ahead holds whatever the row's age.
spl_box_quota_from_rows() {
  jq -c --arg id "$2" --argjson max "$3" --arg k "$4" --arg here "${5:-}" --arg hw "${6:-}" '
    def pct($aged): split(",") | map(capture("^(?<v>[a-z]+):(?<p>[0-9]{1,3})(@(?<at>[0-9]+))?$")) | map(select(.v == $k))[0]
      | if . == null then null
        elif (.at // "") == "" then (if $aged then null else .p | tonumber end)
        elif (.at | tonumber) <= now then null
        else .p | tonumber end;
    [(.lanes // [])[] | select(.agent_id == $id and .state == "live" and (.age_s // -1) >= 0)]
    | group_by(.agent_box) | map(min_by(.age_s))
    | map({key: .agent_box, value: ((.age_s >= $max) as $aged | (.scope // "") | [capture("(^| )wk=(?<w>[^ ]*)")][0].w // "" | pct($aged))})
    | from_entries
    | if $here != "" then .[$here] = ($hw | pct(false)) else . end
    | with_entries(select(.value != null))' <<<"${1:-{\}}" 2>/dev/null || echo '{}'
}
