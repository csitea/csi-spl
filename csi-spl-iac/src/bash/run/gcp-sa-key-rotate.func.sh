#!/bin/bash
#------------------------------------------------------------------------------
# @description One rotation of the per-env project SA key (SPL-2735, build
# @description order row 1 of SPL-1945; the runbook: secret-rotation.md
# @description section 5), step by step, refusing a step out of order like
# @description do_spl_secret_rotate:
# @description   status  (default) the SA's user-managed keys (id, age), the
# @description           key the key file holds, and the next step
# @description   mint    a new key, written ONLY to the per-env key file
# @description           ($HOME/.gcp/.<org>/key-<project>.json, mode 600); the
# @description           old file is kept beside it as <file>.prev until retire.
# @description           Refused while the SA has a second user key.
# @description   prove   the key file mints a token and reads the project, in
# @description           a throwaway gcloud config; prints and records a proof id
# @description   retire  deletes OLD_KEY_ID, only with this box's recorded
# @description           proof, a proof id from the other box for the same new
# @description           key and a CI run id (it cannot check the other box or
# @description           CI itself: the caller passes them)
# @description The key is never printed. Runs as the env's project SA
# @description (do_gcp_pin_account), never the owner account.
# @param ENV - required: dev or prd
# @param ROTATE_STEP (optional) - status (default), mint, prove or retire
# @param DRY_RUN (optional) - 1 (default) or 0: mint and retire change nothing at 1
# @param OLD_KEY_ID (retire) - the key id to delete
# @param PROOF_IDS (retire) - comma list: this box's and the other box's proof ids
# @param CI_RUN_ID (retire) - a green CI run (numeric id) on the new key
# @param SA_KEY_MAX_AGE_DAYS (optional) - 30 (owner Q1 A, SPL-1945)
# @example ENV=dev ./run -a do_gcp_sa_key_rotate
# @example ENV=dev ROTATE_STEP=mint DRY_RUN=0 ./run -a do_gcp_sa_key_rotate
#------------------------------------------------------------------------------
# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

do_gcp_sa_key_rotate() {
  local step="${ROTATE_STEP:-status}" dry="${DRY_RUN:-1}"
  [[ "$step" =~ ^(status|mint|prove|retire)$ ]] || { do_log "FATAL ROTATE_STEP must be status, mint, prove or retire, got: '$step'"; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 2; }
  do_gcp_spl_proj_id || return 1
  local key
  key="$(do_gcp_sa_key_file)" || { do_log "FATAL no project SA key for $PROJ_ID at \$HOME/.gcp/.<org>/key-$PROJ_ID.json on this box"; return 1; }
  [[ "$step" == prove ]] && { gcp_sa_key_rotate_prove "$key"; return; }

  local _spl_sdk_saved _spl_sdk_dir sa file_id
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  do_require_bin jq python3 || return 1
  sa="$(do_gcp_sa_key_email "$key")" || { do_log "FATAL no client_email in the key file of $PROJ_ID"; return 1; }
  file_id="$(jq -r '.private_key_id // ""' "$key" 2>/dev/null)"
  [[ -n "$file_id" ]] || { do_log "FATAL the key file of $PROJ_ID has no private_key_id"; return 1; }
  do_gcp_pin_account || return 1
  gcp_sa_key_rotate_list "$sa" "$_spl_sdk_dir/keys" || return 1
  gcp_sa_key_rotate_show "$sa" "$file_id" "$_spl_sdk_dir/keys" || return 1
  case "$step" in
    status) gcp_sa_key_rotate_next "$file_id" "$_spl_sdk_dir/keys" ;;
    mint)   gcp_sa_key_rotate_mint "$key" "$sa" "$file_id" "$_spl_sdk_dir/keys" "$dry" ;;
    retire) gcp_sa_key_rotate_retire "$key" "$sa" "$file_id" "$_spl_sdk_dir/keys" "$dry" ;;
  esac
}

# gcp_sa_key_rotate_list <sa> <out> - "<key id> <created> <age days>" per
# user-managed, enabled key of <sa>, oldest first. Metadata only.
gcp_sa_key_rotate_list() {
  local sa="$1" out="$2"
  gcloud iam service-accounts keys list --iam-account="$sa" --managed-by=user --project="$PROJ_ID" \
    --account="$GCP_ACCOUNT" --format=json --quiet </dev/null >"$out.json" ||
    { do_log "FATAL cannot list the keys of $sa in $PROJ_ID as $GCP_ACCOUNT"; return 1; }
  python3 - "$out.json" "$out" <<'PY'
import datetime as d, json, sys
now = d.datetime.now(d.timezone.utc)
rows = []
for k in json.load(open(sys.argv[1])):
    if k.get("disabled"):
        continue
    t = d.datetime.fromisoformat(k["validAfterTime"].replace("Z", "+00:00"))
    rows.append((t, k["name"].split("/")[-1]))
with open(sys.argv[2], "w") as f:
    for t, i in sorted(rows):
        print(i, t.strftime("%Y-%m-%dT%H:%M:%SZ"), (now - t).days, file=f)
PY
}

# gcp_sa_key_rotate_show <sa> <file key id> <keys> - one line per key; refuses
# a key file whose key the SA does not hold (stale, or another SA's)
gcp_sa_key_rotate_show() {
  local sa="$1" fid="$2" keys="$3" id at age mark max="${SA_KEY_MAX_AGE_DAYS:-30}"
  do_log "INFO $ENV $sa: $(wc -l <"$keys") user-managed enabled key(s), max age $max d"
  while read -r id at age; do
    mark=""; [[ "$id" == "$fid" ]] && mark=" <- the key file"
    (( age > max )) && mark="$mark OVER"
    do_log "INFO   key $id created $at age ${age} d$mark"
  done <"$keys"
  grep -q "^$fid " "$keys" || { do_log "FATAL the key file holds key $fid, which $sa does not hold enabled (deleted or disabled): restore the current key file first"; return 1; }
}

# gcp_sa_key_rotate_next <file key id> <keys> - the next step
gcp_sa_key_rotate_next() {
  local fid="$1" keys="$2" n newest r="ENV=$ENV" max="${SA_KEY_MAX_AGE_DAYS:-30}" age
  n=$(wc -l <"$keys"); newest=$(awk 'END{print $1}' "$keys")
  if (( n == 1 )); then
    age=$(awk '{print $3}' "$keys")
    (( age > max )) && do_log "WARN the key is $age d old, past the $max d max age"
    do_log "NEXT mint: $r ROTATE_STEP=mint ./run -a do_gcp_sa_key_rotate (dry run), then DRY_RUN=0 with the owner's go"
  elif [[ "$fid" != "$newest" ]]; then
    do_log "NEXT a newer key $newest exists: copy its key file to this box from the box that minted it (out of band, never by git or log), then $r ROTATE_STEP=prove"
  elif ! gcp_sa_key_rotate_proof_of "$fid" >/dev/null; then
    do_log "NEXT prove: $r ROTATE_STEP=prove ./run -a do_gcp_sa_key_rotate, here and on the other box, and a green CI run on the new key"
  else
    do_log "NEXT retire, after the other box and CI proved the new key: $r ROTATE_STEP=retire OLD_KEY_ID=<old id> PROOF_IDS=$(gcp_sa_key_rotate_proof_of "$fid"),<other box's proof id> CI_RUN_ID=<run id> ./run -a do_gcp_sa_key_rotate"
  fi
}

# gcp_sa_key_rotate_mint <key> <sa> <file key id> <keys> <dry> - writes the
# new key to the key file only; the old file stays as <key>.prev for the undo
gcp_sa_key_rotate_mint() {
  local key="$1" sa="$2" fid="$3" keys="$4" dry="$5" tmp new
  (( $(wc -l <"$keys") == 1 )) ||
    { do_log "FATAL $sa already holds $(wc -l <"$keys") user keys: a rotation is open; prove and retire it first (ROTATE_STEP=status names the step)"; return 1; }
  [[ ! -e "$key.prev" ]] || { do_log "FATAL $key.prev exists: an earlier rotation was not retired; check it, then remove it by hand"; return 1; }
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: gcloud iam service-accounts keys create <tmp in $(dirname "$key")> --iam-account=$sa --project=$PROJ_ID --account=$GCP_ACCOUNT, then keep $key as $key.prev and move the new key to $key (mode 600)"
    return 0
  fi
  tmp="$(dirname "$key")/.$(basename "$key").new.$$"
  ( umask 077; gcloud iam service-accounts keys create "$tmp" --iam-account="$sa" --project="$PROJ_ID" \
      --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ) ||
    { rm -f "$tmp"; do_log "FATAL gcloud could not create a key for $sa"; return 1; }
  chmod 600 "$tmp"
  [[ "$(do_gcp_sa_key_email "$tmp")" == "$sa" ]] || { rm -f "$tmp"; do_log "FATAL the new key is not a key of $sa: discarded (its id stays in GCP: check ROTATE_STEP=status)"; return 1; }
  new="$(jq -r '.private_key_id' "$tmp")"
  { mv "$key" "$key.prev" && mv "$tmp" "$key"; } || { do_log "FATAL could not move the new key into $key; the new key is at $tmp"; return 1; }
  do_log "OK new key $new written to $key (mode 600); the old key $fid is still valid, its file is $key.prev"
  do_log "NEXT ENV=$ENV ROTATE_STEP=prove ./run -a do_gcp_sa_key_rotate here; copy $key to the other box and the CI secret (out of band), prove there too"
}

# gcp_sa_key_rotate_prove <key> - the key file alone, in a throwaway config:
# a token and one read call. Records "<project> <key id> <proof id>".
gcp_sa_key_rotate_prove() {
  local key="$1" _spl_sdk_saved _spl_sdk_dir sa kid box proof state
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  kid="$(jq -r '.private_key_id // ""' "$key" 2>/dev/null)"
  [[ -n "$kid" ]] || { do_log "FATAL the key file of $PROJ_ID has no private_key_id"; return 1; }
  sa="$(do_gcp_activate_sa_key "$key")" || { do_log "FATAL PROVE the key file of $PROJ_ID does not activate"; return 1; }
  gcloud auth print-access-token --account="$sa" --quiet </dev/null >/dev/null 2>&1 ||
    { do_log "FATAL PROVE key $kid mints no token for $sa"; return 1; }
  [[ "$(gcloud projects describe "$PROJ_ID" --account="$sa" --format='value(projectId)' --quiet </dev/null 2>/dev/null)" == "$PROJ_ID" ]] ||
    { do_log "FATAL PROVE key $kid cannot read the project $PROJ_ID"; return 1; }
  box="${SA_KEY_PROOF_BOX:-$(spl_box_name)}"
  proof="$box:${kid:0:12}:$(date -u +%Y%m%dT%H%M%SZ)"
  state="$(gcp_sa_key_rotate_state)"
  mkdir -p "$(dirname "$state")" && printf '%s %s %s\n' "$PROJ_ID" "$kid" "$proof" >>"$state" ||
    { do_log "FATAL PROVE passed but $state is not writable: no proof recorded"; return 1; }
  do_log "OK PROVE key $kid of $sa mints a token and reads $PROJ_ID on $box. Proof id: $proof"
}

# the proof record of this box
gcp_sa_key_rotate_state() { echo "${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/gcp-sa-key-rotate.proofs"; }

# gcp_sa_key_rotate_proof_of <key id> - this box's newest proof id for it
gcp_sa_key_rotate_proof_of() {
  local f; f="$(gcp_sa_key_rotate_state)"
  [[ -f "$f" ]] && awk -v p="$PROJ_ID" -v k="$1" '$1 == p && $2 == k {x = $3} END {if (x == "") exit 1; print x}' "$f"
}

# gcp_sa_key_rotate_retire <key> <sa> <file key id> <keys> <dry> - deletes
# OLD_KEY_ID, after the proofs; removes <key>.prev
gcp_sa_key_rotate_retire() {
  local key="$1" sa="$2" fid="$3" keys="$4" dry="$5" old="${OLD_KEY_ID:-}" ci="${CI_RUN_ID:-}" mine p other=""
  [[ "$old" =~ ^[0-9a-f]{8,64}$ ]] || { do_log "FATAL OLD_KEY_ID must be a key id (hex), got: '$old'"; return 2; }
  [[ "$old" != "$fid" ]] || { do_log "FATAL OLD_KEY_ID is the key the key file holds: retire deletes the OLD key only"; return 1; }
  grep -q "^$old " "$keys" || { do_log "FATAL $sa holds no enabled key $old"; return 1; }
  [[ "$(awk 'END{print $1}' "$keys")" == "$fid" ]] || { do_log "FATAL the key file holds $fid, not the newest key: mint or copy the new key here first"; return 1; }
  mine="$(gcp_sa_key_rotate_proof_of "$fid")" || { do_log "FATAL no proof on this box for key $fid: ROTATE_STEP=prove first"; return 1; }
  [[ ",${PROOF_IDS:-}," == *",$mine,"* ]] || { do_log "FATAL PROOF_IDS lacks this box's proof $mine"; return 1; }
  for p in ${PROOF_IDS//,/ }; do
    [[ "$p" != "$mine" && "$p" =~ ^[A-Za-z0-9._-]+:${fid:0:12}:[0-9]{8}T[0-9]{6}Z$ && "${p%%:*}" != "${mine%%:*}" ]] && other="$p"
  done
  [[ -n "$other" ]] || { do_log "FATAL PROOF_IDS has no proof id from another box for key ${fid:0:12} (<box>:${fid:0:12}:<UTC time>, printed by its ROTATE_STEP=prove)"; return 1; }
  [[ "$ci" =~ ^[0-9]+$ ]] || { do_log "FATAL CI_RUN_ID must be the numeric id of a green CI run on the new key, got: '$ci'"; return 1; }
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: gcloud iam service-accounts keys delete $old --iam-account=$sa --project=$PROJ_ID --account=$GCP_ACCOUNT, then remove $key.prev (proofs $mine, $other, CI run $ci)"
    return 0
  fi
  gcloud iam service-accounts keys delete "$old" --iam-account="$sa" --project="$PROJ_ID" \
    --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 || { do_log "FATAL gcloud could not delete key $old of $sa"; return 1; }
  rm -f "$key.prev"
  do_log "OK retired key $old of $sa (proofs $mine, $other, CI run $ci); $key.prev removed"
}
