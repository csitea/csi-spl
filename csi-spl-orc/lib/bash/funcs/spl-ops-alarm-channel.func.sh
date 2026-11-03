#!/bin/bash
#------------------------------------------------------------------------------
# spl_ops_alarm_channel: print the channel the CI ops desk's automatic alarms
# post into (the deploy lag alarm, a failed 20/30 deploy run, the weekly scan's
# missed week). SPL-4700 (owner HUM-10, t1 3a18a0b5 msg 6a43f1a2): they go to
# #alerts, not #spool-hub-ops. An explicit DESK_CHANNEL wins; else cnf
# env.ops_alarms.channel of all.env.yaml (OPS_ALARM_CNF replaces the file,
# tests). No literal default: an unset or bad key is one FATAL, rc 1, and the
# alarm is not sent.
#------------------------------------------------------------------------------
spl_ops_alarm_channel() {
  local chan="${DESK_CHANNEL:-}" here cnf
  if [[ -z "$chan" ]]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cnf="${OPS_ALARM_CNF:-$here/../../../../csi-spl-cnf/csi-spl/all.env.yaml}"
    [[ -r "$cnf" ]] || { echo "FATAL no cnf $cnf: the ops alarm channel is unknown, the alarm is not sent" >&2; return 1; }
    command -v yq >/dev/null 2>&1 || { echo "FATAL yq is missing: cannot read env.ops_alarms.channel from $cnf" >&2; return 1; }
    chan="$(yq -r '.env.ops_alarms.channel // ""' "$cnf")"
  fi
  chan="${chan#\#}"
  [[ "$chan" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
    { echo "FATAL env.ops_alarms.channel is not set (or DESK_CHANNEL is bad: '$chan'): the alarm is not sent" >&2; return 1; }
  printf '%s\n' "$chan"
}
