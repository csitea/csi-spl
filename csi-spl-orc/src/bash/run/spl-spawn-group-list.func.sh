#!/bin/bash
# @description The work groups (SPL-2370, do_spl_spawn_group_put): one line
# @description per group, rows done / running / in line / waiting against its
# @description width N, then one line per row: its state (waiting, open,
# @description queued, placing, running, done, closed, failed), the issue,
# @description class, placement, ask and the lane it placed. The state is
# @description read from the hub's asks, the epic's issues and the lane map,
# @description as the placer reads it.
# @param GROUP_EPIC (optional) - one group only
# @param GROUP_FORMAT (optional) - table (default) or json
# @param GROUP_LIVE (optional) - 0 skips the lane map and the issues (hub rows only: a placed row shows running)
# @param SPAWN_GROUP_DIR SPAWN_GROUP_GRACE_MIN (optional) - as do_spl_spawn_group_put
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_spawn_group_list
# @example GROUP_EPIC=SPL-2151 GROUP_FORMAT=json ./run -a do_spl_spawn_group_list

do_spl_spawn_group_list() {
  local fmt="${GROUP_FORMAT:-table}" dir f g asks st err all='[]' live=1
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL GROUP_FORMAT must be table or json"; return 1; }
  [[ -z "${GROUP_EPIC:-}" || "$GROUP_EPIC" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { do_log "FATAL GROUP_EPIC must be an epic key, e.g. SPL-2151"; return 1; }
  [[ "${GROUP_LIVE:-1}" == 0 ]] && live=0
  spl_spawn_q_init || return 1
  dir="$(spl_spawn_group_dir)"
  asks="$(spl_asks_hub_list)" || { do_log "FATAL the hub did not answer: a group's state is read from its asks"; return 1; }
  for f in "$dir"/${GROUP_EPIC:-*}.json; do
    [[ -r "$f" ]] || continue
    g="$(jq -c 'select(.epic and .width and (.rows | type) == "array")' "$f" 2>/dev/null)"
    [[ -n "$g" ]] || { do_log "WARN ${f##*/}: not a work group file"; continue; }
    err="$(mktemp)"
    st="$(spl_spawn_group_read "$g" "$asks" "$live" 2>"$err")" ||
      { do_log "WARN ${f##*/}: state not read: $(grep . "$err" | tail -1 | cut -c1-200)"; rm -f "$err"; continue; }
    rm -f "$err"
    all="$(jq -c --slurpfile s <(printf '%s' "$st") '. + $s' <<<"$all")"
  done
  if [[ "$fmt" == json ]]; then
    jq -c '{groups: .}' <<<"$all"
    return 0
  fi
  [[ "$all" != "[]" ]] || { do_log "INFO no work group${GROUP_EPIC:+ $GROUP_EPIC} in $dir"; return 0; }
  while IFS= read -r st; do
    jq -r '"GROUP \(.epic) width \(.width): \(.counts.done) done, \(.counts.running) running, \(.counts.open + .counts.queued + .counts.placing) in line, \(.counts.waiting) waiting, \(.counts.closed + .counts.failed) closed or failed (\(.rows | length) rows)"' <<<"$st"
    jq -r '(["ROW", "STATE", "ISSUE", "CLASS", "PLACEMENT", "ASK", "LANE", "WHY"] | @tsv),
      (.rows[] | [.seq, .state, .issue, .class, .place, .ask_id[0:8], (if .agent == "" then "-" else .agent end), .why] | @tsv)' <<<"$st" |
      column -t -s $'\t' -c 1000 | sed 's/^/  /'
  done < <(jq -c '.[]' <<<"$all")
  [[ "$live" == 1 ]] || do_log "INFO GROUP_LIVE=0: the lane map and the issues were not read"
}
