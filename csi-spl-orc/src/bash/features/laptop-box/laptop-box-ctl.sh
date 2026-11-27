#!/usr/bin/env bash
#------------------------------------------------------------------------------
# laptop-box-ctl.sh - the member's own controls of her laptop box (SPL-6680,
# spec 037 "Laptop box"). do_spl_laptop_box_install copies it, root-owned, to
# /usr/local/bin/spl-laptop-box, so each control is one short line and runs
# a copy the agents' user cannot change:
#   spl-laptop-box status     her hours, the state, the agents running here
#   spl-laptop-box stop       stop for today: running agents move to the
#                             fleet's home box within 5 min; tomorrow as usual
#   spl-laptop-box off        stop until she runs start (agents move too)
#   spl-laptop-box start      undo stop / off: agents run again in her hours
#   spl-laptop-box continue   past her hours: keep the agents 1 more hour
#   sudo spl-laptop-box github-token   paste the fleet's GitHub push token
#                             once (not shown): the agents push with it
#                             through gh (owner Q6 = MIN: no other secret)
#   sudo spl-laptop-box remove   take it all off the laptop (refused while
#                             agents still run here: stop first)
# The controls only write marker files in the state dir; the tick
# (do_spl_laptop_box_tick, every 5 min) acts on them.
# State dir: $LAPTOP_STATE_DIR, default <spool root>/dispatch/laptop-box:
#   off, stopped (a date), move-now, continue-until (epoch), asked-at,
#   ask-pending (the question text), answer, lanes (written by the tick).
# Env (tests): SPOOL_ROOT, LAPTOP_STATE_DIR, LAPTOP_NOW (epoch),
#   LAPTOP_ROOT_SH (the root runner of remove, default bash -c),
#   LAPTOP_EUID (default $EUID), LAPTOP_RUNUSER (default runuser),
#   LAPTOP_ENV_FILE (default /etc/spl-laptop-box/laptop-box.env, root's),
#   LAPTOP_ID (default id).
# Exit: 0 ok, 2 usage, 3 refused (remove while agents run, or not root).
#------------------------------------------------------------------------------
set -uo pipefail
SR="${SPOOL_ROOT:-/var/spool-hub}"
D="${LAPTOP_STATE_DIR:-$SR/dispatch/laptop-box}"
ENVF="${LAPTOP_ENV_FILE:-/etc/spl-laptop-box/laptop-box.env}"
NOW="${LAPTOP_NOW:-$(date +%s)}"

put() { printf '%s\n' "$2" >"$D/$1.tmp" && mv -f "$D/$1.tmp" "$D/$1"; }
envget() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -n 1; }
lanes() { [[ -s "$D/lanes" ]] && grep -c . "$D/lanes" || echo 0; }

status() {
  local st="in use"
  [[ -e "$D/off" ]] && st="off (run: spl-laptop-box start)"
  [[ "$(cat "$D/stopped" 2>/dev/null)" == "$(date -d "@$NOW" +%F)" ]] && st="stopped for today"
  echo "hours:  $(envget LAPTOP_HOURS)"
  echo "state:  $st"
  echo "agents: $(lanes) running here (as of the last check)"
  [[ -s "$D/ask-pending" ]] && echo "asked:  her hours are over; answer the pop-up, or run spl-laptop-box continue / stop"
  return 0
}

remove() {
  [[ "${LAPTOP_EUID:-$EUID}" == 0 ]] || { echo "refused: remove needs root: sudo spl-laptop-box remove" >&2; return 3; }
  [[ "$(lanes)" == 0 ]] || { echo "refused: $(lanes) agent(s) still run here; run: spl-laptop-box stop, wait 5 min for them to move, then remove" >&2; return 3; }
  local u; u="$(envget LAPTOP_AGENT_USER)"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "refused: no agents' user in $ENVF" >&2; return 3; }
  # W3: never her own user, root or a system user, whatever the file says
  local uid; uid="$(${LAPTOP_ID:-id} -u "$u" 2>/dev/null)"
  if [[ "$u" == "$(envget LAPTOP_MEMBER)" || "$u" == "${SUDO_USER:-}" || ! "$uid" =~ ^[0-9]+$ ]] || (( uid < 1000 )); then
    echo "refused: '$u' is not a separate agents' user (her own, root or a system user)" >&2; return 3
  fi
  # W3 (R7 a-736): its crontabs out and the account expired (cron runs no job
  # for it) BEFORE its processes are killed, so the 1-min spawn receiver
  # cannot start one between pkill and userdel; userdel retried, then checked
  local c
  for c in \
    "systemctl disable --now spl-laptop-box-tick.timer spl-laptop-box-login.timer 2>/dev/null; systemctl --global disable spl-laptop-box-ask.timer 2>/dev/null; true" \
    "rm -f /etc/systemd/system/spl-laptop-box-tick.service /etc/systemd/system/spl-laptop-box-tick.timer /etc/systemd/system/spl-laptop-box-login.service /etc/systemd/system/spl-laptop-box-login.timer /etc/systemd/user/spl-laptop-box-ask.service /etc/systemd/user/spl-laptop-box-ask.timer" \
    "systemctl daemon-reload" \
    "crontab -r -u '$u' 2>/dev/null; rm -f '/var/spool/cron/crontabs/$u'; usermod --expiredate 1 '$u' 2>/dev/null; true" \
    "pkill -KILL -u '$u' || true" \
    "for i in 1 2 3; do userdel -r '$u' 2>/dev/null; id -u '$u' >/dev/null 2>&1 || exit 0; pkill -KILL -u '$u'; sleep 1; done; exit 1" \
    "rm -rf '$SR' /usr/local/lib/spl-laptop-box /usr/local/bin/spl-laptop-box '${ENVF%/*}'"; do
    ${LAPTOP_ROOT_SH:-bash -c} "$c" || { echo "remove: failed: $c" >&2; return 1; }
  done
  echo "OK removed from this laptop. A workspace admin revokes its seat in the web UI (Monitoring -> Boxes)."
}

# github-token: the token from stdin (a terminal: asked without echo) into the
# agents' user's gh login, then gh as its git credential helper; the token
# rides stdin only, never an argv, a file of ours or a log (SPL-3761: no
# clear-text git credential store).
github_token() {
  [[ "${LAPTOP_EUID:-$EUID}" == 0 ]] || { echo "refused: needs root: sudo spl-laptop-box github-token" >&2; return 3; }
  local u tok; u="$(envget LAPTOP_AGENT_USER)"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "refused: no agents' user in $ENVF" >&2; return 3; }
  if [[ -t 0 ]]; then read -rsp 'GitHub push token (not shown): ' tok; echo >&2; else read -r tok; fi
  [[ "$tok" =~ ^[A-Za-z0-9_]{20,255}$ ]] || { echo "refused: that is not a GitHub token" >&2; return 2; }
  # N2 (R7 a-736): no caller token or config dir crosses into its gh
  local -a ge=(env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_CONFIG_DIR -u XDG_CONFIG_HOME)
  umask 077
  printf '%s\n' "$tok" | ${LAPTOP_RUNUSER:-runuser} -u "$u" -- "${ge[@]}" gh auth login --hostname github.com --git-protocol https --with-token ||
    { echo "github-token: gh did not take the token" >&2; return 1; }
  ${LAPTOP_RUNUSER:-runuser} -u "$u" -- "${ge[@]}" gh auth setup-git --hostname github.com || return 1
  echo "OK the agents push to GitHub with that token"
}

case "${1:-status}" in
  status) status ;;
  start) rm -f "$D/off" "$D/stopped" "$D/move-now"; echo "OK started: agents run again in your hours (next check within 5 min)" ;;
  stop) put stopped "$(date -d "@$NOW" +%F)" && put move-now "$NOW" && echo "OK stopped for today: running agents move to the fleet within 5 min" ;;
  off) put off "$NOW" && put move-now "$NOW" && echo "OK off until you run: spl-laptop-box start" ;;
  continue) put continue-until "$((NOW + 3600))" && rm -f "$D/asked-at" "$D/ask-pending" "$D/answer" "$D/ask-wui" && echo "OK the agents keep running for 1 more hour" ;;
  remove) remove ;;
  github-token) github_token ;;
  *) echo "usage: spl-laptop-box status|start|stop|off|continue|github-token|remove" >&2; exit 2 ;;
esac
