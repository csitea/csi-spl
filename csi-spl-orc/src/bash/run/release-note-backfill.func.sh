#!/bin/bash
#------------------------------------------------------------------------------
# @description Backfill the release notes table back to the repo's very first
# @description commit (owner, t1 ee8cd6f2: "loading of older version up till
# @description the first entry"). Every deploy re-sends only its newest 500
# @description commits (do_release_note_ingest), so commits older than the
# @description first 500-commit window never reached the hub. This runs THE
# @description SAME ingest, with the window set to every first-parent commit
# @description of RELEASE_SHA: one row per commit, its version the first
# @description v-tag that shipped it, idempotent (the hub upserts by sha and
# @description keeps a row's first version). Safe to re-run.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): print the request bodies, call nothing; 0: POST them
# @param RELEASE_SHA (optional) - the newest commit to send, default HEAD
# @param RELEASE_NOTE_BATCH (optional) - rows per request, default 100 (hub max 500)
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev DRY_RUN=0 ./run -a do_release_note_backfill
# @example ENV=prd DRY_RUN=0 RELEASE_SHA=origin/master ./run -a do_release_note_backfill
#------------------------------------------------------------------------------
do_release_note_backfill() {
  do_require_bin git || return 1
  local tip="${RELEASE_SHA:-HEAD}" depth first
  depth="$(git -C "$APP_PATH" rev-list --first-parent --count "$tip" 2>/dev/null)" ||
    { do_log "FATAL RELEASE_SHA is not a commit in $APP_PATH: '$tip'"; return 1; }
  ((depth >= 1 && depth <= 99999)) || { do_log "FATAL $depth first-parent commits: the ingest takes 1..99999"; return 1; }
  first="$(git -C "$APP_PATH" rev-list --first-parent --max-parents=0 "$tip" | tail -1)"
  do_log "INFO backfill: all $depth first-parent commit(s) of ${tip}, back to ${first:0:8} ($(git -C "$APP_PATH" log -1 --format=%cI "$first"))" >&2
  RELEASE_NOTE_DEPTH="$depth" do_release_note_ingest
}
