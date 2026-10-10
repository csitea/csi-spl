#!/bin/bash
#------------------------------------------------------------------------------
# @description Hand a mistral lane over to a new agent on another box (owner
# @description t1 ba8104f6 msg b072af77, topic 9d603c3d): the shape of
# @description do_spl_lane_handover (claude), whose helpers it calls; only the
# @description session part is mistral's.
# @description   Where vibe 2.26.0 keeps a session: the agent user's
# @description   ~/.vibe/logs/session/unified/<sid>/ (CURRENT, meta.json, chunks/,
# @description   generations/, journal/); its lease lives outside it, in
# @description   ../active/<sid>.lock. `vibe --resume <sid>` needs only
# @description   unified/<sid>/CURRENT, on any box (vibe/app_server/_runtime.py,
# @description   _resolve_unified_session_id). The identity record of an m- lane
# @description   has no session id, so the session is the newest root one whose
# @description   meta.json working_directory is FROM's worktree: what
# @description   `vibe --continue` picks there (restore-mistral.sh).
# @description   1. WIP: do_spl_lane_handover_wip, scan first (a hit = exit 3,
# @description      nothing pushed, FROM untouched, no ssh call).
# @description   2. the new worktree <repo>-wt/<TO_ID> on TO_BOX at the wip ref.
# @description   3. A, resume: BEFORE FROM is closed, the session dir goes over
# @description      ssh stdin ONLY (never the hub, git or a log) into the target
# @description      AGENT_USER's ~/.vibe/logs/session/unified (a failed copy = exit
# @description      1, FROM untouched); after the WIP step restore-mistral.sh runs
# @description      `vibe --resume <sid>` in a new tmux window, the brief as kick.
# @description   4. B, written handoff: TO_ID != FROM (the session names the old
# @description      worktree path), no session, bigger than
# @description      HANDOVER_TRANSCRIPT_MAX_MB, key material in it, or
# @description      HANDOVER_MODE=B: spawn-window.sh mistral
# @description      starts a fresh agent with the handover brief.
# @description   5. FROM closed before its WIP is pushed, retired after the start
# @description      (RETIRE_WORKTREE=0), so it never runs on both boxes; any failure
# @description      after the push exits 1. The new agent deletes the wip ref after
# @description      its first landed push.
# @description Dry run unless DRY_RUN=0: the WIP scan, the mode and the plan, no ssh.
# @param FROM (required) - the lane to hand over, a mistral id on this box (m-NNN)
# @param TO_BOX (required) - the target box id (its BOX_TAG, e.g. sat)
# @param TO_ID (optional) - the new id, default FROM (same worktree path: A)
# @param HANDOVER_MODE (optional) - auto (default), A or B
# @param HANDOVER_TRANSCRIPT_MAX_MB (optional) - default 100; a bigger session = B
# @param BOX_SSH_<BOX> (optional) - the ssh destination, default the satellite alias
# @param DRY_RUN (optional) - 1 (default) or 0
# @example FROM=m-050 TO_BOX=sat ./run -a do_spl_lane_handover_mistral
# @example FROM=m-050 TO_BOX=sat DRY_RUN=0 ./run -a do_spl_lane_handover_mistral
#------------------------------------------------------------------------------

do_spl_lane_handover_mistral() {
  do_require_bin jq tar zstd || return 1
  local from="${FROM:-}" box="${TO_BOX:-}" to="${TO_ID:-${FROM:-}}" mode="${HANDOVER_MODE:-auto}" dry="${DRY_RUN:-1}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" here
  [[ "$from" =~ ^m-[0-9]{3}$ ]] || { do_log "FATAL FROM must be a mistral lane id (m-NNN), got '$from'"; return 1; }
  [[ "$to" =~ ^m-[0-9]{3}$ ]] || { do_log "FATAL TO_ID must be a mistral lane id (m-NNN), got '$to'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TO_BOX must be a box id (e.g. sat), got '$box'"; return 1; }
  [[ "$mode" =~ ^(auto|A|B)$ ]] || { do_log "FATAL HANDOVER_MODE must be auto, A or B, got '$mode'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  here="$(spl_box_state_box)" || return 1
  [[ "$box" != "$here" || "$to" != "$from" ]] || { do_log "FATAL TO_BOX is this box ($here): give a TO_ID other than $from"; return 1; }

  local rec="$root/agents/$from.json" wt user kind repo
  [[ -r "$rec" ]] || { do_log "FATAL no identity record $rec"; return 1; }
  kind="$(jq -r '.kind // ""' "$rec")"; wt="$(jq -r '.worktree // ""' "$rec")"; user="$(jq -r '.user // ""' "$rec")"
  [[ "$kind" == mistral ]] || { do_log "FATAL $from is a '$kind' lane: this action hands over mistral lanes"; return 1; }
  [[ -d "$wt" ]] || { do_log "FATAL $from: worktree '$wt' is not here"; return 1; }
  repo="$(spl_handover_main_checkout "$wt")" || { do_log "FATAL $from: $wt is not a linked worktree of a checkout"; return 1; }

  local out rc=0
  out="$(ID="$from" WIP_WORKTREE="$wt" DRY_RUN=1 do_spl_lane_handover_wip 2>&1)" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL HANDOVER $from: the WIP step refused (exit $rc): nothing handed over, $from untouched"; return "$rc"; }

  local work tr="" why sid
  work="$(umask 077 && mktemp -d)" || return 1
  why="$(spl_handover_mistral_pick_mode "$mode" "$from" "$to" "$user" "$wt" "$work")"
  sid="$(cat "$work/sid" 2>/dev/null)"
  [[ -f "$work/session.tar" ]] && tr="$work/session.tar"
  local m="${why%% *}" newwt="$repo-wt/$to" ref="refs/heads/wip/handover/$from"
  echo "HANDOVER $from@$here -> $to@$box mode=$why"
  if (( dry )); then
    echo "PLAN close   $from (tmux-close-window.sh --agent $from)"
    echo "PLAN wip     push $ref"
    echo "PLAN prep    ssh $box: worktree $newwt on branch $to-handover at $ref"
    [[ "$m" == A ]] && echo "PLAN session ssh $box: vibe session $sid -> the agent user's ~/.vibe/logs/session/unified; restore-mistral.sh $to $newwt $sid"
    [[ "$m" == B ]] && echo "PLAN spawn   ssh $box: spawn-window.sh mistral $to $repo <handover brief>"
    echo "PLAN retire  $from (agent-id-retire.sh --apply, RETIRE_WORKTREE=0)"
    do_log "OK DRY_RUN nothing was handed over. DRY_RUN=0 does it."
    rm -rf "$work"; return 0
  fi
  spl_handover_mistral_live "$from" "$to" "$box" "$here" "$m" "$wt" "$repo" "$sid" "$tr" "$work"; rc=$?
  rm -rf "$work"
  return "$rc"
}

# spl_handover_mistral_live FROM TO BOX HERE MODE WT REPO SID SESSION_TAR WORK:
# the side effects, in order; the first failure stops with what is left to do
spl_handover_mistral_live() {
  local from="$1" to="$2" box="$3" here="$4" m="$5" wt="$6" repo="$7" sid="$8" tr="$9" work="${10}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" scripts newwt="$repo-wt/$to" ref="refs/heads/wip/handover/$from"
  local out rc=0 sha agent dest brief rbrief pane
  scripts="$(spl_handover_scripts_dir "$repo")"
  dest="$(spl_handover_dest "$box")"
  spl_handover_probe "$dest" "$box" "$repo" "$newwt" || return 1
  agent="$HO_AGENT"
  # the session first: a failed copy stops before FROM is closed or anything is pushed
  if [[ "$m" == A ]]; then
    spl_handover_mistral_on "$dest" agent session "$sid" <"$tr" >"$work/tr" 2>&1 ||
      { do_log "FATAL HANDOVER $from: the session copy to $box failed ($(tail -n1 "$work/tr")): $from untouched, nothing pushed; HANDOVER_MODE=B hands over without it"; return 1; }
    echo "COPIED  vibe session $sid to $box (ssh)"
  fi

  ID="$from" HANDOFF_WORKDIR="$wt" do_spl_agent_handoff >/dev/null 2>&1 || echo "WARN $from: handoff.md not composed; the brief carries the rest"
  out="$(${HANDOVER_CLOSE_CMD:-bash "$scripts/tmux-close-window.sh"} --agent "$from" 2>&1)" || rc=$?
  (( rc == 0 || rc == 3 )) || { do_log "FATAL HANDOVER $from: cannot close its window (exit $rc): $out"; return 1; }
  echo "CLOSED  $from ($( ((rc == 3)) && echo 'no window' || echo 'window closed'))"

  rc=0
  out="$(ID="$from" WIP_WORKTREE="$wt" DRY_RUN=0 do_spl_lane_handover_wip 2>&1)" || rc=$?
  printf '%s\n' "$out"
  sha="$(sed -n 's/^OK HANDOVER-WIP .* sha=\([0-9a-f]*\) .*/\1/p' <<<"$out" | tail -1)"
  [[ -n "$sha" ]] || { do_log "FATAL HANDOVER $from: the WIP push failed; $from is closed, its worktree $wt untouched: fix, then run again"; return 1; }

  spl_handover_on "$dest" owner prep "$repo" "$newwt" "$ref" "$to-handover" "$scripts" </dev/null >"$work/prep" 2>&1 ||
    { do_log "FATAL HANDOVER $from: worktree on $box: $(tail -n1 "$work/prep")"; return 1; }
  echo "PREPARED $newwt on $box at ${sha:0:12}"

  brief="$work/brief.md" rbrief="$root/handover/$to-from-$from.md"
  spl_handover_brief "$from" "$to" "$box" "$here" "$m" "$wt" "$newwt" "$ref" "$sha" >"$brief"
  spl_handover_on "$dest" owner brief "$rbrief" <"$brief" >/dev/null 2>&1 || { do_log "FATAL HANDOVER $from: cannot write $rbrief on $box"; return 1; }
  rc=0
  if [[ "$m" == A ]]; then
    out="$(spl_handover_mistral_on "$dest" owner resume "$scripts" "$to" "$newwt" "$sid" "$rbrief" "$agent" </dev/null 2>&1)" || rc=$?
  else
    out="$(spl_handover_mistral_on "$dest" owner spawn "$scripts" "$to" "$repo" "$rbrief" </dev/null 2>&1)" || rc=$?
  fi
  pane="$(grep -E "^$to(@[a-z0-9-]+)? %[0-9]+$" <<<"$out" | tail -1 | cut -d' ' -f2)"
  [[ -n "$pane" ]] || { do_log "FATAL HANDOVER $from: the start of $to on $box failed (exit $rc): $(tail -n2 <<<"$out" | tr '\n' ' ')"; return 1; }
  echo "STARTED $to@$box $pane mode=$m"

  out="$(RETIRE_WORKTREE=0 ${HANDOVER_RETIRE_CMD:-bash "$scripts/agent-id-retire.sh"} --apply "$from" 2>&1)" ||
    echo "WARN retire $from: $(tail -n1 <<<"$out")"
  echo "OK HANDOVER $from@$here -> $to@$box mode=$m wip=${sha:0:12}; $wt stays until $to lands, then git -C $repo worktree remove $wt"
}

# spl_handover_mistral_pick_mode MODE FROM TO USER WT WORK -> "A" or "B (<why>)";
# leaves the session id at WORK/sid and, for A, the session tar at WORK/session.tar
spl_handover_mistral_pick_mode() {
  local mode="$1" from="$2" to="$3" user="$4" wt="$5" work="$6" home dir sid max size
  [[ "$mode" == B ]] && { echo "B (HANDOVER_MODE=B)"; return 0; }
  [[ "$to" == "$from" ]] || { echo "B (TO_ID $to != $from: another worktree path than the session's)"; return 0; }
  home="${HANDOVER_AGENT_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  dir="$home/.vibe/logs/session/unified"
  sid="$(spl_handover_mistral_sid "$user" "$dir" "$wt")"
  [[ -n "$sid" ]] || { echo "B (no vibe session of $wt under $dir for $user)"; return 0; }
  printf '%s' "$sid" >"$work/sid"
  spl_handover_as "$user" tar -C "$dir" -cf - "./$sid" >"$work/session.tar" 2>/dev/null ||
    { rm -f "$work/session.tar"; echo "B (cannot read session $sid as $user)"; return 0; }
  max="${HANDOVER_TRANSCRIPT_MAX_MB:-100}" size="$(stat -c %s "$work/session.tar")"
  (( size <= max * 1048576 )) || { rm -f "$work/session.tar"; echo "B (session $((size / 1048576)) MB > ${max} MB)"; return 0; }
  zstd -q -o "$work/session.tar.zst" <"$work/session.tar" &&
    bash "${HANDOVER_PACK_SH:-$(spl_handover_pack_sh)}" scan "$work/session.tar.zst" >/dev/null 2>&1
  local src=$?
  rm -f "$work/session.tar.zst"
  (( src == 0 )) || { rm -f "$work/session.tar"; echo "B (the session scan found key material, or failed: it stays on this box)"; return 0; }
  echo "A"
}

# spl_handover_mistral_sid USER DIR WT -> the newest root vibe session in DIR
# (by its CURRENT's mtime) whose meta.json working_directory is WT, else nothing
spl_handover_mistral_sid() {
  local user="$1" dir="$2" wt="$3" _t d meta
  while read -r _t d; do
    meta="$(spl_handover_as "$user" cat "$d/meta.json" 2>/dev/null)" || continue
    jq -e --arg w "$wt" '.parent_session_id == null and .environment.working_directory == $w' <<<"$meta" >/dev/null 2>&1 || continue
    d="${d##*/}"
    [[ "$d" =~ ^[0-9a-f-]{36}$ ]] && { printf '%s' "$d"; return 0; }
  done < <(spl_handover_as "$user" find "$dir" -mindepth 2 -maxdepth 2 -name CURRENT -printf '%T@ %h\n' 2>/dev/null | sort -rn)
  return 0
}

# spl_handover_mistral_on DEST owner|agent OP ARGS...: one mistral step on the
# target box (spl_handover_on's transport, this file's remote script)
spl_handover_mistral_on() {
  local dest="$1" who="$2" u; shift 2
  u="${HO_OWNER:-}"; [[ "$who" == agent ]] && u="${HO_AGENT:-}"
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ${HANDOVER_SSH:-ssh -o BatchMode=yes} "$dest" "$(printf '%q ' sudo -n -u "$u" -H bash -c "$(spl_handover_mistral_remote_script)" lane-handover-mistral "$@")"
}

# The mistral remote steps, run on the target box. session | resume | spawn
spl_handover_mistral_remote_script() {
  cat <<'SCRIPT'
op="$1"; shift
case "$op" in
  session)
    # staged in a dir vibe ignores (no CURRENT), then swapped in: a rerun replaces it
    umask 077
    d="$HOME/.vibe/logs/session/unified" in="$HOME/.vibe/logs/session/unified/.handover-$1"
    rm -rf "$in" && mkdir -p "$in" && tar -x -C "$in" -f - && [ -f "$in/$1/CURRENT" ] ||
      { rm -rf "$in"; echo "the session tar did not unpack to $1/CURRENT" >&2; exit 1; }
    rm -rf "${d:?}/$1" && mv "$in/$1" "$d/$1" && rmdir "$in" && echo ok ;;
  resume)
    scripts="$1" id="$2" wt="$3" sid="$4" brief="$5" agent="$6"
    . "$scripts/../lib/spool-env.inc.sh"; spool_env_resolve; spool_tmux_argv
    bash "$scripts/next-agent-id.sh" --claim "$id" >/dev/null || { echo "id $id is taken here" >&2; exit 3; }
    sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_attached} #{session_id}' 2>/dev/null | awk '$1 > 0 {print $2; exit}')"
    [ -n "$sess" ] || sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_id}' 2>/dev/null | sed -n 1p)"
    [ -n "$sess" ] || { echo "no tmux session" >&2; exit 5; }
    pane="$("${SPOOL_TM[@]}" new-window -d -t "$sess:" -n "$(spool_decorate "$id")" -P -F '#{pane_id}' \
      "env SPOOL_AGENT_USER=$agent bash '$scripts/restore-mistral.sh' '$id' '$wt' '$sid' '$brief'" | grep -xE '%[0-9]+' | sed -n 1p)"
    [ -n "$pane" ] || { echo "new-window printed no pane" >&2; exit 4; }
    printf '%s\tmistral\t%s\t%s\t%s\t-\n' "$id" "$pane" "$wt" "$(date -u +%Y%m%dT%H%M%SZ)" >>"$SPOOL_ROOT/registry.tsv"
    echo "$id $pane" ;;
  spawn)
    bash "$1/spawn-window.sh" mistral "$2" "$3" "$4" handover ;;
  *) echo "unknown op $op" >&2; exit 2 ;;
esac
SCRIPT
}
