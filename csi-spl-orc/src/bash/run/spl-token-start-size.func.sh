#!/bin/bash
#------------------------------------------------------------------------------
# @description What a lane's session sends on its FIRST model call (system
# @description prompt, tools, CLAUDE.md / AGENTS.md, skills list, the seed),
# @description per vendor, from the harness's own counter (SPL-2214, the
# @description "Grok burns 3-4x" hypotheses of t1 bd5579e7):
# @description   claude: the first assistant row's usage, input +
# @description     cache_creation + cache_read, of each lane transcript
# @description     (~/.claude/projects/*-wt-c-*/<session>.jsonl)
# @description   grok: _meta.totalTokens on the first tool_call of each lane
# @description     session (~/.grok/sessions/*wt%2Fg-*/<id>/updates.jsonl):
# @description     the first call's prompt plus its few output tokens
# @description Prints one row per session (vendor, lane, start, tokens), then
# @description per vendor n, min, p50 and max. Read only; transcripts are read
# @description as their agent user (sudo -n -u), as the token burn collector does.
# @param TOKEN_START_SINCE (optional) - sessions started after this date (default 2 days ago)
# @param TOKEN_START_UNTIL (optional) - and before this date (default now)
# @param TOKEN_START_HOMES (optional, tests) - space-separated homes, read as the current user
# @param TOKEN_START_ROWS (optional) - 0 prints the summary only
# @example ./run -a do_spl_token_start_size
# @example TOKEN_START_SINCE=2026-10-13T12:00 TOKEN_START_UNTIL=2026-10-14T06:00 ./run -a do_spl_token_start_size
#------------------------------------------------------------------------------
do_spl_token_start_size() {
  local since="${TOKEN_START_SINCE:-$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M)}"
  local until="${TOKEN_START_UNTIL:-$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M)}"
  local rows u h
  declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"
  rows="$(
    if [[ -n "${TOKEN_START_HOMES:-}" ]]; then
      for h in $TOKEN_START_HOMES; do spl_token_start_read "$h" "$since" "$until"; done
    else
      for u in $(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}"); do
        h="$(getent passwd "$u" | cut -d: -f6)"
        [[ -n "$h" ]] && spl_cost_as "$u" bash -c "$(declare -f spl_token_start_read); spl_token_start_read \"\$@\"" _ "$h" "$since" "$until"
      done
    fi | sort -t$'\t' -k3
  )"
  [[ "${TOKEN_START_ROWS:-1}" == 0 ]] || { [[ -n "$rows" ]] && printf '%s\n' "$rows"; }
  printf '%s\n' "$rows" | awk -F'\t' -v since="$since" -v until="$until" '
    NF >= 4 { v[$1] = v[$1] " " $4; n[$1]++ }
    END {
      printf "first-call context tokens, sessions started %s .. %s\n", since, until
      for (k in n) {
        m = split(substr(v[k], 2), a, " ")
        for (i = 2; i <= m; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] + 0 > x + 0; j--) a[j + 1] = a[j]; a[j + 1] = x }
        printf "%s n=%d min=%d p50=%d max=%d\n", k, m, a[1], a[int((m + 1) / 2)], a[m]
      }
      if (length(n) == 0) print "no lane session in the window"
    }'
}

# spl_token_start_read HOME SINCE UNTIL: one "vendor<TAB>lane<TAB>start<TAB>tokens"
# row per lane session of HOME started in the window. Runs as HOME's user.
spl_token_start_read() {
  local home="$1" since="$2" until="$3" f d lane t ts line
  {
  while IFS= read -r f; do
    d="${f%/updates.jsonl}" lane="${d%/*}" lane="${lane##*%2F}"
    line="$(grep -m1 '"sessionUpdate":"tool_call"' "$f")" || continue
    t="$(jq -r '.params._meta.totalTokens // empty' <<<"$line" 2>/dev/null)"
    ts="$(date -u -r "$d/system_prompt.txt" +%Y-%m-%dT%H:%M 2>/dev/null)" || continue
    [[ -n "$t" ]] && printf 'grok\t%s\t%s\t%s\n' "$lane" "$ts" "$t"
  done < <(find "$home/.grok/sessions" -mindepth 3 -maxdepth 3 -path '*wt%2Fg-*' -name updates.jsonl \
    -newermt "$since" 2>/dev/null)
  while IFS= read -r f; do
    lane="${f%/*}" lane="${lane##*-wt-}"
    line="$(grep -m1 '"type":"assistant"' "$f")" || continue
    jq -r --arg lane "$lane" 'select(.message.usage != null) | .message.usage as $u |
      ["claude", $lane, (.timestamp // "" | .[0:16]),
       (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0))] | @tsv' \
      <<<"$line" 2>/dev/null
  done < <(find "$home/.claude/projects" -mindepth 2 -maxdepth 2 -path '*-wt-c-*' -name '*.jsonl' \
    -newermt "$since" 2>/dev/null)
  } 2>/dev/null | awk -F'\t' -v s="$since" -v u="$until" '$3 >= s && $3 < u && $4 > 0'
}
