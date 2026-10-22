#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the four read-only gcp actions that run as each env's OWN project SA
#          (do_gcp_list_monitoring, do_gcp_list_secrets,
#          do_gcp_list_alert_incidents, do_gcp_get_alert_incident) find that SA
#          key from the PROJECT (do_gcp_sa_key_file), never from the checkout
#          dir name (SPL-2937). ./run sets APP from the checkout dir, so from a
#          checkout named <org>-<app>-desk-cron APP is that name, and the old
#          key-<org>-${APP#<org>-}-<env>.json does not exist.
#   1. per action, ORG/APP as ./run sets them in a checkout-like dir: the run
#      uses $HOME/.gcp/.csi/key-csi-spl-<env>.json, as its SA, on its project
#   2. ORG/APP are unchanged for the caller afterwards
#   3. CONTROL: the same run with no key for that project still refuses
#   4. a one-project pin (PROJ_ID) over several envs refuses; with one ENV it
#      names the key, as in do_gcp_account
# Nothing reaches GCP: gcloud is a stub on PATH, and the alert actions' per-env
# readers (which run gcloud, curl and python) are replaced after sourcing.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN_DIR="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

# a checkout NOT named <org>-<app>: ./run gives APP_PATH's basename as APP
CO="$T/co/csi-spl-desk-cron"
mkdir -p "$T/bin" "$T/home/.gcp/.csi" "$CO/csi-spl-iac"
cat >"$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-<unset>}|$*" >>"$GC_CALLS"
STUB
chmod +x "$T/bin/gcloud"
for e in dev prd; do
  printf '{"client_email":"sa-%s@csi-spl-%s.iam.gserviceaccount.com","project_id":"csi-spl-%s"}\n' "$e" "$e" "$e" \
    >"$T/home/.gcp/.csi/key-csi-spl-$e.json"
done

# run_action <func> <action file> <env assignments...> -> rc; output in $T/out.log
run_action() {
  local fn="$1" file="$2"; shift 2
  : >"$T/calls.log"
  env -u ENV -u CLOUDSDK_CONFIG -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT -u GCP_SA_KEY_FILE \
    PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" ACTION="$RUN_DIR/$file" FN="$fn" \
    PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" OAP="$PROJ_ROOT/lib/bash/funcs/resolve-oap.func.sh" \
    HOME="$T/home" ORG=csi APP=csi-spl-desk-cron APP_PATH="$CO" PROJ_PATH="$CO/csi-spl-iac" "$@" \
    bash -c 'source "$PIN"; source "$OAP"; do_log(){ echo "$*"; }; do_require_var(){ [[ -n "$2" ]] || exit 1; }
      do_gcp_log_identity(){ echo "identity $1 $2"; }
      source "$ACTION"
      gcp_alert_incidents_env(){ echo "reader key=$1 project=$2 account=$3"; }
      gcp_alert_incident_env(){ echo "reader key=$1 project=$2 account=$3"; }
      "$FN"; rc=$?; echo "after ORG=$ORG APP=$APP"; exit $rc' >"$T/out.log" 2>&1
}

key_prd="$T/home/.gcp/.csi/key-csi-spl-prd.json"
want_id="identity csi-spl-prd sa-prd@csi-spl-prd.iam.gserviceaccount.com"

for spec in \
  "do_gcp_list_monitoring gcp-list-monitoring.func.sh" \
  "do_gcp_list_secrets gcp-list-secrets.func.sh" \
  "do_gcp_list_alert_incidents gcp-list-alert-incidents.func.sh" \
  "do_gcp_get_alert_incident gcp-get-alert-incident.func.sh"; do
  read -r fn file <<<"$spec"
  # --- 1. from the checkout-like dir --------------------------------------------
  run_action "$fn" "$file" ENV=prd POLICY='p 1' OPENED=2026-10-22T09:31Z; rc=$?
  used=$( { cut -d'|' -f1 "$T/calls.log"; sed -n 's/^reader key=\([^ ]*\) .*/\1/p' "$T/out.log"; } | grep -v '^$' | sort -u)
  [[ $rc -eq 0 && "$used" == "$key_prd" ]] && grep -qxF "$want_id" "$T/out.log" \
    && pass "$fn: APP=csi-spl-desk-cron -> the project key key-csi-spl-prd.json, as its SA" \
    || fail "$fn: rc=$rc used='$used' out=$(tr '\n' ' ' <"$T/out.log")"
  # --- 2. the caller's ORG/APP ---------------------------------------------------
  grep -qxF "after ORG=csi APP=csi-spl-desk-cron" "$T/out.log" \
    && pass "$fn: the caller's ORG/APP are unchanged" || fail "$fn: ORG/APP changed: $(grep '^after' "$T/out.log")"
  # --- 3. CONTROL: no key for the project ---------------------------------------
  mv "$key_prd" "$T/away.json"
  run_action "$fn" "$file" ENV=prd POLICY='p 1' OPENED=2026-10-22T09:31Z; rc=$?
  mv "$T/away.json" "$key_prd"
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && ! grep -q '^reader ' "$T/out.log" \
    && pass "$fn: CONTROL no project key -> refused, nothing read" || fail "$fn CONTROL: rc=$rc out=$(tr '\n' ' ' <"$T/out.log")"
done

# --- 4. a one-project pin over several envs refuses; over one env it is used ---
for fn_file in "do_gcp_list_monitoring gcp-list-monitoring.func.sh" "do_gcp_list_secrets gcp-list-secrets.func.sh" \
  "do_gcp_list_alert_incidents gcp-list-alert-incidents.func.sh"; do
  read -r fn file <<<"$fn_file"
  run_action "$fn" "$file" GCP_LIST_ENVS="dev prd" PROJ_ID=csi-spl-prd; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && ! grep -q '^reader ' "$T/out.log" && grep -q 'name one project' "$T/out.log" \
    && pass "$fn: PROJ_ID over 'dev prd' -> refused, nothing read" || fail "$fn pin: rc=$rc out=$(tr '\n' ' ' <"$T/out.log")"
  run_action "$fn" "$file" ENV=dev PROJ_ID=csi-spl-prd; rc=$?
  [[ $rc -eq 0 ]] && grep -qxF "$want_id" "$T/out.log" \
    && pass "$fn: PROJ_ID with one ENV -> that project's key, as do_gcp_account" || fail "$fn pin one: rc=$rc out=$(tr '\n' ' ' <"$T/out.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
