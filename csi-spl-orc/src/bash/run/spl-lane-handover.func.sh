#!/bin/bash
#------------------------------------------------------------------------------
# @description Hand a claude lane over to a new agent on another box (owner
# @description t1 ba8104f6, msgs 6d3cafa7 + b072af77; design 1 + A, B fallback).
# @description   1. WIP: do_spl_lane_handover_wip scans and pushes FROM's
# @description      uncommitted work and unpushed commits to
# @description      refs/heads/wip/handover/<FROM>. A scan hit = exit 3: nothing
# @description      pushed, FROM untouched, no ssh call.
# @description   2. the new worktree on TO_BOX, <repo>-wt/<TO_ID>, on branch
# @description      <TO_ID>-handover starting AT that ref (over ssh, as the box's
# @description      OWNER_USER).
# @description   3. A, session resume: FROM's transcript (<sid>.jsonl + <sid>/)
# @description      goes over ssh ONLY (never the hub, git or a log) into the
# @description      target AGENT_USER's ~/.claude/projects/<same slug>, then
# @description      restore-claude.sh resumes it in a new tmux window (bypass flags
# @description      from spool_claude_perm_flags, as the agent user).
# @description   4. B, written handoff: when A cannot work (TO_ID != FROM so the
# @description      slug differs, no transcript, bigger than
# @description      HANDOVER_TRANSCRIPT_MAX_MB, key material in it, HANDOVER_MODE=B,
# @description      or the copy failed) spawn-window.sh starts a fresh agent on
# @description      the target with the handover brief (FROM's brief, task id, last
# @description      outbox report and the spec 102 handoff.md).
# @description   5. FROM is closed (tmux-close-window.sh --agent) before its WIP
# @description      is pushed and retired after the start (agent-id-retire.sh,
# @description      RETIRE_WORKTREE=0: its worktree stays until the new lane lands).
# @description   6. the new agent deletes refs/heads/wip/handover/<FROM> after its
# @description      first landed push (its handover brief says so).
# @description The box is reached by BOX_SSH_<BOX>, else the satellite alias; its
# @description /etc/csi-spl-satellite.env must name BOX_TAG=<TO_BOX>. Dry run
# @description unless DRY_RUN=0: the WIP scan, the mode and the plan, no ssh call.
# @param FROM (required) - the lane to hand over, a claude id on this box (c-NNN)
# @param TO_BOX (required) - the target box id (its BOX_TAG, e.g. sat)
# @param TO_ID (optional) - the new id, default FROM (same worktree path = same session slug: A)
# @param HANDOVER_MODE (optional) - auto (default), A or B
# @param HANDOVER_TRANSCRIPT_MAX_MB (optional) - default 100; bigger = B
# @param BOX_SSH_<BOX> (optional) - the ssh destination (<BOX>: upper case, - as _), default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite
# @param DRY_RUN (optional) - 1 (default) or 0
# @example FROM=c-050 TO_BOX=sat ./run -a do_spl_lane_handover
# @example FROM=c-050 TO_BOX=sat DRY_RUN=0 ./run -a do_spl_lane_handover
#------------------------------------------------------------------------------

do_spl_lane_handover() {
  do_require_bin jq tar zstd || return 1
  local from="${FROM:-}" box="${TO_BOX:-}" to="${TO_ID:-${FROM:-}}" mode="${HANDOVER_MODE:-auto}" dry="${DRY_RUN:-1}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" here
  [[ "$from" =~ ^c-[0-9]{3}$ ]] || { do_log "FATAL FROM must be a claude lane id (c-NNN), got '$from'"; return 1; }
  [[ "$to" =~ ^c-[0-9]{3}$ ]] || { do_log "FATAL TO_ID must be a claude lane id (c-NNN), got '$to'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TO_BOX must be a box id (e.g. sat), got '$box'"; return 1; }
  [[ "$mode" =~ ^(auto|A|B)$ ]] || { do_log "FATAL HANDOVER_MODE must be auto, A or B, got '$mode'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  here="$(spl_box_state_box)" || return 1
  [[ "$box" != "$here" || "$to" != "$from" ]] || { do_log "FATAL TO_BOX is this box ($here): give a TO_ID other than $from"; return 1; }

  local rec="$root/agents/$from.json" wt sid user kind repo
  [[ -r "$rec" ]] || { do_log "FATAL no identity record $rec"; return 1; }
  kind="$(jq -r '.kind // ""' "$rec")"; sid="$(jq -r '.session_id // ""' "$rec")"
  wt="$(jq -r '.worktree // ""' "$rec")"; user="$(jq -r '.user // ""' "$rec")"
  [[ "$kind" == claude ]] || { do_log "FATAL $from is a '$kind' lane: this action hands over claude lanes (agy, mistral: their own actions)"; return 1; }
  [[ -d "$wt" ]] || { do_log "FATAL $from: worktree '$wt' is not here"; return 1; }
  repo="$(spl_handover_main_checkout "$wt")" || { do_log "FATAL $from: $wt is not a linked worktree of a checkout"; return 1; }

  # 1. the scan first: a refusal stops everything before FROM is touched
  local out rc=0
  out="$(ID="$from" WIP_WORKTREE="$wt" DRY_RUN=1 do_spl_lane_handover_wip 2>&1)" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL HANDOVER $from: the WIP step refused (exit $rc): nothing handed over, $from untouched"; return "$rc"; }

  local work tr="" why
  work="$(umask 077 && mktemp -d)" || return 1
  why="$(spl_handover_pick_mode "$mode" "$from" "$to" "$user" "$wt" "$sid" "$work")"
  [[ -f "$work/transcript.tar" ]] && tr="$work/transcript.tar"
  local m="${why%% *}" newwt="$repo-wt/$to" ref="refs/heads/wip/handover/$from"
  echo "HANDOVER $from@$here -> $to@$box mode=$why"
  if (( dry )); then
    echo "PLAN close   $from (tmux-close-window.sh --agent $from)"
    echo "PLAN wip     push $ref"
    echo "PLAN prep    ssh $box: worktree $newwt on branch $to-handover at $ref"
    [[ "$m" == A ]] && echo "PLAN session ssh $box: transcript $sid -> the agent user's ~/.claude/projects/$(spl_handover_slug "$newwt"); restore-claude.sh $to $newwt $sid"
    [[ "$m" == B ]] && echo "PLAN spawn   ssh $box: spawn-window.sh claude $to $repo <handover brief>"
    echo "PLAN retire  $from (agent-id-retire.sh --apply, RETIRE_WORKTREE=0)"
    do_log "OK DRY_RUN nothing was handed over. DRY_RUN=0 does it."
    rm -rf "$work"; return 0
  fi
  spl_handover_live "$from" "$to" "$box" "$here" "$m" "$wt" "$repo" "$sid" "$tr" "$work"; rc=$?
  rm -rf "$work"
  return "$rc"
}

# spl_handover_live FROM TO BOX HERE MODE WT REPO SID TRANSCRIPT_TAR WORK: the
# side effects, in order; the first failure stops with what is left to do
spl_handover_live() {
  local from="$1" to="$2" box="$3" here="$4" m="$5" wt="$6" repo="$7" sid="$8" tr="$9" work="${10}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" scripts newwt="$repo-wt/$to" ref="refs/heads/wip/handover/$from"
  local out rc=0 sha agent dest brief rbrief pane
  scripts="$(spl_handover_scripts_dir "$repo")"
  dest="$(spl_handover_dest "$box")"
  spl_handover_probe "$dest" "$box" "$repo" "$newwt" || return 1
  agent="$HO_AGENT"

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
  if [[ "$m" == A ]]; then
    if spl_handover_on "$dest" agent transcript "$(spl_handover_slug "$newwt")" "$sid" <"$tr" >"$work/tr" 2>&1; then
      echo "COPIED  transcript $sid to $box (ssh)"
    else
      echo "WARN transcript copy failed ($(tail -n1 "$work/tr")): falling back to B"; m=B
      spl_handover_brief "$from" "$to" "$box" "$here" B "$wt" "$newwt" "$ref" "$sha" >"$brief"
    fi
  fi
  spl_handover_on "$dest" owner brief "$rbrief" <"$brief" >/dev/null 2>&1 || { do_log "FATAL HANDOVER $from: cannot write $rbrief on $box"; return 1; }
  rc=0
  if [[ "$m" == A ]]; then
    out="$(spl_handover_on "$dest" owner resume "$scripts" "$to" "$newwt" "$sid" "$rbrief" "$agent" </dev/null 2>&1)" || rc=$?
  else
    out="$(spl_handover_on "$dest" owner spawn "$scripts" "$to" "$repo" "$rbrief" </dev/null 2>&1)" || rc=$?
  fi
  pane="$(grep -E "^$to(@[a-z0-9-]+)? %[0-9]+$" <<<"$out" | tail -1 | cut -d' ' -f2)"
  [[ -n "$pane" ]] || { do_log "FATAL HANDOVER $from: the start of $to on $box failed (exit $rc): $(tail -n2 <<<"$out" | tr '\n' ' ')"; return 1; }
  echo "STARTED $to@$box $pane mode=$m"

  out="$(RETIRE_WORKTREE=0 ${HANDOVER_RETIRE_CMD:-bash "$scripts/agent-id-retire.sh"} --apply "$from" 2>&1)" ||
    echo "WARN retire $from: $(tail -n1 <<<"$out")"
  echo "OK HANDOVER $from@$here -> $to@$box mode=$m wip=${sha:0:12}; $wt stays until $to lands, then git -C $repo worktree remove $wt"
}

# spl_handover_pick_mode MODE FROM TO USER WT SID WORK -> "A" or "B (<why>)";
# for A it leaves the transcript tar at WORK/transcript.tar
spl_handover_pick_mode() {
  local mode="$1" from="$2" to="$3" user="$4" wt="$5" sid="$6" work="$7" home slug max size
  [[ "$mode" == B ]] && { echo "B (HANDOVER_MODE=B)"; return 0; }
  [[ "$to" == "$from" ]] || { echo "B (TO_ID $to != $from: another worktree path, another session slug)"; return 0; }
  [[ "$sid" =~ ^[0-9a-f-]{36}$ ]] || { echo "B (no session id in the identity record)"; return 0; }
  home="${HANDOVER_AGENT_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  slug="$(spl_handover_slug "$wt")"
  [[ -n "$home" ]] && spl_handover_as "$user" test -f "$home/.claude/projects/$slug/$sid.jsonl" ||
    { echo "B (no transcript $slug/$sid.jsonl for $user)"; return 0; }
  # ./ first: a slug starts with "-", which tar would read as an option
  local -a members=("./$slug/$sid.jsonl")
  spl_handover_as "$user" test -d "$home/.claude/projects/$slug/$sid" && members+=("./$slug/$sid")
  spl_handover_as "$user" tar -C "$home/.claude/projects" -cf - "${members[@]}" >"$work/transcript.tar" 2>/dev/null ||
    { rm -f "$work/transcript.tar"; echo "B (cannot read the transcript as $user)"; return 0; }
  max="${HANDOVER_TRANSCRIPT_MAX_MB:-100}" size="$(stat -c %s "$work/transcript.tar")"
  (( size <= max * 1048576 )) || { rm -f "$work/transcript.tar"; echo "B (transcript $((size / 1048576)) MB > ${max} MB)"; return 0; }
  zstd -q -o "$work/transcript.tar.zst" <"$work/transcript.tar" &&
    bash "${HANDOVER_PACK_SH:-$(spl_handover_pack_sh)}" scan "$work/transcript.tar.zst" >/dev/null 2>&1
  local src=$?
  rm -f "$work/transcript.tar.zst"
  (( src == 0 )) || { rm -f "$work/transcript.tar"; echo "B (the transcript scan found key material, or failed: it stays on this box)"; return 0; }
  [[ "$mode" == A || "$mode" == auto ]] && echo "A"
}

# spl_handover_as USER CMD...: CMD as USER (sudo -n when that is another user)
spl_handover_as() {
  local u="$1"; shift
  if [[ -z "$u" || "$u" == "$(id -un)" ]]; then "$@"; else sudo -n -u "$u" "$@"; fi
}

# spl_handover_slug PATH -> Claude Code's project dir name for a cwd
spl_handover_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

spl_handover_pack_sh() { printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/box-state-pack.sh"; }

# spl_handover_main_checkout WT -> the main checkout WT is a linked worktree of
spl_handover_main_checkout() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == */.git && -d "${common%/.git}" ]] || return 1
  printf '%s' "${common%/.git}"
}

# spl_handover_scripts_dir REPO -> the spawn-agents scripts dir (the same path on every box)
spl_handover_scripts_dir() { printf '%s' "${HANDOVER_SCRIPTS_DIR:-$1/csi-spl-orc/src/bash/features/spawn-agents/scripts}"; }

# spl_handover_dest BOX -> BOX_SSH_<BOX>, else the satellite alias
spl_handover_dest() {
  local k s
  k="$(tr 'a-z-' 'A-Z_' <<<"$1")"; s="BOX_SSH_$k"
  printf '%s' "${!s:-${SATELLITE_ALIAS:-satellite}}"
}

# spl_handover_probe DEST BOX REPO NEWWT -> sets HO_AGENT / HO_OWNER; refuses a
# box answering to another tag, no checkout, or a worktree already there
spl_handover_probe() {
  local dest="$1" box="$2" repo="$3" newwt="$4" envf tag agent
  envf="$(${HANDOVER_SSH:-ssh -o BatchMode=yes} "$dest" 'cat /etc/csi-spl-satellite.env' </dev/null 2>/dev/null)" ||
    { do_log "FATAL ssh $dest: cannot read its /etc/csi-spl-satellite.env" >&2; return 1; }
  tag="$(sed -n 's/^BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' <<<"$envf")"
  agent="$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  HO_OWNER="$(sed -n 's/^OWNER_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  [[ "$tag" == "$box" ]] || { do_log "FATAL ssh $dest answers as box '${tag:-?}', not '$box': nothing done" >&2; return 1; }
  [[ -n "$agent" && -n "$HO_OWNER" ]] || { do_log "FATAL box $box names no AGENT_USER / OWNER_USER" >&2; return 1; }
  HO_AGENT="$agent"
  local p
  p="$(spl_handover_on "$dest" owner probe "$repo" "$newwt" </dev/null 2>/dev/null)"
  grep -qx 'repo yes' <<<"$p" || { do_log "FATAL box $box has no checkout $repo" >&2; return 1; }
  grep -qx 'wt free' <<<"$p" || { do_log "FATAL box $box already has $newwt: nothing done" >&2; return 1; }
}

# spl_handover_on DEST owner|agent OP ARGS...: one step of the remote script,
# as the box's OWNER_USER or AGENT_USER; argv carries names only, data rides stdin
spl_handover_on() {
  local dest="$1" who="$2" u; shift 2
  u="${HO_OWNER:-}"; [[ "$who" == agent ]] && u="${HO_AGENT:-}"
  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  ${HANDOVER_SSH:-ssh -o BatchMode=yes} "$dest" "$(printf '%q ' sudo -n -u "$u" -H bash -c "$(spl_handover_remote_script)" lane-handover "$@")"
}

# The remote steps, run on the target box. probe | prep | transcript | brief | resume | spawn
spl_handover_remote_script() {
  cat <<'SCRIPT'
op="$1"; shift
case "$op" in
  probe)
    [ -d "$1/.git" ] && echo "repo yes" || echo "repo no"
    [ -e "$2" ] && echo "wt exists" || echo "wt free" ;;
  prep)
    repo="$1" wt="$2" ref="$3" br="$4" scripts="$5" rb="refs/remotes/origin/${3#refs/heads/}"
    [ ! -e "$wt" ] || { echo "worktree $wt exists" >&2; exit 3; }
    git -C "$repo" fetch -q origin "+$ref:$rb" || { echo "fetch $ref failed" >&2; exit 1; }
    git -C "$repo" worktree add -q -b "$br" "$wt" "$rb" || { echo "worktree add failed" >&2; exit 1; }
    bash "$scripts/install-pre-push-hook.sh" "$wt" >/dev/null 2>&1 || true
    git -C "$wt" rev-parse HEAD ;;
  transcript)
    umask 077
    d="$HOME/.claude/projects"
    [ ! -e "$d/$1/$2.jsonl" ] || { echo "transcript $1/$2.jsonl is already there" >&2; exit 3; }
    mkdir -p "$d" && tar -x -C "$d" -f - && [ -f "$d/$1/$2.jsonl" ] && echo ok ;;
  brief)
    mkdir -p "${1%/*}" && cat >"$1" && chmod 644 "$1" && echo ok ;;
  resume)
    scripts="$1" id="$2" wt="$3" sid="$4" brief="$5" agent="$6"
    . "$scripts/../lib/spool-env.inc.sh"; spool_env_resolve; spool_tmux_argv
    bash "$scripts/next-agent-id.sh" --claim "$id" >/dev/null || { echo "id $id is taken here" >&2; exit 3; }
    sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_attached} #{session_id}' 2>/dev/null | awk '$1 > 0 {print $2; exit}')"
    [ -n "$sess" ] || sess="$("${SPOOL_TM[@]}" list-sessions -F '#{session_id}' 2>/dev/null | sed -n 1p)"
    [ -n "$sess" ] || { echo "no tmux session" >&2; exit 5; }
    pane="$("${SPOOL_TM[@]}" new-window -d -t "$sess:" -n "$(spool_decorate "$id")" -P -F '#{pane_id}' \
      "env SPOOL_AGENT_USER=$agent bash '$scripts/restore-claude.sh' '$id' '$wt' '$sid' '$brief'" | grep -xE '%[0-9]+' | sed -n 1p)"
    [ -n "$pane" ] || { echo "new-window printed no pane" >&2; exit 4; }
    printf '%s\tclaude\t%s\t%s\t%s\t-\n' "$id" "$pane" "$wt" "$(date -u +%Y%m%dT%H%M%SZ)" >>"$SPOOL_ROOT/registry.tsv"
    echo "$id $pane" ;;
  spawn)
    bash "$1/spawn-window.sh" claude "$2" "$3" "$4" handover ;;
  *) echo "unknown op $op" >&2; exit 2 ;;
esac
SCRIPT
}

# spl_handover_brief FROM TO BOX HERE MODE WT NEWWT REF SHA -> the handover brief (stdout)
spl_handover_brief() {
  local from="$1" to="$2" box="$3" here="$4" m="$5" wt="$6" newwt="$7" ref="$8" sha="$9"
  local root="${SPOOL_ROOT:-/var/spool-hub}" d task last reqr
  d="$root/$from"
  reqr="$(awk -F'\t' -v id="$from" '$1 == id {r = $6} END {print r}' "$root/registry.tsv" 2>/dev/null)"
  last="$(ls -1 "$d/outbox"/*.json 2>/dev/null | tail -n 1)"
  task="$( [[ -n "$last" ]] && jq -r '.task_id // ""' "$last" 2>/dev/null)"
  cat <<EOF
# Handover: $to@$box continues the lane $from@$here

Owner t1 ba8104f6. You CONTINUE lane $from's task; you do not start a new one.
Mode $m: $( [[ "$m" == A ]] && echo "your session IS $from's, resumed: what you remember is its work" || echo "a fresh session: $from's own handoff is below")

- Worktree $newwt, branch $to-handover, started at $ref (${sha:0:12}):
  $from's unpushed commits plus its uncommitted work. When the top commit is
  "wip($from): ... handover", it holds that uncommitted work: run
  'git reset --mixed HEAD~1' first, then commit it properly in small commits.
- Spool task: ${task:-unknown (read your inbox)}. Report to ${reqr:-c-001} as $from would have.
- After your FIRST landed push to master: 'git push origin :$ref' (deletes the
  handover ref), and tell ${reqr:-c-001} that $from's old worktree $wt on
  $here may be removed.
- Everything else (scope, integration, closing steps) is $from's brief below.

## $from's brief (verbatim)

$(cat "$d/lifetime/brief.md" 2>/dev/null || echo "(none on $here)")

## $from's last outbox message

$( [[ -n "$last" ]] && jq -r '"kind \(.kind) to \(.to), task \(.task_id), \(.ts)\n\n\(.body | if type == "string" then . else tojson end)"' "$last" 2>/dev/null || echo "(none)")
EOF
  [[ "$m" == B ]] && printf '\n## %s handoff (spec 102)\n\n%s\n' "$from's" "$(cat "$d/handoff.md" 2>/dev/null || echo "(none)")"
  return 0
}
