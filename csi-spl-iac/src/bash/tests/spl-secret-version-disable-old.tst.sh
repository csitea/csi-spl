#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_version_disable_old (security round 1 row 6,
#          SPL-1967) disables only the OLDER enabled versions of one secret,
#          only when told, and never one the hub pins.
#   1. DRY_RUN unset: names version 1 by number and create date, keeps 2, NO
#      disable call; every call as the dev project SA on csi-spl-dev
#   2. DRY_RUN=0: one `versions disable 1 --secret=<s>`, checked DISABLED,
#      an undo line; never `versions access`
#   3. CONTROL: the hub pins the secret to version 1 -> refused, no disable
#      (fails when the pin check is removed)
#   4. one enabled version -> nothing to disable
#   5. a bad SECRET or DRY_RUN=2 -> refused before any gcloud call
#   6. the hub service unreadable -> refused, no disable
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-secret-version-disable-old.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
S=csi-spl-hub-stripe-secret-key
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
v() { printf '{"name":"projects/1/secrets/s/versions/%s","state":"%s","createTime":"%s"}' "$1" "$2" "$3"; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets versions list"*)
    if [[ -n "${STUB_ONE:-}" ]]; then echo "[$(v 1 ENABLED 2026-09-19T10:00:00Z)]"
    else echo "[$(v 2 ENABLED 2026-09-30T10:00:00Z),$(v 1 ENABLED 2026-09-19T10:00:00Z)]"; fi ;;
  "run services describe"*) [[ -n "${STUB_NO_HUB:-}" ]] && exit 1
    printf '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"X","value":"y"},{"name":"SPOOL_HUB_STRIPE_SECRET_KEY","valueFrom":{"secretKeyRef":{"name":"csi-spl-hub-stripe-secret-key","key":"%s"}}}]}]}}}}\n' "${STUB_PIN:-latest}" ;;
  "secrets versions describe"*) echo DISABLED ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev SECRET="$S" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-secret-version-disable-old.func.sh; do source "$f"; done
    do_spl_secret_version_disable_old' >"$T/out" 2>&1
}
disables() { grep -c '|secrets versions disable' "$T/calls.log"; }

# --- 1. dry run ----------------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 && $(disables) -eq 0 ]] && grep -q "would disable csi-spl-dev $S version 1 (created 2026-09-19); keeps version 2 (created 2026-09-30)" "$T/out" \
  && pass "1. DRY_RUN unset: version 1 named by number and date, version 2 kept, no disable" || fail "1. rc=$rc $(cat "$T/out")"
grep -q 'the hub reads csi-spl-hub-stripe-secret-key at: latest' "$T/out" && pass "1. says how the hub reads it" || fail "1. hub line"
grep -q '|run services describe csi-spl-hub-dev --region=europe-north1 ' "$T/calls.log" && pass "1. the hub service and region come from the dev cnf" || fail "1. describe: $(cat "$T/calls.log")"
n=$(grep -cE '\|(secrets|run) ' "$T/calls.log"); m=$(grep -E '\|(secrets|run) ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -ge 2 && $n -eq $m ]] && pass "1. every call as the dev project SA on csi-spl-dev" || fail "1. identity $n/$m"

# --- 2. real run -----------------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc -eq 0 && $(disables) -eq 1 ]] && grep -q "|secrets versions disable 1 --secret=$S --project=csi-spl-dev --account=$DEV_SA" "$T/calls.log" \
  && pass "2. DRY_RUN=0: exactly one disable, of version 1" || fail "2. rc=$rc $(cat "$T/calls.log")"
grep -q "OK disabled csi-spl-dev $S version 1 (created 2026-09-19); undo: gcloud secrets versions enable 1 --secret=$S --project=csi-spl-dev" "$T/out" \
  && pass "2. checked DISABLED, with its undo line" || fail "2. out: $(cat "$T/out")"
! grep -q 'versions access' "$T/calls.log" && pass "2. no versions access: no value is read" || fail "2. a value was read"

# --- 3. CONTROL: the hub pins version 1 --------------------------------------------------
act DRY_RUN=0 STUB_PIN=1; rc=$?
[[ $rc -ne 0 && $(disables) -eq 0 ]] && grep -q 'pins csi-spl-hub-stripe-secret-key to version 1' "$T/out" \
  && pass "3. CONTROL: hub pins version 1 -> refused, no disable" || fail "3. rc=$rc $(cat "$T/out")"
act DRY_RUN=0 STUB_PIN=2; rc=$?
[[ $rc -eq 0 && $(disables) -eq 1 ]] && pass "3. a pin on the KEPT version 2 is fine" || fail "3. pin 2: rc=$rc $(cat "$T/out")"

# --- 4. one enabled version --------------------------------------------------------------
act DRY_RUN=0 STUB_ONE=1; rc=$?
[[ $rc -eq 0 && $(disables) -eq 0 ]] && grep -q 'nothing to disable' "$T/out" && pass "4. one enabled version -> nothing to disable" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5. bad input ----------------------------------------------------------------------
act SECRET='a b'; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "5. a bad SECRET -> refused, no gcloud call" || fail "5. secret: rc=$rc"
act DRY_RUN=2; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "5. DRY_RUN=2 -> refused, no gcloud call" || fail "5. dry=2: rc=$rc"

# --- 6. hub unreadable ---------------------------------------------------------------------
act DRY_RUN=0 STUB_NO_HUB=1; rc=$?
[[ $rc -ne 0 && $(disables) -eq 0 ]] && grep -q 'refusing without the pin check' "$T/out" && pass "6. hub unreadable -> refused, no disable" || fail "6. rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
