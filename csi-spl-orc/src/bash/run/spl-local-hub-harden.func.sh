#!/bin/bash
#------------------------------------------------------------------------------
# @description The local private spool-hub's hardening gates (local hub swarm,
# @description lane L5). Both run AS the hub user (do_spl_local_hub_up re-execs
# @description through `sudo -u <user> -H` first) and never call sudo: what
# @description needs root is do_spl_local_hub_install's.
# @description
# @description do_spl_local_hub_harden_check  one PASS / FAIL / INFO line per
# @description   check, exit 1 on any FAIL (do_spl_local_hub_up refuses on it):
# @description   - the hub user: a system user with no login shell, in no
# @description     docker / sudo / wheel / adm / root group, alone in its group
# @description   - its home: owned by it, 0700
# @description   - a /etc/subuid and /etc/subgid range (>= 65536), linger on
# @description   - its OWN rootless dockerd: /run/user/<uid> 0700, docker.sock
# @description     owned by it, `docker info` says rootless, the data root (so
# @description     every named volume) under the 0700 home
# @description   - compose: every published port bound to 127.0.0.1 / ::1
# @description   - hub.env: no outbound cloud call. STORAGE_EMULATOR_HOST set
# @description     (the GCS emulator), no cloud credentials, mail log/none, no
# @description     social sign-in, every URL on localhost or a compose service
# @description   - running containers of the project: no process as host root
# @description     (the hub user or its subuids only), published on loopback
# @description do_spl_local_hub_ports_gate  `ss -ltune`: every listener of the
# @description   hub user, and every listener on a local hub port by anyone,
# @description   is on loopback; exit 1 otherwise (do_spl_local_hub_status).
# @description
# @description The user, home, project and ports are cnf env.lde.local_hub
# @description (lde.env.yaml); LOCAL_HUB_USER / LOCAL_HUB_HOME /
# @description LOCAL_HUB_PROJECT win. Nothing here names a workspace.
# @param LOCAL_HUB_COMPOSE_JSON (optional) - `docker compose config --format json`
# @param   output; default: lde_compose config, when it is defined
# @param LOCAL_HUB_HUB_ENV (optional) - default $LOCAL_HUB_HOME/state/hub.env
# @example sudo -u spl-hub -H ./run -a do_spl_local_hub_harden_check
# @example ./run -a do_spl_local_hub_ports_gate
#------------------------------------------------------------------------------

# _slh_cnf -- exports LOCAL_HUB_USER, _HOME, _PROJECT and LOCAL_HUB_PORTS (the
# pg gcs hub wui host ports) from cnf env.lde.local_hub. No literal default:
# a missing key is FATAL. LOCAL_HUB_CNF overrides the cnf file.
_slh_cnf() {
  local cnf="${LOCAL_HUB_CNF:-}" base k v
  if [[ -z "$cnf" ]]; then
    base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
    [[ "$base" =~ ^([a-z]+-[a-z]+)-orc$ ]] || { do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
    cnf="$(dirname "$PROJ_PATH")/${BASH_REMATCH[1]}-cnf/${BASH_REMATCH[1]}/lde.env.yaml"
  fi
  [[ -r "$cnf" ]] || { do_log "FATAL cannot read the local hub cnf $cnf"; return 1; }
  local -A c=()
  for k in user home compose_project pg_port gcs_port hub_port wui_port; do
    v="$(yq -r ".env.lde.local_hub.$k // \"\"" "$cnf")"
    [[ -n "$v" && "$v" != null ]] || { do_log "FATAL cnf env.lde.local_hub.$k is empty ($cnf)"; return 1; }
    c[$k]="$v"
  done
  LOCAL_HUB_USER="${LOCAL_HUB_USER:-${c[user]}}"
  LOCAL_HUB_HOME="${LOCAL_HUB_HOME:-${c[home]}}"
  LOCAL_HUB_PROJECT="${LOCAL_HUB_PROJECT:-${c[compose_project]}}"
  LOCAL_HUB_PORTS="${c[pg_port]} ${c[gcs_port]} ${c[hub_port]} ${c[wui_port]}"
  export LOCAL_HUB_USER LOCAL_HUB_HOME LOCAL_HUB_PROJECT LOCAL_HUB_PORTS
}

# _slh_loopback <addr> -- true for 127.0.0.0/8 and ::1 (brackets, %iface ok)
_slh_loopback() {
  local a="${1#[}"; a="${a%]}"; a="${a%%%*}"
  [[ "$a" == 127.* || "$a" == ::1 || "$a" == ::ffff:127.* ]]
}

# _slh_verdict <rc> <pass text> <fail text> -- PASS on rc 0, else FAIL
_slh_verdict() {
  if [[ "$1" == 0 ]]; then _slh_mark PASS "$2"; else _slh_mark FAIL "$3"; fi
}

# _slh_mark PASS|FAIL|INFO <text> -- one result line; counts the FAILs
_slh_mark() {
  printf '%s  %s\n' "$1" "$2"
  [[ "$1" == FAIL ]] && _SLH_FAILS=$((_SLH_FAILS + 1))
  return 0
}

_slhc_user() {
  local rc u="$LOCAL_HUB_USER" uid gid shell g bad="" others
  uid="$(id -u "$u" 2>/dev/null)" || { _slh_mark FAIL "user $u does not exist (do_spl_local_hub_install)"; return 1; }
  rc=1; [[ "$(id -un)" == "$u" ]] && rc=0
  _slh_verdict "$rc" "running as $u" "run the check as $u, not $(id -un)"
  local sys_max="${LOCAL_HUB_SYS_UID_MAX:-$(awk '$1=="SYS_UID_MAX"{print $2}' /etc/login.defs 2>/dev/null)}"
  ((uid <= ${sys_max:-999})); rc=$?
  _slh_verdict "$rc" "$u is a system user (uid $uid)" "$u uid $uid is not a system uid (<= ${sys_max:-999})"
  shell="$(getent passwd "$u" | cut -d: -f7)"
  rc=1; [[ "$shell" == */nologin || "$shell" == */false ]] && rc=0
  _slh_verdict "$rc" "$u has no login shell" "$u has a login shell: $shell"
  for g in $(id -nG "$u"); do [[ " docker sudo wheel adm root " == *" $g "* ]] && bad+="$g "; done
  rc=1; [[ -z "$bad" ]] && rc=0
  _slh_verdict "$rc" "$u is in no docker/sudo/wheel/adm/root group" "$u is in privileged group(s): $bad"
  gid="$(id -g "$u")"
  others="$(getent group "$gid" | cut -d: -f4)"
  others+="$(getent passwd | awk -F: -v g="$gid" -v u="$u" '$4==g && $1!=u {printf " %s", $1}')"
  [[ -z "${others// /}" ]]; rc=$?
  _slh_verdict "$rc" "$u is alone in its group" "other users share $u's group: $others"
}

_slhc_home() {
  local rc h="$LOCAL_HUB_HOME" got
  got="$(stat -c '%U %a' "$h" 2>/dev/null)"
  [[ "$got" == "$LOCAL_HUB_USER 700" ]]
  rc=$?
  _slh_verdict "$rc" "home $h is $LOCAL_HUB_USER 0700" "home $h must be $LOCAL_HUB_USER 0700, is: ${got:-missing}"
}

_slhc_subids() {
  local rc f n
  for n in uid gid; do
    f="/etc/sub$n"; [[ $n == uid ]] && f="${LOCAL_HUB_SUBUID_FILE:-$f}" || f="${LOCAL_HUB_SUBGID_FILE:-$f}"
    if awk -F: -v u="$LOCAL_HUB_USER" '$1==u && $3>=65536 {ok=1} END {exit !ok}' "$f" 2>/dev/null; then
      _slh_mark PASS "sub$n range for $LOCAL_HUB_USER in $f"
    else _slh_mark FAIL "no sub$n range (>= 65536) for $LOCAL_HUB_USER in $f"; fi
  done
  [[ -e "${LOCAL_HUB_LINGER_DIR:-/var/lib/systemd/linger}/$LOCAL_HUB_USER" ]]
  rc=$?
  _slh_verdict "$rc" "linger on for $LOCAL_HUB_USER" "linger off for $LOCAL_HUB_USER (loginctl enable-linger)"
}

_slhc_daemon() {
  local rc uid rd sec root
  uid="$(id -u "$LOCAL_HUB_USER" 2>/dev/null)" || return 0
  rd="${LOCAL_HUB_RUN_DIR:-/run/user}/$uid"
  [[ "$(stat -c '%U %a' "$rd" 2>/dev/null)" == "$LOCAL_HUB_USER 700" ]]
  rc=$?
  _slh_verdict "$rc" "$rd is $LOCAL_HUB_USER 0700" "$rd must be $LOCAL_HUB_USER 0700"
  [[ -S "$rd/docker.sock" && "$(stat -c %U "$rd/docker.sock")" == "$LOCAL_HUB_USER" ]] \
    || { _slh_mark FAIL "no rootless docker socket $rd/docker.sock owned by $LOCAL_HUB_USER"; return 0; }
  export DOCKER_HOST="unix://$rd/docker.sock"
  sec="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null)"
  rc=1; [[ "$sec" == *name=rootless* ]] && rc=0
  _slh_verdict "$rc" "the daemon at $DOCKER_HOST is rootless" "the daemon at $DOCKER_HOST is not rootless: ${sec:-no answer}"
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  [[ -n "$root" && "$root/" == "$LOCAL_HUB_HOME/"* ]]
  rc=$?
  _slh_verdict "$rc" "docker data root (the volumes) under $LOCAL_HUB_HOME" "docker data root ${root:-unknown} is outside $LOCAL_HUB_HOME"
}

_slhc_compose() {
  local json="${LOCAL_HUB_COMPOSE_JSON:-}" rows s ip p bad=0
  if [[ -z "$json" ]] && declare -F lde_compose >/dev/null; then
    json="$(mktemp)"; lde_compose config --format json >"$json" 2>/dev/null || { rm -f "$json"; json=""; }
  fi
  [[ -s "$json" ]] || { _slh_mark FAIL "compose: cannot read the compose config (LOCAL_HUB_COMPOSE_JSON)"; return 0; }
  rows="$(jq -r '.services // {} | to_entries[] | .key as $s | (.value.ports // [])[] | "\($s) \(.host_ip // "-") \(.published // "-")"' "$json")"
  [[ "$json" == "${LOCAL_HUB_COMPOSE_JSON:-}" ]] || rm -f "$json"
  while read -r s ip p; do
    [[ -z "$s" ]] && continue
    _slh_loopback "$ip" || { _slh_mark FAIL "compose: $s publishes $p on '${ip/-/all interfaces}'"; bad=1; }
  done <<<"$rows"
  ((bad)) || _slh_mark PASS "compose: every published port is on loopback"
}

_slhc_hubenv() {
  local f="${LOCAL_HUB_HUB_ENV:-$LOCAL_HUB_HOME/state/hub.env}" hosts h bad=0 v
  [[ -r "$f" ]] || { _slh_mark INFO "hub.env $f not rendered yet: the outbound check runs once it is"; return 0; }
  grep -qE '^STORAGE_EMULATOR_HOST=.+' "$f" || { _slh_mark FAIL "hub.env: no STORAGE_EMULATOR_HOST, the hub would call real GCS"; bad=1; }
  grep -qE '^(GOOGLE_APPLICATION_CREDENTIALS|GOOGLE_CLOUD_PROJECT|CLOUDSDK_[A-Z_]*|AWS_[A-Z_]*)=' "$f" \
    && { _slh_mark FAIL "hub.env: carries cloud credentials or a cloud project"; bad=1; }
  v="$(sed -n 's/^SPOOL_HUB_MAIL_TRANSPORT=//p' "$f")"
  [[ -z "$v" || "$v" == log || "$v" == none ]] || { _slh_mark FAIL "hub.env: mail transport '$v' sends mail out (log or none only)"; bad=1; }
  v="$(sed -n 's/^SPOOL_HUB_AUTH_PROVIDERS=//p' "$f")"
  [[ -z "${v//\"/}" ]] || { _slh_mark FAIL "hub.env: social sign-in '$v' calls an outside IdP"; bad=1; }
  hosts="$(grep -oE '[a-z]+://[^/:" ]+' "$f" | sed 's#.*://##' | sort -u)"
  for h in $hosts; do
    [[ "$h" == localhost || "$h" == *.localhost || "$h" != *.* ]] || _slh_loopback "$h" \
      || { _slh_mark FAIL "hub.env: names an outside host $h"; bad=1; }
  done
  v="$(sed -n 's/^STORAGE_EMULATOR_HOST=//p' "$f")"; v="${v#*://}"; v="${v%%[:/]*}"
  [[ -z "$v" || "$v" != *.* ]] || _slh_loopback "$v" || { _slh_mark FAIL "hub.env: STORAGE_EMULATOR_HOST $v is not the compose gcs"; bad=1; }
  ((bad)) || _slh_mark PASS "hub.env: no outbound cloud call"
}

# _slhc_containers -- every running container of the project: its init pid
# on the host belongs to the hub user or its subuid range, never host root;
# every published port on loopback.
_slhc_containers() {
  local ids uid lo cnt name pid ips hu ip bad=0
  [[ -n "${DOCKER_HOST:-}" ]] || return 0
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$LOCAL_HUB_PROJECT" 2>/dev/null)"
  [[ -n "$ids" ]] || { _slh_mark INFO "no running container of $LOCAL_HUB_PROJECT yet"; return 0; }
  uid="$(id -u "$LOCAL_HUB_USER")"
  read -r lo cnt < <(awk -F: -v u="$LOCAL_HUB_USER" '$1==u {print $2, $3; exit}' "${LOCAL_HUB_SUBUID_FILE:-/etc/subuid}")
  # shellcheck disable=SC2086
  while read -r name pid ips; do
    [[ -z "$name" ]] && continue
    hu="$(stat -c %u "/proc/$pid" 2>/dev/null)"
    if [[ -z "$hu" ]]; then _slh_mark FAIL "${name#/}: cannot see its process $pid"; bad=1
    elif ((hu == 0)); then _slh_mark FAIL "${name#/}: runs as host root"; bad=1
    elif ((hu != uid)) && ! ((hu >= ${lo:-0} && hu < ${lo:-0} + ${cnt:-0})); then
      _slh_mark FAIL "${name#/}: runs as host uid $hu, not $LOCAL_HUB_USER or its subuids"; bad=1; fi
    for ip in $ips; do _slh_loopback "$ip" || { _slh_mark FAIL "${name#/}: published on $ip"; bad=1; }; done
  done < <(docker inspect --format '{{.Name}} {{.State.Pid}} {{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}} {{end}}{{end}}' $ids 2>/dev/null)
  ((bad)) || _slh_mark PASS "running containers: unprivileged on the host, loopback only"
}

do_spl_local_hub_harden_check() {
  _slh_cnf || return 1
  _SLH_FAILS=0
  _slhc_user; _slhc_home; _slhc_subids; _slhc_daemon; _slhc_compose; _slhc_hubenv; _slhc_containers
  if ((_SLH_FAILS)); then do_log "FATAL local hub harden check: $_SLH_FAILS FAIL(s)"; return 1; fi
  do_log "OK local hub harden check: $LOCAL_HUB_USER, $LOCAL_HUB_HOME, $LOCAL_HUB_PROJECT"
}

# do_spl_local_hub_ports_gate -- nothing public: `ss -Hltune` (tcp + udp, the
# socket's uid), every listener of the hub user and every listener on a local
# hub port (cnf) must be on loopback.
do_spl_local_hub_ports_gate() {
  _slh_cnf || return 1
  local uid net addr port owner line n=0 bad=0
  uid="$(id -u "$LOCAL_HUB_USER" 2>/dev/null)" || uid=-1
  while read -r line; do
    [[ -z "$line" ]] && continue
    read -r net _ _ _ addr _ <<<"$line"
    port="${addr##*:}"; addr="${addr%:*}"
    owner="$(grep -oE '(^| )uid:[0-9]+' <<<"$line" | cut -d: -f2)"
    [[ "$owner" == "$uid" || " $LOCAL_HUB_PORTS " == *" $port "* ]] || continue
    n=$((n + 1))
    _slh_loopback "$addr" || { echo "FAIL  $net $addr:$port is public (uid ${owner:-0})"; bad=1; }
  done < <(ss -Hltune 2>/dev/null)
  if ((bad)); then do_log "FATAL local hub ports gate: a listener is public"; return 1; fi
  do_log "OK local hub ports gate: $n listener(s) of $LOCAL_HUB_USER / ports $LOCAL_HUB_PORTS, all loopback"
}
