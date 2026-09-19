#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY IAM audit of one env, as the env's project service
# @description account in a private gcloud config (harvested from the
# @description 2026-09-19 before/after-destroy IAM dumps, adhoc-harvest.md).
# @description Dumps the project policy, every service account's policy, every
# @description secret's policy, the relay (020) and files (050) bucket
# @description policies, the 028 registry and the 030 Cloud Run service
# @description policies into one JSON (an unreadable policy is recorded as
# @description {"error":"unreadable"}, never as empty), then prints the
# @description markdown analysis of src/bash/scripts/iam-analyze.py: the step
# @description owning each binding (UNOWNED = report, never delete), user-held
# @description and deleted principals, grants a step expects but the policy
# @description lacks, and the diff against IAM_BASELINE when given.
# @description Every resource name comes from the effective cnf. Mutates nothing.
# @param ENV - required: dev or prd
# @param IAM_TAG (optional) - label of this dump, default the UTC timestamp
# @param IAM_BASELINE (optional) - an earlier dump to diff against
# @param IAM_AUDIT_DIR (optional) - default $HOME/.local/share/<org>-<app>/iam
# @example ENV=prd IAM_TAG=before ./run -a do_gcp_audit_iam
# @example ENV=prd IAM_TAG=after IAM_BASELINE=~/.local/share/csi-spl/iam/prd-before.json ./run -a do_gcp_audit_iam
#------------------------------------------------------------------------------
do_gcp_audit_iam() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  do_require_bin yq python3 || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID" cnf="$_spl_sdk_dir/cnf.yaml" tmp="$_spl_sdk_dir/dump"
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  yq -o json '.' "$cnf" >"$_spl_sdk_dir/cnf.json" || return 1
  _ia() { yq -r "$1 // \"\"" "$cnf"; }
  local relay files repo svc region
  relay="$(_ia '.env.steps."020-gcp-relay-bucket".relay_bucket_name')"
  files="$(_ia '.env.steps."050-gcs-files".files_bucket_name')"
  repo="$(_ia '.env.steps."028-gcp-artifact-registry".repository_id')"
  svc="$(_ia .env.hub.service_name)"
  region="$(_ia .env.gcp.gcp_region)"
  unset -f _ia

  # the env's project SA from its key, in this private config (cc7f79f)
  do_gcp_pin_account || return 1
  local sa="$GCP_ACCOUNT"

  mkdir -p "$tmp/sa" "$tmp/secret"
  _iag() { gcloud "$@" --account="$sa" --format=json 2>/dev/null || echo '{"error":"unreadable"}'; }
  _iag projects get-iam-policy "$p" >"$tmp/project.json"
  _iag iam service-accounts list --project="$p" >"$tmp/sas.json"
  local e s
  for e in $(python3 -c 'import json,sys;[print(s["email"]) for s in json.load(open(sys.argv[1])) if isinstance(s,dict)]' "$tmp/sas.json" 2>/dev/null); do
    _iag iam service-accounts get-iam-policy "$e" --project="$p" >"$tmp/sa/$e.json"
  done
  _iag secrets list --project="$p" >"$tmp/secrets.json"
  for s in $(python3 -c 'import json,sys;[print(x["name"].split("/")[-1]) for x in json.load(open(sys.argv[1])) if isinstance(x,dict)]' "$tmp/secrets.json" 2>/dev/null); do
    _iag secrets get-iam-policy "$s" --project="$p" >"$tmp/secret/$s.json"
  done
  [[ -n "$relay" ]] && _iag storage buckets get-iam-policy "gs://$relay" >"$tmp/bucket-relay.json"
  [[ -n "$files" ]] && _iag storage buckets get-iam-policy "gs://$files" >"$tmp/bucket-files.json"
  [[ -n "$repo" ]] && _iag artifacts repositories get-iam-policy "$repo" --location="$region" --project="$p" >"$tmp/repo.json"
  [[ -n "$svc" ]] && _iag run services get-iam-policy "$svc" --region="$region" --project="$p" >"$tmp/run.json"
  unset -f _iag

  local dir="${IAM_AUDIT_DIR:-$HOME/.local/share/$ORG-$APP/iam}" tag="${IAM_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL IAM_TAG must match ^[A-Za-z0-9._-]+$, got: '$tag'"; return 1; }
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  local out="$dir/$ENV-$tag.json"
  python3 - "$tmp" "$out" "$p" "$sa" "$tag" <<'PY' || { do_log "FATAL could not assemble $out"; return 1; }
import json, os, sys, datetime
tmp, out, proj, sa, tag = sys.argv[1:]
def ld(f):
    try: return json.load(open(os.path.join(tmp, f)))
    except Exception: return {"error": "missing"}
doc = {"project": proj, "as": sa, "tag": tag,
       "taken_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "policies": {"project": ld("project.json")}}
for d in ("sa", "secret"):
    for f in sorted(os.listdir(os.path.join(tmp, d))):
        doc["policies"][f"{d}:{f[:-5]}"] = ld(os.path.join(d, f))
for f, k in (("bucket-relay.json", "bucket:relay"), ("bucket-files.json", "bucket:files"),
             ("repo.json", "artifact-repo"), ("run.json", "run-service")):
    if os.path.exists(os.path.join(tmp, f)): doc["policies"][k] = ld(f)
json.dump(doc, open(out, "w"), indent=1, sort_keys=True)
PY
  do_log "INFO IAM dump of $p: $out"
  local py="$PROJ_PATH/src/bash/scripts/iam-analyze.py" args=("$_spl_sdk_dir/cnf.json" "$out")
  [[ -n "${IAM_BASELINE:-}" ]] && args=("$_spl_sdk_dir/cnf.json" "$IAM_BASELINE" "$out")
  python3 "$py" "${args[@]}" | tee "${out%.json}.md" || { do_log "FATAL iam-analyze.py failed"; return 1; }
  do_log "OK IAM audit of $p: ${out%.json}.md"
}
