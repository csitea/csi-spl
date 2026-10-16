#!/bin/bash
#------------------------------------------------------------------------------
# @description The push whose lane is gone (SPL-2264, owner t1 b61851fb row D1):
# @description m-595 closed at 01:29Z, its push was refused at 01:34Z, and nobody
# @description saw it for 2.5 h. Every minute (box-cron push-orphan-check) this
# @description scans every do_spl_push_master state dir of THIS box, live
# @description (<SPOOL_ROOT>/<id>/lifetime/push-master) and retired
# @description (<SPOOL_ROOT>/.retired/<id>.<ts>/lifetime/push-master), whose log
# @description changed within PUSH_ORPHAN_MAX_AGE_MIN. A push ALERTS when its
# @description verdict is REFUSED, GAVE-UP or DIED (status RUNNING, no worker
# @description holds the lock, no END line in the log) AND its agent is gone
# @description (retired, or no live process + pane in the identity map). ONE
# @description blocker to the dispatch lease holder per push: agent, sha, the
# @description log's last line, the brief's topic. The marker `orphan-alerted`
# @description in the push dir (it moves with a retired dir) holds the push's
# @description key; the same push never alerts twice. A live lane's own refusal
# @description and a landed push never alert. Plain coded checks, no AI.
# @param DRY_RUN (optional) - 1 (default) prints PLAN lines, sends and marks nothing
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param PUSH_ORPHAN_MAX_AGE_MIN (optional) - only pushes whose log changed within it; default 360
# @param PUSH_ORPHAN_TO (optional) - default the dispatch lease holder
# @param PUSH_ORPHAN_TASK (optional) - the task when the brief names no dispatch-<hex8>; default dispatch-push-orphan
# @param PUSH_ORPHAN_LIVE_CMD (optional) - test seam: prints the live agent ids
# @param PUSH_ORPHAN_SEND (optional) - test seam: the spool-send.sh to run
# @example ./run -a do_spl_push_orphan_check
# @example DRY_RUN=0 ./run -a do_spl_push_orphan_check
#------------------------------------------------------------------------------

do_spl_push_orphan_check() {
  local dry="${DRY_RUN:-1}" age="${PUSH_ORPHAN_MAX_AGE_MIN:-360}" d n=0 sent=0 failed=0 rc
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$age" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL PUSH_ORPHAN_MAX_AGE_MIN must be whole minutes, got: '$age'"; return 1; }
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then spool_test_guard || return 96; fi
  PO_DRY="$dry"; PO_TAG="$(ai_tag)"; PO_LIVE=""; PO_LIVE_READ=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    _po_one "$d"; rc=$?
    (( rc == 0 )) && sent=$((sent + 1))
    (( rc == 2 )) && failed=$((failed + 1))
  done < <(_po_dirs "$age")
  echo "push-orphan-check@${PO_TAG:-box}: pushes=$n alerted=$sent failed=$failed$([[ "$dry" == 1 ]] && echo ' (DRY_RUN)')"
  (( failed == 0 ))
}

# The push state dirs, live and retired, whose log changed within <age> min.
_po_dirs() {
  find "$SPOOL_ROOT" "$SPOOL_ROOT/.retired" -mindepth 4 -maxdepth 4 -path '*/lifetime/push-master/log' \
    -mmin "-$1" -printf '%h\n' 2>/dev/null | sort -u
}

# The agent ids the identity map proves alive with a pane on this box.
_po_live_ids() {
  if [[ -n "${PUSH_ORPHAN_LIVE_CMD:-}" ]]; then bash -c "$PUSH_ORPHAN_LIVE_CMD"; return 0; fi
  local id live
  live="$(ai_tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  while IFS= read -r id; do
    [[ -n "$id" ]] && ai_pane_of "$id" "$live" >/dev/null && echo "$id"
  done < <(ai_live_ids)
  return 0
}

# _po_verdict <push dir> - prints PUSHED | REFUSED | GAVE-UP | DIED | RUNNING | NONE.
# A RUNNING status with an END line in the log takes the END's word: a worker
# that wrote its END to the log but whose status write was lost (m-595).
_po_verdict() {
  local d="$1" first end
  first="$(sed -n 1p "$d/status" 2>/dev/null)"
  case "$first" in
    PUSHED*) echo PUSHED; return ;;
    REFUSED*) echo REFUSED; return ;;
    GAVE-UP*) echo GAVE-UP; return ;;
    RUNNING) ;;
    *) echo NONE; return ;;
  esac
  end="$(grep -oE ' END (PUSHED|REFUSED|GAVE-UP)' "$d/log" 2>/dev/null | tail -n 1)"
  [[ -n "$end" ]] && { echo "${end# END }"; return; }
  # flock -E 75: 75 = a worker holds it; 0 = free; anything else = unreadable.
  flock -n -E 75 "$d/lock" true 2>/dev/null; case $? in 0) echo DIED ;; *) echo RUNNING ;; esac
}

# _po_sha <push dir> - the sha of the last push try, else of the status, else "-".
_po_sha() {
  local s
  s="$(grep -oE 'push [0-9a-f]{7,40} -> ' "$1/log" 2>/dev/null | tail -n 1 | awk '{print $2}')"
  [[ -n "$s" ]] || s="$(sed -n '1s/^\(PUSHED\|REFUSED push of\) \([0-9a-f]\{7,40\}\).*/\2/p' "$1/status" 2>/dev/null)"
  echo "${s:--}"
}

# _po_one <push dir> - 0 alerted (or planned), 1 nothing to do, 2 the alert failed.
_po_one() {
  local d="$1" agent_dir id retired=0 v sha key last brief task topic to body send
  agent_dir="${d%/lifetime/push-master}"
  id="${agent_dir##*/}"
  if [[ "$agent_dir" == "$SPOOL_ROOT/.retired/"* ]]; then retired=1; id="${id%%.*}"; fi
  [[ "$id" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || return 1
  v="$(_po_verdict "$d")"
  [[ "$v" =~ ^(REFUSED|GAVE-UP|DIED)$ ]] || return 1
  # A live lane sees its own refusal through PUSH_CMD=status.
  if (( retired == 0 )); then
    (( PO_LIVE_READ )) || { PO_LIVE="$(_po_live_ids)"; PO_LIVE_READ=1; }
    grep -qx "$id" <<<"$PO_LIVE" && return 1
  fi
  sha="$(_po_sha "$d")"
  key="$v $sha $(head -n 1 "$d/log" 2>/dev/null) $(sed -n '/^\(since\|finished\)=/{s///p;q}' "$d/status" 2>/dev/null)"
  [[ "$(cat "$d/orphan-alerted" 2>/dev/null)" == "$key" ]] && return 1
  last="$(grep -v '^[[:space:]]*$' "$d/log" 2>/dev/null | tail -n 1)"
  brief="$agent_dir/lifetime/brief.md"
  task="$(grep -m 1 -oE 'dispatch-[0-9a-f]{8}' "$brief" 2>/dev/null)"
  topic="$(grep -m 1 -oE '/t/[0-9a-f]{8}-[0-9a-f-]{27}' "$brief" 2>/dev/null)"
  to="$(_po_to)"
  body="$(printf '**push-orphan@%s**: the push of %s by %s ended %s and its lane is gone (%s); nobody watches it.\n- sha: %s\n- log, last line: %s\n- topic: %s, task %s\n- issue: %s\n- push dir: %s\n' \
    "${PO_TAG:-box}" "${sha:0:12}" "$id" "$v" "$( ((retired)) && echo retired || echo 'no live pane')" \
    "$sha" "${last:-none}" "${topic:-none in the brief}" "${task:-none}" \
    "$(head -c 40 "$agent_dir/lifetime/issue" 2>/dev/null | tr -d '\n' || true)" "$d")"
  if [[ "$PO_DRY" == 1 ]]; then echo "PLAN blocker to $to:"; printf '%s\n' "$body" | sed 's/^/  /'; return 0; fi
  # The marker first: a send that fails later is retried by hand, never every minute.
  printf '%s\n' "$key" >"$d/orphan-alerted.tmp" 2>/dev/null && mv -f "$d/orphan-alerted.tmp" "$d/orphan-alerted" ||
    { do_log "WARN cannot write the marker in $d - no alert for $id (it would repeat every minute)"; return 2; }
  send="${PUSH_ORPHAN_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$(_po_from)" --to "$to" --kind blocker \
    --task "${task:-${PUSH_ORPHAN_TASK:-dispatch-push-orphan}}" --body "$body" >/dev/null 2>&1 ||
    { do_log "WARN the blocker for $id ($sha) to $to was not sent; marker $d/orphan-alerted"; return 2; }
  echo "ALERT $id $v $sha -> $to"
}

# The dispatch lease holder ("<ID>@<box> <epoch>"); bare when on this box.
_po_to() {
  [[ -n "${PUSH_ORPHAN_TO:-}" ]] && { echo "$PUSH_ORPHAN_TO"; return 0; }
  local h=""
  read -r h _ <"$SPOOL_ROOT/dispatch/lease" 2>/dev/null || true
  [[ "$h" =~ ^${SPOOL_AGENT_ID_RX}(@[a-z0-9][a-z0-9-]*)?$ ]] || { echo orchestrator; return 0; }
  [[ "${h#*@}" == "$PO_TAG" ]] && h="${h%@*}"
  echo "$h"
}

# The sender: this box's orchestrator seat.
_po_from() {
  local o
  o="$(sed -n 's/^LEASE_ORCH=//p' "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null | tail -1)"
  [[ "$o" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || o="$(spl_role_seat 1)"
  echo "$o"
}
