#!/bin/bash
#------------------------------------------------------------------------------
# @description Unlock the local hub's encrypted Postgres (lane L5; owner: the
# @description pg data is encrypted at rest with a passphrase only the owner
# @description types at start). The passphrase is read ONLY from the owner's
# @description terminal, without echo: stdin must be a tty, and it is read
# @description from /dev/tty. It is never taken from env, argv, a file, a pipe,
# @description a chat or a spool message, never stored and never logged; it
# @description goes to `docker exec -i <pg> vault-unlock` over stdin (printf
# @description is a builtin: no argv). A new volume asks twice and wants at
# @description least LOCAL_HUB_PASS_MIN (16) characters. A wrong passphrase
# @description asks again, up to 3 tries.
# @description Runs as the hub user, against its rootless daemon; do_spl_local_
# @description hub_up calls it after `up -d pg` and before migrate.
# @description Exit: 0 unlocked (or already); 1 refused / not unlocked.
# @param DOCKER_HOST (optional) - default the hub user's rootless socket
# @example sudo -u spl-hub -H ./run -a do_spl_local_hub_unlock
#------------------------------------------------------------------------------

# _slu_ask <prompt> -- one line from /dev/tty, no echo, into _SLU_PASS
_slu_ask() {
  printf '%s' "$1" >/dev/tty
  IFS= read -rs _SLU_PASS </dev/tty
  printf '\n' >/dev/tty
}

# _slu_pg -- the running pg container of the local hub project
_slu_pg() {
  docker ps -q --filter "label=com.docker.compose.project=$LOCAL_HUB_PROJECT" \
    --filter "label=com.docker.compose.service=pg" 2>/dev/null
}

# _slu_new_pass -- a new volume: ask twice, they must match and be long enough
_slu_new_pass() {
  local first min="${LOCAL_HUB_PASS_MIN:-16}"
  printf 'new encrypted volume: choose its passphrase (>= %s characters); it is never stored, keep it safe\n' "$min" >/dev/tty
  _slu_ask "type the passphrase here: "; first="$_SLU_PASS"
  _slu_ask "type it again: "
  if [[ "$first" != "$_SLU_PASS" ]]; then first=""; _SLU_PASS=""; do_log "FATAL local hub unlock: the two passphrases differ"; return 1; fi
  first=""
  ((${#_SLU_PASS} >= min)) || { _SLU_PASS=""; do_log "FATAL local hub unlock: the passphrase is shorter than $min characters"; return 1; }
}

do_spl_local_hub_unlock() {
  # the tty rule first: nothing else runs on a pipe, a file or /dev/null
  if [[ ! -t 0 ]] || ! { : </dev/tty; } 2>/dev/null; then
    do_log "FATAL local hub unlock: the passphrase is read from the terminal only; stdin is not a tty (no pipe, file, env or argv)"
    return 1
  fi
  declare -F _slh_cnf >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-local-hub-harden-check.func.sh"
  _slh_cnf || return 1
  export DOCKER_HOST="${DOCKER_HOST:-unix://${LOCAL_HUB_RUN_DIR:-/run/user}/$(id -u)/docker.sock}"
  local cid state rc try
  cid="$(_slu_pg)"
  [[ -n "$cid" ]] || { do_log "FATAL local hub unlock: no running pg of $LOCAL_HUB_PROJECT at $DOCKER_HOST"; return 1; }
  state="$(docker exec "$cid" cat /run/vault/state 2>/dev/null)"
  case "$state" in
    unlocked) do_log "OK local hub unlock: already unlocked"; return 0 ;;
    needs-init) _slu_new_pass || return 1 ;;
    "locked "*) _slu_ask "type the passphrase here: " ;;
    *) do_log "FATAL local hub unlock: pg is not a vault image or not waiting (state: ${state:-none})"; return 1 ;;
  esac
  for try in 1 2 3; do
    printf '%s\n' "$_SLU_PASS" | docker exec -i "$cid" vault-unlock >/dev/null 2>&1
    rc=$?
    _SLU_PASS=""
    case "$rc" in
      0) do_log "OK local hub unlock: pg is unlocked"; return 0 ;;
      2) do_log "WARN local hub unlock: wrong passphrase (try $try of 3)"
         ((try < 3)) && { sleep 2; _slu_ask "type the passphrase here: "; } ;;
      *) do_log "FATAL local hub unlock: vault-unlock exit $rc"; return 1 ;;
    esac
  done
  do_log "FATAL local hub unlock: 3 wrong passphrases; pg stays locked"
  return 1
}
