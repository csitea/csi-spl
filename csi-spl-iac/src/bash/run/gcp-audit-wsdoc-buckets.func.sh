#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description READ-ONLY audit of one env's per-workspace docs buckets (iac
# @description step 052, spec 114 section 9.4 guard 3, tasks R1). One
# @description FINDING line per breach, then exit 1 on any finding:
# @description   no-bucket     a workspace (tenants, minus `system`) with no
# @description                 <bucket_prefix><slug> bucket
# @description   not-uniform   a 052 bucket without uniform bucket-level access
# @description   not-enforced  a 052 bucket whose public access prevention is
# @description                 not `enforced` (e.g. `inherited`)
# @description   public        allUsers / allAuthenticatedUsers in its policy
# @description   member        a member other than the legacy project
# @description                 bindings (projectOwner/Editor/Viewer) and the
# @description                 hub runtime SA (cnf hub.runtime_sa_account_id)
# @description   unreadable    a policy or listing it could not read: "could
# @description                 not check" is never "private"
# @description   on-050        a workspace Qto doc's attrs.assets sha256 with
# @description                 no qto-assets/<sha256> object in its 052 bucket,
# @description                 i.e. the picture still lives in the shared 050
# @description                 bucket (spec 114 9.3; tasks R3 + R4 move them)
# @description The bucket prefix and the hub SA come from the effective cnf;
# @description the workspaces and the asset references from the hub DB through
# @description csi-spl-orc's read-only do_spl_db_query (tenant slug and sha256
# @description only, never a doc's content). gcloud runs as the env's project
# @description service account (do_gcp_pin_account, --account on every call) in
# @description a throwaway gcloud config. Mutates nothing.
# @param ENV - required: dev or prd
# @example ENV=prd ./run -a do_gcp_audit_wsdoc_buckets
#------------------------------------------------------------------------------
do_gcp_audit_wsdoc_buckets() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  do_require_bin yq python3 || return 1
  # ORG/APP from the project dir's own name: ./run takes APP from the checkout
  # dir (csi-spl), which made <org>-<app>-orc csi-csi-spl-orc (SPL-2945)
  if [[ -n "${PROJ_PATH:-}" ]]; then do_resolve_oap ORG && do_resolve_oap APP || return 1; fi
  [[ -n "${ORG:-}" && -n "${APP:-}" ]] || { do_log "FATAL ORG and APP are unset and there is no PROJ_PATH to read them from"; return 1; }

  # the DB reads first, outside the private gcloud config: orc pins its own
  local ws refs
  ws="$(_gcp_audit_wsdoc_sql "select 'WS ' || tenant_id from tenants where tenant_id <> 'system' order by 1" WS)" || return 1
  refs="$(_gcp_audit_wsdoc_sql "select distinct 'ASSET ' || i.tenant_id || ' ' || a.value from workspace_doc_item i, jsonb_each_text(CASE WHEN jsonb_typeof(i.attrs->'assets') = 'object' THEN i.attrs->'assets' ELSE '{}'::jsonb END) a where i.parent_id is null and i.tenant_id <> 'system' order by 1" ASSET)" || return 1
  [[ -n "$ws" ]] || { do_log "FATAL ENV=$ENV: the hub DB lists no workspace; nothing to audit against"; return 1; }

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_gcp_spl_proj_id || return 1
  local cnf="$_spl_sdk_dir/cnf.yaml" bprefix hubid
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  bprefix="$(yq -r '.env.steps."052-gcs-workspace-docs".bucket_prefix // ""' "$cnf")"
  hubid="$(yq -r '.env.hub.runtime_sa_account_id // ""' "$cnf")"
  [[ -n "$bprefix" && "$bprefix" != null ]] ||
    { do_log "FATAL ENV=$ENV has no steps.052-gcs-workspace-docs.bucket_prefix: no workspace docs buckets"; return 1; }
  [[ -n "$hubid" && "$hubid" != null ]] || { do_log "FATAL ENV=$ENV has no hub.runtime_sa_account_id"; return 1; }
  local hubsa="serviceAccount:$hubid@$PROJ_ID.iam.gserviceaccount.com"

  do_gcp_pin_account || return 1
  local acct="--account=$GCP_ACCOUNT" n=0 out
  do_log "INFO PROJ_ID=$PROJ_ID bucket_prefix=$bprefix GCP_ACCOUNT=$GCP_ACCOUNT workspaces=$(grep -c . <<<"$ws") asset_refs=$(grep -c . <<<"$refs")"

  # name<TAB>uniform<TAB>pap of every bucket of the project, then the 052 ones
  out="$(gcloud storage buckets list --project="$PROJ_ID" "$acct" \
    --format='value(name,uniform_bucket_level_access,public_access_prevention)' 2>&1)" ||
    { do_log "FATAL ENV=$ENV: cannot list the buckets of $PROJ_ID: $out"; return 1; }
  local b u pap slug have=" "
  while IFS=$'\t' read -r b u pap; do
    [[ "$b" == "$bprefix"?* ]] || continue
    slug="${b#"$bprefix"}" have+="$slug "
    [[ "${u,,}" == true ]] || _gcp_audit_wsdoc_find "not-uniform gs://$b uniform_bucket_level_access=${u:-<none>}"
    [[ "${pap,,}" == enforced ]] || _gcp_audit_wsdoc_find "not-enforced gs://$b public_access_prevention=${pap:-<none>}"
    _gcp_audit_wsdoc_policy "$b" "$acct" "$hubsa"
  done <<<"$out"
  for slug in $ws; do
    [[ "$have" == *" $slug "* ]] || _gcp_audit_wsdoc_find "no-bucket $slug (want gs://$bprefix$slug)"
  done

  _gcp_audit_wsdoc_on050 "$bprefix" "$acct" "$have" <<<"$refs"
  ((n == 0)) || { do_log "FATAL ENV=$ENV: $n finding(s) in the workspace docs buckets"; return 1; }
  do_log "OK ENV=$ENV: 0 findings ($(wc -w <<<"$have") 052 buckets, $(wc -w <<<"$ws") workspaces, $(grep -c . <<<"$refs") asset refs)"
}

# _gcp_audit_wsdoc_find <text>: one FINDING line; counts in the caller's n.
_gcp_audit_wsdoc_find() {
  do_log "FINDING $ENV $*"
  n=$((n + 1))
}

# _gcp_audit_wsdoc_sql <sql> <marker> -> the rest of every output line whose
# first word is <marker>, via csi-spl-orc's read-only do_spl_db_query (it
# pins its own SA, so it runs outside the caller's private gcloud config).
_gcp_audit_wsdoc_sql() {
  local out rc=0
  out="$(cd "$APP_PATH/$ORG-$APP-orc" && env -u CLOUDSDK_CONFIG ENV="$ENV" SQL="$1" ./run -a do_spl_db_query 2>&1)" || rc=$?
  ((rc == 0)) || { do_log "FATAL ENV=$ENV: the hub DB read failed (rc=$rc)" >&2; return 1; }
  awk -v m="$2" '$1 == m { $1 = ""; sub(/^ /, ""); print }' <<<"$out"
}

# _gcp_audit_wsdoc_policy <bucket> <--account=..> <hub member>: the public and
# member findings of one bucket's IAM policy. A human member is printed
# redacted; an unreadable policy is a finding.
_gcp_audit_wsdoc_policy() {
  local b="$1" acct="$2" hubsa="$3" pol m role mem
  pol="$(gcloud storage buckets get-iam-policy "gs://$b" "$acct" --format=json 2>/dev/null)" ||
    { _gcp_audit_wsdoc_find "unreadable gs://$b IAM policy"; return 0; }
  m="$(python3 -c 'import json,sys
for x in json.load(sys.stdin).get("bindings", []):
    for mm in x.get("members", []): print(x.get("role", "?"), mm)' <<<"$pol" 2>/dev/null)" ||
    { _gcp_audit_wsdoc_find "unreadable gs://$b IAM policy (not JSON)"; return 0; }
  while read -r role mem; do
    [[ -n "$mem" ]] || continue
    case "$mem" in
      allUsers | allAuthenticatedUsers) _gcp_audit_wsdoc_find "public gs://$b $role $mem" ;;
      projectOwner:* | projectEditor:* | projectViewer:* | "$hubsa") ;;
      # a person's address never reaches the log (SPL-2945 D1); a domain is
      # an organisation, printed
      user:* | *:user:* | group:* | *:group:*) _gcp_audit_wsdoc_find "member gs://$b $role ${mem%:*}:<redacted>" ;;
      principal://* | principalSet://*) _gcp_audit_wsdoc_find "member gs://$b $role ${mem%%://*}://<redacted>" ;;
      *) _gcp_audit_wsdoc_find "member gs://$b $role $mem" ;;
    esac
  done <<<"$m"
}

# _gcp_audit_wsdoc_on050 <prefix> <--account=..> <" slug ... "> < "<tenant>
# <sha256>" lines (sorted): an on-050 finding per reference whose 052 bucket
# has no qto-assets/<sha256>, so every reference of a workspace with no bucket.
_gcp_audit_wsdoc_on050() {
  local bprefix="$1" acct="$2" have="$3" t sha last="" objs="" out rc
  while read -r t sha; do
    [[ -n "$t" ]] || continue
    if [[ "$t" != "$last" ]]; then
      last="$t" objs=""
      if [[ "$have" == *" $t "* ]]; then
        rc=0
        out="$(gcloud storage ls "gs://$bprefix$t/qto-assets/" "$acct" 2>&1)" || rc=$?
        if ((rc == 0)); then
          objs="$out"
        elif ! grep -qi 'matched no objects' <<<"$out"; then
          _gcp_audit_wsdoc_find "unreadable gs://$bprefix$t/qto-assets/ (rc=$rc)"
        fi
      fi
    fi
    grep -qxF "gs://$bprefix$t/qto-assets/$sha" <<<"$objs" || _gcp_audit_wsdoc_find "on-050 $t $sha"
  done
}
