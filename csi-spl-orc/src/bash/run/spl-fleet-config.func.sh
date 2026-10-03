#!/bin/bash
#------------------------------------------------------------------------------
# @description Write one fleet config file on EVERY machine or on none (spec
# @description 068 section 5, lane L5; F5: one rank line applied on one
# @description machine flapped the orchestrator for 3 h). Under the mutex
# @description fleet-config (do_spl_peer_gate), in two phases:
# @description   1. stage: <file>.stage.<txn> on every box, read back and
# @description      compared; one failure removes every stage: none written
# @description   2. commit: on each box keep the old file as
# @description      <file>.prev.<txn>, then rename the stage over it; one
# @description      failure puts back every box already committed: none
# @description      written. Success removes the .prev copies.
# @description A box is this machine (its spool root), a dir reachable from
# @description here (FLEET_CONFIG_ROOT_<BOX>), or a host over ssh
# @description (FLEET_CONFIG_SSH_<BOX>, no default host; its root is
# @description FLEET_CONFIG_ROOT_<BOX>, default /var/spool-hub). A box with
# @description no way in is refused before anything is written.
# @param FLEET_CONFIG_FILE - required: the file under the spool root, peer/<name> or dispatch/<name> (e.g. peer/seats, dispatch/lease.conf)
# @param FLEET_CONFIG_SRC - required: a local file holding the new content
# @param FLEET_CONFIG_BOXES - required: the boxes, space-separated (e.g. "sat pc")
# @param FLEET_CONFIG_ROOT_<BOX> / FLEET_CONFIG_SSH_<BOX> (optional) - how a box is reached (<BOX>: upper case, - as _)
# @param FLEET_CONFIG_SSH_CMD (optional) - the ssh binary, default ssh
# @param PEER_SEAT / PEER_MSG / PEER_GEN - the seat and the message it acts for (do_spl_peer_gate)
# @example FLEET_CONFIG_FILE=peer/seats FLEET_CONFIG_SRC=/tmp/seats FLEET_CONFIG_BOXES="sat pc" FLEET_CONFIG_SSH_PC=<host> ./run -a do_spl_fleet_config
#------------------------------------------------------------------------------
declare -F spl_peer_gate >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-gate.func.sh"

do_spl_fleet_config() {
  local rel="${FLEET_CONFIG_FILE:-}" src="${FLEET_CONFIG_SRC:-}" boxes=() b txn sum i rc=0 done=()
  [[ "$rel" =~ ^(peer|dispatch)/[A-Za-z0-9][A-Za-z0-9._-]*$ && "$rel" != *..* ]] ||
    { do_log "FATAL FLEET_CONFIG_FILE must be peer/<name> or dispatch/<name>, got: '$rel'"; return 1; }
  [[ -f "$src" && -r "$src" ]] || { do_log "FATAL FLEET_CONFIG_SRC is no readable file: '$src'"; return 1; }
  read -ra boxes <<<"${FLEET_CONFIG_BOXES:-}"
  (( ${#boxes[@]} > 0 )) || { do_log "FATAL FLEET_CONFIG_BOXES is not set (every machine of the fleet, e.g. \"sat pc\")"; return 1; }
  spl_peer_init ro || return 1
  for b in "${boxes[@]}"; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL '$b' is not a box id"; return 1; }
    spl_fc_how "$b" >/dev/null || { do_log "FATAL box $b: no way in - set FLEET_CONFIG_SSH_$(spl_fc_key "$b") or FLEET_CONFIG_ROOT_$(spl_fc_key "$b")"; return 1; }
  done
  spl_peer_gate fleet-config || { rc=$?; do_log "ERROR fleet config $rel refused by the gate (exit $rc): nothing written"; return "$rc"; }
  txn="$(date -u +%Y%m%dT%H%M%SZ).$$"
  sum="$(sha1sum < "$src" | cut -c1-40)"
  for b in "${boxes[@]}"; do
    if ! spl_fc_on "$b" stage "$rel" "$txn" "$sum" < "$src"; then
      do_log "ERROR fleet config $rel: stage on $b failed - removing every stage, nothing written"
      for i in "${boxes[@]}"; do spl_fc_on "$i" drop "$rel" "$txn" </dev/null || true; done
      return 1
    fi
  done
  for b in "${boxes[@]}"; do
    if ! spl_fc_on "$b" commit "$rel" "$txn" </dev/null; then
      do_log "ERROR fleet config $rel: commit on $b failed - putting back ${done[*]:-no box}, nothing written"
      for i in "${done[@]}"; do spl_fc_on "$i" undo "$rel" "$txn" </dev/null || do_log "ERROR fleet config $rel: undo on $i FAILED - fix by hand from $rel.prev.$txn"; done
      for i in "${boxes[@]}"; do spl_fc_on "$i" drop "$rel" "$txn" </dev/null || true; done
      return 1
    fi
    done+=("$b")
  done
  for b in "${boxes[@]}"; do spl_fc_on "$b" clean "$rel" "$txn" </dev/null || true; done
  do_log "INFO fleet config $rel written on ${boxes[*]} (sha1 ${sum:0:12}, txn $txn)"
  return 0
}

spl_fc_key() { tr 'a-z-' 'A-Z_' <<<"$1"; }

# How box <b> is reached: "local <root>", "dir <root>" or "ssh <dest> <root>".
spl_fc_how() {
  local k r s
  k="$(spl_fc_key "$1")"; r="FLEET_CONFIG_ROOT_$k"; s="FLEET_CONFIG_SSH_$k"
  if [[ -n "${!s:-}" ]]; then echo "ssh ${!s} ${!r:-/var/spool-hub}"
  elif [[ -n "${!r:-}" ]]; then echo "dir ${!r}"
  elif [[ "$1" == "$PEER_BOX" ]]; then echo "local ${SPOOL_ROOT:-/var/spool-hub}"
  else return 1; fi
}

# spl_fc_on <box> <op> <rel> <txn> [sha1]: one step on one box (stdin = the
# content for stage). The step is the same script locally and over ssh.
spl_fc_on() {
  local how mode dest root
  how="$(spl_fc_how "$1")" || return 1
  read -r mode dest root <<<"$how"
  [[ "$mode" == ssh ]] || root="$dest"
  if [[ "$mode" == ssh ]]; then
    "${FLEET_CONFIG_SSH_CMD:-ssh}" -o BatchMode=yes "$dest" \
      "$(printf '%q ' bash -c "$(spl_fc_script)" spl-fc "$2" "$root/$3" "$4" "${5:-}")"
  else
    bash -c "$(spl_fc_script)" spl-fc "$2" "$root/$3" "$4" "${5:-}"
  fi
}

# The step script: <op> <file> <txn> [sha1]; stage reads the content on stdin.
spl_fc_script() {
  cat <<'SCRIPT'
op="$1" f="$2" txn="$3" sum="$4"
case "$op" in
  stage)
    mkdir -p "$(dirname "$f")" || exit 1
    cat > "$f.stage.$txn" || exit 1
    [ "$(sha1sum < "$f.stage.$txn" | cut -c1-40)" = "$sum" ] ;;
  commit)
    [ -f "$f.stage.$txn" ] || exit 1
    if [ -e "$f" ]; then cp -p "$f" "$f.prev.$txn" || exit 1; else : > "$f.absent.$txn" || exit 1; fi
    mv -f "$f.stage.$txn" "$f" ;;
  undo)
    if [ -f "$f.prev.$txn" ]; then mv -f "$f.prev.$txn" "$f"; elif [ -f "$f.absent.$txn" ]; then rm -f "$f" "$f.absent.$txn"; fi ;;
  drop) rm -f "$f.stage.$txn" ;;
  clean) rm -f "$f.prev.$txn" "$f.absent.$txn" ;;
  *) exit 2 ;;
esac
SCRIPT
}
