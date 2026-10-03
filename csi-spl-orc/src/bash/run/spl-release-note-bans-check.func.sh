#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove the LIVE hub redacts the release-note bans (spec 065 L4):
# @description after hub.release_note_bans is seeded and injected (030 apply),
# @description for every ban line in the slot's latest version that has a
# @description plain literal alternative (a name, a box id, an org), POST a
# @description probe note to /v1/operator/release-notes carrying that literal
# @description and read the hub's own `redacted` count, which counts a row the
# @description filter rewrote to "[redacted]". The probe's sha is not a commit
# @description sha, so the hub REJECTS the row after filtering it: nothing is
# @description stored, no member ever sees a probe. A control probe with no
# @description banned text must come back redacted 0 (a hub that redacts
# @description everything proves nothing). The literals are personal data:
# @description read into a 0600 file, sent as a curl body file (never argv),
# @description and never printed; the report counts them. A hub without the
# @description env injected redacts none of them, so this fails before the
# @description apply and passes after it. Authenticated as the env's project
# @description service account (operator id token), never the owner account.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev ./run -a do_spl_release_note_bans_check
#------------------------------------------------------------------------------
do_spl_release_note_bans_check() {
  do_require_bin yq jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local slot
  slot="$(yq -r '.env.hub.release_note_bans.secret_env.SPOOL_HUB_RELEASE_NOTE_BANS // ""' "$SPL_CNF")"
  [[ -n "$slot" ]] || { do_log "FATAL cnf hub.release_note_bans.secret_env.SPOOL_HUB_RELEASE_NOTE_BANS names no slot"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  (umask 077 && gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >"$h/bans" 2>/dev/null) ||
    { do_log "FATAL $slot has no readable version in $SPL_PROJECT: run do_spl_release_note_bans_seed first"; return 1; }
  (umask 077 && spl_release_note_bans_probe_words <"$h/bans" >"$h/words")
  local nbans nwords
  nbans="$(grep -c . "$h/bans")"
  nwords="$(grep -c . "$h/words")"
  (( nwords > 0 )) || { do_log "FATAL none of the $nbans ban line(s) in $slot has a plain literal to probe with"; return 1; }

  # control: no banned text, must not be redacted
  local ctl
  ctl="$(spl_release_note_bans_probe "$h" "release note bans check control")" || return 1
  [[ "$ctl" == 0 ]] || { do_log "FATAL the control probe (no banned text) came back redacted=$ctl: this check proves nothing on $SPL_HUB_URL"; return 1; }

  local w got hit=0 miss=0
  while IFS= read -r w; do
    got="$(spl_release_note_bans_probe "$h" "release note bans check $w")" || return 1
    if [[ "$got" == 1 ]]; then hit=$((hit + 1)); else miss=$((miss + 1)); fi
  done <"$h/words"
  printf '{"env":"%s","hub":"%s","ban_lines":%d,"probed":%d,"redacted":%d,"missed":%d,"control_redacted":0}\n' \
    "$ENV" "$SPL_HUB_URL" "$nbans" "$nwords" "$hit" "$miss"
  if (( miss > 0 )); then
    do_log "FAIL $miss of $nwords banned probe(s) came back unredacted from $SPL_HUB_URL: is hub.release_note_bans.inject \"true\" and 030 applied?"
    return 1
  fi
  do_log "OK $SPL_HUB_URL redacts all $nwords probed ban(s) to [redacted]; nothing stored (probe rows rejected)"
}

# spl_release_note_bans_probe <dir> <subject> -> the hub's `redacted` count for
# one probe row on stdout. The body goes to curl as a file (@<path>), so the
# subject never rides argv.
spl_release_note_bans_probe() {
  local d="$1" subject="$2" r
  (umask 077 && jq -cn --arg s "$subject" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{notes: [{sha: "release-note-bans-probe", committed_at: $t, subject: $s, state: "ok"}]}' >"$d/body.json") || return 1
  spl_hub_operator_call POST /v1/operator/release-notes "@$d/body.json" || return 1
  shred -u "$d/body.json" 2>/dev/null
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL POST /v1/operator/release-notes answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '.error // .code // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"; return 1; }
  r="$(jq -r 'if (.stored == 0 and (.rejected | length) == 1) then .redacted else "stored" end' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
  [[ "$r" =~ ^[0-9]+$ ]] || { do_log "FATAL the hub stored a probe row or answered no redacted count"; return 1; }
  echo "$r"
}

# spl_release_note_bans_probe_words: RE2 ban lines on stdin -> per line, the
# first alternative that is a plain literal once (?i), \b and \. are read.
spl_release_note_bans_probe_words() {
  local p a
  local -a alts
  while IFS= read -r p; do
    p="${p#"(?i)"}"
    IFS='|' read -ra alts <<<"$p"
    for a in "${alts[@]}"; do
      a="${a//\\b/}"; a="${a//\\./.}"
      [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && { echo "$a"; break; }
    done
  done
}
