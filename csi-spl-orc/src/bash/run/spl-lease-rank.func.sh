#!/bin/bash
#------------------------------------------------------------------------------
# @description Set the per-role machine ranking of the fleet lease in THIS
# @description machine's <spool root>/dispatch/lease.conf (spec 064 L1): the
# @description LEASE_PRIORITY_ORCH and LEASE_PRIORITY_DISPATCH knobs that the
# @description fleet loop (do_spl_dispatch_lease, spl_fleet_rank) reads. Only
# @description those two lines change; every other line is kept as it is.
# @description Dry run by default: prints the diff and touches nothing.
# @description APPLY=1 writes, after copying the old file next to it as
# @description lease.conf.bak-<UTC>. Idempotent: a file that already carries
# @description the ranking is reported OK and not rewritten (no backup).
# @description The loop reads lease.conf once at its start, but the file is
# @description part of its version hash, so the next ensure tick (the desk
# @description reconcile cron) replaces the loop with one on the new ranking.
# @description Every machine of the fleet needs the SAME ranking: run this on
# @description each of them, or the role ping-pongs while they disagree.
# @param LEASE_RANK (optional) - machines, comma-separated, preferred first, for BOTH roles (e.g. sat,<pc box>,box-desk)
# @param LEASE_RANK_ORCH (optional) - the orch role's ranking; default LEASE_RANK
# @param LEASE_RANK_DISPATCH (optional) - the dispatch role's ranking; default LEASE_RANK
# @param APPLY (optional) - 1 writes; default 0 (dry run)
# @example LEASE_RANK=sat,<pc box>,box-desk ./run -a do_spl_lease_rank
# @example LEASE_RANK=sat,<pc box>,box-desk APPLY=1 ./run -a do_spl_lease_rank
#------------------------------------------------------------------------------
# the lease dir, lease.conf reader and the desk box id, also when sourced on its own
declare -F spl_lease_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_lease_rank() {
  local apply="${APPLY:-0}" orch dispatch machine k v cur new bak tmp
  [[ "$apply" == 0 || "$apply" == 1 ]] || { do_log "FATAL APPLY must be 0 or 1"; return 1; }
  orch="${LEASE_RANK_ORCH:-${LEASE_RANK:-}}"
  dispatch="${LEASE_RANK_DISPATCH:-${LEASE_RANK:-}}"
  [[ -n "$orch" && -n "$dispatch" ]] ||
    { do_log "FATAL set LEASE_RANK (both roles), or LEASE_RANK_ORCH and LEASE_RANK_DISPATCH"; return 1; }

  spl_lease_init ro || return 1
  [[ -f "$LEASE_CONF" ]] || { do_log "FATAL no $LEASE_CONF - this box runs no lease (do_spl_dispatch_setup first)"; return 1; }
  grep -qE '^LEASE_FLEET=' "$LEASE_CONF" ||
    { do_log "FATAL $LEASE_CONF is not in fleet mode (no LEASE_FLEET): a ranking means nothing there"; return 1; }
  # the machine the fleet loop will call itself (spl_fleet_ids): env, lease.conf, else the desk box id
  machine="$(spl_lease_conf; echo "${LEASE_MACHINE:-$(spl_desk_box_default)}")"

  for k in orch dispatch; do
    v="${!k}"
    [[ "$v" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] ||
      { do_log "FATAL the $k ranking must list the machines, preferred first (e.g. sat,pc), got '$v'"; return 1; }
    [[ -z "$(tr , '\n' <<<"$v" | sort | uniq -d)" ]] || { do_log "FATAL the $k ranking names a machine twice: $v"; return 1; }
    # the loop refuses to start on a ranking without this machine: never write one
    [[ ",$v," == *",$machine,"* ]] ||
      { do_log "FATAL this machine ($machine) is not in the $k ranking ($v): the fleet loop would refuse to run"; return 1; }
  done

  cur="$(cat "$LEASE_CONF")"
  new="$(printf '%s\n' "$cur" | spl_lease_rank_set LEASE_PRIORITY_ORCH "$orch" | spl_lease_rank_set LEASE_PRIORITY_DISPATCH "$dispatch")"
  if [[ "$new" == "$cur" ]]; then
    echo "OK lease-conf $LEASE_CONF already ranks orch $orch, dispatch $dispatch (machine $machine)"
    return 0
  fi
  diff -u --label "$LEASE_CONF" --label "$LEASE_CONF (ranked)" <(printf '%s\n' "$cur") <(printf '%s\n' "$new")
  if [[ "$apply" != 1 ]]; then
    echo "PLAN lease-conf rank orch $orch, dispatch $dispatch on $machine (dry run: APPLY=1 writes)"
    return 0
  fi

  bak="$LEASE_CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -e "$bak" ]] && bak="$bak-$$"
  cp -p "$LEASE_CONF" "$bak" || { do_log "FATAL cannot back up $LEASE_CONF to $bak"; return 1; }
  # a temp file in the same dir, then a rename: a reader never sees half a file
  tmp="$(mktemp "$LEASE_DIR/.lease.conf.XXXXXX")" || { do_log "FATAL cannot create a temp file in $LEASE_DIR"; return 1; }
  printf '%s\n' "$new" >"$tmp" && chmod --reference="$LEASE_CONF" "$tmp" &&
    { chgrp --reference="$LEASE_CONF" "$tmp" 2>/dev/null || true; } && mv -f "$tmp" "$LEASE_CONF" ||
    { rm -f "$tmp"; do_log "FATAL cannot write $LEASE_CONF (the old file is unchanged)"; return 1; }
  [[ "$(sed -n 's/^LEASE_PRIORITY_ORCH=//p' "$LEASE_CONF")" == "$orch" &&
     "$(sed -n 's/^LEASE_PRIORITY_DISPATCH=//p' "$LEASE_CONF")" == "$dispatch" ]] ||
    { do_log "FATAL $LEASE_CONF does not read back the ranking; the old file is $bak"; return 1; }
  printf '%s RANK orch %s, dispatch %s set on %s by do_spl_lease_rank (backup %s)\n' \
    "$(date -u +%FT%TZ)" "$orch" "$dispatch" "$machine" "$bak" >>"$LEASE_DIR/lease.log" 2>/dev/null || true
  echo "DONE lease-conf rank orch $orch, dispatch $dispatch on $machine (backup $bak); the next ensure tick restarts the fleet loop on it"
  echo "NEXT run the same ranking on every other machine of the fleet, or the roles ping-pong while they disagree"
}

# stdin -> stdout: <key>=<value> replaces the first <key>= line, drops any
# later one, and is appended when the key is absent. Other lines untouched.
spl_lease_rank_set() {
  awk -v k="$1" -v v="$2" '
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }'
}
