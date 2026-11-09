#!/bin/bash
#------------------------------------------------------------------------------
# @description The sender audit (SPL-5136, spec 165 3.3.1): every agent has
# @description sudo to the box user, so a lane can run `spool send --from <any
# @description seat>` past spool-send.sh's guard, and the hub trusts the box,
# @description not the seat. Prevention is not possible; this detects it. Each
# @description CLI send journals its message id, from, ancestor pids with their
# @description start times, and the agent id read at send time
# @description (action.AuditSender); this action judges each line and sends the
# @description orchestrator ONE note on task fleet-anomaly listing the posts
# @description whose from is not that agent. Not flagged: a chain with no agent
# @description (cron, a human's shell), a role seat as the caller, and a relayed
# @description line whose from_agent names the caller. A line it cannot judge
# @description is counted as unjudgeable, never read as clean.
# @description Dry run unless DRY_RUN=0: the report only, the journal is kept.
# @description A failed send keeps the batch for the next run.
# @param SPOOL_SENDER_AUDIT (optional) - the journal, default /var/spool-hub/dispatch/sender-audit.jsonl
# @param SENDER_AUDIT_TO (optional) - who gets the note, default orchestrator
# @param SENDER_AUDIT_FROM (optional) - the sender, default role seat 1
# @param SENDER_AUDIT_SEND (optional) - the spool sender script (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_sender_audit
#------------------------------------------------------------------------------
_spl_sa_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib"
declare -F spl_role_seat >/dev/null || source "$_spl_sa_lib/spool-env.inc.sh"
declare -F send_chain_caller >/dev/null || source "$_spl_sa_lib/spool-caller.inc.sh"

do_spl_sender_audit() {
  local dry="${DRY_RUN:-1}" tmp rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SA_JOURNAL="${SPOOL_SENDER_AUDIT:-/var/spool-hub/dispatch/sender-audit.jsonl}"
  do_require_bin jq || return 1
  spool_env_resolve
  tmp="$(mktemp -d)" || return 1
  if (( dry )); then
    if [[ -e "$SA_JOURNAL" ]]; then
      { spl_sa_scan "$SA_JOURNAL" "$tmp/rows" && spl_sa_report "$tmp/rows"; } || rc=1
    else
      spl_sa_no_journal
    fi
  else
    ( flock -n 9 || { do_log "INFO another sender audit holds the lock - skipped"; exit 0; }
      spl_sa_run "$tmp" ) 9>"$SA_JOURNAL.lock" || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# spl_sa_run <tmp>: take the journal (or a batch a failed send left), alarm.
spl_sa_run() {
  local work="$SA_JOURNAL.work"
  [[ -e "$work" || ! -e "$SA_JOURNAL" ]] || mv "$SA_JOURNAL" "$work" || { do_log "FATAL cannot take $SA_JOURNAL"; return 1; }
  [[ -e "$work" ]] || { spl_sa_no_journal; return 0; }
  spl_sa_scan "$work" "$1/rows" || return 1
  spl_sa_report "$1/rows"
  if [[ -s "$1/rows" ]]; then
    spl_sa_body "$1/rows" >"$1/body"
    spl_sa_send "$1/body" || return 1
  fi
  rm -f "$work"
}

spl_sa_no_journal() {
  do_log "WARN sender audit: no journal at $SA_JOURNAL: nothing was judged, this is not a clean result"
}

# spl_sa_root: the /proc to read (a fake one under SPOOL_TEST=1).
spl_sa_root() {
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then echo "${SPOOL_FROM_GUARD_PROC:-}"; else echo /proc; fi
}

# spl_sa_live <root> <chain> <starts>: the pids of chain still running as the
# same process; a reused pid has another start time.
spl_sa_live() {
  local root="$1" i rec
  local -a c s f
  read -ra c <<<"$2"
  read -ra s <<<"$3"
  for i in "${!c[@]}"; do
    rec="$(cat "$root/${c[i]}/stat" 2>/dev/null)" || continue
    read -ra f <<<"${rec##*) }"
    [[ "${f[19]:-}" == "${s[i]:-}" ]] && printf '%s ' "${c[i]}"
  done
}

# spl_sa_judge <root> <chain> <starts> <agent> <unread> <pane>: sets SA_CALLER
# and SA_HOW (empty: no agent in the chain). Returns 1 when the line cannot be
# judged. The id read at send time decides; with none, only a still-running
# outermost pid (the one a window holds) can.
spl_sa_judge() {
  local root="$1" chain="$2" starts="$3" agent="$4" unread="$5" pane="$6" live
  SA_CALLER="" SA_HOW=""
  if [[ "$agent" != - ]]; then SA_CALLER="$agent" SA_HOW=environ; return 0; fi
  [[ "$unread" == 0 && "$pane" == false ]] && return 0
  [[ "$chain" != - ]] || return 1
  live="$(spl_sa_live "$root" "$chain" "$starts")"
  [[ " $live" == *" ${chain##* } "* ]] || return 1
  read -r SA_CALLER SA_HOW < <(send_chain_caller "$root" "${live% }")
  [[ -n "$SA_CALLER" ]]
}

# spl_sa_scan <journal> <rows file>: writes "msg_id from caller how" for each
# flagged line and sets SA_JUDGED, SA_UNJUDGED, SA_BAD. A malformed line, or
# one whose values are not ids, is counted and skipped.
spl_sa_scan() {
  local root msg from chain claim agent starts unread pane
  SA_JUDGED=0 SA_UNJUDGED=0 SA_BAD=0
  root="$(spl_sa_root)"
  [[ -n "$root" ]] || { do_log "FATAL sender audit: no /proc to read"; return 1; }
  : >"$2"
  while IFS=$'\t' read -r msg from chain claim agent starts unread pane; do
    [[ "$msg" =~ ^[0-9a-f-]{8,64}$ && "$from" =~ ^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$ ]] || { SA_BAD=$((SA_BAD + 1)); continue; }
    from="${from%%@*}"
    spl_sa_judge "$root" "$chain" "$starts" "$agent" "$unread" "$pane" || { SA_UNJUDGED=$((SA_UNJUDGED + 1)); continue; }
    SA_JUDGED=$((SA_JUDGED + 1))
    [[ -n "$SA_CALLER" && "$SA_CALLER" != "$from" && "$SA_CALLER" != "$claim" ]] || continue
    send_role_seat "$SA_CALLER" && continue
    printf '%s %s %s %s\n' "$msg" "$from" "$SA_CALLER" "$SA_HOW" >>"$2"
  done < <(jq -Rr '(fromjson? // {}) | (if type == "object" then . else {} end) | try ([(.msg_id // ""), (.from // ""),
      (if ((.chain // []) | length) > 0 then (.chain | map(tostring) | join(" ")) else "-" end),
      (if (.claim // "") != "" then .claim else "-" end),
      (if (.agent // "") != "" then .agent else "-" end),
      (if ((.starts // []) | length) > 0 then (.starts | map(tostring) | join(" ")) else "-" end),
      ((.unread // 1) | tostring), ((.pane // false) | tostring)] | @tsv) catch ""' "$1")
}

# spl_sa_counts: what a run could and could not judge.
spl_sa_counts() {
  echo "$1 flagged, $SA_JUDGED judged, $SA_UNJUDGED unjudgeable, $SA_BAD malformed"
}

# spl_sa_report <rows>: one line a run, WARN unless every line was judged; the
# rows on stdout.
spl_sa_report() {
  local level=OK
  (( SA_JUDGED > 0 && SA_UNJUDGED == 0 && SA_BAD == 0 )) || level=WARN
  do_log "$level sender audit: $(spl_sa_counts "$(wc -l <"$1")")"
  cat "$1"
}

# spl_sa_body <rows>: the note, at most 20 rows.
spl_sa_body() {
  local n
  n="$(wc -l <"$1")"
  echo "**Sender audit on $(hostname -s) (SPL-5136):** $n post(s) whose \`from\` is not the agent that ran the send. Detection only, the posts were delivered."
  echo
  echo "| msg_id | from | caller |"
  echo "|---|---|---|"
  head -20 "$1" | awk '{ print "| " $1 " | " $2 " | " $3 " (by its " $4 ") |" }'
  (( n <= 20 )) || { echo; echo "and $((n - 20)) more."; }
  echo
  echo "This run: $(spl_sa_counts "$n")."
}

# spl_sa_send <body file>: one note on task fleet-anomaly (spec 165 3.4).
spl_sa_send() {
  local send="${SENDER_AUDIT_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local to="${SENDER_AUDIT_TO:-orchestrator}" from="${SENDER_AUDIT_FROM:-$(spl_role_seat 1)}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$from" --to "$to" \
    --kind note --task fleet-anomaly --body-file "$1" >/dev/null 2>&1 9>&- ||
    { do_log "WARN could not send the sender audit to $to: the batch is kept"; return 1; }
}
