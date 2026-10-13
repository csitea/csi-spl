#!/bin/bash
#------------------------------------------------------------------------------
# @description Host setup of the local private spool-hub (local hub swarm, lane
# @description L5): the one step that needs root. Docker is the only host tool:
# @description nothing is installed here, a missing prerequisite is refused
# @description with the Debian package that carries it.
# @description   1. prereqs: docker, compose v2+, the rootless extras
# @description      (dockerd-rootless-setuptool.sh, rootlesskit), slirp4netns
# @description      or pasta, newuidmap/newgidmap (uidmap), ss, loginctl
# @description   2. the dedicated SYSTEM user (cnf env.lde.local_hub.user), its
# @description      own group, no login shell; refused when it is in a docker /
# @description      sudo / wheel / adm group or shares its group
# @description   3. its home (cnf .home): created EMPTY, owned by it, 0700; the
# @description      long-lived tree is do_spl_local_hub_update's, not this one's
# @description   4. a subuid / subgid range of 65536 past every range in use
# @description   5. linger, so its systemd --user (and dockerd) runs unattended
# @description   6. its OWN rootless dockerd (dockerd-rootless-setuptool.sh):
# @description      /run/user/<uid>/docker.sock, data root under the home; the
# @description      system daemon's docker group never reaches its volumes
# @description   7. verify: the socket answers as rootless, as that user
# @description   8. firewall report (WARN only): every port is bound to
# @description      127.0.0.1, so the firewall is a second fence, not the gate
# @description DRY_RUN=1 (default) prints every root command, runs none.
# @description Idempotent: a step already in place is reported, not redone.
# @description Trust caveat: a sudoer on the box is root and can still read
# @description the data; this lock-down stops accidental reads, sweeps and
# @description docker-group access, not a deliberate sudo.
# @param DRY_RUN (optional) - 1 (default) prints, 0 applies (sudo -n)
# @param LOCAL_HUB_USER / LOCAL_HUB_HOME (optional) - override cnf
# @example ./run -a do_spl_local_hub_install
# @example DRY_RUN=0 ./run -a do_spl_local_hub_install
#------------------------------------------------------------------------------

# _sli_run <cmd...> -- a root command: printed on DRY_RUN=1, else sudo -n
_sli_run() {
  if [[ "${DRY_RUN:-1}" != 0 ]]; then echo "DRY-RUN: sudo $*"; return 0; fi
  sudo -n "$@"
}

# _sli_as <cmd...> -- a command as the hub user, in its systemd --user env
_sli_as() {
  local rd; rd="$(_sli_rundir)"
  _sli_run -u "$LOCAL_HUB_USER" -H env HOME="$LOCAL_HUB_HOME" XDG_RUNTIME_DIR="$rd" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$rd/bus" "$@"
}

# _sli_rundir -- the hub user's /run/user/<uid> (LOCAL_HUB_RUN_DIR overrides /run/user)
_sli_rundir() {
  echo "${LOCAL_HUB_RUN_DIR:-/run/user}/$(id -u "$LOCAL_HUB_USER" 2>/dev/null || echo '<uid>')"
}

_sli_prereqs() {
  local missing="" b v
  for b in docker:docker-ce dockerd-rootless-setuptool.sh:docker-ce-rootless-extras rootlesskit:docker-ce-rootless-extras \
           newuidmap:uidmap newgidmap:uidmap ss:iproute2 loginctl:systemd; do
    command -v "${b%%:*}" >/dev/null 2>&1 || missing+="${b%%:*} (${b#*:}) "
  done
  command -v slirp4netns >/dev/null 2>&1 || command -v pasta >/dev/null 2>&1 || missing+="slirp4netns|pasta (slirp4netns) "
  v="$(docker compose version --short 2>/dev/null)"; v="${v#v}"
  [[ "${v%%.*}" =~ ^[0-9]+$ ]] && ((${v%%.*} >= 2)) || missing+="docker compose v2+ (docker-compose-plugin) "
  if [[ -n "$missing" ]]; then
    do_log "FATAL local hub install: missing prerequisites: $missing-- install them with apt, docker is the only host tool"
    return 1
  fi
  do_log "OK local hub install: prerequisites present (compose $v)"
}

_sli_user() {
  local u="$LOCAL_HUB_USER" g bad="" others gid
  if ! id -u "$u" >/dev/null 2>&1; then
    _sli_run useradd --system --user-group --home-dir "$LOCAL_HUB_HOME" --no-create-home \
      --shell /usr/sbin/nologin --comment "local spool-hub" "$u" || return 1
    [[ "${DRY_RUN:-1}" != 0 ]] && return 0
  fi
  for g in $(id -nG "$u"); do [[ " docker sudo wheel adm root " == *" $g "* ]] && bad+="$g "; done
  [[ -z "$bad" ]] || { do_log "FATAL local hub install: $u is in privileged group(s) $bad-- remove it by hand first"; return 1; }
  gid="$(id -g "$u")"
  others="$(getent group "$gid" | cut -d: -f4)$(getent passwd | awk -F: -v g="$gid" -v u="$u" '$4==g && $1!=u {printf " %s", $1}')"
  [[ -z "${others// /}" ]] || { do_log "FATAL local hub install: other users share $u's group: $others"; return 1; }
  do_log "OK local hub install: system user $u, alone in its group"
}

_sli_home() {
  local h="$LOCAL_HUB_HOME" u="$LOCAL_HUB_USER"
  [[ "$h" == /* && "$h" != / ]] || { do_log "FATAL local hub install: home must be an absolute path, got '$h'"; return 1; }
  # mode and owner of the home itself, never recursive: its content is the user's
  _sli_run install -d -m 0700 -o "$u" -g "$u" "$h" || return 1
  do_log "OK local hub install: home $h, $u, 0700"
}

# _sli_next_subid <file...> -- the first id past every range in the files
# (SUB_UID_MIN 100000 at least), so the new range overlaps nobody's
_sli_next_subid() {
  awk -F: 'BEGIN {n=100000} NF>=3 && $2+$3>n {n=$2+$3} END {print n}' "$@" 2>/dev/null
}

_sli_subids() {
  local u="$LOCAL_HUB_USER" fu="${LOCAL_HUB_SUBUID_FILE:-/etc/subuid}" fg="${LOCAL_HUB_SUBGID_FILE:-/etc/subgid}" s
  if grep -q "^$u:" "$fu" 2>/dev/null && grep -q "^$u:" "$fg" 2>/dev/null; then
    do_log "OK local hub install: $u already has subuid/subgid ranges"; return 0
  fi
  s="$(_sli_next_subid "$fu" "$fg")"
  _sli_run usermod --add-subuids "$s-$((s + 65535))" --add-subgids "$s-$((s + 65535))" "$u" || return 1
  do_log "OK local hub install: subuid/subgid $s-$((s + 65535)) for $u"
}

_sli_linger() {
  local u="$LOCAL_HUB_USER" rd i
  _sli_run loginctl enable-linger "$u" || return 1
  [[ "${DRY_RUN:-1}" != 0 ]] && return 0
  rd="$(_sli_rundir)"
  _sli_run systemctl start "user@$(id -u "$u").service" || return 1
  # the run dir is the user's 0700: look through sudo
  for ((i = 0; i < 20; i++)); do _sli_run test -S "$rd/bus" && break; sleep 0.5; done
  _sli_run test -S "$rd/bus" || { do_log "FATAL local hub install: no systemd --user bus for $u"; return 1; }
  do_log "OK local hub install: linger on, systemd --user running for $u"
}

_sli_rootless() {
  local u="$LOCAL_HUB_USER" sock sec
  sock="$(_sli_rundir)/docker.sock"
  if [[ "${DRY_RUN:-1}" == 0 ]] && _sli_run test -S "$sock" && _sli_as docker -H "unix://$sock" info >/dev/null 2>&1; then
    do_log "OK local hub install: rootless dockerd already up for $u"
  else
    _sli_as dockerd-rootless-setuptool.sh install || { do_log "FATAL local hub install: dockerd-rootless-setuptool.sh failed"; return 1; }
    _sli_as systemctl --user enable --now docker.service || return 1
  fi
  [[ "${DRY_RUN:-1}" != 0 ]] && return 0
  sec="$(_sli_as docker -H "unix://$sock" info --format '{{json .SecurityOptions}} {{.DockerRootDir}}' 2>/dev/null)"
  [[ "$sec" == *name=rootless*" $LOCAL_HUB_HOME/"* ]] || {
    do_log "FATAL local hub install: $sock is not a rootless daemon under $LOCAL_HUB_HOME: ${sec:-no answer}"; return 1; }
  do_log "OK local hub install: rootless dockerd for $u at unix://$sock"
}

# _sli_firewall -- WARN only: an nftables / iptables INPUT policy of drop is a
# second fence; the gate is the 127.0.0.1 binds (do_spl_local_hub_ports_gate)
_sli_firewall() {
  [[ "${DRY_RUN:-1}" != 0 ]] && { echo "DRY-RUN: sudo nft list ruleset (firewall report)"; return 0; }
  if sudo -n nft list ruleset 2>/dev/null | grep -E 'hook input .*policy drop' >/dev/null; then
    do_log "OK local hub install: firewall input policy is drop"
  else
    do_log "WARN local hub install: no input-drop firewall; every local hub port is bound to 127.0.0.1, which is the gate"
  fi
}

do_spl_local_hub_install() {
  # the cnf reader and the gates live in the harden file
  declare -F _slh_cnf >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-local-hub-harden.func.sh"
  _slh_cnf || return 1
  do_log "INFO local hub install: user $LOCAL_HUB_USER, home $LOCAL_HUB_HOME, DRY_RUN=${DRY_RUN:-1}"
  _sli_prereqs && _sli_user && _sli_home && _sli_subids && _sli_linger && _sli_rootless || return 1
  _sli_firewall
  if [[ "${DRY_RUN:-1}" != 0 ]]; then do_log "OK local hub install: dry run, nothing changed (DRY_RUN=0 applies)"
  else do_log "OK local hub install: done; next: sudo -u $LOCAL_HUB_USER -H ./run -a do_spl_local_hub_harden_check"; fi
}
