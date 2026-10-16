#!/bin/bash
#------------------------------------------------------------------------------
# @description Run one `spool doctree` verb (spec 113, the Qto workspace
# @description documents) for a desk agent, without handing the caller the desk
# @description state. The doctree verbs need hub mode: a desk spool root with a
# @description pinned box key, SPOOL_HUB_URL and SPOOL_TENANT. The desk state
# @description dir is 0700 and holds keys/; an agent lane is never pointed at
# @description it nor given a key path (data rule). So, as do_spl_desk_reply
# @description does for replies, the agent names ENV / TENANT_ID / DESK_AGENT
# @description and the verb, and this action resolves the state dir and the
# @description hub from cnf itself and runs the INSTALLED spool binary
# @description (<state>/bin/spool, never a rebuild) as the box user that runs
# @description the action (the owner of the desk state: sudo -u <box user>).
# @description The hub sees the desk box (its role=cli token, rbac pure_agent).
# @description It prints only the verb's output; the desk state path is masked
# @description as <desk> in it and in any error, so no key, token or keys/
# @description path reaches the output.
# @description Refused, before any spool call:
# @description   - a DESK_AGENT with no seat in that desk's roster (its seat
# @description     dir under the desk spool, and the hub roster cache when the
# @description     desk has one)
# @description   - a verb outside the doctree list
# @description   - DOCTREE_IN outside the caller's worktree (APP_PATH), /tmp
# @description     or /var/spool-hub/dispatch, or inside the desk state
# @description   - a file flag (--file, --path) naming any file but
# @description     DOCTREE_IN, and --out (it would write as the box user)
# @description The writing verbs (create add edit move delete rename folder move-node
# @description asset-put) are a dry run unless DRY_RUN=0; the reads (list nodes
# @description head read export asset-get) run as they are.
# @description A write with DRY_RUN=0 is also refused, no spool call, unless
# @description DESK_AGENT is the caller itself: AGENT_ID, else SPOOL_AGENT_ID /
# @description MCP_BOT_AGENT_ID, else the agent id of the tmux window $TMUX_PANE
# @description is in; no caller id is a refusal too (SPL-2078: lanes wrote prd
# @description Qto under c-001's seat). A lane with no seat of its own sends
# @description the DRY_RUN=0 command list to the orchestrator (spec 137
# @description unified-fs.md section 6).
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent the verb runs for (a seat of the desk)
# @param DOCTREE_ARGS - required: the verb and its flags, shell-quoted, e.g.
# @param   `create --title "Rebuild guide"` or `add <doc> --kind para`
# @param DOCTREE_IN (optional) - the one file the verb may read (a body, a
# @param   picture). When DOCTREE_ARGS names no --file / --path it is passed as
# @param   --path for `add --kind picture`, else as --file.
# @param DOCTREE_FS (optional) - the tree: workspace (default) or repo, the
# @param   repository docs (spec 137); the hub lets only the operator
# @param   workspace's agents and admins write repo
# @param DESK_BOX (optional) - default this machine's desk box (spl_desk_box_default)
# @param DRY_RUN (optional) - 1 (default) or 0; reads ignore it
# @param AGENT_ID (optional) - the caller's own id; a DRY_RUN=0 write needs it
# @param   to equal DESK_AGENT (else the id of the $TMUX_PANE window)
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=a-177 DOCTREE_ARGS=list ./run -a do_spl_desk_doctree
# @example AGENT_ID=a-177 ENV=prd TENANT_ID=t1 DESK_AGENT=a-177 DOCTREE_ARGS='add 42 --kind para' DOCTREE_IN=/tmp/body.md DRY_RUN=0 ./run -a do_spl_desk_doctree
#------------------------------------------------------------------------------
do_spl_desk_doctree() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local args=()
  _spl_desk_doctree_split args || return 1
  local verb="${args[0]}" fs="${DOCTREE_FS:-}"
  [[ "$fs" == "" || "$fs" == workspace || "$fs" == repo ]] ||
    { do_log "FATAL DOCTREE_FS is workspace or repo, not '$fs'"; return 1; }
  [[ " list nodes folder move-node create head read add edit move delete rename export asset-put asset-get " == *" $verb "* ]] ||
    { do_log "FATAL '$verb' is not a doctree verb (list nodes folder move-node create head read add edit move delete rename export asset-put asset-get)"; return 1; }
  local in=""
  _spl_desk_doctree_in in || return 1
  _spl_desk_doctree_file_flags args "$in" || return 1

  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  _spl_desk_doctree_seated "$d" "$box" "$agent" "$tenant" || return 1

  local dry=0
  if [[ " create add edit move delete rename folder move-node asset-put " == *" $verb "* ]]; then
    dry=1
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: spool doctree ${args[*]} for $agent on $box in $tenant${fs:+ (fs=$fs)}"
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0 to run it."
    return 0
  fi
  if [[ " create add edit move delete rename folder move-node asset-put " == *" $verb "* ]]; then
    _spl_desk_doctree_caller_ok "$agent" || return 1
  fi

  SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  [[ -x "$SPL_SPOOL" ]] || { do_log "FATAL no installed spool binary for ENV=$ENV on this box: run do_spl_desk_up first"; return 1; }
  local out rc=0
  out="$(SPOOL_DOCTREE_FS="$fs" spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- doctree "${args[@]}" 2>&1)" || rc=$?
  # The desk state (and with it keys/) never reaches the caller, not even
  # inside an error message the binary built from SPOOL_KEYS_DIR.
  out="${out//"$d"/<desk>}"
  out="${out//"$SPL_STATE_DIR"/<state>}"
  if (( rc != 0 )); then
    do_log "FATAL spool doctree $verb for $agent on $box (exit $rc): $out"
    return 1
  fi
  printf '%s\n' "$out"
}

# _spl_desk_doctree_split <array name>: DOCTREE_ARGS split shell-style (quotes
# kept, nothing expanded or run) into the named array. 1 with the FATAL when
# it is empty or does not parse.
_spl_desk_doctree_split() {
  local -n _dt_out="$1"
  local raw="${DOCTREE_ARGS:-}" split='import shlex,sys; sys.stdout.write("".join(w + "\0" for w in shlex.split(sys.argv[1])))'
  [[ -n "${raw//[[:space:]]/}" ]] || { do_log "FATAL DOCTREE_ARGS must carry the doctree verb and its flags, e.g. DOCTREE_ARGS=list"; return 1; }
  python3 -c "$split" "$raw" >/dev/null 2>&1 ||
    { do_log "FATAL DOCTREE_ARGS does not parse (an unbalanced quote?): $raw"; return 1; }
  mapfile -d '' -t _dt_out < <(python3 -c "$split" "$raw")
  (( ${#_dt_out[@]} > 0 )) || { do_log "FATAL DOCTREE_ARGS is empty"; return 1; }
}

# _spl_desk_doctree_in <var name>: DOCTREE_IN resolved (symlinks followed) into
# the named var, empty when unset. Refused: not a readable regular file, inside
# the desk state, or outside the caller's worktree (APP_PATH), /tmp and the
# spool root's dispatch/ dir.
_spl_desk_doctree_in() {
  local -n _dt_in="$1"
  local raw="${DOCTREE_IN:-}" real root ok=0
  _dt_in=""
  [[ -n "$raw" ]] || return 0
  real="$(realpath -e -- "$raw" 2>/dev/null)" || real=""
  if [[ ! -f "$real" || ! -r "$real" ]]; then
    do_log "FATAL DOCTREE_IN is not a readable file: $raw"; return 1
  fi
  if [[ "$real" == "$(realpath -m -- "$SPL_STATE_DIR")/"* ]]; then
    do_log "FATAL DOCTREE_IN lies in the desk state, which never leaves this action"; return 1
  fi
  for root in "${APP_PATH:-}" /tmp /var/spool-hub/dispatch; do
    [[ -n "$root" ]] || continue
    root="$(realpath -m -- "$root")"
    [[ "$real" == "$root/"* ]] && { ok=1; break; }
  done
  (( ok )) || { do_log "FATAL DOCTREE_IN must lie in the caller's worktree (${APP_PATH:-unset}), /tmp or /var/spool-hub/dispatch: $raw"; return 1; }
  _dt_in="$real"
}

# _spl_desk_doctree_file_flags <array name> <in>: the file flags of the verb.
# --file / --path may name only DOCTREE_IN (the action runs as the box user,
# which can read the desk keys); --out is refused (it writes as that user).
# DOCTREE_IN given and not named: appended as --path for a picture, else
# --file. The named array is rewritten with DOCTREE_IN's resolved path.
_spl_desk_doctree_file_flags() {
  local -n _dt_a="$1"
  local in="$2" i a named=0 pic=0 next=""
  for ((i = 0; i < ${#_dt_a[@]}; i++)); do
    a="${_dt_a[$i]}"
    if [[ -n "$next" ]]; then
      [[ "$next" == kind && "$a" == picture ]] && pic=1
      if [[ "$next" == file ]]; then
        _spl_desk_doctree_is_in "$a" "$in" || return 1
        _dt_a[i]="$in"; named=1
      fi
      next=""; continue
    fi
    case "$a" in
      -out|--out|-out=*|--out=*)
        do_log "FATAL --out is refused: export prints to stdout here"; return 1 ;;
      -file|--file|-path|--path) next="file" ;;
      -file=*|--file=*|-path=*|--path=*)
        _spl_desk_doctree_is_in "${a#*=}" "$in" || return 1
        _dt_a[i]="${a%%=*}=$in"; named=1 ;;
      -kind|--kind) next="kind" ;;
      -kind=picture|--kind=picture) pic=1 ;;
    esac
  done
  [[ "$next" != file ]] || { do_log "FATAL a --file / --path in DOCTREE_ARGS has no value"; return 1; }
  if [[ -n "$in" ]] && (( ! named )); then
    if (( pic )); then _dt_a+=(--path "$in"); else _dt_a+=(--file "$in"); fi
  fi
  return 0
}

# _spl_desk_doctree_is_in <value> <in>: 0 when a file flag's value is
# DOCTREE_IN (the same file once resolved); else the FATAL.
_spl_desk_doctree_is_in() {
  [[ -n "$2" && "$(realpath -m -- "$1" 2>/dev/null)" == "$2" ]] && return 0
  do_log "FATAL a --file / --path in DOCTREE_ARGS may only name DOCTREE_IN; pass the file as DOCTREE_IN (the refused path is not echoed: it may point into the desk state)"
  return 1
}

# _spl_desk_doctree_seated <state dir> <box> <agent> <tenant>: 0 when the agent
# has a seat in the desk: its seat dir under the desk spool (do_spl_desk_up
# makes it) and, when the sidecar keeps a hub roster cache, a place in it under
# this box. The FATAL names neither the state dir nor its path.
_spl_desk_doctree_seated() {
  local d="$1" box="$2" agent="$3" tenant="$4"
  local roster="$d/spool/.hub/roster.json"
  [[ -d "$d/spool/$agent" ]] ||
    { do_log "FATAL $agent has no seat in the $box desk of $tenant (ENV=$ENV): do_spl_desk_up seats one, and this action runs as the desk's box user"; return 1; }
  [[ -r "$roster" ]] || return 0
  python3 -c 'import json,sys; sys.exit(0 if sys.argv[3] in (json.load(open(sys.argv[1])).get(sys.argv[2]) or []) else 1)' \
    "$roster" "$box" "$agent" 2>/dev/null ||
    { do_log "FATAL $agent is not in the hub roster of the $box desk of $tenant (ENV=$ENV)"; return 1; }
}

# _spl_desk_doctree_caller <var name>: the caller's own agent id into the named
# var, empty when none resolves: AGENT_ID, else SPOOL_AGENT_ID /
# MCP_BOT_AGENT_ID (the session env, as kill-your-self-report.sh reads it),
# else the id heading the name of the tmux window $TMUX_PANE is in. Only
# TMUX_PANE: a CLE_TMUX_PANE inherited from a parent session names THAT
# session's pane, and a sudo hop strips both.
_spl_desk_doctree_caller() {
  local -n _dt_who="$1"
  local w
  _dt_who="${AGENT_ID:-${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}}"
  [[ -n "$_dt_who" || -z "${TMUX_PANE:-}" ]] && return 0
  w="$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" || return 0
  declare -F an_strip >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/agent-state.inc.sh"
  _dt_who="$(an_strip "$w" | grep -oE "^${SPOOL_AGENT_ID_RX}" || true)"
}

# _spl_desk_doctree_caller_ok <desk agent>: 0 when the desk agent is the
# caller (SPL-2078), else the FATAL that says what to do instead. Run only
# before a real write: reads and dry runs stay open to anyone, so a lane can
# still prepare the exact command list.
_spl_desk_doctree_caller_ok() {
  local agent="$1" who=""
  _spl_desk_doctree_caller who
  [[ -n "$who" && "$who" == "$agent" ]] && return 0
  do_log "FATAL DESK_AGENT=$agent is not you (${who:-no caller id: set AGENT_ID}): a lane without its own desk seat sends the DRY_RUN=0 command list to the orchestrator, who runs it as its own seat (csi-spl-doc/specs/137-qto-only-doc-editor/unified-fs.md section 6)"
  return 1
}
