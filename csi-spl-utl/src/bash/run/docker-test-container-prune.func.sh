#!/usr/bin/env bash
# docker-test-container-prune.func.sh — remove the ephemeral test containers a
# gone lane left behind, and report the unlabelled ones.
#
# Part of Reliability Round Row 07 (feat(rel-07-docker-test-container-prune)).
# Tracked by SPL-2450 (Refs: SPL-2364).
#
# The test call sites label what they start: `--label csi-spl.lane=<agent id>`.
# The action never decides by container name. A container is REMOVED
# (`docker rm -f -v <id>`, DRY_RUN=0 only) when ALL of these hold:
#   1. it carries a csi-spl.lane label whose value is an agent id
#      (c-803, CLE-77974, c-285@sat, ...);
#   2. that lane is gone: no tmux window names it, AND it is absent from
#      registry.tsv or present in registry.retired.tsv;
#   3. it was created more than DOCKER_PRUNE_MIN_AGE_MIN (default 120) min ago;
#   4. its name is not on the infrastructure whitelist
#      (con-csi-csi-spl-tf-runner, con-csi-csi-spl-tpl-gen,
#      con-csi-csi-spl-conf-validator, plus DOCKER_PRUNE_KEEP_NAMES).
# A container WITHOUT the label is reported only, never removed: those older
# than the age limit that no compose project owns (compose-made containers
# are services, not test leftovers). A labelled container whose label is not
# an agent id (empty when the starter had no agent id) is reported the same way.
#
# Report: with DRY_RUN=0, one spool note to the orchestrator when the set of
# reported or removed containers changes, or after DOCKER_PRUNE_THROTTLE_S
# (default 6 h) for the same set. A set that is ONLY reported (no removal, no
# failure) is noted once and never re-sent by the throttle: a long-lived
# container of another project stays reported every hour, and a repeated note
# and a red cron would only hide a real failure (SPL-4285). DRY_RUN=1
# (default) plans the note and the removals and changes nothing.
#
# Exit: 0 nothing to remove, or only reported (unlabelled) containers; 1 a
# container was (or would be) removed, or a removal failed; 2 docker unusable.
#
# Environment variables:
#   DRY_RUN: 1 (default) plans only; 0 removes and sends the note.
#   DOCKER_PRUNE_DOCKER: docker command (default docker).
#   DOCKER_PRUNE_MIN_AGE_MIN: age limit in minutes (default 120).
#   DOCKER_PRUNE_NOW: current epoch override (tests).
#   DOCKER_PRUNE_KEEP_NAMES: extra space-separated names never removed.
#   DOCKER_PRUNE_ACTIVE_REGISTRY: default $SPOOL_ROOT/registry.tsv.
#   DOCKER_PRUNE_RETIRED_REGISTRY: default $SPOOL_ROOT/registry.retired.tsv.
#   DOCKER_PRUNE_TMUX_SOCKET: fleet tmux socket (default $SPOOL_TMUX_SOCKET,
#     else /tmp/tmux-<registry owner uid>/default when it exists).
#   DOCKER_PRUNE_TMUX: tmux command (default tmux).
#   DOCKER_PRUNE_STATE_DIR: state dir (default $SPL_STATE_DIR or
#     ~/.local/state/csi-spl, + /docker-test-container-prune).
#   DOCKER_PRUNE_THROTTLE_S: same-set resend interval (default 21600).
#   DOCKER_PRUNE_ALERT_TO / _FROM / _TASK: note routing (default orchestrator,
#     $SPOOL_AGENT_ID or docker-test-container-prune@<box>,
#     docker-test-container-prune).
#   DOCKER_PRUNE_SEND_CMD: sender override (default the repo's spool-send.sh).
#
# @example cd csi-spl-utl && DRY_RUN=1 ./run -a do_docker_test_container_prune
# @example cd csi-spl-utl && DRY_RUN=0 ./run -a do_docker_test_container_prune
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# the containers the round names as permanent infrastructure
DOCKER_PRUNE_INFRA_NAMES="con-csi-csi-spl-tf-runner con-csi-csi-spl-tpl-gen con-csi-csi-spl-conf-validator"

# field separator of the docker listing: not whitespace, so an empty label
# keeps its column
_DTCP_FS=$'\x1f'

# _dtcp_is_agent_id <id>: an agent id with an optional @box (spec 061 forms
# and the legacy CLE-/GRK-/AGY-/QWN- ids).
_dtcp_is_agent_id() {
  [[ "${1%@*}" =~ ^([acgmq]-[0-9]{3,}|(CLE|GRK|AGY|QWN)-[0-9]+)$ ]]
}

# _dtcp_created_epoch <docker CreatedAt>: "2026-10-17 17:16:02 +0300 EEST" ->
# epoch; the trailing zone name is dropped (date -d reads the offset). Prints
# nothing for a value it cannot read.
_dtcp_created_epoch() {
  local c="$1"
  [[ "$c" =~ ^([0-9-]+\ [0-9:]+\ [+-][0-9]{4}) ]] && c="${BASH_REMATCH[1]}"
  date -d "$c" +%s 2>/dev/null || true
}

# _dtcp_registry_ids <tsv> <assoc name>: the first column of each row, @box cut.
_dtcp_registry_ids() {
  local tsv="$1" id _rest
  local -n _ids="$2"
  [[ -r "$tsv" ]] || return 0
  while IFS=$'\t' read -r id _rest; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    _ids["${id%@*}"]=1
  done <"$tsv"
}

# _dtcp_tmux_ids <assoc name> <active tsv>: agent ids named by a live window.
_dtcp_tmux_ids() {
  local -n _win="$1"
  local active_tsv="$2" sock="${DOCKER_PRUNE_TMUX_SOCKET:-${SPOOL_TMUX_SOCKET:-}}" uid name
  local -a tm
  read -ra tm <<<"${DOCKER_PRUNE_TMUX:-tmux}"
  command -v "${tm[0]}" &>/dev/null || return 0
  if [[ -z "$sock" && -f "$active_tsv" ]]; then
    uid="$(stat -c %u "$active_tsv" 2>/dev/null || true)"
    if [[ -n "$uid" && -S "/tmp/tmux-$uid/default" ]]; then sock="/tmp/tmux-$uid/default"; fi
  fi
  if [[ -n "$sock" ]]; then tm+=(-S "$sock"); fi
  while IFS= read -r name; do
    if [[ "$name" =~ (^|[^A-Za-z0-9_-])([acgmq]-[0-9]{3,}|(CLE|GRK|AGY|QWN)-[0-9]+) ]]; then
      _win["${BASH_REMATCH[2]}"]=1
    fi
  done < <(timeout 5 "${tm[@]}" list-windows -a -F '#{window_name}' 2>/dev/null || true)
}

_dtcp_stamp() {
  echo "${DOCKER_PRUNE_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/docker-test-container-prune}/alert.stamp"
}

_dtcp_box() {
  local box="${DEV_BOX:-$(hostname -s 2>/dev/null || echo PC)}"
  [[ "$box" == "box" ]] && box="PC"
  echo "$box"
}

# _dtcp_note <dry> <signature> <body> [once]: send (or plan) the orchestrator
# note, once per new signature or per throttle interval; with "once", once per
# new signature only.
_dtcp_note() {
  local dry="$1" sig="$2" body="$3" once="${4:-}" stamp prev_sig="" prev_t=0 now from
  local to="${DOCKER_PRUNE_ALERT_TO:-orchestrator}" task="${DOCKER_PRUNE_ALERT_TASK:-docker-test-container-prune}"
  local -a send
  stamp="$(_dtcp_stamp)"
  now="${DOCKER_PRUNE_NOW:-$(date +%s)}"
  from="${DOCKER_PRUNE_ALERT_FROM:-${SPOOL_AGENT_ID:-docker-test-container-prune@$(_dtcp_box)}}"
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  if [[ -f "$stamp" ]]; then read -r prev_sig prev_t <"$stamp" 2>/dev/null || true; fi
  [[ "$prev_t" =~ ^[0-9]+$ ]] || prev_t=0
  if [[ "$prev_sig" == "$sig" ]] && { [[ -n "$once" ]] || ((now - prev_t < ${DOCKER_PRUNE_THROTTLE_S:-21600})); }; then
    do_log "INFO docker-test-container-prune note throttled by $stamp"
    return 0
  fi
  read -ra send <<<"${DOCKER_PRUNE_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: note not sent"; return 0; }
  fi
  if timeout -k 2 20 "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$sig $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run sends again"
    do_log "INFO docker-test-container-prune note sent to $to"
  else
    do_log "WARN docker-test-container-prune: the note to $to failed"
  fi
  return 0
}

# The steps below read and fill the locals of do_docker_test_container_prune
# by bash dynamic scope: dry, now, min_age, fs, dk, active_tsv, retired_tsv,
# listing (in), total, prune, report, kept (classify), done_names, failed
# (remove).

# _dtcp_list: the docker listing into listing; 2 when docker is unusable.
_dtcp_list() {
  local fmt="{{.ID}}${fs}{{.Names}}${fs}{{.CreatedAt}}${fs}{{.Label \"csi-spl.lane\"}}${fs}{{.Label \"com.docker.compose.project\"}}${fs}{{.Labels}}"
  if ! listing="$("${dk[@]}" ps -a --no-trunc --format "$fmt" 2>&1)"; then
    do_log "FATAL docker ps failed: ${listing:0:200}"
    return 2
  fi
}

# _dtcp_classify: sort each listed container into kept, report or prune.
_dtcp_classify() {
  local -A active=() retired=() window=() keep=()
  _dtcp_registry_ids "$active_tsv" active
  _dtcp_registry_ids "$retired_tsv" retired
  _dtcp_tmux_ids window "$active_tsv"
  local n
  for n in $DOCKER_PRUNE_INFRA_NAMES ${DOCKER_PRUNE_KEEP_NAMES:-}; do keep["$n"]=1; done

  local id name created lane project labels epoch age_min lane_id
  while IFS="$fs" read -r id name created lane project labels; do
    [[ -z "$id" ]] && continue
    total=$((total + 1))
    if [[ -n "${keep[$name]:-}" ]]; then kept+=("$name:infrastructure"); continue; fi
    epoch="$(_dtcp_created_epoch "$created")"
    if [[ -z "$epoch" ]]; then
      do_log "WARN $name: cannot read its creation time '$created': left alone"
      continue
    fi
    age_min=$(((now - epoch) / 60))
    ((age_min > min_age)) || continue
    if [[ ",$labels," != *",csi-spl.lane="* ]]; then
      # unlabelled: report only; a compose-made container is a service
      [[ -n "$project" ]] && continue
      report+=("$name (${age_min} min, no csi-spl.lane label)")
      continue
    fi
    if ! _dtcp_is_agent_id "$lane"; then
      report+=("$name (${age_min} min, csi-spl.lane='$lane' is not an agent id)")
      continue
    fi
    lane_id="${lane%@*}"
    if [[ -n "${window[$lane_id]:-}" ]]; then
      kept+=("$name:lane $lane has a tmux window")
      continue
    fi
    if [[ -n "${active[$lane_id]:-}" && -z "${retired[$lane_id]:-}" ]]; then
      kept+=("$name:lane $lane is in registry.tsv")
      continue
    fi
    prune+=("$id$fs$name$fs$lane$fs$age_min")
  done <<<"$listing"
}

# _dtcp_remove: log the kept, remove (or plan) the prune rows, log the report.
_dtcp_remove() {
  local row k out id name lane age_min
  for k in "${kept[@]}"; do do_log "INFO keep ${k%%:*}: ${k#*:}"; done
  for row in "${prune[@]}"; do
    IFS="$fs" read -r id name lane age_min <<<"$row"
    if [[ "$dry" != 0 ]]; then
      do_log "INFO PLAN remove $name (lane $lane gone, ${age_min} min old)"
      done_names+=("$name (lane $lane, ${age_min} min)")
    elif out="$("${dk[@]}" rm -f -v "$id" 2>&1)"; then
      do_log "INFO removed $name (lane $lane gone, ${age_min} min old)"
      done_names+=("$name (lane $lane, ${age_min} min)")
    else
      do_log "WARN cannot remove $name: ${out:0:200}"
      failed=$((failed + 1))
    fi
  done
  for row in "${report[@]}"; do do_log "WARN unlabelled, report only: $row"; done
}

# _dtcp_report: the summary line, then the all-clear (0), the report-only
# note (0) or the note (1).
_dtcp_report() {
  local verb="removed"
  [[ "$dry" != 0 ]] && verb="would remove"
  do_log "INFO docker-test-container-prune: $total container(s), $verb ${#done_names[@]}, reported ${#report[@]}, failed $failed, kept ${#kept[@]}"

  if ((${#done_names[@]} == 0 && ${#report[@]} == 0 && failed == 0)); then
    if [[ "$dry" == 0 ]]; then rm -f "$(_dtcp_stamp)" 2>/dev/null || true; fi
    return 0
  fi
  local body sig
  body="docker-test-container-prune on $(_dtcp_box): $verb ${#done_names[@]} stale lane test container(s)"
  ((${#done_names[@]})) && body+=": $(IFS=';'; echo "${done_names[*]}")"
  ((failed)) && body+=". $failed removal(s) FAILED, see the run log"
  ((${#report[@]})) && body+=". ${#report[@]} unlabelled container(s) older than ${min_age} min, NOT removed (a human decides): $(IFS=';'; echo "${report[*]}")"
  sig="$(printf '%s\n' "${done_names[@]%% *}" "${report[@]%% *}" "$failed" | sort | md5sum | cut -c1-16)"
  if ((${#done_names[@]} == 0 && failed == 0)); then
    _dtcp_note "$dry" "$sig" "$body" once
    return 0
  fi
  _dtcp_note "$dry" "$sig" "$body"
  return 1
}

do_docker_test_container_prune() {
  local dry="${DRY_RUN:-1}" spool_root="${SPOOL_ROOT:-/var/spool-hub}"
  local active_tsv="${DOCKER_PRUNE_ACTIVE_REGISTRY:-$spool_root/registry.tsv}"
  local retired_tsv="${DOCKER_PRUNE_RETIRED_REGISTRY:-$spool_root/registry.retired.tsv}"
  local min_age="${DOCKER_PRUNE_MIN_AGE_MIN:-120}" now listing fs="$_DTCP_FS"
  local -a dk
  read -ra dk <<<"${DOCKER_PRUNE_DOCKER:-docker}"
  [[ "$min_age" =~ ^[0-9]+$ ]] || { do_log "FATAL DOCKER_PRUNE_MIN_AGE_MIN '$min_age' is not a number"; return 2; }
  now="${DOCKER_PRUNE_NOW:-$(date +%s)}"
  _dtcp_list || return 2

  local -a prune=() report=() kept=() done_names=()
  local total=0 failed=0
  _dtcp_classify
  _dtcp_remove
  _dtcp_report
}
