#!/bin/bash
#------------------------------------------------------------------------------
# @description Let a peer box of the fleet ssh into THIS box through the reverse
# @description tunnel of do_setup_reverse_tunnel (SPL-1766, owner t1 0bb05176:
# @description "Let the satellite ssh into" the main box), as a forced command only:
# @description   1. over this box's ssh to the peer (BOX_SSH_<BOX> or the
# @description      satellite alias) the peer's /etc/csi-spl-satellite.env
# @description      must name BOX_TAG=<FROM_BOX>; it gives its AGENT_USER
# @description   2. on the peer, as that agent user: an ed25519 key
# @description      ~/.ssh/id_ed25519_spl_peer_<this box> made THERE if it is
# @description      missing (the private key never leaves the peer), and a
# @description      Host <this box>-tunnel block in its ~/.ssh/config
# @description      (127.0.0.1:<port>, that key, IdentitiesOnly)
# @description   3. here, in the authorized_keys of PEER_SSH_USER: the PUBLIC
# @description      key as one line
# @description        from="127.0.0.1,::1",restrict,command="bash <gate> <peer>"
# @description      tagged ` spl-peer:<peer>`; the old line of that peer is
# @description      replaced, every other line kept, a backup written first.
# @description      The gate (src/bash/scripts/peer-ssh-gate.sh) runs only its
# @description      allowed verbs (ping, lease).
# @description Prints the key's fingerprint, never a private key. Idempotent.
# @description Dry run unless DRY_RUN=0; from a linked worktree DRY_RUN=0 is
# @description refused (the gate path would vanish with it).
# @param FROM_BOX (optional) - the peer box id (its BOX_TAG), default sat
# @param BOX_SSH_<BOX> (optional) - its ssh destination (<BOX>: upper case, - as _), default the satellite alias
# @param SATELLITE_ALIAS (optional) - default satellite (do_satellite_ssh_config)
# @param PEER_SSH_USER (optional) - the local user the peer logs in as, default SPOOL_AGENT_USER of <spool root>/box.env
# @param REVERSE_TUNNEL_PORT (optional) - the tunnel port on the peer, default 2222
# @param SPOOL_ROOT (optional) - default /var/spool-hub (its box.env names this box: SPOOL_BOX_TAG)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_box_peer_ssh_grant
# @example DRY_RUN=0 ./run -a do_box_peer_ssh_grant
#------------------------------------------------------------------------------
do_box_peer_ssh_grant() {
  local box="${FROM_BOX:-sat}" port="${REVERSE_TUNNEL_PORT:-2222}" root="${SPOOL_ROOT:-/var/spool-hub}" dry=1
  local benv me user k s dest gate gd cd
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL FROM_BOX must be a box id (e.g. sat), got: '$box'"; return 1; }
  [[ "$port" =~ ^[0-9]{4,5}$ ]] || { do_log "FATAL REVERSE_TUNNEL_PORT must be a port, got: '$port'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  benv="$root/box.env"
  me="$(sed -n 's/^SPOOL_BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' "$benv" 2>/dev/null | tail -n1)"
  [[ -n "$me" ]] || { do_log "FATAL $benv names no SPOOL_BOX_TAG: this box has no id"; return 1; }
  [[ "$me" != "$box" ]] || { do_log "FATAL FROM_BOX=$box is this box"; return 1; }
  user="${PEER_SSH_USER:-$(sed -n 's/^SPOOL_AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' "$benv" 2>/dev/null | tail -n1)}"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { do_log "FATAL no local user: set PEER_SSH_USER or SPOOL_AGENT_USER in $benv"; return 1; }
  k="$(tr 'a-z-' 'A-Z_' <<<"$box")"; s="BOX_SSH_$k"
  dest="${!s:-${SATELLITE_ALIAS:-satellite}}"
  gate="$PROJ_PATH/src/bash/scripts/peer-ssh-gate.sh"
  [[ -f "$gate" ]] || { do_log "FATAL no gate script $gate"; return 1; }
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if (( ! dry )) && [[ -n "$gd" && "$gd" != "$cd" && "${PEER_SSH_ALLOW_WORKTREE:-0}" != 1 ]]; then
    do_log "FATAL $PROJ_PATH is a linked worktree: grant from the main checkout - nothing changed"; return 1
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: on $box (ssh $dest) make the agent user's key id_ed25519_spl_peer_$me if missing and a Host $me-tunnel (127.0.0.1:$port, user $user); here put its public key in $user's authorized_keys as from=127.0.0.1,restrict,command=\"bash $gate $box\""
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to grant."
    return 0
  fi

  local err envf tag agent pub line fp
  err="$(mktemp)" || return 1
  envf="$(ssh -o BatchMode=yes "$dest" 'cat /etc/csi-spl-satellite.env' </dev/null 2>"$err")" ||
    { do_log "FATAL ssh $dest: cannot read its /etc/csi-spl-satellite.env: $(tail -n1 "$err")"; rm -f "$err"; return 1; }
  tag="$(sed -n 's/^BOX_TAG=\([a-z0-9][a-z0-9-]*\)$/\1/p' <<<"$envf")"
  agent="$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")"
  [[ "$tag" == "$box" ]] || { do_log "FATAL ssh $dest answers as box '${tag:-?}', not '$box': nothing changed"; rm -f "$err"; return 1; }
  [[ -n "$agent" ]] || { do_log "FATAL box $box names no AGENT_USER: nothing changed"; rm -f "$err"; return 1; }

  # shellcheck disable=SC2029 # the command is built for the remote shell on purpose
  pub="$(ssh -o BatchMode=yes "$dest" "$(printf '%q ' sudo -n -u "$agent" -H bash -c "$(spl_bpsg_peer_script)" box-peer-ssh "$me" "$port" "$user")" </dev/null 2>"$err")" ||
    { do_log "FATAL on $box: no key for $agent: $(tail -n1 "$err")"; rm -f "$err"; return 1; }
  rm -f "$err"
  pub="$(tail -n1 <<<"$pub")"
  [[ "$pub" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || { do_log "FATAL $box returned no ed25519 public key"; return 1; }
  pub="$(cut -d' ' -f1,2 <<<"$pub")"
  line="from=\"127.0.0.1,::1\",restrict,command=\"bash $gate $box\" $pub spl-peer:$box"
  spl_bpsg_as "$user" bash -c "$(spl_bpsg_local_script)" box-peer-ssh "$box" "$line" ||
    { do_log "FATAL cannot write the authorized_keys of $user"; return 1; }
  fp="$(ssh-keygen -lf - <<<"$pub" 2>/dev/null | cut -d' ' -f2)"
  do_log "OK $agent@$box may run the gate verbs as $user here, through its 127.0.0.1:$port (key ${fp:-?}); on $box: ssh $me-tunnel ping"
}

# spl_bpsg_as <user> <cmd...> - run as that local user (sudo only when it is
# another user than this one)
spl_bpsg_as() {
  local u="$1"; shift
  if [[ "$u" == "$(id -un)" ]]; then "$@"; else "${SUDO_BIN:-sudo}" -n -u "$u" -H "$@"; fi
}

# The step on the peer, as its agent user: the key (made here if missing) and
# the Host block; prints the PUBLIC key last.
spl_bpsg_peer_script() {
  cat <<'SCRIPT'
me="$1" port="$2" user="$3"
umask 077
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 1
key="$HOME/.ssh/id_ed25519_spl_peer_$me"
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C "spl-peer-$me" -f "$key" </dev/null >/dev/null || exit 1
cfg="$HOME/.ssh/config" b="# csi-spl:peer-ssh:$me begin" e="# csi-spl:peer-ssh:$me end"
touch "$cfg"
awk -v b="$b" -v e="$e" '$0==b{s=1} !s{print} $0==e{s=0}' "$cfg" >"$cfg.new" || exit 1
printf '%s\nHost %s-tunnel\n  HostName 127.0.0.1\n  Port %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n%s\n' \
  "$b" "$me" "$port" "$user" "$key" "$e" >>"$cfg.new" && mv "$cfg.new" "$cfg" && chmod 600 "$cfg" || exit 1
cat "$key.pub"
SCRIPT
}

# The step here, as PEER_SSH_USER: back up authorized_keys, drop the peer's old
# line (tagged spl-peer:<peer>), append the new one.
spl_bpsg_local_script() {
  cat <<'SCRIPT'
box="$1" line="$2"
umask 077
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 1
ak="$HOME/.ssh/authorized_keys"
touch "$ak"
grep -qxF -- "$line" "$ak" && exit 0
cp -p "$ak" "$ak.bak-spl-peer-$(date -u +%Y%m%dT%H%M%SZ)" || exit 1
grep -v -- " spl-peer:$box\$" "$ak" >"$ak.new"
printf '%s\n' "$line" >>"$ak.new" && chmod 600 "$ak.new" && mv "$ak.new" "$ak"
SCRIPT
}
