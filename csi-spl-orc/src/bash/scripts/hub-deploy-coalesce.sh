#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: fewer hub rollouts (SPL-5641, spec 175 task 5.10). Every hub
#          revision drops every box's socket; prd went from revision 01683 to
#          01722 in about 34 h (about 39 rollouts), and one of them cost a
#          lane-map timeout. Workflow 20's deploy job is serialised per env
#          (concurrency group) and a newer pending run replaces an older
#          pending one, so a run that HOLDS before it rolls lets the pushes of
#          a burst coalesce into the one run that rolls next.
#
#          The rule: a push-guarded deploy rolls an env at most once per
#          HUB_DEPLOY_COALESCE_MIN minutes, counted from that env's newest
#          revision. A run that arrives sooner waits out the rest of the
#          window, then rolls. An operator dispatch naming one env never waits.
#
# Usage:
#   hub-deploy-coalesce.sh hold <last-epoch> [<now-epoch>]
#       -> the seconds to wait before rolling (0 = roll now); exit 2 bad input
#   hub-deploy-coalesce.sh per-day
#       -> stdin: one revision creation time a line (ISO 8601, as gcloud
#          prints metadata.creationTimestamp); stdout "<YYYY-MM-DD> <count>",
#          oldest day first: the proof count, revisions per day
# Env:
#   HUB_DEPLOY_COALESCE_MIN - optional, the window in minutes (default 15;
#                             0 turns the hold off)
#------------------------------------------------------------------------------
set -uo pipefail

coalesce_hold() {
  local last="${1:-}" now="${2:-$(date -u +%s)}" min="${HUB_DEPLOY_COALESCE_MIN:-15}" left
  [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] \
    || { echo "::error::hold needs <last-epoch> [<now-epoch>] and a numeric HUB_DEPLOY_COALESCE_MIN" >&2; return 2; }
  left=$((last + min * 60 - now))
  ((left > 0)) || left=0
  # a revision stamped in the future (clock skew) never holds longer than one window
  ((left <= min * 60)) || left=$((min * 60))
  echo "$left"
}

coalesce_per_day() {
  local ts days=""
  while IFS= read -r ts; do
    [[ -n "$ts" ]] || continue
    days+="$(date -u -d "$ts" +%F 2>/dev/null)"$'\n' || { echo "::error::not a timestamp: $ts" >&2; return 2; }
  done
  [[ -n "$days" ]] || return 0
  printf '%s' "$days" | sort | uniq -c | awk '{ print $2, $1 }'
}

case "${1:-}" in
  hold) shift; coalesce_hold "$@" ;;
  per-day) coalesce_per_day ;;
  *) echo "usage: $0 hold <last-epoch> [<now-epoch>] | per-day" >&2; exit 2 ;;
esac
