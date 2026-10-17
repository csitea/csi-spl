#!/bin/bash
# @description Put a spawn request in line (owner HUM-10, t1 c9beaa77; rdb
# @description 0180): the ask goes queued on the hub with its position, and its
# @description sender is told on its task "queued, position N of M, placed when
# @description the box has room". From then on the asks tick never re-raises,
# @description escalates or dead-letters it; the placer (do_spl_spawn_place)
# @description takes it when it is position 1 and the box has room. The
# @description acting orchestrator runs this instead of acking a spawn request
# @description it cannot place now. Enqueueing a queued ask again keeps its
# @description place (and sets a new placement when one is given).
# @description Every request carries its work class (SPL-1817, rdb 0195): the
# @description queue places by class and the placer keeps the bands of the live
# @description lanes; the rule's one home is
# @description csi-spl-doc/doc/md/fleet-rules-index.md.
# @description A SPAWN_PLACE brief with no `Issue:` key names a spec folder on
# @description origin/master (`Spec:` line) and its epic (`Epic: SPL-<n>`, or
# @description the spec's pin), or the ask is not queued (one FATAL line): the
# @description placer would file its issue, and there is no issue without an
# @description epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6).
# @param SPAWN_CLASS (required) - ci (a CI-red fix on trunk), refactor, bug or feature; no default, never guessed
# @param SPAWN_URGENT (optional) - 1: a bug placed even over its band (owner-reported prd breakage; the dispatcher's call)
# @param SPAWN_BYPASS (optional) - the owner message id (a UUID) that explicitly asked for this feature outside the bands; ONLY on the owner's ask, recorded and listed by do_spl_spawn_share
# @param ASK_ID (required) - the ask id, or its first 8 hex digits (do_spl_asks_open prints them)
# @param SPAWN_PLACE (optional) - <vendor>:<slug>: the placer launches it itself, `spawn-window.sh <vendor> auto <workdir> <brief> <slug>`, with the brief file <slug>.md under SPAWN_PLACE_BRIEF_DIR on the orch box. Unset: the placer hands it to the orchestrator when it is next
# @param SPAWN_KIND (optional) - the lane's task kind (spec 115); unset reads the "Kind:" of the brief <slug>.md. A mistral placement of any kind but specs_and_docs or i18n is refused (owner HUM-10, t1 b61851fb, msg 91bf8278: mistral does docs and reviews only) while cnf env.box.agent_split.mistral_coding_allowed is not true
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=refactor ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=feature SPAWN_BYPASS=8cb6cc7d-7628-4ac3-be00-86e427bb3487 ./run -a do_spl_spawn_enqueue

do_spl_spawn_enqueue() {
  local by id row pos len rc=0
  spl_spawn_q_init || return 1
  by="$(spl_asks_by)" || return 1
  id="$(spl_spawn_q_resolve)" || return 1
  row="$(spl_spawn_q_enqueue "$id" "$by" "${SPAWN_PLACE:-}" "${SPAWN_CLASS:-}" "${SPAWN_URGENT:-0}" "${SPAWN_BYPASS:-}")" || rc=$?
  (( rc == 0 )) || return "$rc"
  pos="$(jq -r '.position // 0' <<<"$row")"
  len="$(jq -r '.queue_len // 0' <<<"$row")"
  if ! spl_spawn_q_reply "$row" "$by" "queued, position $pos of $len, placed when the box has room (ask ${id:0:8}; the queue: \`./run -a do_spl_spawn_queue\`)"; then
    do_log "WARN ask ${id:0:8} is queued but its sender was not told"
  fi
}

# One ask into the queue: the checks, the hub's queue op, the bypass record;
# the hub's row on stdout, the log on stderr. The one path every queue row
# takes: a single enqueue, and each row a work group feeds
# (spl-spawn-group-put.func.sh; a single ask is a group of one row, width 1).
spl_spawn_q_enqueue() {  # ID BY PLACE CLASS URGENT(0|1) BYPASS_MSG
  local id="$1" by="$2" place="$3" class="$4" msg="$6" flag="" row rc=0
  [[ -z "$place" || "$place" =~ ^[a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    { do_log "FATAL SPAWN_PLACE must be <vendor>:<slug> (lowercase), got '$place'" >&2; return 1; }
  spl_spawn_enqueue_mistral_ok "$place" >&2 || return 1
  [[ "$class" =~ ^(ci|refactor|bug|feature)$ ]] ||
    { do_log "FATAL SPAWN_CLASS must be ci, refactor, bug or feature (got '$class'; no default: classify the request)" >&2; return 1; }
  [[ "$5" == 1 ]] && flag=urgent
  if [[ -n "$msg" ]]; then
    [[ "$msg" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
      { do_log "FATAL SPAWN_BYPASS must be the owner's message id (a full lowercase UUID), got '$msg'" >&2; return 1; }
    flag=bypass
  fi
  [[ "$flag" != urgent || "$class" == bug ]] || { do_log "FATAL SPAWN_URGENT goes with SPAWN_CLASS=bug only" >&2; return 1; }
  [[ "$flag" != bypass || "$class" == feature ]] || { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only" >&2; return 1; }
  [[ -z "$msg" || "$5" != 1 ]] || { do_log "FATAL SPAWN_URGENT and SPAWN_BYPASS exclude each other" >&2; return 1; }
  if [[ -n "$place" ]]; then  # the placer files the lane's issue from this brief: refuse it here, not at placement
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 1
    declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
    local brief; brief="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spl_spawn_place_brief "${place#*:}")"
    [[ -z "$brief" ]] || LI_REFUSED="ask not queued" li_brief_epic_spec "$brief" >/dev/null || return 1
  fi
  row="$(spl_spawn_q_op queue "$id" "$by" "" "$place" "$class" "$flag" "$msg")" || rc=$?
  (( rc == 0 )) || return "$rc"
  if [[ "$flag" == bypass ]]; then
    spl_spawn_share_bypass_record "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$msg" "$by" "$(jq -r '.summary // ""' <<<"$row")" ||
      do_log "WARN the bypass of ask ${id:0:8} is on the hub row but not in the local bypass log" >&2
    do_log "INFO ask ${id:0:8} is a feature BYPASS on owner msg ${msg:0:8}: recorded, listed by do_spl_spawn_share" >&2
  fi
  do_log "OK ask ${id:0:8} queued ($class${flag:+, $flag}): position $(jq -r '.position // 0' <<<"$row") of $(jq -r '.queue_len // 0' <<<"$row")${place:+, placement $place}" >&2
  printf '%s\n' "$row"
}

# spl_spawn_enqueue_mistral_ok <placement> -> refuses (one FATAL line) a
# mistral placement whose kind (SPAWN_KIND, else the brief's "Kind:", none
# counting as coding) is coding: the coding rule of spl-lane-mix.func.sh
spl_spawn_enqueue_mistral_ok() {
  local why kind="${SPAWN_KIND:-}"
  [[ "$1" == mistral:* ]] || return 0
  declare -F spl_lane_mix_mistral_code_off >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  [[ -n "$kind" ]] || kind="$(spl_lane_mix_brief_kind "$(spl_spawn_place_brief "${1#mistral:}")")"
  why="$(spl_lane_mix_mistral_code_off "${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}" "$kind")"
  [[ -z "$why" ]] && return 0
  do_log "FATAL SPAWN_PLACE=$1 refused: $why; place it as claude:${1#mistral:}"
  return 1
}
