#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: prove the three shared bodies of refactor item 3 (CLE-77915) and the
#          actions folded onto them, by CALLING each action against a stubbed
#          gcloud / terraform and reading the recorded argv. HOME is a temp dir,
#          so no real key is read and nothing reaches GCP.
#            do_gcp_each_env_sa  <- the 7 do_gcp_list_* actions
#            do_gcp_project_apis <- do_gcp_{,modify_}project_apis_{enable,disable}
#            do_tf_each_target   <- do_tf_{taint,untaint}_target, do_tf_state_show
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
LIB="$PROJ_ROOT/lib/bash/funcs"
T=$(mktemp -d); trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT

fails=0

LISTS=(cloudsql buckets firewall-rules scheduler-jobs static-dns-addresses service-accounts vpcs)
APIS=(project-apis-enable project-apis-disable modify-project-apis-enable modify-project-apis-disable)
TFS=(tf-taint-target tf-untaint-target tf-state-show)
for f in "$LIB"/gcp-each-env-sa.func.sh "$LIB"/gcp-project-apis.func.sh "$LIB"/tf-each-target.func.sh \
         "${LISTS[@]/#/$RUN/gcp-list-}" "${APIS[@]/#/$RUN/gcp-}" "${TFS[@]/#/$RUN/}"; do
  f="${f%.func.sh}.func.sh"
  bash -n "$f" && pass "bash -n $(basename "$f")" || fail "bash -n $(basename "$f")"
done

# run_fn <fn> <log> [VAR=value ...] — the action's stdout+stderr lands in <log>.out
run_fn() {
  local fn="$1" log="$2"; shift 2
  : >"$log"
  env -u CLOUDSDK_CONFIG FN="$fn" LOG="$log" RUN="$RUN" LIB="$LIB" HOME="$T/home" APP_PATH="$T/app" \
      ORG=csi APP=spl ENV=dev ACCOUNT=stub-sa@example.com GCP_BILLING_ACCOUNT_ID=000000-000000-000000 "$@" \
  bash <<'INNER'
    quit_on(){ rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Failed to $1"; exit $rv; fi; }
    do_require_var() { [[ -n "${2:-}" ]] || { echo "FATAL $1 empty"; exit 1; }; }
    do_log()         { echo "$*"; }
    do_simple_log()  { echo "$*"; }
    do_resolve_oap() { export ORG=csi APP=spl; }   # as from csi-spl-iac
    do_tf_init()     { tf_run_path="$HOME/tfrun"; tf_proj=stub; mkdir -p "$tf_run_path"; }
    gcloud() {
      echo "gcloud $* CLOUDSDK_CONFIG=${CLOUDSDK_CONFIG:-<unset>}" >>"$LOG"
      case "$*" in
        "auth list"*) echo "sa-of-active@example.com" ;;
        "auth activate-service-account"*) [[ -f "${3#--key-file=}" ]] ;;
        *) return 0 ;;
      esac
    }
    gsutil()    { :; }
    terraform() { echo "terraform $*" >>"$LOG"; }
    for f in "$LIB"/gcp-account-pin.func.sh "$LIB"/gcp-each-env-sa.func.sh "$LIB"/gcp-project-apis.func.sh \
             "$LIB"/tf-each-target.func.sh "$RUN"/gcp-list-*.func.sh "$RUN"/gcp-*project-apis-*.func.sh \
             "$RUN"/tf-taint-target.func.sh "$RUN"/tf-untaint-target.func.sh "$RUN"/tf-state-show.func.sh; do
      source "$f"
    done
    "$FN" >"$LOG.out" 2>&1
    rc=$?
    echo "AFTER CLOUDSDK_CONFIG=${CLOUDSDK_CONFIG:-<unset>}" >>"$LOG.out"
    exit $rc
INNER
}

# --- do_gcp_each_env_sa: keys for dev and prd only --------------------------------
mkdir -p "$T/home/.gcp/.csi"
echo '{}' >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
echo '{}' >"$T/home/.gcp/.csi/key-csi-spl-prd.json"
declare -A VERB=([cloudsql]="sql instances list" [buckets]="storage buckets list" [firewall-rules]="compute firewall-rules list"
  [scheduler-jobs]="scheduler jobs list" [static-dns-addresses]="compute addresses list"
  [service-accounts]="iam service-accounts list" [vpcs]="compute networks list")
log="$T/l.log"
for l in "${LISTS[@]}"; do
  fn="do_gcp_list_${l//-/_}"
  run_fn "$fn" "$log"; rc=$?
  calls=$(grep -c "^gcloud ${VERB[$l]} " "$log")
  unpinned=$(grep "^gcloud ${VERB[$l]} " "$log" | grep -vcE -- '--account=sa-of-active@example.com .*--project=csi-spl-(dev|prd)|--project=csi-spl-(dev|prd).*--account=sa-of-active@example.com' || true)
  [[ $rc -eq 0 && $calls -eq 2 && $unpinned -eq 0 ]] \
    && pass "$fn: one '${VERB[$l]}' per env with a key (dev, prd), each --account + --project pinned" \
    || fail "$fn: rc=$rc calls=$calls unpinned=$unpinned: $(cat "$log")"
  grep -q 'key-csi-spl-all.json not found' "$log.out" && grep -q 'key-csi-spl-stg.json not found' "$log.out" \
    && pass "$fn: an env without a key is reported and skipped" || fail "$fn: missing-key envs not reported: $(cat "$log.out")"
  ! grep -qE 'CLOUDSDK_CONFIG=(<unset>|.*/\.config/gcloud)' "$log" && grep -q '^AFTER CLOUDSDK_CONFIG=<unset>$' "$log.out" \
    && pass "$fn: every gcloud call runs in a throwaway CLOUDSDK_CONFIG, restored after" || fail "$fn: CLOUDSDK_CONFIG leaked: $(grep -h CLOUDSDK "$log" "$log.out")"
done
run_fn do_gcp_list_service_accounts "$log"
[[ $(grep -c -- 'beta iam service-accounts list --include-managed-service-accounts --account=' "$log") -eq 2 ]] \
  && pass "service-accounts also lists the google-managed ones per env" || fail "service-accounts beta list: $(cat "$log")"
run_fn do_gcp_list_vpcs "$log"
rep="$T/app/spl-cnf/spl/gcp/networking-report.txt"
[[ $(grep -c 'networks peerings describe peer-csi-spl-\(dev\|prd\)-to-all-back' "$log") -eq 2 ]] && grep -q '^START ::: csi-spl-prd' "$rep" \
  && pass "vpcs checks each env's peering and writes the report" || fail "vpcs: $(cat "$log") / $(cat "$rep" 2>/dev/null)"
run_fn do_gcp_list_scheduler_jobs "$log" LOCATION=europe-north1
grep -q -- '--location=europe-north1' "$log" && pass "scheduler-jobs honours LOCATION" || fail "scheduler LOCATION: $(cat "$log")"
run_fn do_gcp_list_buckets "$log" GCP_EACH_ENVS=prd
[[ $(grep -c '^gcloud storage buckets list' "$log") -eq 1 ]] && pass "GCP_EACH_ENVS narrows the envs" || fail "GCP_EACH_ENVS: $(cat "$log")"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$LIB"'/gcp-each-env-sa.func.sh"; do_gcp_each_env_sa nosuchfn' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"give a callback"* ]] && pass "CONTROL: do_gcp_each_env_sa refuses a missing callback" || fail "callback refusal: rc=$rc $out"

# --- do_gcp_project_apis: verb + the action's exact list --------------------------
declare -A NSVC=([project-apis-enable]=12 [project-apis-disable]=11 [modify-project-apis-enable]=13 [modify-project-apis-disable]=11)
for a in "${APIS[@]}"; do
  fn="do_gcp_${a//-/_}"; verb="${a##*-}"
  run_fn "$fn" "$log"; rc=$?
  line=$(grep "^gcloud services ${verb} " "$log")
  n=$(grep -o '[a-z0-9]*\.googleapis\.com' <<<"$line" | wc -l)
  [[ $rc -eq 0 && $n -eq ${NSVC[$a]} && "$line" == *"--project csi-spl-dev --account=sa-of-active@example.com"* ]] \
    && pass "$fn: services $verb with its ${NSVC[$a]} APIs, pinned to csi-spl-dev" || fail "$fn: rc=$rc n=$n line='$line'"
  grep -q "account=stub-sa@example.com — pinned per invocation.*($fn)" "$log.out" \
    && pass "$fn: logs the identity under its own name" || fail "$fn identity log: $(cat "$log.out")"
done
run_fn do_gcp_project_apis_enable "$log"
grep -q 'cloudrun.googleapis.com' "$log" && ! grep -q 'compute.googleapis.com' "$log" \
  && pass "project-apis-enable keeps its list (cloudrun, no compute)" || fail "enable list drifted: $(cat "$log")"
out=$(bash -c 'do_log(){ echo "$*"; }; source "'"$LIB"'/gcp-project-apis.func.sh"; do_gcp_project_apis wipe x a.googleapis.com' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"enable or disable"* ]] && pass "CONTROL: do_gcp_project_apis refuses any verb but enable/disable" || fail "verb refusal: rc=$rc $out"

# --- do_tf_each_target: every comma-separated address -----------------------------
declare -A TFV=([tf-taint-target]="taint -lock=false -allow-missing" [tf-untaint-target]="untaint -lock=false -allow-missing" [tf-state-show]="state show")
for t in "${TFS[@]}"; do
  fn="do_${t//-/_}"
  run_fn "$fn" "$log" STEP=001-x TARGET='a.b,c.d'; rc=$?
  [[ $rc -eq 0 && $(grep -c "^terraform -chdir=.* init -backend-config=" "$log") -eq 1 \
     && $(grep -cE "^terraform -chdir=.* ${TFV[$t]} (a\.b|c\.d)$" "$log") -eq 2 && ! -d "$T/home/tfrun" ]] \
    && pass "$fn: one init, '${TFV[$t]}' on each of 2 targets, run dir removed" || fail "$fn: rc=$rc $(cat "$log")"
done
run_fn do_tf_taint_target "$log" STEP=001-x; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^terraform' "$log" && pass "CONTROL: no TARGET -> refused before terraform" || fail "TARGET guard: rc=$rc $(cat "$log")"

echo
if (( fails )); then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all gcp-tf-shared-bodies checks"
