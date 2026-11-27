#!/bin/bash
#------------------------------------------------------------------------------
# Helpers of the laptop box (SPL-6680, spec 037 "Laptop box"): a member's own
# Debian laptop joins the fleet as a worker box during her working hours, set
# up and run by one-liners only. Shared by do_spl_laptop_box_install and the
# start / stop / end-of-hours actions. The help page with the one-liners:
# csi-spl-doc/doc/help/laptop-box.md.
#------------------------------------------------------------------------------

# spl_laptop_hours_parse "<days> <HH:MM>-<HH:MM>": the working-hours window, as
# the member writes it in the install one-liner ("Mon-Fri 09:00-17:00",
# "Mon,Wed,Fri 08:30-16:00", "Sat 10:00-14:00"). Prints "<days> <start> <end>",
# days in systemd OnCalendar form ("Mon..Fri", "Mon,Wed,Fri"). The window is
# one span inside one day: start before end. Exit 2 = not a window.
spl_laptop_hours_parse() {
  local s="${1:-}" d='(Mon|Tue|Wed|Thu|Fri|Sat|Sun)' t='([01][0-9]|2[0-3]):[0-5][0-9]'
  local rx="^(${d}(-${d})?(,${d}(-${d})?)*) (${t})-(${t})$"
  [[ "$s" =~ $rx ]] || return 2
  local days="${BASH_REMATCH[1]}" start="${BASH_REMATCH[9]}" end="${BASH_REMATCH[11]}"
  [[ "${start/:/}" < "${end/:/}" ]] || return 2
  printf '%s %s %s\n' "${days//-/..}" "$start" "$end"
}

# spl_laptop_box_tag_ok <tag>: a box tag as box.env takes it (box-config.sh).
spl_laptop_box_tag_ok() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$1" != box-wui ]]
}

# spl_laptop_cnf_get <checkout> <env> <dotted.key>: one value of the rendered
# cnf <checkout>/csi-spl-cnf/csi-spl/<env>.env.json, read with python3 (a
# fresh laptop has no yq before the install). Empty when absent.
spl_laptop_cnf_get() {
  python3 - "$1/csi-spl-cnf/csi-spl/$2.env.json" "$3" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split("."):
        v = v[k]
    print("" if v is None else v)
except Exception:
    print("")
PY
}

# spl_laptop_install_root_cmds <user> <checkout> <spool root> <group> <tag>
#   <env> <tenant> <hours> <max> <move box> <member> <ask lines>: the commands the install
# runs as root, one per line. The member's own account is never used by the
# agents: they get their own OS user, with no sudo and a locked password. The
# member joins the spool group only so her controls can write the state dir.
# Her controls and her pop-up run root-owned copies the agents' user cannot
# change. No secret is in any line.
spl_laptop_install_root_cmds() {
  local u="$1" co="$2" sr="$3" g="$4" tag="$5" env="$6" ten="$7" hours="$8" max="$9" to="${10}" me="${11}" ask="${12:-LAPTOP_ASK=wui}"
  local -a al; read -ra al <<<"$ask"
  local fb="$co/csi-spl-orc/src/bash/features/laptop-box" lib=/usr/local/lib/spl-laptop-box st="$sr/dispatch/laptop-box"
  echo "DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y git tmux curl tar zstd python3 perl util-linux jq ca-certificates libnotify-bin"
  echo "getent group '$g' >/dev/null || groupadd '$g'"
  echo "id -u '$u' >/dev/null 2>&1 || { useradd -m -s /bin/bash '$u' && passwd -l '$u' >/dev/null; }"
  echo "usermod -aG '$g' '$u'"
  [[ -z "$me" ]] || echo "usermod -aG '$g' '$me'"
  echo "chown -R '$u:$u' '$co'"
  echo "install -d -o '$u' -g '$g' -m 2770 '$sr' '$sr/dispatch' '$st'"
  # W3 (R7 a-664): her config is root's. The agents' user owns the spool root,
  # so a file in it could be replaced by that user: laptop-box.env, which the
  # root control remove reads, lives in a root-owned dir under /etc.
  spl_laptop_root_write "$sr/box.env" root "$g" "SPOOL_AGENT_USER=$u" "SPOOL_DESK_USER=$u" "SPOOL_DESK_BOX=$tag" \
    "SPOOL_BOX_TAG=$tag" "SPOOL_FLEET_ENV=$env" "SPOOL_FLEET_TENANT=$ten" "SPOOL_DIR_LAYOUT=qualified"
  echo "install -d -o root -g root -m 0755 '${LAPTOP_ENV_DIR:-/etc/spl-laptop-box}'"
  spl_laptop_root_write "${LAPTOP_ENV_DIR:-/etc/spl-laptop-box}/laptop-box.env" root root "LAPTOP_HOURS=$hours" "LAPTOP_AGENT_MAX=$max" \
    "LAPTOP_BOX_TAG=$tag" "LAPTOP_AGENT_USER=$u" "LAPTOP_MOVE_BOX=$to" "LAPTOP_MEMBER=$me" "${al[@]}"
  echo "install -d -o root -g root -m 0755 '$lib' && install -o root -g root -m 0755 '$fb/laptop-box-ask.sh' '$lib/laptop-box-ask.sh' && install -o root -g root -m 0755 '$fb/laptop-box-ctl.sh' /usr/local/bin/spl-laptop-box"
  spl_laptop_root_write /etc/systemd/system/spl-laptop-box-tick.service root root "[Unit]" "Description=fleet laptop box: one check (her hours, the cap, the end-of-hours ask)" \
    "[Service]" "Type=oneshot" "User=$u" "UMask=0007" "WorkingDirectory=$co/csi-spl-orc" "Environment=SPOOL_ROOT=$sr" "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin" "ExecStart=$co/csi-spl-orc/run -a do_spl_laptop_box_tick"
  spl_laptop_root_write /etc/systemd/system/spl-laptop-box-tick.timer root root "[Unit]" "Description=fleet laptop box: a check every 5 min" \
    "[Timer]" "OnBootSec=2min" "OnUnitActiveSec=5min" "[Install]" "WantedBy=timers.target"
  # W7: no member, no user units (an empty ConditionUser= would match every user)
  if [[ -n "$me" ]]; then
    spl_laptop_root_write /etc/systemd/user/spl-laptop-box-ask.service root root "[Unit]" "Description=fleet laptop box: the end-of-hours question" \
      "ConditionUser=$me" "[Service]" "Type=oneshot" "Environment=SPOOL_ROOT=$sr" "ExecStart=$lib/laptop-box-ask.sh"
    spl_laptop_root_write /etc/systemd/user/spl-laptop-box-ask.timer root root "[Unit]" "Description=fleet laptop box: look for the question every minute" \
      "ConditionUser=$me" "[Timer]" "OnActiveSec=1min" "OnUnitActiveSec=1min" "[Install]" "WantedBy=timers.target"
  fi
  echo "systemctl daemon-reload && systemctl enable --now spl-laptop-box-tick.timer"
  [[ -z "$me" ]] || echo "systemctl --global enable spl-laptop-box-ask.timer"
}

# spl_laptop_root_write <file> <owner> <group> <line>...: a root command that
# writes the lines to the file (single-quoted, so nothing in them expands).
spl_laptop_root_write() {
  local f="$1" o="$2" g="$3" l q=""; shift 3
  for l in "$@"; do q+=" '${l//\'/\'\\\'\'}'"; done
  printf "printf '%%s\\\\n'%s >'%s' && chown '%s:%s' '%s' && chmod 0644 '%s'\n" "$q" "$f" "$o" "$g" "$f" "$f"
}

# spl_laptop_read_token: the join token from SPOOL_JOIN_TOKEN, else asked on
# the terminal without echo, so it never sits in a command line or a history.
spl_laptop_read_token() {
  local tok="${SPOOL_JOIN_TOKEN:-}"
  # W4: only from a terminal on stdin; /dev/tty stays readable under </dev/null
  if [[ -z "$tok" && -t 0 && -r /dev/tty ]]; then
    read -rsp 'Join token (from the workspace admin; not shown): ' tok </dev/tty
    echo >&2
  fi
  printf '%s' "$tok"
}

# spl_laptop_env_get <file> <KEY>: the last KEY=value of a laptop-box.env.
spl_laptop_env_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# spl_laptop_in_hours <hours> <epoch>: true when the epoch (local time) is
# inside the window: its weekday is one of the days and start <= HH:MM < end.
spl_laptop_in_hours() {
  local w days start end dow hm part a b
  w="$(spl_laptop_hours_parse "$1")" || return 2
  read -r days start end <<<"$w"
  # W5: C locale (a Bulgarian %a never reads Mon); the weekday as 1..7
  dow="$(LC_ALL=C date -d "@$2" +%u)"; hm="$(LC_ALL=C date -d "@$2" +%H:%M)"
  [[ ! "${hm/:/}" < "${start/:/}" && "${hm/:/}" < "${end/:/}" ]] || return 1
  for part in ${days//,/ }; do
    a="$(spl_laptop_day_num "${part%%..*}")"; b="$(spl_laptop_day_num "${part##*..}")"
    if (( a <= b )); then (( dow >= a && dow <= b )) && return 0
    else (( dow >= a || dow <= b )) && return 0; fi   # a wrap-around range, Fri..Mon
  done
  return 1
}

# spl_laptop_day_num <Mon..Sun>: 1..7 (date +%u).
spl_laptop_day_num() {
  case "$1" in Mon) echo 1 ;; Tue) echo 2 ;; Wed) echo 3 ;; Thu) echo 4 ;; Fri) echo 5 ;; Sat) echo 6 ;; Sun) echo 7 ;; *) echo 0 ;; esac
}
