#!/usr/bin/env bash
# spool-fleet.inc.sh — messages and reports across the machines of one fleet
# (specs/058 N1). Sourced by spool-send.sh and agent-send.sh after
# spool-env.inc.sh (needs SPOOL_ROOT, SPOOL_BOX_USER, SPOOL_ORCHESTRATOR_ID).
#
# Each machine has its own $SPOOL_ROOT. A local `spool send` to an agent that
# lives on the OTHER machine used to mint an orphan inbox here and report
# "local": the message was lost (spec 058 O3). Now:
#
#   spool_fleet_local <id>        0 when <id> is an agent of THIS machine's root
#                                 (its dir, or a registry.tsv row)
#   spool_fleet_retired <id>      0 when THIS machine retired <id> less than
#                                 SPOOL_ID_QUARANTINE_H (24) hours ago
#                                 (registry.retired.tsv, specs/061 3.6): a send
#                                 to it is not relayed, the binary bounces it
#   spool_fleet_box               this machine's desk box (the <box> of
#                                 <ID>@<box>): LEASE_MACHINE, else SPOOL_DESK_BOX
#                                 (env, box.env), else box-desk
#   spool_fleet_orchestrator      where reports go, as <ID> (on this machine) or
#                                 <ID>@<box> (another machine's box): the holder
#                                 of the fleet lease's orch role (lease.orch,
#                                 written by do_spl_dispatch_lease fleet mode),
#                                 else the local LEASE_ORCH, else
#                                 SPOOL_ORCHESTRATOR_ID. The box is kept for a
#                                 remote holder because the role ids 001-003
#                                 exist on EVERY machine: a bare CLE-001 is
#                                 ambiguous on the hub
#   spool_fleet_relay <send args> hand the message to the hub through THIS
#                                 machine's desk sidecar (scripts/spool-fleet-
#                                 relay.sh, run as the box user); the hub's
#                                 roster names the box that holds <to>, and that
#                                 box's sidecar writes it into the agent's
#                                 inbox there (SPOOL_FLEET_ROOT)
#
# SPOOL_FLEET_RELAY_CMD replaces the relay command (the tests' two simulated
# machines); SPOOL_FLEET_RELAY=0 turns the relay off, so an unknown id is
# refused instead of relayed.

spool_fleet_local() {  # ID
  local id="$1"
  [ -d "$SPOOL_ROOT/$id" ] && return 0
  [ -r "$SPOOL_ROOT/registry.tsv" ] &&
    cut -f1 "$SPOOL_ROOT/registry.tsv" | sed -E 's/^.*: //; s/@.*//' | grep -qx -- "$id"
}

# The wall clock, as the binary's bounce reads it (SPOOL_NOW is not its clock).
spool_fleet_retired() {  # ID
  local f="$SPOOL_ROOT/registry.retired.tsv" cut
  [ -r "$f" ] || return 1
  cut="$(date -u -d "-${SPOOL_ID_QUARANTINE_H:-24} hours" +%Y%m%dT%H%M%SZ)" || return 1
  awk -F'\t' -v id="$1" -v c="$cut" '{ k = $1; sub(/^.*: /, "", k); sub(/@.*/, "", k) }
    k == id && $6 > c { hit = 1 } END { exit !hit }' "$f"
}

spool_fleet_box() {
  local b="${LEASE_MACHINE:-${SPOOL_DESK_BOX:-}}" f="${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}"
  [ -n "$b" ] || b="$(_spool_fleet_conf LEASE_MACHINE)"
  [ -n "$b" ] || b="$(sed -n "s/^SPOOL_DESK_BOX=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "$f" 2>/dev/null | tail -1)"
  printf '%s' "${b:-box-desk}"
}

# One KEY from <root>/dispatch/lease.conf (read, never sourced).
_spool_fleet_conf() {  # KEY
  local f="$SPOOL_ROOT/dispatch/lease.conf"
  [ -r "$f" ] || return 0
  sed -n "s/^$1=\([A-Za-z0-9_-]*\)\$/\1/p" "$f" | tail -1
}

# The orchestrator a report goes to. lease.orch holds "<ID>@<box> <epoch>"
# (fleet mode), "none@unreachable" when this machine lost the hub while
# holding it, or a bare "<ID> <epoch>" (the single-machine lease). The
# unreachable mark and a missing file (no fleet mode) fall back to the local
# order. A holder on this machine's box prints as the bare id (a local send).
spool_fleet_orchestrator() {
  local f="$SPOOL_ROOT/dispatch/lease.orch" h="" id="" box=""
  [ -r "$f" ] && read -r h _ <"$f"
  case "$h" in
    none@*|unknown:*|'') ;;
    *@*) id="${h%@*}" box="${h##*@}" ;;
    *) id="$h" ;;
  esac
  if [[ "$id" =~ $SPOOL_ID_RE ]]; then
    if [ -n "$box" ] && [ "$box" != "$(spool_fleet_box)" ]; then
      printf '%s@%s' "$id" "$box"; return 0
    fi
  else
    id="$(_spool_fleet_conf LEASE_ORCH)"
    [[ "$id" =~ $SPOOL_ID_RE ]] || id="$SPOOL_ORCHESTRATOR_ID"
  fi
  printf '%s' "$id"
}

# 0 when this machine can relay: a fleet desk env + tenant is configured (the
# same lookup spool-fleet-relay.sh makes), or the tests' relay command is set.
spool_fleet_desk_configured() {
  [ "${SPOOL_FLEET_RELAY:-1}" = 0 ] && return 1
  [ -n "${SPOOL_FLEET_RELAY_CMD:-}" ] && return 0
  local benv="${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}" e t
  e="${SPOOL_FLEET_ENV:-$(sed -n 's/^SPOOL_FLEET_ENV=//p' "$benv" 2>/dev/null | tail -1)}"
  t="${SPOOL_FLEET_TENANT:-$(sed -n 's/^SPOOL_FLEET_TENANT=//p' "$benv" 2>/dev/null | tail -1)}"
  e="${e:-$(_spool_fleet_conf LEASE_ENV)}"; t="${t:-$(_spool_fleet_conf LEASE_TENANT)}"
  [ -n "$e" ] && [ -n "$t" ]
}

# The relay leg: prints the spool JSON result, returns the relay's code
# (0 handed to the hub; 3 refused - not seated, no desk, unknown on the hub).
spool_fleet_relay() {  # spool send args...
  if [ "${SPOOL_FLEET_RELAY:-1}" = 0 ]; then
    echo "spool-fleet: relay off (SPOOL_FLEET_RELAY=0)" >&2; return 3
  fi
  if [ -n "${SPOOL_FLEET_RELAY_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPOOL_FLEET_RELAY_CMD "$@"; return
  fi
  if [ "${SPOOL_TEST:-}" = 1 ]; then
    echo "spool-fleet: relay REFUSED under SPOOL_TEST=1 (set SPOOL_FLEET_RELAY_CMD to a stub)" >&2; return 3
  fi
  local relay="$SPOOL_FEATURE_DIR/scripts/spool-fleet-relay.sh"
  if [ "$(id -un)" = "$SPOOL_BOX_USER" ]; then
    SPOOL_ROOT="$SPOOL_ROOT" bash "$relay" "$@"
  else
    # the desk tree and its box key are the box user's (0700); one hop, the
    # way spool-mcp.sh reaches them. The root travels as an argument: sudo
    # resets the environment.
    sudo -n -u "$SPOOL_BOX_USER" -- bash "$relay" --spool-root "$SPOOL_ROOT" "$@"
  fi
}
