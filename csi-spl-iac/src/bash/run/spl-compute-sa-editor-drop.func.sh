#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description Drop roles/editor from the env project's DEFAULT compute
# @description service account (<project number>-compute@developer...), and
# @description only after measuring that nothing uses it (security round 1
# @description row 6, SPL-1967). The measurement, each a count: Cloud Run
# @description services and jobs running as it (an EMPTY service account runs
# @description as it too), VM instances, Cloud Functions and Cloud Builds (only
# @description when their API is enabled; disabled = 0), its user-managed keys,
# @description and the audit log rows of the last AUDIT_DAYS where it is the
# @description caller. A control query must find audit rows at all, else the
# @description log is unreadable and the run is refused. Any use > 0 refuses.
# @description It removes that ONE binding (remove-iam-policy-binding), no
# @description other; the project SA holds roles/owner (gcp-003). Terraform
# @description does not manage it. Runs as the env's project SA in a private
# @description gcloud config. DRY_RUN=1 (default) prints the measurement and the
# @description command; DRY_RUN=0 runs it and re-reads the policy.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param AUDIT_DAYS (optional) - the audit window in days (default 30)
# @example ENV=prd ./run -a do_spl_compute_sa_editor_drop
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_compute_sa_editor_drop
#------------------------------------------------------------------------------
do_spl_compute_sa_editor_drop() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  local dry="${DRY_RUN:-1}" days="${AUDIT_DAYS:-30}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$days" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL AUDIT_DAYS must be a positive integer, got: $days"; return 2; }
  do_require_bin python3 || return 1
  do_gcp_spl_proj_id || return 1
  do_gcp_pin_account || return 1
  local p="$PROJ_ID" a="$GCP_ACCOUNT" d="$_spl_sdk_dir/m" num sa
  mkdir -p "$d" || return 1
  num="$(spl_csa_g "$p" "$a" projects describe "$p" --format='value(projectNumber)')"
  [[ "$num" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot read the project number of $p as $a"; return 1; }
  sa="$num-compute@developer.gserviceaccount.com"
  spl_csa_g "$p" "$a" projects get-iam-policy "$p" --format=json >"$d/policy.json" ||
    { do_log "FATAL cannot read the IAM policy of $p"; return 1; }
  if ! spl_csa_holds_editor "$d/policy.json" "$sa"; then
    do_log "OK $p: $sa holds no unconditional roles/editor; nothing to drop"
    return 0
  fi
  spl_csa_measure "$p" "$a" "$sa" "$days" "$d" || return 1
  local cmd=(gcloud projects remove-iam-policy-binding "$p" --member="serviceAccount:$sa" --role=roles/editor --condition=None --account="$a")
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: ${cmd[*]}"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0 to drop the binding."
    return 0
  fi
  "${cmd[@]}" --quiet </dev/null >/dev/null || { do_log "FATAL remove-iam-policy-binding failed"; return 1; }
  spl_csa_g "$p" "$a" projects get-iam-policy "$p" --format=json >"$d/after.json" || { do_log "ERROR cannot re-read the policy"; return 1; }
  spl_csa_holds_editor "$d/after.json" "$sa" && { do_log "ERROR $sa still holds roles/editor"; return 1; }
  do_log "OK dropped roles/editor from $sa in $p; undo: gcloud projects add-iam-policy-binding $p --member=serviceAccount:$sa --role=roles/editor --condition=None"
}

# spl_csa_g <project> <account> <gcloud args...> - one pinned, non-interactive
# call (a disabled API asks "enable it?" on a tty otherwise).
spl_csa_g() {
  local p="$1" a="$2"; shift 2
  gcloud "$@" --project="$p" --account="$a" --quiet </dev/null
}

# spl_csa_holds_editor <policy.json> <sa> - succeed when the SA holds
# roles/editor without a condition.
spl_csa_holds_editor() {
  python3 - "$1" "serviceAccount:$2" <<'PY'
import json, sys
pol, m = json.load(open(sys.argv[1])), sys.argv[2]
sys.exit(0 if any(b.get("role") == "roles/editor" and not b.get("condition") and m in b.get("members", [])
                  for b in pol.get("bindings", [])) else 1)
PY
}

# spl_csa_measure <project> <account> <sa> <days> <dir> - dump each source,
# print one count per source, refuse (exit 1) on any use or an unreadable log.
spl_csa_measure() {
  local p="$1" a="$2" sa="$3" days="$4" d="$5" since apis
  since="$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%SZ)"
  apis="$(spl_csa_g "$p" "$a" services list --enabled --format='value(config.name)')" ||
    { do_log "FATAL cannot list the enabled APIs of $p"; return 1; }
  spl_csa_g "$p" "$a" run services list --format=json >"$d/run.json" || { do_log "FATAL cannot list Cloud Run services"; return 1; }
  spl_csa_g "$p" "$a" run jobs list --format=json >"$d/jobs.json" || { do_log "FATAL cannot list Cloud Run jobs"; return 1; }
  spl_csa_g "$p" "$a" compute instances list --format=json >"$d/vms.json" || { do_log "FATAL cannot list VM instances"; return 1; }
  echo '[]' >"$d/fns.json"; echo '[]' >"$d/builds.json"
  if grep -qx cloudfunctions.googleapis.com <<<"$apis"; then
    spl_csa_g "$p" "$a" functions list --format=json >"$d/fns.json" || { do_log "FATAL cannot list Cloud Functions"; return 1; }
  fi
  if grep -qx cloudbuild.googleapis.com <<<"$apis"; then
    spl_csa_g "$p" "$a" builds list --limit=200 --format=json >"$d/builds.json" || { do_log "FATAL cannot list Cloud Builds"; return 1; }
  fi
  spl_csa_g "$p" "$a" iam service-accounts keys list --iam-account="$sa" --managed-by=user --format=json >"$d/keys.json" ||
    { do_log "FATAL cannot list the keys of $sa"; return 1; }
  spl_csa_g "$p" "$a" logging read "protoPayload.authenticationInfo.principalEmail=\"$sa\" AND timestamp>=\"$since\"" \
    --limit=50 --format=json >"$d/audit.json" || { do_log "FATAL cannot read the audit log"; return 1; }
  spl_csa_g "$p" "$a" logging read "logName:\"cloudaudit.googleapis.com\" AND timestamp>=\"$since\"" \
    --limit=1 --format=json >"$d/control.json" || { do_log "FATAL cannot read the audit log (control)"; return 1; }
  python3 - "$d" "$sa" "$days" "$apis" <<'PY'
import json, os, sys
d, sa, days, apis = sys.argv[1:]
ld = lambda f: json.load(open(os.path.join(d, f))) or []
def spec(o, *ks):
    for k in ks:
        o = (o or {}).get(k, {})
    return o or ""
use = {
  "Cloud Run services": [s["metadata"]["name"] for s in ld("run.json") if spec(s, "spec", "template", "spec", "serviceAccountName") in ("", sa)],
  "Cloud Run jobs": [j["metadata"]["name"] for j in ld("jobs.json") if spec(j, "spec", "template", "spec", "template", "spec", "serviceAccountName") in ("", sa)],
  "VM instances": [v["name"] for v in ld("vms.json") if sa in [x.get("email") for x in v.get("serviceAccounts", [])]],
  "Cloud Functions": [f["name"] for f in ld("fns.json") if f.get("serviceAccountEmail", f.get("serviceConfig", {}).get("serviceAccountEmail")) == sa],
  "Cloud Builds": [b["id"] for b in ld("builds.json") if sa in (b.get("serviceAccount") or "")],
  "user-managed keys": [k["name"].split("/")[-1][:8] for k in ld("keys.json")],
  f"audit rows as caller, {days} d": [r.get("timestamp", "") for r in ld("audit.json")],
}
off = [a for a in ("cloudfunctions.googleapis.com", "cloudbuild.googleapis.com") if a not in apis.split()]
for k, v in use.items():
    print(f"INFO {sa}: {k}: {len(v)}" + (f" ({', '.join(v[:5])})" if v else ""))
if off: print(f"INFO API disabled, so 0: {', '.join(off)}")
if not ld("control.json"):
    print(f"FATAL the audit log returned no row at all in {days} d: unreadable, so 0 proves nothing; refusing"); sys.exit(1)
n = sum(len(v) for v in use.values())
if n:
    print(f"FATAL {sa} is in use ({n}): refusing to drop roles/editor"); sys.exit(1)
print(f"OK {sa}: nothing uses it (control: the audit log is readable)")
PY
}
