#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: fewer hub rollouts (SPL-5641, spec 175 task 5.10). Every hub
#          revision drops every box's socket. The owner's pick (HUM-10, poll
#          9f948a6a, msg 3197121d): count the rollouts AND hold them 2 hours
#          (replayed on 200 prd revisions: 26 % fewer, a fix up to 2 h late).
#
#          The rule: a push-guarded deploy of workflow 20 (push, or a dispatch
#          of "all") rolls an env at most once per HUB_DEPLOY_COALESCE_MIN
#          minutes, counted from the build time the env's hub SERVES
#          (GET /version .built_at). A run inside the window does not sleep: it
#          STANDS DOWN, and workflow 21's catch-up, which also waits out the
#          window, dispatches trunk head once it has passed, so every push of
#          the window lands in that one roll. An operator dispatch naming one
#          env is never held (a hot fix, a rollback).
#
# Usage:
#   hub-deploy-coalesce.sh hold <last-epoch> [<now-epoch>]
#       -> the seconds to wait before rolling (0 = roll now); exit 2 bad input
#   hub-deploy-coalesce.sh hold-version [<now-epoch>]
#       -> stdin: a hub GET /version body; the seconds to wait, read from its
#          .built_at. No body, no .built_at or a junk one -> 0 (roll: a hold
#          never strands a deploy on a field it cannot read) and a note on
#          stderr
#   hub-deploy-coalesce.sh per-day
#       -> stdin: one revision creation time a line (ISO 8601, as gcloud
#          prints metadata.creationTimestamp); stdout "<YYYY-MM-DD> <count>",
#          oldest day first: the proof count, revisions per day
# Env:
#   HUB_DEPLOY_COALESCE_MIN - optional, the window in minutes (default 120,
#                             the owner's 2 h; 0 turns the hold off)
#------------------------------------------------------------------------------
set -uo pipefail

coalesce_hold() {
  local last="${1:-}" now="${2:-$(date -u +%s)}" min="${HUB_DEPLOY_COALESCE_MIN:-120}" left
  [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] \
    || { echo "::error::hold needs <last-epoch> [<now-epoch>] and a numeric HUB_DEPLOY_COALESCE_MIN" >&2; return 2; }
  left=$((last + min * 60 - now))
  ((left > 0)) || left=0
  # a revision stamped in the future (clock skew) never holds longer than one window
  ((left <= min * 60)) || left=$((min * 60))
  echo "$left"
}

coalesce_hold_version() {
  local body built last
  body="$(cat)"
  built="$(jq -r 'if type == "object" and (.built_at | type) == "string" then .built_at else "" end' <<<"$body" 2>/dev/null)" || built=""
  if [[ -z "$built" ]] || ! last="$(date -u -d "$built" +%s 2>/dev/null)"; then
    echo "hold-version: no readable .built_at in the /version body -- not holding" >&2
    echo 0; return 0
  fi
  coalesce_hold "$last" "$@"
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
  hold-version) shift; coalesce_hold_version "$@" ;;
  per-day) coalesce_per_day ;;
  *) echo "usage: $0 hold <last-epoch> [<now-epoch>] | hold-version [<now-epoch>] | per-day" >&2; exit 2 ;;
esac
