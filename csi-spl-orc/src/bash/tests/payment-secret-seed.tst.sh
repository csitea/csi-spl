#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 006 T022 do_spl_payment_secret_seed, CALLED against a stubbed
#          gcloud with a file-backed secret store (as wui-key-mail-seed.tst.sh):
#          - refused: no owner file, a non-0600 file, a malformed secret key,
#            a live key on dev / a test key on prd, a non-whsec_ webhook secret,
#            a pk_ of the wrong mode, a missing 030 slot
#          - CONTROL shared account: the same secret key under another app's
#            dir (csi-rel's .rel) is refused, and passes only with
#            STRIPE_SHARED_ACCOUNT_OK=1
#          - dry run adds nothing; DRY_RUN=0 adds exactly the two stripe
#            versions (the parsed values, quotes stripped); a re-run adds
#            nothing; PayPal is seeded only while cnf enables it
#          - no secret value in any output or gcloud argv; every gcloud call
#            carries --account
#          - SPL_STRIPE_KEY_DIR is set after spl_stripe_key_dir (out-param)
#          Key-shaped values are built at run time: no literal key in git.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SD="$T/home/.stripe/.csi/.spl" RD="$T/home/.stripe/.csi/.rel" PD="$T/home/.paypal/.csi/.spl"
mkdir -p "$T/store" "$SD" "$RD" "$PD"

rnd() { head -c 24 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c 1-24; }
p_sk=sk p_pk=pk p_wh=whsec
SK_TEST="${p_sk}_test_$(rnd)" SK_LIVE="${p_sk}_live_$(rnd)" WH="${p_wh}_$(rnd)" PP="pp$(rnd)"
PK_TEST="${p_pk}_test_$(rnd)" PK_LIVE="${p_pk}_live_$(rnd)"

stripe_env() {  # <env> <sk> <wh>
  printf 'STRIPE_SECRET_KEY="%s"\nSTRIPE_WEBHOOK_SECRET=%s\nSTRIPE_CONNECT_WEBHOOK_SECRET=%s_other\n' "$2" "$3" "$p_wh" >"$SD/stripe-$1.env"
  chmod 600 "$SD/stripe-$1.env"
}

run_act() {  # [VAR=value ...]
  local o rc
  o=$(env PATH="$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" ENV="${ENV_:-dev}" GCP_ACCOUNT=stub-sa@example.com \
      CNF_OVERRIDE="${CNF_OVERRIDE:-}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "secrets describe "*) [[ "${NO_SLOT:-0}" == 1 ]] && return 1; return 0 ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*)
          local s="$4"; cat >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    if [[ -n "$CNF_OVERRIDE" ]]; then
      eval "$(declare -f do_spl_cloud_cnf | sed "1s/do_spl_cloud_cnf/_orig_cloud_cnf/")"
      do_spl_cloud_cnf() { _orig_cloud_cnf || return 1; yq -i "$CNF_OVERRIDE" "$SPL_CNF"; }
    fi
    do_spl_payment_secret_seed' 2>&1); rc=$?
  printf '%s\n' "$o" >>"$T/allout"; printf '%s\n' "$o"; return $rc
}
adds() { cat "$T/store/.adds" 2>/dev/null | grep -c .; }
SKS=csi-spl-hub-stripe-secret-key WHS=csi-spl-hub-stripe-webhook-secret PPS=csi-spl-hub-paypal-client-secret
refused() {  # <label> [VAR=value ...]
  local label="$1"; shift
  local n out rc; n=$(adds); out=$(run_act DRY_RUN=0 "$@"); rc=$?
  [[ $rc -ne 0 && $(adds) -eq $n ]] && pass "refused: $label" || fail "not refused: $label (rc=$rc) $out"
}

refused "no owner file"
stripe_env dev "$SK_TEST" "$WH"; chmod 644 "$SD/stripe-dev.env"
refused "a non-0600 owner file"
stripe_env dev "notakey" "$WH";              refused "a malformed secret key"
stripe_env dev "$SK_LIVE" "$WH";             refused "a live secret key on dev"
stripe_env dev "$SK_TEST" "not-a-webhook";   refused "a non-whsec_ webhook secret"
stripe_env dev "$SK_TEST" "";
out=$(run_act); grep -q "left to do_spl_provision_stripe_endpoints" <<<"$out" && pass "no webhook secret in the file: the slot is left to the endpoints action" || fail "no-whsec: $out"
stripe_env prd "$SK_TEST" "$WH"
ENV_=prd refused "a test secret key on prd"
stripe_env dev "$SK_TEST" "$WH"
printf '%s\n' "$PK_LIVE" >"$SD/stripe-publishable-key-dev.txt"
refused "a publishable key of the other mode"
printf '%s\n' "$PK_TEST" >"$SD/stripe-publishable-key-dev.txt"
refused "a missing 030 slot" NO_SLOT=1

# CONTROL: the same key under csi-rel's dir is another app's account
printf 'STRIPE_SECRET_KEY=%s\n' "$SK_TEST" >"$RD/stripe-dev.env"; chmod 600 "$RD/stripe-dev.env"
refused "CONTROL: a secret key shared with another app's dir"
out=$(run_act STRIPE_SHARED_ACCOUNT_OK=1); rc=$?
[[ $rc -eq 0 ]] && grep -q "shared with" <<<"$out" && pass "shared key passes (dry run) with STRIPE_SHARED_ACCOUNT_OK=1" || fail "shared ok: rc=$rc $out"
# STRIPE_KEY_APP=rel reads csi-rel's files in place; never its whsec_
REL_WH="${p_wh}_$(rnd)"
printf 'STRIPE_SECRET_KEY=%s\nSTRIPE_WEBHOOK_SECRET=%s\n' "$SK_TEST" "$REL_WH" >"$RD/stripe-dev.env"; chmod 600 "$RD/stripe-dev.env"
printf '%s\n' "$PK_TEST" >"$RD/stripe-publishable-key-dev.txt"
refused "CONTROL: STRIPE_KEY_APP=rel without the owner's go" STRIPE_KEY_APP=rel
n=$(adds); out=$(run_act DRY_RUN=0 STRIPE_KEY_APP=rel STRIPE_SHARED_ACCOUNT_OK=1); rc=$?
[[ $rc -eq 0 && $(adds) -eq $((n + 1)) && "$(cat "$T/store/$SKS")" == "$SK_TEST" && ! -f "$T/store/$WHS" ]] &&
  pass "STRIPE_KEY_APP=rel + go: the secret key is seeded, csi-rel's whsec_ is NOT" || fail "key app rel: rc=$rc adds=$(adds) $out"
rm -f "$T/store/$SKS"; sed -i '/csi-spl-hub-stripe-secret-key/d' "$T/store/.adds"
printf 'STRIPE_SECRET_KEY=%s\n' "${p_sk}_test_$(rnd)" >"$RD/stripe-dev.env"

out=$(run_act); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 ]] && pass "default is a dry run, nothing added" || fail "dry run: rc=$rc adds=$(adds) $out"
grep -q "differs from" <<<"$out" && pass "a cnf publishable key that differs from the owner file is reported" || fail "no pk mismatch warning: $out"
out=$(run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && $(adds) -eq 2 ]] && pass "DRY_RUN=0 adds exactly the two stripe versions" || fail "real run: rc=$rc adds=$(adds) $out"
[[ "$(cat "$T/store/$SKS")" == "$SK_TEST" && "$(cat "$T/store/$WHS")" == "$WH" ]] &&
  pass "the versions are the parsed values (quotes stripped, no newline)" || fail "stored values differ"
[[ ! -f "$T/store/$PPS" ]] && pass "PayPal slot untouched while cnf has it off" || fail "paypal seeded while off"
n=$(adds); out=$(run_act DRY_RUN=0)
[[ $(adds) -eq $n ]] && pass "a re-run with the same files adds nothing" || fail "re-run added"

PPON='.env.hub.env.SPOOL_HUB_ENABLE_PAYPAL = "true"'
CNF_OVERRIDE="$PPON" refused "PayPal on without its owner file"
printf 'PAYPAL_CLIENT_SECRET=%s\n' "$PP" >"$PD/paypal-dev.env"; chmod 600 "$PD/paypal-dev.env"
out=$(CNF_OVERRIDE="$PPON" run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$PPS" 2>/dev/null)" == "$PP" ]] && pass "PayPal on: its secret is seeded" || fail "paypal: rc=$rc $out"

stripe_env prd "$SK_LIVE" "$WH"; printf '%s\n' "$PK_LIVE" >"$SD/stripe-publishable-key-prd.txt"
out=$(ENV_=prd run_act); rc=$?
[[ $rc -eq 0 ]] && pass "prd accepts live keys (dry run)" || fail "prd live: rc=$rc $out"
# csi-rel layout: the dedicated .prd-stripe-secret-key wins over an EMPTY env-file key
stripe_env prd "" "$WH"; SK_LIVE2="${p_sk}_live_$(rnd)"
printf '%s\n' "$SK_LIVE2" >"$SD/.prd-stripe-secret-key"; chmod 600 "$SD/.prd-stripe-secret-key"
out=$(ENV_=prd run_act DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$SKS")" == "$SK_LIVE2" ]] && pass "the dedicated .prd-stripe-secret-key file is the key (env-file key empty)" || fail "dedicated key file: rc=$rc $out"
chmod 644 "$SD/.prd-stripe-secret-key"
ENV_=prd refused "a group/other-readable dedicated key file"

all_out="$(cat "$T/argv" "$T/allout")"
leak=0
for v in "$SK_TEST" "$SK_LIVE" "$SK_LIVE2" "$WH" "$PP" "$REL_WH"; do grep -qF "$v" <<<"$all_out" && leak=1; done
(( leak == 0 )) && pass "no secret value in any output or gcloud argv" || fail "a secret value leaked into output or argv"
[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call: $(grep -v -- '--account=' "$T/argv" | sed -n 1,2p)"

# pins the out-param contract: the caller reads SPL_STRIPE_KEY_DIR after the call
out=$(in_orc HOME="$T/home" SNIPPET='spl_stripe_key_dir csi spl || exit 9; printf "KEYDIR=%s\n" "${SPL_STRIPE_KEY_DIR:-}"')
key=$(sed -n 's/^KEYDIR=//p' <<<"$out" | tail -n 1)
[[ "$key" == "$T/home/.stripe/.csi/.spl" ]] && pass "SPL_STRIPE_KEY_DIR is set after spl_stripe_key_dir" || fail "out-param SPL_STRIPE_KEY_DIR: ${key:-<empty>} ($out)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
