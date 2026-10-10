#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the tries journal of one task (spec 115 section 6),
# @description the input of do_spl_lane_mix's backup rule (section 5): per
# @description vendor, how many lanes tried the task and how many failed.
# @description A row is `task_id kind vendor id start_epoch outcome [source]`,
# @description outcome `run`, `ok` or `fail:<F1|F2|F3>`. A lane's row is
# @description closed by a later row for the same id, so the LAST row of an
# @description id wins. Read from $SPOOL_ROOT/dispatch/attempts.tsv (spec 115)
# @description and $SPOOL_ROOT/<id>/attempts.tsv (where spawn-window.sh writes
# @description it today). An S2 verdict (limit, auth, login) is never a row: a
# @description vendor that is out is skipped by availability, not counted.
# @param LANE_MIX_TASK - required: the task_id
# @param LANE_MIX_JOURNAL (optional) - the journal files, space-separated;
# @param   default the two places above
# @example LANE_MIX_TASK=caef117a-6767-57f3-b805-b4ed1bc96608 ./run -a do_spl_lane_mix_journal
#------------------------------------------------------------------------------
do_spl_lane_mix_journal() {
  local task="${LANE_MIX_TASK:-}" v
  [[ -n "$task" ]] || { do_log "FATAL LANE_MIX_TASK must name the task_id"; return 1; }
  declare -gA _LM_TRIED=() _LM_FAILS=()
  _spl_lane_mix_journal "${SPOOL_ROOT:-/var/spool-hub}" "$task"
  for v in claude grok agy qwen mistral; do
    printf '%-7s tries=%s failed=%s\n' "$v" "${_LM_TRIED[$v]:-0}" "${_LM_FAILS[$v]:-0}"
  done
  printf 'task=%s tries=%s\n' "$task" "$_LM_TRIES"
}

# _spl_lane_mix_journal <spool-root> <task_id> -> _LM_TRIES (lanes that tried
# the task), _LM_TRIED[<vendor>] and _LM_FAILS[<vendor>] (lanes whose last
# row is fail:F1|F2|F3), into the caller's declared maps; an empty task_id
# reads as no try
_spl_lane_mix_journal() {
  local task="$2" f files=() on=() v n
  _LM_TRIES=0
  [[ -n "$task" ]] || return 0
  if [[ -n "${LANE_MIX_JOURNAL:-}" ]]; then read -r -a files <<<"$LANE_MIX_JOURNAL"
  else files=("$1/dispatch/attempts.tsv" "$1"/*/attempts.tsv); fi
  for f in "${files[@]}"; do [[ -f "$f" && -r "$f" ]] && on+=("$f"); done
  (( ${#on[@]} > 0 )) || return 0
  while read -r v n; do
    if [[ "$v" == '*' ]]; then _LM_TRIES="$n"
    elif [[ "$v" == fail:* ]]; then _LM_FAILS[${v#fail:}]="$n"
    else _LM_TRIED[$v]="$n"; fi
  done < <(cat "${on[@]}" | awk -F'\t' -v t="$task" '
    $1 == t && NF >= 6 && $4 != "" { vend[$4] = $3; out[$4] = $6 }
    END {
      for (i in vend) {
        n++; tried[vend[i]]++
        if (out[i] ~ /^fail:F[123]$/) failed[vend[i]]++
      }
      print "*", n + 0
      for (v in tried) print v, tried[v]
      for (v in failed) print "fail:" v, failed[v]
    }')
}
