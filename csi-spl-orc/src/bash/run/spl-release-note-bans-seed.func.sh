#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the hub's release-note bans (spec 065 L4) into their Secret
# @description Manager slot, cnf hub.release_note_bans.secret_env (030 creates
# @description it empty). The hub reads SPOOL_HUB_RELEASE_NOTE_BANS as RE2
# @description patterns, one per line, and redacts every match in a note.
# @description ONE list for the fleet: the patterns are the 10 ci
# @description distribution-hygiene Sweep's own `sweep "<label>" '<pcre>'`
# @description lines, read out of .github/workflows/10_ci-quality.yml with yq
# @description (as do_check_dist_hygiene), never a copy. PCRE lookarounds
# @description have no RE2 form and are dropped, which only widens a ban
# @description (redacts more, never less); any other non-RE2 construct is
# @description refused. The patterns are personal data: they travel via a 0600
# @description scratch file only, never argv, stdout or a log (counted and
# @description hashed, never printed). Added only when they differ from the
# @description latest version (sha256), so re-running after the Sweep changes
# @description keeps the hub in step. After a version exists: set
# @description hub.release_note_bans.inject "true" in <env>.env.yaml,
# @description re-render, plan + apply 030. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: add the version.
# @param HYGIENE_WORKFLOW (optional) - default: $APP_PATH/.github/workflows/10_ci-quality.yml
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_release_note_bans_seed
#------------------------------------------------------------------------------
do_spl_release_note_bans_seed() {
  do_require_bin yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local slot
  slot="$(yq -r '.env.hub.release_note_bans.secret_env.SPOOL_HUB_RELEASE_NOTE_BANS // ""' "$SPL_CNF")"
  [[ -n "$slot" ]] || { do_log "FATAL cnf hub.release_note_bans.secret_env.SPOOL_HUB_RELEASE_NOTE_BANS names no slot"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  (umask 077 && spl_release_note_bans_render "${HYGIENE_WORKFLOW:-$APP_PATH/.github/workflows/10_ci-quality.yml}" >"$h/bans") || return 1
  local n want
  n="$(grep -c . "$h/bans")"
  want="$(sha256sum <"$h/bans" | cut -d' ' -f1)"

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  gcloud secrets describe "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "FATAL slot $slot does not exist in $SPL_PROJECT: apply 030 first (ENV=$ENV STEP=030-cloud-run-hub)"; return 1; }
  local have
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "$have" == "$want" ]]; then
    do_log "OK $slot latest version already holds the $n Sweep pattern(s) (sha256 ${want:0:12}): nothing added"
    return 0
  fi
  if (( dry )); then
    do_log "OK DRY_RUN would add $n Sweep pattern(s) (sha256 ${want:0:12}) as a new version of $slot in $SPL_PROJECT"
    return 0
  fi
  gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --data-file="$h/bans" >/dev/null 2>&1 || { do_log "FATAL could not add a version to $slot"; return 1; }
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || { do_log "ERROR $slot latest version does not match the rendered patterns (sha256)"; return 1; }
  do_log "OK $slot: $n pattern(s) added and verified by sha256 ${want:0:12} (values not logged). Next: hub.release_note_bans.inject \"true\", render, 030 plan + apply"
}

# spl_release_note_bans_render <workflow> -> the distribution-hygiene Sweep's
# patterns as RE2, one per line, on stdout. Refuses (non-zero, nothing on
# stdout) a workflow with no Sweep patterns or a pattern RE2 cannot take.
spl_release_note_bans_render() {
  local wf="$1" body pats p out=""
  [[ -f "$wf" ]] || { do_log "FATAL no workflow at $wf"; return 1; }
  body="$(yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$wf" 2>/dev/null)"
  pats="$(sed -nE "s/^[[:space:]]*sweep[[:space:]]+\"[^\"]*\"[[:space:]]+'([^']+)'[[:space:]]*$/\1/p" <<<"$body")"
  [[ -n "$pats" ]] || { do_log "FATAL no distribution-hygiene Sweep patterns in $wf -- nothing to seed"; return 1; }
  while IFS= read -r p; do
    # lookarounds only NARROW a ban; RE2 has none, so drop them (a wider ban)
    p="$(sed -E 's/\(\?<?[!=][^()]*\)//g' <<<"$p")"
    if grep -qE '\(\?<?[!=]|\\[1-9]|[*+?}][+]|\(\?>' <<<"$p"; then
      do_log "FATAL a Sweep pattern (length ${#p}) has a construct RE2 cannot compile -- nothing seeded"
      return 1
    fi
    out+="$p"$'\n'
  done <<<"$pats"
  printf '%s' "$out"
}
