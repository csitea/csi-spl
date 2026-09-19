#!/bin/bash
#------------------------------------------------------------------------------
# @description Mint the hub's box-wui Ed25519 key into its Secret Manager slot
# @description (spec 014 T022, contracts/wui-dispatch.md section 2.1). The
# @description slot is terraform (030, cnf hub.wui_key.secret_env); the
# @description VERSION is never tf. Minted ONLY when the slot has no version:
# @description a new key invalidates every tenant's box-wui pin, so rotation
# @description (section 2.3) is a separate, deliberate step, never this one.
# @description `spool keygen --box box-wui` (crypto/rand) writes the base64
# @description private key into a 0700 scratch dir; gcloud reads it from that
# @description file (never argv, stdout or a log); the file is shredded; the
# @description stored version is verified by sha256. Prints the PUBLIC key.
# @description After a version exists: set hub.wui_key.inject "true" in
# @description <env>.env.yaml, re-render, plan + apply 030.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: mint + add the version.
# @param SPOOL_BIN (optional) - spool CLI; otherwise built from csi-spl-api
# @example ENV=dev GCP_ACCOUNT=<project-sa-email> DRY_RUN=0 ./run -a do_spl_wui_key_seed
#------------------------------------------------------------------------------
do_spl_wui_key_seed() {
  do_require_bin yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local slot
  slot="$(yq -r '.env.hub.wui_key.secret_env.SPOOL_HUB_WUI_KEY // ""' "$SPL_CNF")"
  [[ -n "$slot" ]] || { do_log "FATAL cnf hub.wui_key.secret_env.SPOOL_HUB_WUI_KEY names no slot"; return 1; }
  gcloud secrets describe "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "FATAL slot $slot does not exist in $SPL_PROJECT: apply 030 first (ENV=$ENV STEP=030-cloud-run-hub)"; return 1; }

  local n
  n="$(gcloud secrets versions list "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --filter='state=ENABLED' --format='value(name)' 2>/dev/null | wc -l)"
  if (( n > 0 )); then
    do_log "OK $slot already has $n enabled version(s): kept (never rotated here; the pubkey is GET /v1/wui/pubkey once 030 injects it)"
    return 0
  fi
  if (( dry )); then
    do_log "OK DRY_RUN would mint a box-wui Ed25519 key and add it as the first version of $slot in $SPL_PROJECT"
    return 0
  fi

  local cli="${SPOOL_BIN:-}"
  if [[ -z "$cli" || ! -x "$cli" ]]; then
    spl_host_spool || return 1
    cli="$SPL_SPOOL"
  fi

  local tmp pub want got rc=0
  tmp="$(mktemp -d)" && chmod 700 "$tmp" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$tmp'/*.key 2>/dev/null; rm -rf '$tmp'; trap - RETURN" RETURN
  pub="$(SPOOL_KEYS_DIR="$tmp" "$cli" keygen --box box-wui)" || { do_log "FATAL spool keygen failed"; return 1; }
  [[ -s "$tmp/box-box-wui.key" && "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { do_log "FATAL keygen left no key file or no pubkey"; return 1; }
  want="$(sha256sum <"$tmp/box-box-wui.key" | cut -d' ' -f1)"
  gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --data-file="$tmp/box-box-wui.key" >/dev/null 2>&1 || { do_log "FATAL could not add a version to $slot"; return 1; }
  got="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || { do_log "ERROR $slot latest version does not match the minted key (sha256)"; rc=1; }
  printf '{"env":"%s","secret":"%s","box_id":"box-wui","pubkey":"%s"}\n' "$ENV" "$slot" "$pub"
  (( rc == 0 )) || return 1
  do_log "OK $slot: first version added and verified by sha256 (private key not logged, scratch copy shredded). Next: hub.wui_key.inject \"true\", render, 030 plan + apply, then pin box-wui per tenant"
}
