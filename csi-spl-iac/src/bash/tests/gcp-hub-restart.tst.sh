#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_hub_restart (the named action for the 2026-10-04 17:41Z ad
#          hoc prd recovery) forces a fresh hub revision only when told to,
#          as the env's project SA in a private gcloud config.
#   1. DRY_RUN unset: reads the service named by the cnf (hub.service_name,
#      gcp_region), every call as the env SA on the env project, NO update
#   2. DRY_RUN=0: one `run services update --update-env-vars=
#      SPOOL_HUB_RESTART_AT=<UTC ts>`, then prints the new ready revision and
#      a 200 from <service url>/v1/health
#   3. DRY_RUN=0, /v1/health never 200 -> non-zero, the code is named
#   4. DRY_RUN=0, no new ready revision -> non-zero, health not polled
#   5. DRY_RUN=2 -> refused before any gcloud call
#   6. CONTROL: no key -> refused, no `gcloud run` call at all
# gcloud, curl and sleep are stubs on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-hub-restart.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; the ready revision lives in
# $REV (an update bumps it unless STUB_NO_BUMP=1)
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "run services describe"*)
    if [[ "$*" == *status.url* ]]; then printf '%s\t%s\n' "$(cat "$REV")" "https://hub.example.com"; else cat "$REV"; fi ;;
  "run services update"*) [[ "${STUB_NO_BUMP:-0}" == 1 ]] || echo svc-00002-new >"$REV" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "curl|$*" >>"$STUB_LOG"; printf %%s "${CURL_CODE:-200}"\n' >"$T/stub/curl"
printf '#!/usr/bin/env bash\n:\n' >"$T/stub/sleep"
chmod +x "$T/stub/"*

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"; echo svc-00001-old >"$T/rev"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN HOME="$T/home" PATH="$T/stub:$PATH" \
    STUB_LOG="$T/calls.log" REV="$T/rev" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-hub-restart.func.sh; do source "$f"; done
    do_gcp_hub_restart' >"$T/out" 2>&1
}
run_calls() { grep -c '|run ' "$T/calls.log"; }
run_calls_as_sa() { grep '|run ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev'; }

# --- 1. dry run (the default) ---------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '|run services update' "$T/calls.log" && grep -q 'DRY_RUN would run' "$T/out" \
  && pass "1. DRY_RUN unset: no update, the update it would make is printed" || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
grep -q '|run services describe csi-spl-hub-dev --region=europe-north1 ' "$T/calls.log" \
  && pass "1. the service and region come from the dev cnf" || fail "1. describe: $(cat "$T/calls.log")"
[[ "$(run_calls)" -ge 1 && "$(run_calls)" == "$(run_calls_as_sa)" ]] \
  && pass "1. every gcloud run call as the dev project SA on csi-spl-dev" || fail "1. identity: $(cat "$T/calls.log")"
cfg=$(awk -F'|' '/\|run / {print $1; exit}' "$T/calls.log")
[[ "$cfg" != "<unset>" && "$cfg" != "$T/home/.config/gcloud" && ! -e "$cfg" && ! -e "$T/home/.config/gcloud" ]] \
  && pass "1. a private CLOUDSDK_CONFIG, removed afterwards; ~/.config/gcloud untouched" || fail "1. config: '$cfg'"

# --- 2. real run ----------------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(grep -c '|run services update' "$T/calls.log")" -eq 1 ]] \
  && grep -qE '\|run services update csi-spl-hub-dev .*--update-env-vars=SPOOL_HUB_RESTART_AT=[0-9]{8}T[0-9]{6}Z' "$T/calls.log" \
  && pass "2. DRY_RUN=0: exactly one update, SPOOL_HUB_RESTART_AT=<UTC ts>" || fail "2. update: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
[[ "$(run_calls)" == "$(run_calls_as_sa)" ]] && pass "2. the update ran as the dev project SA" || fail "2. identity: $(cat "$T/calls.log")"
grep -q 'new revision svc-00002-new (was svc-00001-old)' "$T/out" && grep -q 'curl|.*https://hub.example.com/v1/health' "$T/calls.log" \
  && grep -q '/v1/health 200 on revision svc-00002-new' "$T/out" \
  && pass "2. prints the new revision and /v1/health 200 from the service url" || fail "2. report: $(cat "$T/out")"

# --- 3. health never 200 --------------------------------------------------------------
act DRY_RUN=0 CURL_CODE=429 HEALTH_TRIES=3; rc=$?
[[ $rc -ne 0 && "$(grep -c '^curl|' "$T/calls.log")" -eq 3 ]] && grep -q 'answered 429 after 3 attempts' "$T/out" \
  && pass "3. /v1/health 429 x3 -> non-zero, the code is named" || fail "3. health: rc=$rc $(cat "$T/out")"

# --- 4. no new revision ---------------------------------------------------------------
act DRY_RUN=0 STUB_NO_BUMP=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no new ready revision' "$T/out" && ! grep -q '^curl|' "$T/calls.log" \
  && pass "4. no new ready revision -> non-zero, health not polled" || fail "4. no bump: rc=$rc $(cat "$T/out")"

# --- 5. bad DRY_RUN -------------------------------------------------------------------
act DRY_RUN=2; rc=$?
[[ $rc -eq 2 && ! -s "$T/calls.log" ]] && pass "5. DRY_RUN=2 refused before any gcloud call" || fail "5. rc=$rc $(cat "$T/calls.log")"

# --- 6. CONTROL: no key ---------------------------------------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
act DRY_RUN=0; rc=$?
[[ $rc -ne 0 && "$(run_calls)" -eq 0 ]] && pass "6. CONTROL: no key -> refused, no gcloud run call" || fail "6. rc=$rc $(cat "$T/calls.log")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
