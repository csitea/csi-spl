#!/bin/bash
#------------------------------------------------------------------------------
# @description The release notes lag alarm (SPL-4988, spec 065 L15): wf 26 keeps
# @description a failed ingest green on purpose, so a lasting break (a lost SA
# @description permission, a changed route) would let Reporting -> Releases fall
# @description behind with every run green. This reads the OUTCOME, not the run:
# @description per env, are there master commits older than the limit with no
# @description release_notes row? It posts in #alerts on the EDGE only: one post
# @description when an env starts lagging, one "recovered", same -> same silent.
# @description A read that fails is no verdict and never flaps the channel; one
# @description lasting past the limit posts once, because a blind alarm is the
# @description same silence again.
# @description THE LIMIT, 120 min, is counted from the committer date, which a
# @description rebase stamps BEFORE the land, so it covers the land gap and not
# @description only the ingest. Measured 2026-11-07, tree 48dc6c573: committer
# @description date to push, wf 10 push runs on master, n=300: median 3.6, p90
# @description 26.6, p99 72.9, max 93.3 min; push to row, wf 26, n=13: about
# @description 1 min. 120 covers 93.3 + 1 with room, so the normal lag cannot
# @description fire it. A land later than the limit fires only if a tick hits the
# @description minute before its row, and the next tick posts the recovery.
# @description Runs on the dispatch lease holder's box only (one post per
# @description episode); a dry run reads and prints from any box, and touches no
# @description desk (spl_lane_init is for the post).
# @param RELEASE_LAG_LIMIT_MIN (optional) - minutes, default 120 (why: above)
# @param RELEASE_LAG_DEPTH (optional) - master commits to read, default 500 (the ingest's window: an older commit no ingest would re-send)
# @param RELEASE_LAG_ENVS (optional) - default "prd dev"
# @param RELEASE_LAG_REPO (optional) - the checkout to fetch and read, default APP_PATH
# @param RELEASE_LAG_STATE (optional) - the edge state, default $XDG_STATE_HOME/csi-spl/release-notes-lag.state
# @param RELEASE_LAG_ROWS_CMD (optional, tests) - args ENV FILE-OF-SHAS, prints the shas that have a row; default do_spl_db_query
# @param RELEASE_LAG_POST_CMD (optional, tests) - replaces the #alerts post: the text on stdin, exit 0 = posted
# @param DRY_RUN (optional) - 1 (default): print what it would post, write no state; 0: post
# @example ./run -a do_spl_release_notes_lag_alarm
# @example DRY_RUN=0 RELEASE_LAG_ENVS=prd ./run -a do_spl_release_notes_lag_alarm
#------------------------------------------------------------------------------
do_spl_release_notes_lag_alarm() {
  local dry="${DRY_RUN:-1}" lim="${RELEASE_LAG_LIMIT_MIN:-120}" depth="${RELEASE_LAG_DEPTH:-500}"
  local envs="${RELEASE_LAG_ENVS:-prd dev}" repo="${RELEASE_LAG_REPO:-$APP_PATH}"
  local st="${RELEASE_LAG_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/release-notes-lag.state}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$lim" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL RELEASE_LAG_LIMIT_MIN must be whole minutes, got: '$lim'"; return 1; }
  [[ "$depth" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL RELEASE_LAG_DEPTH must be 1..99999, got: '$depth'"; return 1; }
  if [[ "$dry" == 0 ]]; then
    spl_lane_init || return 1
    # Another box holds the lease: this box's verdict goes stale from here on
    # (read back later it silences a new outage, or posts a stale recovery), so
    # drop it. No holder at all is a gap in the lease: the state stays.
    local hrc=0
    spl_release_lag_holder_here || hrc=$?
    if ((hrc)); then
      ((hrc != 2)) || rm -f "$st"
      return 0
    fi
  fi
  mkdir -p "$(dirname "$st")" || { do_log "FATAL cannot create the dir of $st"; return 1; }
  [[ -f "$st" ]] || : >"$st"

  local d rc=0 readable=1 e
  d="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  spl_release_lag_old_commits "$repo" "$depth" "$lim" >"$d/old" || { readable=0; do_log "WARN cannot read origin/master in $repo"; }
  for e in $envs; do
    if ((readable)) && spl_release_lag_have "$e" "$d/old" >"$d/have"; then
      grep -vxFf "$d/have" "$d/old" >"$d/missing" || true
      if [[ -s "$d/missing" ]]; then
        spl_release_lag_edge "$e" lag "$d/missing" || rc=1
      else
        spl_release_lag_edge "$e" ok "" || rc=1
      fi
    else
      do_log "WARN $e: no verdict, the commits or the rows could not be read"
      spl_release_lag_edge "$e" unknown "" || true
      rc=1
    fi
  done
  return "$rc"
}

# Only the box of the dispatch lease holder posts. Silent success = this box;
# 1 = no holder; 2 = the holder is on another box.
spl_release_lag_holder_here() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" holder box hbox
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  [[ -n "$holder" ]] || { do_log "OK release notes lag: no dispatch lease holder, nothing this tick"; return 1; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  [[ "$hbox" == "$box" ]] || { do_log "OK release notes lag: the dispatch holder $holder is not on this box ($box)"; return 2; }
}

# spl_release_lag_old_commits REPO DEPTH LIMIT_MIN -> the first-parent master
# commits whose committer date is older than the limit, newest first.
spl_release_lag_old_commits() {
  local cut=$(( $(date +%s) - $3 * 60 )) out
  git -C "$1" fetch -q origin master 2>/dev/null || return 1
  out="$(git -C "$1" log --first-parent -n "$2" --format='%H %ct' origin/master)" || return 1
  awk -v c="$cut" '$2 <= c {print $1}' <<<"$out"
}

# spl_release_lag_have ENV FILE -> the shas of FILE that have a row in ENV. An
# empty FILE asks nothing. Exit non-zero = the rows could not be read.
spl_release_lag_have() {
  [[ -s "$2" ]] || return 0
  local out
  if [[ -n "${RELEASE_LAG_ROWS_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($RELEASE_LAG_ROWS_CMD "$1" "$2")" || return 1
  else
    out="$(ENV="$1" SQL="select sha from release_notes where sha in ($(sed "s/.*/'&'/" "$2" | paste -sd,))" do_spl_db_query 2>/dev/null)" || return 1
  fi
  grep -oE '\b[0-9a-f]{40}\b' <<<"$out" || true
}

# spl_release_lag_state_get KEY / _set KEY VALUE: the edge state file ($st).
spl_release_lag_state_get() { sed -n "s|^$1=||p" "$st" | tail -1; }
spl_release_lag_state_set() {
  { grep -v "^$1=" "$st" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } >"$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"
}

# spl_release_lag_edge ENV ok|lag|unknown MISSING_FILE: post on a change of the
# verdict; the state moves only after the post went out, so a failed post is
# retried next tick. Keys: <env> ok|lag|blind, <env>.since the first failed read.
spl_release_lag_edge() {
  local e="$1" v="$2" prev since now text next
  prev="$(spl_release_lag_state_get "$e")"; prev="${prev:-ok}"
  now="$(date +%s)"
  if [[ "$v" == unknown ]]; then
    [[ "$prev" != blind ]] || return 0
    since="$(spl_release_lag_state_get "$e.since")"
    if [[ -z "$since" ]]; then
      [[ "$dry" == 1 ]] || spl_release_lag_state_set "$e.since" "$now"
      since="$now"
    fi
    (( now - since >= lim * 60 )) || return 0
    next=blind
    text="**RELEASE NOTES LAG** $e: this alarm cannot read master or the release_notes rows, so a lag would go unseen (failing for over $lim min, on ${LANE_BOX:-this box})."
  else
    [[ "$dry" == 1 || -z "$(spl_release_lag_state_get "$e.since")" ]] || spl_release_lag_state_set "$e.since" ""
    if [[ "$v" == "$prev" ]]; then return 0; fi
    next="$v"
    if [[ "$v" == lag ]]; then
      text="**RELEASE NOTES LAG** $e: master commits older than the limit have no release note row, so Reporting -> Releases is behind (limit $lim min, $(grep -c . "$3") commit(s), newest $(sed -n 1p "$3" | cut -c1-8), oldest $(tail -1 "$3" | cut -c1-8)). wf 26 stays green on a failed ingest: read its ingest step, then re-send with gh workflow run 26_release-notes-ingest.yml --ref master."
    else
      text="**RELEASE NOTES LAG** $e recovered: of the newest $depth master commits, every one older than the limit has its release note row, and this alarm reads them again."
    fi
  fi
  if [[ "$dry" == 1 ]]; then echo "PLAN post in #alerts: $text"; return 0; fi
  WEEKLY_ALERT_CMD="${RELEASE_LAG_POST_CMD:-}" spl_weekly_alert_post "$text" ||
    { do_log "WARN $e: the #alerts post failed, the state stays, retried next tick"; return 1; }
  do_log "ALERT posted in #alerts: $text"
  spl_release_lag_state_set "$e" "$next"
}
