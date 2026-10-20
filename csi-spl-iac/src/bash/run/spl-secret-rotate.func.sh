#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description One rotation of one hub secret, step by step (SPL-2657, Cloud
# @description Run radar step 6 part 2; the runbook: secret-rotation.md
# @description section 2). Each step reads the secret's versions (metadata
# @description only, never `versions access`), its cnf pin
# @description (env.hub.secret_versions) and the pin the live hub service
# @description reads, and refuses to run out of order:
# @description   status  (default) prints the three and the next step
# @description   pin     raises the cnf pin to the newest enabled version and
# @description           renders the 030 tfvars (do_tpl_gen); the 030 apply
# @description           after it is the owner's go, never this action's
# @description   verify  the live hub reads the cnf pin and its newest revision
# @description           is Ready
# @description   disable the older enabled versions, by
# @description           do_spl_secret_version_disable_old
# @description The new version itself is added by the secret's seed action
# @description first; status names it. Runs as the env's project SA in a
# @description private gcloud config.
# @param ENV - required: dev or prd
# @param SECRET - required: a secret id the hub pins, e.g. csi-spl-hub-wui-key
# @param ROTATE_STEP (optional) - status (default), pin, verify or disable
# @param DRY_RUN (optional) - 1 (default) or 0: pin and disable change nothing at 1
# @example ENV=dev SECRET=csi-spl-hub-wui-key ./run -a do_spl_secret_rotate
# @example ENV=dev SECRET=csi-spl-hub-wui-key ROTATE_STEP=pin DRY_RUN=0 ./run -a do_spl_secret_rotate
#------------------------------------------------------------------------------
do_spl_secret_rotate() {
  local step="${ROTATE_STEP:-status}" dry="${DRY_RUN:-1}" secret="${SECRET:-}"
  [[ "$step" =~ ^(status|pin|verify|disable)$ ]] || { do_log "FATAL ROTATE_STEP must be status, pin, verify or disable, got: '$step'"; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$secret" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL SECRET must be a secret id ([A-Za-z0-9_-]+), got: '$secret'"; return 2; }
  [[ "$step" == disable ]] && { spl_secret_rotate_disable "$secret" "$dry"; return; }

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  do_require_bin yq python3 || return 1
  local newest cnf_pin live_pin ready
  spl_secret_rotate_state "$secret" "$_spl_sdk_dir/state" || return 1
  read -r newest cnf_pin live_pin ready <"$_spl_sdk_dir/state"
  do_log "INFO $ENV $secret: newest enabled version $newest, cnf pin $cnf_pin, live hub pin $live_pin, newest revision Ready=$ready"
  case "$step" in
    status) spl_secret_rotate_next "$secret" "$newest" "$cnf_pin" "$live_pin" ;;
    pin)    spl_secret_rotate_pin "$secret" "$newest" "$cnf_pin" "$dry" ;;
    verify) spl_secret_rotate_verify "$secret" "$cnf_pin" "$live_pin" "$ready" ;;
  esac
}

# spl_secret_rotate_state <secret> <out> - writes "<newest enabled> <cnf pin>
# <live pin> <Ready>" to <out>, "-" for one that does not exist. Runs gcloud
# as the env's project SA (the caller set the private config).
spl_secret_rotate_state() {
  local secret="$1" out="$2" cnf="$_spl_sdk_dir/cnf.yaml" vers="$_spl_sdk_dir/versions.json" hub="$_spl_sdk_dir/hub.json" svc region
  do_gcp_spl_proj_id || return 1
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  svc="$(yq -r '.env.hub.service_name // ""' "$cnf")"
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  [[ -n "$svc" && -n "$region" ]] || { do_log "FATAL the $ENV cnf has no env.hub.service_name or env.gcp.gcp_region"; return 1; }
  do_gcp_pin_account || return 1
  gcloud secrets versions list "$secret" --project="$PROJ_ID" --account="$GCP_ACCOUNT" --format=json --quiet </dev/null >"$vers" ||
    { do_log "FATAL cannot list the versions of $secret in $PROJ_ID as $GCP_ACCOUNT"; return 1; }
  gcloud run services describe "$svc" --region="$region" --project="$PROJ_ID" --account="$GCP_ACCOUNT" --format=json --quiet </dev/null >"$hub" ||
    { do_log "FATAL cannot read the hub service $svc in $PROJ_ID/$region"; return 1; }
  python3 - "$secret" "$vers" "$hub" "$(yq -r ".env.hub.secret_versions[\"$secret\"] // \"-\"" "$cnf")" "$out" <<'PY'
import json, sys
secret, vf, hf, cnf_pin, out = sys.argv[1:]
vs = sorted(int(v["name"].split("/")[-1]) for v in json.load(open(vf)) if v.get("state") == "ENABLED")
hub = json.load(open(hf))
refs = {e["valueFrom"]["secretKeyRef"].get("key", "latest")
        for c in hub.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        for e in c.get("env", []) if e.get("valueFrom", {}).get("secretKeyRef", {}).get("name") == secret}
if len(refs) > 1:
    sys.exit(f"FATAL the hub reads {secret} at more than one version: {', '.join(sorted(refs))}")
ready = [c.get("status", "?") for c in hub.get("status", {}).get("conditions", []) if c.get("type") == "Ready"]
print(vs[-1] if vs else "-", cnf_pin, refs.pop() if refs else "-", ready[0] if ready else "?", file=open(out, "w"))
PY
}

# spl_secret_rotate_next <secret> <newest> <cnf pin> <live pin> - the next step
spl_secret_rotate_next() {
  local s="$1" n="$2" c="$3" l="$4" r="ENV=$ENV SECRET=$1"
  if [[ "$c" == - || "$l" == - ]]; then
    do_log "FATAL $s is not a pinned hub secret in $ENV (cnf pin $c, live pin $l): nothing to rotate here"; return 1
  elif [[ "$l" == latest ]]; then
    do_log "FATAL the live hub reads $s at latest, not a pin: apply 030 first (secret-rotation.md section 1)"; return 1
  elif [[ "$n" == - ]]; then
    do_log "FATAL $s has no enabled version: re-enable the pinned version $c first"; return 1
  elif (( n > c )); then
    do_log "NEXT pin: $r ROTATE_STEP=pin DRY_RUN=0 ./run -a do_spl_secret_rotate"
  elif [[ "$c" != "$l" ]]; then
    do_log "NEXT apply 030 with the owner's go: cd csi-spl-orc && ENV=$ENV STEP=030-cloud-run-hub make do-tf-plan, then make do-provision; then ROTATE_STEP=verify"
  else
    do_log "NEXT the hub reads the newest version $n. To rotate, add a version first: $(spl_secret_seed_hint "$s"); else, older enabled versions go with ROTATE_STEP=disable"
  fi
}

# spl_secret_seed_hint <secret> - the action that adds a new version
spl_secret_seed_hint() {
  case "$1" in
    csi-spl-hub-db-dsn) echo "change the hub DB user's password in Cloud SQL, then add the new DSN as a version (by hand: no seed action yet)" ;;
    csi-spl-hub-auth-session-key) echo "add 48 random bytes, base64, as a version (by hand: do_spl_auth_secrets_seed mints only the first); it signs every session out, the hub has one key" ;;
    csi-spl-hub-auth-*-client-secret) echo "rotate it at the IdP, then cd csi-spl-orc && ENV=$ENV ./run -a do_spl_auth_idp_secret_seed" ;;
    csi-spl-hub-mail-smtp-password) echo "a new app password at the mail provider, then cd csi-spl-orc && ENV=$ENV ./run -a do_spl_mail_secret_seed" ;;
    csi-spl-hub-stripe-*) echo "roll the key at Stripe, then cd csi-spl-orc && ENV=$ENV ./run -a do_spl_payment_secret_seed" ;;
    csi-spl-hub-wui-key) echo "spec 014 contracts/wui-dispatch.md section 2.3 (do_spl_wui_key_seed mints only the first); the boxes trust its public key, so a box rollout too" ;;
    spool-hub-github-app-key) echo "a new private key in the GitHub App settings, then cd csi-spl-iac && ENV=$ENV ./run -a do_spl_gh_app_key_put" ;;
    *) echo "the seed action of $1 (see secret-rotation.md section 4)" ;;
  esac
}

# spl_secret_rotate_pin <secret> <newest> <cnf pin> <dry> - raises the pin in
# <env>.env.yaml (one line, the rest of the file byte for byte) and renders
spl_secret_rotate_pin() {
  local s="$1" n="$2" c="$3" dry="$4" f="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV.env.yaml"
  [[ "$c" != - && "$n" != - ]] || { do_log "FATAL $s has no cnf pin or no enabled version in $ENV"; return 1; }
  (( n > c )) || { do_log "FATAL the newest enabled version of $s is $n, not above the cnf pin $c: add a version first ($(spl_secret_seed_hint "$s"))"; return 1; }
  [[ "$dry" == 1 ]] && { do_log "OK DRY_RUN would set $f env.hub.secret_versions.$s from \"$c\" to \"$n\" and run do_tpl_gen"; return 0; }
  python3 - "$f" "$s" "$c" "$n" <<'PY' || return 1
import re, sys
f, s, c, n = sys.argv[1:]
lines, inside, hit = open(f).read().split("\n"), False, []
for i, l in enumerate(lines):
    if re.match(r"^\s+secret_versions:\s*$", l): inside = True; continue
    if inside and re.match(rf'^\s+{re.escape(s)}: "{re.escape(c)}"\s*$', l): hit.append(i)
    elif inside and l.strip() and not l.startswith("      "): inside = False
if len(hit) != 1:
    sys.exit(f"FATAL expected one '{s}: \"{c}\"' line under secret_versions in {f}, found {len(hit)}")
lines[hit[0]] = lines[hit[0]].replace(f'"{c}"', f'"{n}"')
open(f, "w").write("\n".join(lines))
PY
  do_log "OK $f env.hub.secret_versions.$s: \"$c\" -> \"$n\""
  ENV="$ENV" do_tpl_gen || { do_log "ERROR do_tpl_gen failed: the cnf pin is raised, the tfvars are not rendered"; return 1; }
  do_log "NEXT commit the cnf + tfvars, then apply 030 with the owner's go (cd csi-spl-orc && ENV=$ENV STEP=030-cloud-run-hub make do-tf-plan), then ROTATE_STEP=verify"
}

# spl_secret_rotate_verify <secret> <cnf pin> <live pin> <Ready>
spl_secret_rotate_verify() {
  local s="$1" c="$2" l="$3" r="$4"
  [[ "$l" == "$c" ]] || { do_log "FATAL the live hub reads $s at $l, the cnf pins $c: apply 030 first"; return 1; }
  [[ "$r" == True ]] || { do_log "FATAL the hub's newest revision is not Ready ($r): a new instance cannot start; undo: lower the pin and apply 030 (secret-rotation.md section 2)"; return 1; }
  do_log "OK the live hub reads $s at the cnf pin $c and is Ready. NEXT ENV=$ENV SECRET=$s ROTATE_STEP=disable ./run -a do_spl_secret_rotate"
}

# spl_secret_rotate_disable <secret> <dry> - the old versions go last
spl_secret_rotate_disable() {
  SECRET="$1" DRY_RUN="$2" do_spl_secret_version_disable_old
}
