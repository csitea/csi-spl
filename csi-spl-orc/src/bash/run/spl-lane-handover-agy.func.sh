#!/bin/bash
#------------------------------------------------------------------------------
# @description Hand an agy lane over to a new agent on another box (owner
# @description t1 ba8104f6, topic ab98ad27): the shape of do_spl_lane_handover
# @description (claude), whose helpers it calls; only the session part is agy's.
# @description   Where agy keeps a conversation <c>: the agent user's
# @description   ~/.gemini/antigravity-cli/conversations/<c>.db (+ -wal, -shm,
# @description   .pb), brain/<c>/ and annotations/<c>.pbtxt; its presence lock
# @description   stays behind. `agy --conversation <c>` (restore-agy.sh) resumes
# @description   it on any box. The identity record of an a- lane has no session
# @description   id, so the conversation is CONVERSATION_ID, else the one FROM's
# @description   live agy holds open, else the newest history.jsonl line whose
# @description   workspace is FROM's worktree.
# @description   1. WIP: do_spl_lane_handover_wip, scan first (a hit = exit 3,
# @description      nothing pushed, FROM untouched, no ssh call).
# @description   2. A: BEFORE FROM is closed, the conversation goes over ssh
# @description      stdin ONLY (never the hub, git or a log) into the target
# @description      AGENT_USER's ~/.gemini/antigravity-cli; a failed copy = exit 4,
# @description      FROM untouched, nothing pushed.
# @description   3. FROM closed, its WIP pushed, the new worktree <repo>-wt/<TO_ID>
# @description      on TO_BOX at the wip ref; A: restore-agy.sh starts
# @description      `agy --conversation <c>` in a new tmux window, as the agent user.
# @description   4. B, written handoff: TO_ID != FROM, no conversation, bigger
# @description      than HANDOVER_TRANSCRIPT_MAX_MB, key material in it, or
# @description      HANDOVER_MODE=B: spawn-window.sh agy starts a fresh agent with
# @description      the handover brief.
# @description   5. FROM retired after the start (RETIRE_WORKTREE=0), so it never
# @description      runs on both boxes; a failure after the WIP push returns 4 and
# @description      names the step. The new agent deletes the wip ref after its
# @description      first landed push.
# @description Dry run unless DRY_RUN=0: the WIP scan, the mode and the plan, no ssh.
# @param FROM (required) - the lane to hand over, an agy id on this box (a-NNN)
# @param TO_BOX (required) - the target box id (its BOX_TAG, e.g. sat)
# @param TO_ID (optional) - the new id, default FROM (same worktree path: A)
# @param HANDOVER_MODE (optional) - auto (default), A or B
# @param HANDOVER_TRANSCRIPT_MAX_MB (optional) - default 100; a bigger conversation = B
# @param CONVERSATION_ID (optional) - FROM's agy conversation, default resolved as above
# @param BOX_SSH_<BOX> (optional) - the ssh destination, default the satellite alias
# @param DRY_RUN (optional) - 1 (default) or 0
# @example FROM=a-050 TO_BOX=sat ./run -a do_spl_lane_handover_agy
# @example FROM=a-050 TO_BOX=sat DRY_RUN=0 ./run -a do_spl_lane_handover_agy
#------------------------------------------------------------------------------

do_spl_lane_handover_agy() {
  do_require_bin jq tar zstd || return 1
  local from="${FROM:-}" box="${TO_BOX:-}" to="${TO_ID:-${FROM:-}}" mode="${HANDOVER_MODE:-auto}" dry="${DRY_RUN:-1}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" here
  [[ "$from" =~ ^a-[0-9]{3}$ ]] || { do_log "FATAL FROM must be an agy lane id (a-NNN), got '$from'"; return 1; }
  [[ "$to" =~ ^a-[0-9]{3}$ ]] || { do_log "FATAL TO_ID must be an agy lane id (a-NNN), got '$to'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TO_BOX must be a box id (e.g. sat), got '$box'"; return 1; }
  [[ "$mode" =~ ^(auto|A|B)$ ]] || { do_log "FATAL HANDOVER_MODE must be auto, A or B, got '$mode'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  here="$(spl_box_state_box)" || return 1
  [[ "$box" != "$here" || "$to" != "$from" ]] || { do_log "FATAL TO_BOX is this box ($here): give a TO_ID other than $from"; return 1; }

  local rec="$root/agents/$from.json" wt user kind repo
  [[ -r "$rec" ]] || { do_log "FATAL no identity record $rec"; return 1; }
  kind="$(jq -r '.kind // ""' "$rec")"; wt="$(jq -r '.worktree // ""' "$rec")"; user="$(jq -r '.user // ""' "$rec")"
  [[ "$kind" == agy ]] || { do_log "FATAL $from is a '$kind' lane: this action hands over agy lanes"; return 1; }
  [[ -d "$wt" ]] || { do_log "FATAL $from: worktree '$wt' is not here"; return 1; }
  repo="$(spl_handover_main_checkout "$wt")" || { do_log "FATAL $from: $wt is not a linked worktree of a checkout"; return 1; }

  local out rc=0
  out="$(ID="$from" WIP_WORKTREE="$wt" DRY_RUN=1 do_spl_lane_handover_wip 2>&1)" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL HANDOVER $from: the WIP step refused (exit $rc): nothing handed over, $from untouched"; return "$rc"; }

  local work why conv
  work="$(umask 077 && mktemp -d)" || return 1
  why="$(spl_handover_agy_pick_mode "$mode" "$from" "$to" "$user" "$wt" "$work")"
  conv="$(cat "$work/conv" 2>/dev/null)"
  local m="${why%% *}" newwt="$repo-wt/$to"
  echo "HANDOVER $from@$here -> $to@$box mode=$why"
  if (( dry )); then
    spl_handover_agy_plan "$from" "$to" "$box" "$m" "$repo" "$newwt" "$conv"
    rm -rf "$work"; return 0
  fi
  spl_handover_agy_live "$from" "$to" "$box" "$here" "$m" "$wt" "$repo" "$conv" "$work"; rc=$?
  rm -rf "$work"
  return "$rc"
}

# spl_handover_agy_plan FROM TO BOX MODE REPO NEWWT CONV: the dry-run plan
spl_handover_agy_plan() {
  local from="$1" to="$2" box="$3" m="$4" repo="$5" newwt="$6" conv="$7"
  echo "PLAN close   $from (tmux-close-window.sh --agent $from)"
  echo "PLAN wip     push refs/heads/wip/handover/$from"
  echo "PLAN prep    ssh $box: worktree $newwt on branch $to-handover at refs/heads/wip/handover/$from"
  [[ "$m" == A ]] && echo "PLAN session ssh $box: agy conversation $conv -> the agent user's ~/.gemini/antigravity-cli; restore-agy.sh $to $newwt $conv (agy --conversation $conv)"
  [[ "$m" == B ]] && echo "PLAN spawn   ssh $box: spawn-window.sh agy $to $repo <handover brief>"
  echo "PLAN retire  $from (agent-id-retire.sh --apply, RETIRE_WORKTREE=0)"
  do_log "OK DRY_RUN nothing was handed over. DRY_RUN=0 does it."
}

# spl_handover_agy_live FROM TO BOX HERE MODE WT REPO CONV WORK: the side
# effects, in order; the first failure stops non-zero with what is left to do
spl_handover_agy_live() {
  local from="$1" to="$2" box="$3" here="$4" m="$5" wt="$6" repo="$7" conv="$8" work="$9"
  local root="${SPOOL_ROOT:-/var/spool-hub}" scripts newwt="$repo-wt/$to" ref="refs/heads/wip/handover/$from"
  local out rc=0 sha dest brief rbrief
  scripts="$(spl_handover_scripts_dir "$repo")"
  dest="$(spl_handover_dest "$box")"
  spl_handover_probe "$dest" "$box" "$repo" "$newwt" || return 1
  # the conversation first: a failed copy stops before FROM is closed or anything is pushed
  if [[ "$m" == A ]]; then
    spl_handover_agy_on "$dest" agent session "$conv" <"$work/session.tar" >"$work/tr" 2>&1 ||
      { do_log "FATAL HANDOVER $from: step session, the conversation copy to $box failed ($(tail -n1 "$work/tr")): $from untouched, nothing pushed; HANDOVER_MODE=B hands over without it"; return 4; }
    echo "COPIED  agy conversation $conv to $box (ssh)"
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
    { do_log "FATAL HANDOVER $from: step prep, worktree on $box: $(tail -n1 "$work/prep")"; return 4; }
  echo "PREPARED $newwt on $box at ${sha:0:12}"

  brief="$work/brief.md" rbrief="$root/handover/$to-from-$from.md"
  spl_handover_brief "$from" "$to" "$box" "$here" "$m" "$wt" "$newwt" "$ref" "$sha" >"$brief"
  spl_handover_on "$dest" owner brief "$rbrief" <"$brief" >/dev/null 2>&1 || { do_log "FATAL HANDOVER $from: step brief, cannot write $rbrief on $box"; return 4; }
  spl_handover_agy_start "$from" "$to" "$box" "$m" "$dest" "$scripts" "$repo" "$conv $rbrief" || return 4

  out="$(RETIRE_WORKTREE=0 ${HANDOVER_RETIRE_CMD:-bash "$scripts/agent-id-retire.sh"} --apply "$from" 2>&1)" ||
    echo "WARN retire $from: $(tail -n1 <<<"$out")"
  echo "OK HANDOVER $from@$here -> $to@$box mode=$m wip=${sha:0:12}; $wt stays until $to lands, then git -C $repo worktree remove $wt"
}

# spl_handover_agy_start FROM TO BOX MODE DEST SCRIPTS REPO "CONV RBRIEF": A
# resumes the conversation (restore-agy.sh), B spawns a fresh agy; prints
# STARTED, or FATAL and returns 1 when no pane came back
spl_handover_agy_start() {
  local from="$1" to="$2" box="$3" m="$4" dest="$5" scripts="$6" repo="$7" conv="${8%% *}" rbrief="${8#* }"
  local out rc=0 pane newwt="$repo-wt/$2"
  if [[ "$m" == A ]]; then
    out="$(spl_handover_agy_on "$dest" owner resume "$scripts" "$to" "$newwt" "$conv" "$rbrief" "$HO_AGENT" </dev/null 2>&1)" || rc=$?
  else
    out="$(spl_handover_agy_on "$dest" owner spawn "$scripts" "$to" "$repo" "$rbrief" </dev/null 2>&1)" || rc=$?
  fi
  pane="$(grep -E "^$to(@[a-z0-9-]+)? %[0-9]+$" <<<"$out" | tail -1 | cut -d' ' -f2)"
  [[ -n "$pane" ]] || { do_log "FATAL HANDOVER $from: step start, $to on $box failed (exit $rc): $(tail -n2 <<<"$out" | tr '\n' ' ')"; return 1; }
  echo "STARTED $to@$box $pane mode=$m"
}

# spl_handover_agy_pick_mode MODE FROM TO USER WT WORK -> "A" or "B (<why>)";
# leaves the conversation id at WORK/conv
spl_handover_agy_pick_mode() {
  local mode="$1" from="$2" to="$3" user="$4" wt="$5" work="$6" conv
  [[ "$mode" == B ]] && { echo "B (HANDOVER_MODE=B)"; return 0; }
  [[ "$to" == "$from" ]] || { echo "B (TO_ID $to != $from: another worktree path than the conversation's)"; return 0; }
  conv="$(spl_handover_agy_conv "$user" "$from" "$wt")"
  [[ -n "$conv" ]] || { echo "B (no agy conversation of $from: none open, none in history.jsonl for $wt)"; return 0; }
  printf '%s' "$conv" >"$work/conv"
  spl_handover_agy_pack "$user" "$conv" "$work" >"$work/pack" || { echo "B ($(cat "$work/pack"))"; return 0; }
  echo "A"
}

# spl_handover_agy_home USER -> the agent user's agy dir
spl_handover_agy_home() { printf '%s/.gemini/antigravity-cli' "${HANDOVER_AGENT_HOME:-$(getent passwd "$1" | cut -d: -f6)}"; }

# spl_handover_agy_conv USER FROM WT -> CONVERSATION_ID, else the conversation
# db FROM's live agy holds open, else the newest history.jsonl line of WT
spl_handover_agy_conv() {
  local user="$1" from="$2" wt="$3" dir c
  [[ -n "${CONVERSATION_ID:-}" ]] && { printf '%s' "$CONVERSATION_ID"; return 0; }
  dir="$(spl_handover_agy_home "$user")"
  # shellcheck disable=SC2016 # expanded by the user's bash
  c="$(spl_handover_as "$user" bash -c 'for p in $(pgrep -u "$(id -u)" 2>/dev/null); do
      tr "\0" "\n" <"/proc/$p/environ" 2>/dev/null | grep -x "SPOOL_AGENT_ID=$1" >/dev/null || continue
      for f in /proc/$p/fd/*; do readlink "$f"; done; done' agy-conv "$from" 2>/dev/null |
    sed -n "s#^$dir/conversations/\([0-9a-f-]\{36\}\)\.db\$#\1#p" | sed -n 1p)"
  [[ -z "$c" ]] && c="$(spl_handover_as "$user" cat "$dir/history.jsonl" 2>/dev/null |
    jq -r --arg w "$wt" 'select(.workspace == $w) | .conversationId // empty' 2>/dev/null | tail -n1)"
  [[ "$c" =~ ^[0-9a-f-]{36}$ ]] && printf '%s' "$c"
  return 0
}

# spl_handover_agy_pack USER CONV WORK: WORK/session.tar of the conversation,
# under HANDOVER_TRANSCRIPT_MAX_MB and clean of key material; else the reason, 1
spl_handover_agy_pack() {
  local user="$1" conv="$2" work="$3" dir max size src f
  dir="$(spl_handover_agy_home "$user")"
  rm -f "$work/session.tar"
  local -a members=()
  for f in "conversations/$conv.db" "conversations/$conv.db-wal" "conversations/$conv.db-shm" "conversations/$conv.pb" "brain/$conv" "annotations/$conv.pbtxt"; do
    spl_handover_as "$user" test -e "$dir/$f" && members+=("./$f")
  done
  [[ " ${members[*]} " == *" ./conversations/$conv.db "* ]] || { echo "no conversation db $conv for $user"; return 1; }
  spl_handover_as "$user" tar -C "$dir" -cf - "${members[@]}" >"$work/session.tar" 2>/dev/null ||
    { rm -f "$work/session.tar"; echo "cannot read conversation $conv as $user"; return 1; }
  max="${HANDOVER_TRANSCRIPT_MAX_MB:-100}" size="$(stat -c %s "$work/session.tar")"
  (( size <= max * 1048576 )) || { rm -f "$work/session.tar"; echo "conversation $((size / 1048576)) MB > ${max} MB"; return 1; }
  zstd -q -o "$work/session.tar.zst" <"$work/session.tar" &&
    bash "${HANDOVER_PACK_SH:-$(spl_handover_pack_sh)}" scan "$work/session.tar.zst" >/dev/null 2>&1
  src=$?
  rm -f "$work/session.tar.zst"
  (( src == 0 )) || { rm -f "$work/session.tar"; echo "the conversation scan found key material, or failed: it stays on this box"; return 1; }
}

# spl_handover_agy_on DEST owner|agent OP ARGS...: one agy step on the target
# box (spl_handover_on's transport, this file's remote script)
spl_handover_agy_on() {
  local dest="$1" who="$2" u; shift 2
  u="${HO_OWNER:-}"; [[ "$who" == agent ]] && u="${HO_AGENT:-}"
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ${HANDOVER_SSH:-ssh -o BatchMode=yes} "$dest" "$(printf '%q ' sudo -n -u "$u" -H bash -c "$(spl_handover_agy_remote_script)" lane-handover-agy "$@")"
}

# The agy remote steps, run on the target box. session | resume | spawn
spl_handover_agy_remote_script() {
  cat <<'SCRIPT'
op="$1"; shift
case "$op" in
  session)
    # staged beside the store, then swapped in member by member: a rerun replaces it
    umask 077
    d="$HOME/.gemini/antigravity-cli" in="$HOME/.gemini/.handover-$1"
    rm -rf "$in" && mkdir -p "$in" && tar -x -C "$in" -f - && [ -f "$in/conversations/$1.db" ] ||
      { rm -rf "$in"; echo "the conversation tar did not unpack to conversations/$1.db" >&2; exit 1; }
    for m in conversations/"$1".db conversations/"$1".db-wal conversations/"$1".db-shm conversations/"$1".pb brain/"$1" annotations/"$1".pbtxt; do
      rm -rf "${d:?}/$m"; [ ! -e "$in/$m" ] || { mkdir -p "$d/${m%/*}" && mv "$in/$m" "$d/$m"; } || exit 1
    done
    rm -rf "$in" && echo ok ;;
  resume)
    scripts="$1" id="$2" wt="$3" conv="$4" brief="$5" agent="$6"
    . "$scripts/../lib/spool-env.inc.sh"; spool_env_resolve; spool_tmux_argv
    bash "$scripts/next-agent-id.sh" --claim "$id" >/dev/null || { echo "id $id is taken here" >&2; exit 3; }
    bash "$scripts/trust-workdir.sh" "$wt" "$agent" agy >/dev/null 2>&1 || true
    sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_attached} #{session_id}' 2>/dev/null | awk '$1 > 0 {print $2; exit}')"
    [ -n "$sess" ] || sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_id}' 2>/dev/null | sed -n 1p)"
    [ -n "$sess" ] || { echo "no tmux session" >&2; exit 5; }
    kick="HANDOVER: this conversation moved to $(spool_decorate "$id"), worktree $wt. Read your handover brief at $brief, then continue the lane from there."
    pane="$("${SPOOL_TM[@]}" new-window -d -t "$sess:" -n "$(spool_decorate "$id")" -P -F '#{pane_id}' \
      "env SPOOL_AGENT_USER=$agent bash '$scripts/restore-agy.sh' '$id' '$wt' '$conv' '$kick'" | grep -xE '%[0-9]+' | sed -n 1p)"
    [ -n "$pane" ] || { echo "new-window printed no pane" >&2; exit 4; }
    printf '%s\tagy\t%s\t%s\t%s\t-\n' "$id" "$pane" "$wt" "$(date -u +%Y%m%dT%H%M%SZ)" >>"$SPOOL_ROOT/registry.tsv"
    echo "$id $pane" ;;
  spawn)
    bash "$1/spawn-window.sh" agy "$2" "$3" "$4" handover ;;
  *) echo "unknown op $op" >&2; exit 2 ;;
esac
SCRIPT
}
