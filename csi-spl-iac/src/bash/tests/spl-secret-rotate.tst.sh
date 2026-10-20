#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_rotate (SPL-2657, Cloud Run radar step 6 part 2)
#          walks one rotation of one pinned hub secret, step by step, and
#          refuses each step out of order.
#   1. status: newest 3 > cnf pin 2 -> NEXT pin; metadata calls only, as the
#      dev project SA; no `versions access`
#   2. pin DRY_RUN unset: names the change, the cnf file is untouched
#   3. pin DRY_RUN=0: exactly the one pin line changes, do_tpl_gen runs
#   4. CONTROL: pin when the newest is NOT above the cnf pin -> refused, file
#      untouched, no tpl-gen (fails when the order check is removed)
#   5. verify: live pin != cnf pin -> refused; live = cnf + Ready -> OK
#      + NEXT disable; not Ready -> refused with the undo
#   6. status: cnf pin raised but not applied -> NEXT apply 030 (owner go)
#   7. a secret the hub does not pin -> refused; bad ROTATE_STEP / SECRET /
#      DRY_RUN -> refused before any gcloud call
#   8. the committed schedule: every secret the hub pins in dev or prd has a
#      max age in env.secrets.max_age_days.per_secret, and every entry there
#      is a pinned secret (a typo would never be OVER)
# gcloud and do_tpl_gen are stubs. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-secret-rotate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
S=csi-spl-hub-stripe-secret-key
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/app/csi-spl-cnf"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"
F="$T/app/csi-spl-cnf/csi-spl/dev.env.yaml"
cp "$F" "$T/dev.env.yaml.orig"
yq -e ".env.hub.secret_versions[\"$S\"] == \"2\"" "$F" >/dev/null || { echo "FAIL: the committed dev pin of $S is not \"2\": update this test"; exit 1; }

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
v() { printf '{"name":"projects/1/secrets/s/versions/%s","state":"%s","createTime":"2026-10-0%sT10:00:00Z"}' "$1" "$2" "$1"; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets versions list"*) echo "[$(v "${STUB_NEWEST:-3}" ENABLED),$(v 2 ENABLED),$(v 1 DISABLED)]" ;;
  "run services describe"*)
    printf '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"SPOOL_HUB_STRIPE_SECRET_KEY","valueFrom":{"secretKeyRef":{"name":"%s","key":"%s"}}}]}]}}},"status":{"conditions":[{"type":"Ready","status":"%s"}]}}\n' \
      "${STUB_NAME:-csi-spl-hub-stripe-secret-key}" "${STUB_PIN:-2}" "${STUB_READY:-True}" ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u ROTATE_STEP HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" ENV=dev SECRET="$S" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    do_tpl_gen() { echo "tpl-gen ENV=$ENV" >>"$STUB_LOG"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-secret-rotate.func.sh; do source "$f"; done
    do_spl_secret_rotate' >"$T/out" 2>&1
}
untouched() { cmp -s "$F" "$T/dev.env.yaml.orig"; }

# --- 1. status ------------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && grep -q "newest enabled version 3, cnf pin 2, live hub pin 2, newest revision Ready=True" "$T/out" \
  && grep -q "NEXT pin: ENV=dev SECRET=$S ROTATE_STEP=pin DRY_RUN=0" "$T/out" \
  && pass "1. status: newest 3 above the pin 2 -> NEXT pin" || fail "1. rc=$rc $(cat "$T/out")"
n=$(grep -cE '\|(secrets|run) ' "$T/calls.log"); m=$(grep -E '\|(secrets|run) ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -eq 2 && $n -eq $m ]] && pass "1. two metadata calls, both as the dev project SA on csi-spl-dev" || fail "1. identity $n/$m $(cat "$T/calls.log")"
! grep -qE 'versions access|versions add|versions disable' "$T/calls.log" && pass "1. no value read, nothing changed" || fail "1. calls: $(cat "$T/calls.log")"

# --- 2. pin, dry run ----------------------------------------------------------------
act ROTATE_STEP=pin; rc=$?
[[ $rc -eq 0 ]] && untouched && ! grep -q tpl-gen "$T/calls.log" && grep -q "DRY_RUN would set .*$S from \"2\" to \"3\"" "$T/out" \
  && pass "2. pin DRY_RUN unset: names 2 -> 3, file untouched, no tpl-gen" || fail "2. rc=$rc $(cat "$T/out")"

# --- 3. pin, real -------------------------------------------------------------------
act ROTATE_STEP=pin DRY_RUN=0; rc=$?
d=$(diff "$T/dev.env.yaml.orig" "$F" | grep -c '^[<>]')
[[ $rc -eq 0 && $d -eq 2 ]] && [[ "$(yq -r ".env.hub.secret_versions[\"$S\"]" "$F")" == 3 ]] \
  && pass "3. pin DRY_RUN=0: one line changed, the pin reads 3" || fail "3. rc=$rc diff=$d $(cat "$T/out")"
grep -q 'tpl-gen ENV=dev' "$T/calls.log" && grep -q 'NEXT commit the cnf + tfvars, then apply 030' "$T/out" \
  && pass "3. do_tpl_gen ran, NEXT is the commit and the owner-gated 030 apply" || fail "3. tpl/next: $(cat "$T/out")"
cp "$T/dev.env.yaml.orig" "$F"

# --- 4. CONTROL: out of order ---------------------------------------------------------
act ROTATE_STEP=pin DRY_RUN=0 STUB_NEWEST=2; rc=$?
[[ $rc -ne 0 ]] && untouched && ! grep -q tpl-gen "$T/calls.log" && grep -q 'not above the cnf pin 2: add a version first (roll the key at Stripe' "$T/out" \
  && pass "4. CONTROL: newest = pin -> refused, names the seed, file untouched" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5. verify ------------------------------------------------------------------------
act ROTATE_STEP=verify STUB_PIN=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'reads csi-spl-hub-stripe-secret-key at 1, the cnf pins 2: apply 030 first' "$T/out" \
  && pass "5. verify: live 1 != cnf 2 -> refused" || fail "5. mismatch rc=$rc $(cat "$T/out")"
act ROTATE_STEP=verify; rc=$?
[[ $rc -eq 0 ]] && grep -q "NEXT ENV=dev SECRET=$S ROTATE_STEP=disable" "$T/out" && pass "5. verify: live = cnf, Ready -> OK, NEXT disable" || fail "5. ok rc=$rc $(cat "$T/out")"
act ROTATE_STEP=verify STUB_READY=False; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not Ready (False).*undo: lower the pin' "$T/out" && pass "5. verify: not Ready -> refused with the undo" || fail "5. ready rc=$rc $(cat "$T/out")"

# --- 6. pin raised, not applied ---------------------------------------------------------
act STUB_NEWEST=3 STUB_PIN=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'live hub pin 1' "$T/out" && grep -q 'NEXT pin' "$T/out" && pass "6. status: newest above cnf -> pin comes first" || fail "6a rc=$rc $(cat "$T/out")"
act STUB_NEWEST=2 STUB_PIN=1; rc=$?
[[ $rc -eq 0 ]] && grep -q "NEXT apply 030 with the owner's go" "$T/out" && pass "6. status: cnf 2, live 1 -> NEXT apply 030 with the owner's go" || fail "6b rc=$rc $(cat "$T/out")"

# --- 7. refusals -------------------------------------------------------------------------
act STUB_NAME=other-secret; rc=$?
[[ $rc -ne 0 ]] && grep -q 'not a pinned hub secret' "$T/out" && pass "7. the hub does not read it -> refused" || fail "7. unpinned rc=$rc $(cat "$T/out")"
for bad in "ROTATE_STEP=apply" "SECRET=a b" "DRY_RUN=2"; do
  act "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "7. $bad -> refused before any gcloud call" || fail "7. $bad rc=$rc $(cat "$T/calls.log")"
done

# --- 8. the committed schedule covers the pins ------------------------------------------
C="$APP_ROOT/csi-spl-cnf/csi-spl"
pinned=$(for e in dev prd; do yq -r '.env.hub.secret_versions | keys | .[]' "$C/$e.env.yaml"; done | sort -u)
sched=$(yq -r '.env.secrets.max_age_days.per_secret // {} | keys | .[]' "$C/all.env.yaml" | sort -u)
[[ -n "$pinned" && "$pinned" == "$sched" ]] && pass "8. per_secret names exactly the $(wc -l <<<"$pinned") pinned hub secrets" \
  || fail "8. pinned vs schedule: $(diff <(echo "$pinned") <(echo "$sched") | grep '^[<>]' | tr '\n' ' ')"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
