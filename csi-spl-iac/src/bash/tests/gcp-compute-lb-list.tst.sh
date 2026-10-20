#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_compute_lb_list is read-only; it lists the env's WUI load
#          balancer parts as the env's project SA, in a private gcloud config
#          (test round 2 row 08, SPL-2673). It creates nothing: no load
#          balancer is built (owner 2026-10-07, spec 105).
#   1. the 6 `compute ... list` calls, each with --filter=name~<org>-<app>-<env>-wui,
#      --account=<the env SA> and --project=<org>-<app>-<env>; forwarding
#      rules with --global; no create, delete or update call at all
#   2. the storage bucket describe of gs://<org>-<app>-<env>-site-static
#      with --account=<the env SA>
#   3. every gcloud call in one private CLOUDSDK_CONFIG, removed afterwards;
#      ~/.config/gcloud untouched
#   4. the identity log names the project and the env SA; every log line
#      goes through do_log (the run framework has no log_info / log_error)
#   5. a kind that fails to list -> "None found", the rest still listed, rc 0
#   6. ENV empty -> refused ("ENV is required"), no gcloud call, no private
#      config dir left behind
#   7. ORG_APP empty -> the same
#   8. CONTROL: no key, no ACCOUNT -> refused, no `gcloud compute` call
#   9. CONTROL: the checks of 1 and 6 catch a planted copy of the action
#      that drops --account from one call / defaults ENV to dev
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-compute-lb-list.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
P=csi-spl-dev-wui
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/tmp"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; a key that is not a file
# fails the activate, as real gcloud does; listing kind $STUB_GONE fails
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*)
    k=$(arg --key-file "$@"); [[ -f "$k" ]] || exit 1
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "compute ${STUB_GONE:-<none>} list "*) exit 1 ;;
  "compute "*" list "*) echo "LISTED $2" ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log, the
# private config dirs land in $T/tmp. LB_ACTION (default the real action)
# lets case 9 drive a planted copy.
act() {
  : >"$T/calls.log"; rm -rf "${T:?}/tmp"; mkdir -p "$T/tmp"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u PROJ_ID -u GCP_SA_KEY_FILE \
    HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" LB_ACTION="${LB_ACTION:-$ACTION}" APP_PATH="$T" ORG=csi APP=spl ENV=dev ORG_APP=csi-spl "$@" bash -c '
    do_log() { echo "$*"; }
    quit_on() { rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Error: Failed to $1"; exit $rv; fi; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$LB_ACTION"; do source "$f"; done
    do_gcp_compute_lb_list' >"$T/out" 2>&1
}
lists() { grep '|compute .* list ' "$T/calls.log" | cut -d'|' -f2-; }
compute_calls() { grep -c '|compute ' "$T/calls.log"; }
KINDS=(forwarding-rules target-http-proxies target-https-proxies url-maps backend-buckets ssl-certificates)

# check_flags -> the list calls missing a pinned flag; empty when all carry them
check_flags() {
  lists | grep -v -- " --account=$DEV_SA"
  lists | grep -v -- " --project=csi-spl-dev"
  lists | grep -v -- " --filter=name~$P"
}
# check_refused <var> -> why the last run was not a clean refusal; empty when it was
check_refused() {
  [[ $rc -ne 0 ]] || echo "rc=0"
  [[ ! -s "$T/calls.log" ]] || echo "gcloud called: $(cat "$T/calls.log")"
  grep -q "$1 is required" "$T/out" || echo "no '$1 is required' in: $(cat "$T/out")"
  [[ -z "$(ls -A "$T/tmp")" ]] || echo "private config left: $(ls -A "$T/tmp")"
}

# --- 1. the 6 list calls, flags pinned, nothing mutated ----------------------
act; rc=$?
got=$(lists | awk '{print $2}')
[[ $rc -eq 0 && "$got" == "$(printf '%s\n' "${KINDS[@]}")" ]] && pass "1. 6 compute list calls in order, rc 0" \
  || fail "1. rc=$rc kinds='$got' $(cat "$T/out")"
bad=$(check_flags)
[[ -z "$bad" ]] && pass "1. every list carries --account=<env SA>, --project and --filter=name~$P" || fail "1. flags: $bad"
lists | grep '^compute forwarding-rules list --global ' >/dev/null && pass "1. forwarding rules listed --global" \
  || fail "1. forwarding rules: $(lists | sed -n 1p)"
mut=$(cut -d'|' -f2- "$T/calls.log" | grep -v '^config set project ' | grep -E ' (create|delete|update|add-[a-z-]+|remove-[a-z-]+|set-[a-z-]+) ')
[[ -z "$mut" ]] && pass "1. no create, delete or update call" || fail "1. mutating call: $mut"

# --- 2. the site bucket ------------------------------------------------------
s=$(grep '|storage ' "$T/calls.log" | cut -d'|' -f2-)
[[ "$(grep -c . <<<"$s")" -eq 1 && "$s" == "storage buckets describe gs://csi-spl-dev-site-static --format=value(name) --account=$DEV_SA" ]] \
  && pass "2. one storage describe of the env's site bucket, as the env SA" || fail "2. '$s'"

# --- 3. private gcloud config ------------------------------------------------
cfgs=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ -n "$cfgs" && "$(wc -l <<<"$cfgs")" -eq 1 && "$cfgs" != "<unset>" && "$cfgs" != "$T/home/.config/gcloud" ]] \
  && pass "3. every call in one private CLOUDSDK_CONFIG" || fail "3. configs: '$cfgs'"
[[ ! -e "$cfgs" && -z "$(ls -A "$T/tmp")" && ! -e "$T/home/.config/gcloud" ]] \
  && pass "3. the private config is removed afterwards; ~/.config/gcloud untouched" || fail "3. left: '$cfgs' $(ls -A "$T/tmp")"

# --- 4. the identity log -------------------------------------------------------
grep -q "INFO gcloud project=csi-spl-dev account=$DEV_SA .*(do_gcp_compute_lb_list)" "$T/out" \
  && pass "4. the identity log names the project and the env SA" || fail "4. $(grep 'gcloud project=' "$T/out")"
! grep -q 'command not found' "$T/out" && grep -q '^INFO === LB Resources for prefix: csi-spl-dev-wui ===$' "$T/out" \
  && pass "4. every log line goes through do_log, no undefined helper" || fail "4. $(grep -e 'command not found' -e 'LB Resources' "$T/out")"

# --- 5. one kind fails to list -----------------------------------------------
act STUB_GONE=url-maps; rc=$?
[[ $rc -eq 0 && "$(lists | wc -l)" -eq 6 ]] && grep -A1 '=== URL Maps ===' "$T/out" | grep 'None found' >/dev/null \
  && grep -q 'LISTED ssl-certificates' "$T/out" \
  && pass "5. a kind that fails is 'None found'; the rest are still listed" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6./7. ENV or ORG_APP empty: refused before any gcloud call ---------------
for case in "6 ENV" "7 ORG_APP"; do
  read -r n var <<<"$case"
  act "$var=" ACCOUNT="$DEV_SA"; rc=$?
  bad=$(check_refused "$var")
  [[ -z "$bad" ]] && pass "$n. $var empty -> refused, no gcloud call, no private config left" || fail "$n. $var empty: $bad"
done

# --- 8. CONTROL: no key --------------------------------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
act; rc=$?
[[ $rc -ne 0 && "$(compute_calls)" -eq 0 ]] && grep -q 'no gcloud account' "$T/out" \
  && pass "8. CONTROL: no key -> refused, no gcloud compute call" || fail "8. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"

# --- 9. CONTROL: the checks see a planted break ------------------------------
sed '0,/ --account="\${account}"/s/ --account="\${account}"//' "$ACTION" >"$T/no-account.func.sh"
sed 's/\${ENV:?ENV is required (dev\/tst\/prd)}/${ENV:-dev}/' "$ACTION" >"$T/env-default.func.sh"
for planted in no-account env-default; do
  cmp -s "$ACTION" "$T/$planted.func.sh" && fail "9. CONTROL: the $planted plant matched nothing in the action"
done
LB_ACTION="$T/no-account.func.sh" act; rc=$?
[[ -n "$(check_flags)" ]] && pass "9. CONTROL: a copy that drops --account from one list call fails check 1" \
  || fail "9. CONTROL: check 1 is blind to a dropped --account"
LB_ACTION="$T/env-default.func.sh" act ENV= ACCOUNT="$DEV_SA"; rc=$?
[[ -n "$(check_refused ENV)" ]] && pass "9. CONTROL: a copy that defaults ENV to dev fails check 6" \
  || fail "9. CONTROL: check 6 is blind to a defaulted ENV"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
