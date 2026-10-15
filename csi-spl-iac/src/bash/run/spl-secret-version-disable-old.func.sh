#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description Disable every OLDER enabled version of one Secret Manager secret
# @description and keep its newest enabled version (security round 1 row 6,
# @description SPL-1967: the prd Stripe secret key had 2 enabled versions, the
# @description older one still usable). Before it changes anything it reads the
# @description env's hub Cloud Run service (cnf hub.service_name) and refuses
# @description when the hub pins this secret to a version it would disable; the
# @description hub reads `latest` (030), which is the newest version.
# @description Never reads a value (no `versions access`): disabling is a state
# @description change, undone with `gcloud secrets versions enable`.
# @description Runs as the env's project SA in a private gcloud config.
# @description DRY_RUN=1 (default) names each version it would disable, by
# @description number and create date only; DRY_RUN=0 disables them and checks
# @description each now reads DISABLED.
# @param ENV - required: dev or prd
# @param SECRET - required: the secret id, e.g. csi-spl-hub-stripe-secret-key
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd SECRET=csi-spl-hub-stripe-secret-key ./run -a do_spl_secret_version_disable_old
# @example ENV=prd SECRET=csi-spl-hub-stripe-secret-key DRY_RUN=0 ./run -a do_spl_secret_version_disable_old
#------------------------------------------------------------------------------
do_spl_secret_version_disable_old() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" secret="${SECRET:-}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$secret" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL SECRET must be a secret id ([A-Za-z0-9_-]+), got: '$secret'"; return 2; }
  do_require_bin yq python3 || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" svc region
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  svc="$(yq -r '.env.hub.service_name // ""' "$cnf")"
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  [[ -n "$svc" && -n "$region" ]] || { do_log "FATAL the $ENV cnf has no env.hub.service_name or env.gcp.gcp_region"; return 1; }

  do_gcp_pin_account || return 1
  local a="$GCP_ACCOUNT" vers="$_spl_sdk_dir/versions.json" hub="$_spl_sdk_dir/hub.json" plan
  gcloud secrets versions list "$secret" --project="$p" --account="$a" --format=json --quiet </dev/null >"$vers" ||
    { do_log "FATAL cannot list the versions of $secret in $p as $a"; return 1; }
  gcloud run services describe "$svc" --region="$region" --project="$p" --account="$a" --format=json --quiet </dev/null >"$hub" ||
    { do_log "FATAL cannot read the hub service $svc in $p/$region: refusing without the pin check"; return 1; }
  plan="$(spl_secret_disable_plan "$secret" "$vers" "$hub")" || return 1
  local keep old
  keep="$(sed -n 's/^KEEP //p' <<<"$plan")"; old="$(sed -n 's/^OLD //p' <<<"$plan")"
  sed -n 's/^INFO /INFO /p' <<<"$plan" | while IFS= read -r l; do do_log "$l"; done
  if [[ -z "$old" ]]; then
    if [[ -n "$keep" ]]; then do_log "OK $p $secret: one enabled version, ${keep% *} (created ${keep#* }); nothing to disable"
    else do_log "OK $p $secret: no enabled version; nothing to disable"; fi
    return 0
  fi
  spl_secret_disable_apply "$dry" "$p" "$a" "$secret" "$keep" "$old"
}

# spl_secret_disable_plan <secret> <versions.json> <hub.json> - prints
# "KEEP <n> <date>", one "OLD <n> <date>" per older enabled version, and an
# INFO line on how the hub reads the secret; refuses (exit 1) when the hub
# pins it to an OLD version.
spl_secret_disable_plan() {
  python3 - "$@" <<'PY'
import json, sys
secret, vf, hf = sys.argv[1:]
vs = [v for v in json.load(open(vf)) if v.get("state") == "ENABLED"]
vs.sort(key=lambda v: int(v["name"].split("/")[-1]))
num = lambda v: v["name"].split("/")[-1]
if vs:
    print(f"KEEP {num(vs[-1])} {vs[-1]['createTime'][:10]}")
old = {num(v): v["createTime"][:10] for v in vs[:-1]}
for n, d in old.items():
    print(f"OLD {n} {d}")
hub = json.load(open(hf))
refs = [e["valueFrom"]["secretKeyRef"].get("key", "latest")
        for c in hub.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        for e in c.get("env", []) if e.get("valueFrom", {}).get("secretKeyRef", {}).get("name") == secret]
pinned = sorted(set(refs) & set(old))
if pinned:
    sys.stderr.write(f"FATAL the hub pins {secret} to version {', '.join(pinned)}, which this would disable: refusing\n")
    sys.exit(1)
print(f"INFO the hub reads {secret} at: {', '.join(sorted(set(refs))) or 'nothing (not referenced)'}")
PY
}

# spl_secret_disable_apply <dry> <project> <account> <secret> <keep> <old rows>
spl_secret_disable_apply() {
  local dry="$1" p="$2" a="$3" secret="$4" keep="$5" old="$6" n d st bad=0
  while read -r n d; do
    if [[ "$dry" == 1 ]]; then
      do_log "OK DRY_RUN would disable $p $secret version $n (created $d); keeps version ${keep% *} (created ${keep#* })"
      continue
    fi
    gcloud secrets versions disable "$n" --secret="$secret" --project="$p" --account="$a" --quiet </dev/null >/dev/null ||
      { do_log "ERROR could not disable $secret version $n"; bad=1; continue; }
    st="$(gcloud secrets versions describe "$n" --secret="$secret" --project="$p" --account="$a" --format='value(state)' --quiet </dev/null)"
    if [[ "$st" == DISABLED ]]; then
      do_log "OK disabled $p $secret version $n (created $d); undo: gcloud secrets versions enable $n --secret=$secret --project=$p"
    else
      do_log "ERROR $secret version $n reads '${st:-?}' after disable"; bad=1
    fi
  done <<<"$old"
  [[ "$dry" == 1 ]] && do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0 to disable."
  return "$bad"
}
