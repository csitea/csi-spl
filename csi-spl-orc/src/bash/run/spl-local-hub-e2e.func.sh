#!/bin/bash
#------------------------------------------------------------------------------
# @description End-to-end proof of the local private spool-hub (swarm lane L9,
# @description owner order 496e7273) on a THROWAWAY workspace, never the
# @description private one: its own temp home, compose project and ports, so
# @description the long-lived stack is never touched. The steps, in order:
# @description   unlock    do_spl_local_hub_unlock (L5), a throwaway passphrase typed on a pty
# @description   up        do_spl_local_hub_up (L1)
# @description   health    the hub answers GET /healthz on 127.0.0.1
# @description   owner     do_spl_local_hub_owner_add (L3), a throwaway password typed on a pty
# @description   post      sign in natively, post one message to #general, read it back
# @description   ports     do_spl_local_hub_ports_gate (L5): no public listener
# @description   backup    do_spl_local_hub_backup (L4)
# @description   restore   do_spl_local_hub_restore (L4): proof into a scratch DB
# @description   down      do_spl_local_hub_down (L1) with LOCAL_HUB_PURGE=1, ALWAYS,
# @description             also after a failed step
# @description Owner rule (msg 3cfe43ce): a passphrase or password is read only
# @description from the terminal. So unlock and owner run as ./run -a <action>
# @description under a pseudo-terminal (scripts/local-hub-e2e-tty.py) that types
# @description the throwaway secret at each prompt; nothing is piped or passed in env.
# @description Each step prints PASS|FAIL <step> <evidence>; a lane action that is
# @description not defined is a FAIL naming it and its lane. The first FAIL stops
# @description the run (then down). The tenant must match ^e2e-[a-z0-9]{6,}$ (a
# @description fresh random one by default), so this can never target a real
# @description workspace. Too slow for the cheap gate (images, a WUI generate):
# @description the gate runs local-hub-e2e.tst.sh, which drives this action
# @description against stubbed lane actions. Dry run unless DRY_RUN=0: the plan
# @description only, nothing started.
# @param LOCAL_HUB_E2E_TENANT (optional) - default e2e-<random>
# @param LOCAL_HUB_E2E_HOME (optional) - an EMPTY dir for the throwaway home, default a mktemp dir (removed after)
# @param LOCAL_HUB_E2E_PORT_BASE (optional) - pg/gcs/hub/wui = base+0..3, default 58280 (off the long-lived 55532/54543/58180/3180)
# @param LOCAL_HUB_E2E_WAIT (optional) - seconds the hub may take to answer /healthz, default 300
# @param LOCAL_HUB_E2E_POST_CMD (optional) - the sign-in + post driver, default scripts/local-hub-e2e-post.py (the tests' seam)
# @param LOCAL_HUB_E2E_TTY_CMD (optional) - the pty driver, default scripts/local-hub-e2e-tty.py (the tests' seam)
# @param LOCAL_HUB_E2E_CURL (optional) - the health probe binary, default curl (the tests' seam)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_local_hub_e2e
# @example DRY_RUN=0 LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1 ./run -a do_spl_local_hub_e2e
#------------------------------------------------------------------------------

# the step -> lane action map; "-" = done by this file
_LHE2E_STEPS="unlock:do_spl_local_hub_unlock:L5 up:do_spl_local_hub_up:L1 health:-:L9 owner:do_spl_local_hub_owner_add:L3 post:-:L9 ports:do_spl_local_hub_ports_gate:L5 backup:do_spl_local_hub_backup:L4 restore:do_spl_local_hub_restore:L4"

_lhe2e_tenant_ok() { [[ "$1" =~ ^e2e-[a-z0-9]{6,}$ ]]; }

# a finite read, so no stage dies of SIGPIPE under pipefail (1024 bytes give ~144 chars)
_lhe2e_rand() { head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | cut -c "1-${1:-10}"; }

# _lhe2e_env <home> <tenant>: the throwaway knobs spl_local_hub_cnf reads
_lhe2e_env() {
  local home="$1" tenant="$2" base="${LOCAL_HUB_E2E_PORT_BASE:-58280}"
  export LOCAL_HUB_USER LOCAL_HUB_HOME="$home" LOCAL_HUB_PROJECT="spl-lhe2e-${tenant#e2e-}"
  LOCAL_HUB_USER=$(id -un)
  export LOCAL_HUB_PG_PORT=$((base)) LOCAL_HUB_GCS_PORT=$((base + 1))
  export LOCAL_HUB_HUB_PORT=$((base + 2)) LOCAL_HUB_WUI_PORT=$((base + 3))
  export LOCAL_HUB_E2E_EMAIL="owner-${tenant#e2e-}@example.com"
  export LOCAL_HUB_E2E_PW_FILE="$home/.e2e/pw" LOCAL_HUB_E2E_PASSPHRASE_FILE="$home/.e2e/passphrase"
}

# _lhe2e_seed <home> <tenant>: the private config and the throwaway secrets, 0600
_lhe2e_seed() {
  local home="$1" tenant="$2"
  ( umask 077
    mkdir -p "$home/.config/csi-spl" "$home/.e2e" "$home/state"
    printf 'LOCAL_HUB_TENANT=%s\nLOCAL_HUB_OWNER_EMAIL=%s\n' "$tenant" "$LOCAL_HUB_E2E_EMAIL" \
      >"$home/.config/csi-spl/local-hub.env"
    _lhe2e_rand 24 >"$LOCAL_HUB_E2E_PW_FILE"
    _lhe2e_rand 32 >"$LOCAL_HUB_E2E_PASSPHRASE_FILE" )
  chmod 0700 "$home"
}

_lhe2e_wait_hub() {
  local curl="${LOCAL_HUB_E2E_CURL:-curl}" wait="${LOCAL_HUB_E2E_WAIT:-300}" t=0
  while (( t < wait )); do
    "$curl" -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$LOCAL_HUB_HUB_PORT/healthz" && return 0
    sleep 2; t=$((t + 2))
  done
  return 1
}

_lhe2e_post() {
  local cmd="${LOCAL_HUB_E2E_POST_CMD:-$PROJ_PATH/src/bash/scripts/local-hub-e2e-post.py}"
  LHE2E_API="http://127.0.0.1:$LOCAL_HUB_HUB_PORT" LHE2E_TENANT="$LOCAL_HUB_E2E_TENANT" \
    LHE2E_EMAIL="$LOCAL_HUB_E2E_EMAIL" LHE2E_PW_FILE="$LOCAL_HUB_E2E_PW_FILE" \
    LHE2E_BODY="local-hub e2e $(_lhe2e_rand 12)" "$cmd"
}

# _lhe2e_tty <secret-file> <action>: the action under a pty, the secret typed at its prompts
_lhe2e_tty() {
  local cmd="${LOCAL_HUB_E2E_TTY_CMD:-$PROJ_PATH/src/bash/scripts/local-hub-e2e-tty.py}"
  ( cd "$PROJ_PATH" && DRY_RUN=0 "$cmd" "$1" ./run -a "$2" </dev/null )
}

# _lhe2e_run_step <step> <action> <lane>: 0 = PASS
_lhe2e_run_step() {
  local step="$1" fn="$2" lane="$3" out rc
  if [[ "$fn" != "-" ]] && ! declare -F "$fn" >/dev/null; then
    echo "FAIL $step missing action $fn (lane $lane)"; return 1
  fi
  case "$step" in
    unlock) out=$(_lhe2e_tty "$LOCAL_HUB_E2E_PASSPHRASE_FILE" "$fn" 2>&1) ;;
    owner) out=$(_lhe2e_tty "$LOCAL_HUB_E2E_PW_FILE" "$fn" 2>&1) ;;
    health) out="GET http://127.0.0.1:$LOCAL_HUB_HUB_PORT/healthz"; _lhe2e_wait_hub ;;
    post) out=$(_lhe2e_post 2>&1) ;;
    *) out=$(DRY_RUN=0 "$fn" 2>&1) ;;
  esac
  rc=$?
  out=$(tail -n 3 <<<"$out" | tr '\n' ' ')
  if (( rc == 0 )); then echo "PASS $step $out"; else echo "FAIL $step rc=$rc $out"; fi
  return "$rc"
}

_lhe2e_down() {
  local out rc
  if ! declare -F do_spl_local_hub_down >/dev/null; then
    echo "FAIL down missing action do_spl_local_hub_down (lane L1)"; return 1
  fi
  out=$(LOCAL_HUB_PURGE=1 DRY_RUN=0 do_spl_local_hub_down 2>&1); rc=$?
  out=$(tail -n 3 <<<"$out" | tr '\n' ' ')
  if (( rc == 0 )); then echo "PASS down $out"; else echo "FAIL down rc=$rc $out"; fi
  return "$rc"
}

_lhe2e_plan() {
  local s step fn lane
  echo "DRY RUN local-hub e2e: tenant $LOCAL_HUB_E2E_TENANT, project $LOCAL_HUB_PROJECT, home $LOCAL_HUB_HOME"
  echo "  ports pg $LOCAL_HUB_PG_PORT gcs $LOCAL_HUB_GCS_PORT hub $LOCAL_HUB_HUB_PORT wui $LOCAL_HUB_WUI_PORT"
  for s in $_LHE2E_STEPS down:do_spl_local_hub_down:L1; do
    IFS=: read -r step fn lane <<<"$s"
    [[ "$fn" == "-" ]] && fn="(this action)"
    echo "  $step  $fn ($lane)"
  done
  echo "  DRY_RUN=0 to run it"
}

# _lhe2e_home: echo the throwaway home (an EMPTY dir); 1 = refused
_lhe2e_home() {
  local h="${LOCAL_HUB_E2E_HOME:-}"
  if [[ -z "$h" ]]; then mktemp -d "${TMPDIR:-/tmp}/spl-lhe2e.XXXXXX"; return; fi
  mkdir -p "$h" && [[ -z "$(ls -A "$h")" ]] && { echo "$h"; return 0; }
  return 1
}

do_spl_local_hub_e2e() {
  local tenant="${LOCAL_HUB_E2E_TENANT:-e2e-$(_lhe2e_rand 10)}" home rc=0 s step fn lane own=0
  _lhe2e_tenant_ok "$tenant" || { echo "FATAL tenant '$tenant' is not a throwaway name (^e2e-[a-z0-9]{6,}\$)" >&2; return 2; }
  export LOCAL_HUB_E2E_TENANT="$tenant"
  [[ -n "${LOCAL_HUB_E2E_HOME:-}" ]] || own=1
  if [[ "${DRY_RUN:-1}" != "0" ]]; then
    _lhe2e_env "${LOCAL_HUB_E2E_HOME:-<mktemp>}" "$tenant"; _lhe2e_plan; return 0
  fi
  home=$(_lhe2e_home) || { echo "FATAL LOCAL_HUB_E2E_HOME must be an empty dir" >&2; return 2; }
  _lhe2e_env "$home" "$tenant"
  _lhe2e_seed "$home" "$tenant"
  for s in $_LHE2E_STEPS; do
    IFS=: read -r step fn lane <<<"$s"
    _lhe2e_run_step "$step" "$fn" "$lane" || { rc=1; break; }
  done
  _lhe2e_down || rc=1
  (( own )) && rm -rf "$home"
  if (( rc == 0 )); then echo "OK local-hub e2e green on $tenant"; else echo "FAIL local-hub e2e on $tenant"; fi
  return "$rc"
}
