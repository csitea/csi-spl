#!/bin/bash
#------------------------------------------------------------------------------
# @description Read, list or write one WORKSPACE doc (spec 075: the markdown
# @description catalogue at /v1/workspace/docs, e.g. ws/agents/<name>.md) for a
# @description desk agent, without handing the caller the desk state. The
# @description twin of do_spl_desk_doctree (the Qto documents, spec 113): the
# @description agent names ENV / TENANT_ID / DESK_AGENT and the verb, this
# @description action resolves the desk state dir and the hub from cnf and runs
# @description the INSTALLED spool binary (<state>/bin/spool, never a rebuild)
# @description as the box user that runs the action. The hub sees the desk box
# @description (its role=cli token, rbac pure_agent). It prints only the verb's
# @description output; the desk state path is masked as <desk> in it and in any
# @description error, so no key, token or keys/ path reaches the output.
# @description Verbs (WSDOC_ARGS), each one spool doc-* verb:
# @description   list [prefix]   spool doc-list    (runs as it is)
# @description   read <path>     spool doc-read    (runs as it is)
# @description   write <path>    spool doc-write --file WSDOC_IN (dry run
# @description                   unless DRY_RUN=0; the hub keeps .history/)
# @description   delete <path>   spool doc-delete (dry run unless DRY_RUN=0;
# @description                   the hub first writes a .history/ copy, and the
# @description                   bucket keeps the old generation: a delete
# @description                   hides the doc, it does not purge it; for that
# @description                   see csi-spl-iac do_gcp_purge_wsdoc_prefix)
# @description   rename          refused: the hub has no history-keeping
# @description                   rename for a workspace doc (GET / PUT / DELETE
# @description                   only, its .history/ is keyed by path), and a
# @description                   write + delete would cut the doc's history.
# @description Refused, before any spool call: a DESK_AGENT with no seat in the
# @description desk (do_spl_desk_doctree's seat check), a verb off the list, a
# @description flag in WSDOC_ARGS, a path that is not a relative .md path, and
# @description WSDOC_IN outside the caller's worktree (APP_PATH), /tmp or
# @description /var/spool-hub/dispatch, or inside the desk state. A write with
# @description DRY_RUN=0 is refused unless DESK_AGENT is the caller itself
# @description (do_spl_desk_doctree's caller check, SPL-2078); so is a delete.
# @param ENV (required) - dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID (required) - the tenant the desk is seated in
# @param DESK_AGENT (required) - the agent the verb runs for (a seat of the desk)
# @param WSDOC_ARGS (required) - the verb and its path, e.g. `list ws/agents/`
# @param   or `read ws/agents/join-your-agents.md`
# @param WSDOC_IN (optional) - write only, and needed there: the body file
# @param DESK_BOX (optional) - default this machine's desk box (spl_desk_box_default)
# @param DRY_RUN (optional) - 1 (default) or 0; write and delete only, list and read ignore it
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=a-200 WSDOC_ARGS='list ws/agents/' ./run -a do_spl_desk_wsdoc
# @example AGENT_ID=a-200 ENV=prd TENANT_ID=t1 DESK_AGENT=a-200 WSDOC_ARGS='delete <prefix>/x.md' DRY_RUN=0 ./run -a do_spl_desk_wsdoc
# @example AGENT_ID=a-200 ENV=prd TENANT_ID=t1 DESK_AGENT=a-200 WSDOC_ARGS='write ws/agents/x.bg.md' WSDOC_IN=/var/spool-hub/dispatch/x.bg.md DRY_RUN=0 ./run -a do_spl_desk_wsdoc
#------------------------------------------------------------------------------
do_spl_desk_wsdoc() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local args=()
  _spl_desk_wsdoc_split args || return 1
  local verb="${args[0]}" in=""
  _spl_desk_wsdoc_check args || return 1
  if [[ "$verb" == write ]]; then
    _spl_desk_wsdoc_in in || return 1
  elif [[ -n "${WSDOC_IN:-}" ]]; then
    do_log "FATAL WSDOC_IN is for write only"; return 1
  fi

  local d
  d="$(spl_desk_dir "$tenant" "$box")" || [[ $? -eq 1 ]] || return 1
  declare -F _spl_desk_doctree_seated >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-doctree.func.sh"
  _spl_desk_doctree_seated "$d" "$box" "$agent" "$tenant" || return 1

  local cli=(doc-"$verb" "${args[@]:1}")
  if [[ "$verb" == write || "$verb" == delete ]]; then
    [[ "$verb" == write ]] && cli+=(--file "$in")
    local drc=0
    spl_dry_run || drc=$?
    if (( drc == 0 )); then
      if [[ "$verb" == write ]]; then
        do_log "INFO DRY_RUN would: spool doc-write ${args[1]} (from WSDOC_IN) for $agent on $box in $tenant"
        do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0 to run it."
      else
        do_log "INFO DRY_RUN would: spool doc-delete ${args[1]} for $agent on $box in $tenant"
        do_log "OK DRY_RUN nothing was deleted. Re-run with DRY_RUN=0 to run it."
      fi
      return 0
    fi
    (( drc == 1 )) || return 1
    _spl_desk_doctree_caller_ok "$agent" || return 1
  fi

  SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  [[ -x "$SPL_SPOOL" ]] || { do_log "FATAL no installed spool binary for ENV=$ENV on this box: run do_spl_desk_up first"; return 1; }
  local out rc=0
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- "${cli[@]}" 2>&1)" || rc=$?
  # The desk state (and with it keys/) never reaches the caller, not even
  # inside an error message the binary built from SPOOL_KEYS_DIR.
  out="${out//"$d"/<desk>}"
  out="${out//"$SPL_STATE_DIR"/<state>}"
  if (( rc != 0 )); then
    do_log "FATAL spool doc-$verb for $agent on $box (exit $rc): $out"
    return 1
  fi
  printf '%s\n' "$out"
}

# _spl_desk_wsdoc_split <array name>: WSDOC_ARGS split shell-style into the named array.
_spl_desk_wsdoc_split() {
  # shellcheck source=spl-desk-doctree.func.sh
  declare -F _spl_desk_args_split >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-doctree.func.sh" || return 1
  _spl_desk_args_split "$1" WSDOC_ARGS "the verb and its path, e.g. WSDOC_ARGS='list ws/'"
}

# _spl_desk_wsdoc_check <array name>: the verb, its arity and its path. No
# flag passes (write's one file is WSDOC_IN); a path is the hub's relative
# .md path, a list prefix a relative path. rename is refused here.
_spl_desk_wsdoc_check() {
  local -n _ws_a="$1"
  local verb="${_ws_a[0]}" n=$((${#_ws_a[@]} - 1)) a
  local seg='[A-Za-z0-9_-][A-Za-z0-9._-]*'
  case "$verb" in
    list | read | write | delete) ;;
    rename)
      do_log "FATAL rename is refused: the hub has no history-keeping rename for a workspace doc (GET / PUT / DELETE only, history is kept per path); a write + delete would cut its history. Ask the owner."
      return 1 ;;
    *) do_log "FATAL '$verb' is not a wsdoc verb (list read write delete rename)"; return 1 ;;
  esac
  for a in "${_ws_a[@]:1}"; do
    [[ "$a" != -* ]] || { do_log "FATAL WSDOC_ARGS takes no flag ('$a'): write reads its body from WSDOC_IN"; return 1; }
  done
  if [[ "$verb" == list ]]; then
    (( n <= 1 )) || { do_log "FATAL usage: WSDOC_ARGS='list [prefix]'"; return 1; }
    [[ $n -eq 0 || "${_ws_a[1]}" =~ ^($seg/)*($seg)?$ ]] ||
      { do_log "FATAL '${_ws_a[1]}' is not a relative doc prefix"; return 1; }
    return 0
  fi
  (( n == 1 )) || { do_log "FATAL usage: WSDOC_ARGS='$verb <path>.md'"; return 1; }
  [[ "${_ws_a[1]}" =~ ^($seg/)*$seg\.md$ ]] ||
    { do_log "FATAL '${_ws_a[1]}' is not a workspace doc path (relative, segments of [A-Za-z0-9._-], ending in .md)"; return 1; }
}

# _spl_desk_wsdoc_in <var name>: WSDOC_IN resolved (symlinks followed) into the named var.
_spl_desk_wsdoc_in() {
  # shellcheck source=spl-desk-doctree.func.sh
  declare -F _spl_desk_in_file >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-doctree.func.sh" || return 1
  _spl_desk_in_file "$1" WSDOC_IN "write needs WSDOC_IN: the body file"
}
