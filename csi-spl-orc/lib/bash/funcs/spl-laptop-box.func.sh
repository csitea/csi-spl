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
#   <env> <tenant> <hours> <max>: the commands the install runs as root, one per
# line. The member's own account is never touched: the agents get their own
# OS user, with no sudo and a locked password. No secret is in any line.
spl_laptop_install_root_cmds() {
  local u="$1" co="$2" sr="$3" g="$4" tag="$5" env="$6" ten="$7" hours="$8" max="$9"
  echo "DEBIAN_FRONTEND=noninteractive apt-get install -y git tmux curl tar python3 perl util-linux jq ca-certificates libnotify-bin"
  echo "getent group '$g' >/dev/null || groupadd '$g'"
  echo "id -u '$u' >/dev/null 2>&1 || { useradd -m -s /bin/bash '$u' && passwd -l '$u' >/dev/null; }"
  echo "usermod -aG '$g' '$u'"
  echo "chown -R '$u:$u' '$co'"
  echo "install -d -o '$u' -g '$g' -m 2770 '$sr' '$sr/dispatch'"
  printf "printf '%%s\\\\n' %s >'%s' && chown '%s:%s' '%s' && chmod 0660 '%s'\n" \
    "'SPOOL_AGENT_USER=$u' 'SPOOL_DESK_USER=$u' 'SPOOL_DESK_BOX=$tag' 'SPOOL_BOX_TAG=$tag' 'SPOOL_FLEET_ENV=$env' 'SPOOL_FLEET_TENANT=$ten' 'SPOOL_DIR_LAYOUT=qualified'" \
    "$sr/box.env" "$u" "$g" "$sr/box.env" "$sr/box.env"
  printf "printf '%%s\\\\n' %s >'%s' && chown '%s:%s' '%s' && chmod 0660 '%s'\n" \
    "'LAPTOP_HOURS=$hours' 'LAPTOP_AGENT_MAX=$max' 'LAPTOP_BOX_TAG=$tag' 'LAPTOP_AGENT_USER=$u'" \
    "$sr/dispatch/laptop-box.env" "$u" "$g" "$sr/dispatch/laptop-box.env" "$sr/dispatch/laptop-box.env"
}

# spl_laptop_read_token: the join token from SPOOL_JOIN_TOKEN, else asked on
# the terminal without echo, so it never sits in a command line or a history.
spl_laptop_read_token() {
  local tok="${SPOOL_JOIN_TOKEN:-}"
  if [[ -z "$tok" && -r /dev/tty ]]; then
    read -rsp 'Join token (from the workspace admin; not shown): ' tok </dev/tty
    echo >&2
  fi
  printf '%s' "$tok"
}
