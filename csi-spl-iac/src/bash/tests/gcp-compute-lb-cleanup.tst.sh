#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_compute_lb_cleanup is a destructive action; it deletes the
#          env's WUI load balancer parts, in dependency order, as the env's
#          project SA, in a private gcloud config (test round 1 row 08,
#          SPL-2256).
#   1. defaults: the 8 `compute ... delete` calls, each with --quiet,
#      --account=<the env SA> and --project=<org>-<app>-<env>; the global
#      ones (forwarding rules, url maps) with --global
#   2. dependency order: forwarding rules < proxies < url maps < backend
#      bucket < ssl certificate
#   3. the bucket is kept by default: no `storage rm`, the skip is printed
#   4. every gcloud call in one private CLOUDSDK_CONFIG, removed afterwards
#   5. DELETE_BUCKET=true -> one `storage rm -r gs://<org>-<app>-<env>-site-static`
#      with --account=<the env SA>
#   6. one part already gone -> logged "Not found", the rest still deleted
#   7. ENV empty -> refused ("ENV is required"), no `gcloud compute` call
#   8. ORG_APP empty -> refused ("ORG_APP is required"), no `gcloud compute`
#   9. CONTROL: no key, no ACCOUNT -> refused, no `gcloud compute` call
# The action has NO DRY_RUN guard today: a default run deletes the 8 parts.
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-compute-lb-cleanup.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
P=csi-spl-dev-wui
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/tmp"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; a key that is not a file
# fails the activate, as real gcloud does; deleting $STUB_GONE fails
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*)
    k=$(arg --key-file "$@"); [[ -f "$k" ]] || exit 1
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "compute "*" delete ${STUB_GONE:-<none>} "*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u PROJ_ID -u GCP_SA_KEY_FILE -u DELETE_BUCKET \
    HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" ORG=csi APP=spl ENV=dev ORG_APP=csi-spl "$@" bash -c '
    do_log() { echo "$*"; }; log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }
    quit_on() { rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Error: Failed to $1"; exit $rv; fi; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-compute-lb-cleanup.func.sh; do source "$f"; done
    do_gcp_compute_lb_cleanup' >"$T/out" 2>&1
}
deletes() { grep '|compute .* delete ' "$T/calls.log" | cut -d'|' -f2-; }
compute_calls() { grep -c '|compute ' "$T/calls.log"; }
WANT=(
  "forwarding-rules delete $P-http-forwarding --global"
  "forwarding-rules delete $P-https-forwarding --global"
  "target-http-proxies delete $P-http-proxy"
  "target-https-proxies delete $P-https-proxy"
  "url-maps delete $P-http-redirect --global"
  "url-maps delete $P-https-url-map --global"
  "backend-buckets delete $P-backend"
  "ssl-certificates delete $P-ssl-cert"
)

# --- 1. defaults: 8 deletes, flags pinned -------------------------------------
act; rc=$?
[[ $rc -eq 0 && "$(deletes | wc -l)" -eq 8 ]] && pass "1. 8 delete calls, rc 0" || fail "1. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
bad=$(deletes | grep -v -- " --quiet" ; deletes | grep -v -- " --account=$DEV_SA"; deletes | grep -v -- " --project=csi-spl-dev")
[[ -z "$bad" ]] && pass "1. every delete carries --quiet, --account=<env SA> and --project" || fail "1. flags: $bad"

# --- 2. dependency order ------------------------------------------------------
order_ok=1; i=0
while IFS= read -r line; do
  [[ "$line" == "compute ${WANT[$i]} "* ]] || { order_ok=0; fail "2. call $((i+1)): want 'compute ${WANT[$i]} ...', got '$line'"; }
  i=$((i + 1))
done < <(deletes)
[[ $order_ok -eq 1 && $i -eq 8 ]] && pass "2. the 8 parts, named <org>-<app>-<env>-wui-*, in dependency order"

# --- 3. the bucket is kept by default ----------------------------------------
! grep -q '|storage ' "$T/calls.log" && grep -q 'Skipping storage bucket deletion' "$T/out" \
  && pass "3. DELETE_BUCKET unset: no storage rm, the skip is printed" || fail "3. $(grep '|storage ' "$T/calls.log")"

# --- 4. private gcloud config ------------------------------------------------
cfgs=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ -n "$cfgs" && "$(wc -l <<<"$cfgs")" -eq 1 && "$cfgs" != "<unset>" && "$cfgs" != "$T/home/.config/gcloud" ]] \
  && pass "4. every call in one private CLOUDSDK_CONFIG" || fail "4. configs: '$cfgs'"
[[ ! -e "$cfgs" && ! -e "$T/home/.config/gcloud" ]] \
  && pass "4. the private config is removed afterwards; ~/.config/gcloud untouched" || fail "4. left: '$cfgs'"

# --- 5. DELETE_BUCKET=true ---------------------------------------------------
act DELETE_BUCKET=true; rc=$?
s=$(grep '|storage ' "$T/calls.log" | cut -d'|' -f2-)
[[ $rc -eq 0 && "$(grep -c . <<<"$s")" -eq 1 && "$s" == "storage rm -r gs://csi-spl-dev-site-static --account=$DEV_SA" ]] \
  && pass "5. DELETE_BUCKET=true: one storage rm of the env's site bucket, as the env SA" || fail "5. rc=$rc '$s'"

# --- 6. one part already gone ------------------------------------------------
act STUB_GONE="$P-http-proxy"; rc=$?
[[ $rc -eq 0 && "$(deletes | wc -l)" -eq 8 ]] && grep -q "WARN Not found: $P-http-proxy" "$T/out" \
  && grep -q "INFO Deleted $P-ssl-cert" "$T/out" \
  && pass "6. a part already gone is logged Not found; the rest are still deleted" || fail "6. rc=$rc $(cat "$T/out")"

# --- 7. ENV empty ------------------------------------------------------------
act ENV= ACCOUNT="$DEV_SA"; rc=$?
[[ $rc -ne 0 && "$(compute_calls)" -eq 0 ]] && grep -q 'ENV is required' "$T/out" \
  && pass "7. ENV empty -> refused, no gcloud compute call" || fail "7. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 8. ORG_APP empty --------------------------------------------------------
act ORG_APP=; rc=$?
[[ $rc -ne 0 && "$(compute_calls)" -eq 0 ]] && grep -q 'ORG_APP is required' "$T/out" \
  && pass "8. ORG_APP empty -> refused, no gcloud compute call" || fail "8. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 9. CONTROL: no key ------------------------------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
act; rc=$?
[[ $rc -ne 0 && "$(compute_calls)" -eq 0 ]] && grep -q 'FATAL no gcloud account' "$T/out" \
  && pass "9. CONTROL: no key -> refused, no gcloud compute call" || fail "9. rc=$rc $(cat "$T/calls.log")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
