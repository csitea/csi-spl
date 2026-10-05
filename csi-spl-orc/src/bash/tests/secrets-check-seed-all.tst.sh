#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 072 A30 do_spl_secrets_check and do_spl_secrets_seed_all,
#          CALLED against a stubbed gcloud with a file-backed secret store and
#          stubbed seed actions (each seed has its own test), on fixture
#          030/040 tfvars (SPL_TFVARS_DIR):
#          - check: an empty REQUIRED slot -> exit 1 naming its seed action; an
#            empty OPTIONAL slot is no failure; a missing slot names its step;
#            0 `versions access` calls.
#          - seed-all: the default dry run adds nothing; DRY_RUN=0 adds one
#            version per empty slot it owns (generated ones whenever empty,
#            outside values only when injected: 0 IdP seeds for a provider
#            the tfvars do not inject); a second run adds 0 versions, calls
#            no seed and no `versions access`; the session key reaches gcloud
#            via --data-file=- only; a failing seed does not stop the others
#            and is listed as NEED; every gcloud call carries --account.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/store" "$T/tf"

P=x-y-hub
cat >"$T/tf/030-cloud-run-hub.vars.tfvars" <<EOF
project_id                   = "x-y-prd"
secret_environment_variables = {"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "$P-auth-google-client-secret", "SPOOL_HUB_AUTH_SESSION_KEY": "$P-auth-session-key", "SPOOL_HUB_DB_DSN": "$P-db-dsn", "SPOOL_HUB_MAIL_SMTP_PASSWORD": "$P-mail-smtp-password", "SPOOL_HUB_WUI_KEY": "$P-wui-key"}
auth_secret_ids              = ["$P-auth-session-key", "$P-auth-google-client-secret", "$P-auth-facebook-client-secret", "$P-mail-smtp-password", "$P-wui-key", "$P-stripe-secret-key", "$P-release-note-bans"]
EOF
cat >"$T/tf/040-cloud-sql-postgres.vars.tfvars" <<EOF
dsn_secret_id = "$P-db-dsn"
owner_dsn_secret_id = "$P-db-owner-dsn"
EOF
# the cnf maps a slot 030 does not inject to its env var; point them at the fixture names
# (and the two public dataset login slots of 091 T004)
CNF_FIX='(.. | select(tag == "!!map") | select(has("secret_env")) | .secret_env) |= with_entries(.value |= sub("^[a-z]+-[a-z]+-hub-"; "x-y-hub-"))
  | .env.public_dataset.export_password_secret = "x-y-public-export-db-password"
  | .env.public_dataset.names_password_secret = "x-y-public-names-db-password"'

run_act() {  # <action> [VAR=value ...]
  local act="$1"; shift
  env PATH="$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" SEEDS="$T/seeds" ENV=prd GCP_ACCOUNT=stub-sa@example.com \
      SPL_TFVARS_DIR="$T/tf" CNF_FIX="$CNF_FIX" P="$P" ACT="$act" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "secrets versions list "*)
          grep -qxF "$4" "$STORE/.missing" 2>/dev/null && return 1
          [[ -f "$STORE/$4" ]] && echo "projects/x/secrets/$4/versions/1"; return 0 ;;
        "secrets versions access "*) local s="${5#--secret=}"; cat "$STORE/$s" 2>/dev/null ;;
        "secrets versions add "*)
          local s="$4" df=""; for a in "$@"; do [[ "$a" == --data-file=* ]] && df="${a#--data-file=}"; done
          [[ -n "$df" ]] || return 1
          if [[ "$df" == - ]]; then cat >"$STORE/$s"; else cat "$df" >"$STORE/$s"; fi
          echo "add $s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$(declare -f do_spl_cloud_cnf | sed "1s/do_spl_cloud_cnf/_orig_cloud_cnf/")"
    do_spl_cloud_cnf() { _orig_cloud_cnf || return 1; yq -i "$CNF_FIX" "$SPL_CNF"; }
    # stub seeds: log the call, and on DRY_RUN=0 add a version to the slots each owns
    _stub_seed() {
      local name="$1" s; shift
      echo "$name DRY_RUN=${DRY_RUN:-1} IDP=${IDP:-}" >>"$SEEDS"
      [[ "${FAIL_SEED:-}" == "$name" ]] && { echo "FATAL stub $name: no owner file"; return 1; }
      [[ "${DRY_RUN:-1}" == 0 ]] || return 0
      for s in "$@"; do
        [[ -n "$(gcloud secrets versions list "$s" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --filter=state=ENABLED --format="value(name)" --limit=1)" ]] && continue
        printf "v-%s" "$s" | gcloud secrets versions add "$s" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null
      done
    }
    do_spl_db_bootstrap()            { _stub_seed db "$P-db-owner-dsn" "$P-db-dsn"; }
    do_spl_auth_secrets_seed()       { _stub_seed auth "$P-auth-session-key" "$P-auth-google-client-secret"; }
    do_spl_wui_key_seed()            { _stub_seed wui "$P-wui-key"; }
    do_spl_release_note_bans_seed()  { _stub_seed bans "$P-release-note-bans"; }
    do_spl_mail_secret_seed()        { _stub_seed mail "$P-mail-smtp-password"; }
    do_spl_auth_idp_secret_seed()    { _stub_seed idp "$P-auth-$IDP-client-secret"; }
    do_spl_payment_secret_seed()     { _stub_seed payment "$P-stripe-secret-key"; }
    do_spl_public_export_secret_seed() { _stub_seed public x-y-public-export-db-password x-y-public-names-db-password; }
    "$ACT"' 2>&1
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }  # <pattern> <file>: 0 when absent
adds() { cnt . "$T/store/.adds"; }
access_calls() { cnt 'versions access' "$T/argv"; }
seed_calls() { cnt "${1:-.}" "$T/seeds"; }
put() { local s; for s in "$@"; do printf v >"$T/store/$P-$s"; done; }
REQ=(db-dsn db-owner-dsn auth-session-key auth-google-client-secret mail-smtp-password wui-key)

# ------------------------------------------------------------------ check ----
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 1 ]] && grep -q "EMPTY   $P-db-dsn .*do_spl_db_bootstrap" <<<"$out" && grep -q "EMPTY   $P-mail-smtp-password .*do_spl_mail_secret_seed" <<<"$out" &&
  pass "check: empty required slots -> exit 1, each naming its seed action" || fail "check all empty: rc=$rc $out"
grep -q "INFO    $P-auth-facebook-client-secret (optional" <<<"$out" && ! grep -q "EMPTY   $P-auth-facebook" <<<"$out" &&
  pass "check: an IdP the tfvars do not inject is optional, not a failure" || fail "check optional idp: $out"

put "${REQ[@]}"; rm -f "$T/store/$P-mail-smtp-password"
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 1 && $(grep -c '^EMPTY' <<<"$out") -eq 1 ]] && grep -q "EMPTY   $P-mail-smtp-password (required, SPOOL_HUB_MAIL_SMTP_PASSWORD): seed it: ENV=prd DRY_RUN=0 ./run -a do_spl_mail_secret_seed" <<<"$out" &&
  pass "check: ONE empty required slot -> exit 1 naming do_spl_mail_secret_seed" || fail "check one empty: rc=$rc $out"

put mail-smtp-password
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 0 ]] && grep -q '^OK every required secret slot' <<<"$out" && pass "check: every required slot filled -> exit 0 (optional ones empty)" || fail "check filled: rc=$rc $out"

echo "$P-db-owner-dsn" >"$T/store/.missing"
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 1 ]] && grep -q "MISSING $P-db-owner-dsn .*STEP=040-cloud-sql-postgres" <<<"$out" && pass "check: a missing required slot names the step to apply" || fail "check missing: rc=$rc $out"
rm -f "$T/store/.missing"

[[ $(access_calls) -eq 0 ]] && pass "check: 0 'versions access' calls (no value read)" || fail "check read a value: $(access_calls) access calls"
[[ $(adds) -eq 0 ]] && pass "check: adds nothing" || fail "check added a version"

# --------------------------------------------------------------- seed-all ----
rm -f "$T/store/$P-"* "$T/argv"
out=$(run_act do_spl_secrets_seed_all); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 ]] && grep -q '^OK DRY_RUN' <<<"$out" && pass "seed-all: default is a dry run, nothing added" || fail "seed-all dry: rc=$rc adds=$(adds) $out"
[[ $(seed_calls 'DRY_RUN=0') -eq 0 ]] && pass "seed-all dry: every seed ran as a dry run" || fail "seed-all dry ran a real seed"

: >"$T/seeds"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
# empty slots it owns: 6 required + the generated release-note bans + the two
# public dataset logins (091 T004); not facebook / stripe (ask, not injected)
[[ $rc -eq 0 && $(adds) -eq 9 ]] && pass "seed-all: DRY_RUN=0 adds one version per owned empty slot (9) and the check passes" || fail "seed-all real: rc=$rc adds=$(adds) $out"
[[ $(seed_calls '^idp') -eq 0 && $(seed_calls '^payment') -eq 0 && ! -f "$T/store/$P-auth-facebook-client-secret" ]] &&
  pass "seed-all: no question for an IdP or rail the tfvars do not inject" || fail "seed-all asked a disabled provider: $(cat "$T/seeds")"
[[ -f "$T/store/$P-release-note-bans" ]] && pass "seed-all: a generated slot is seeded even when not injected" || fail "seed-all skipped the bans"
order="$(cut -d' ' -f1 "$T/seeds" | tr '\n' ' ')"
[[ "$order" == "db wui bans public mail auth " ]] && pass "seed-all: generated seeds first, then the asked ones ($order)" || fail "seed-all order: $order"
sk="$(cat "$T/store/$P-auth-session-key")"
[[ "$(base64 -d <<<"$sk" 2>/dev/null | wc -c)" -eq 48 ]] && pass "seed-all: the session key is 48 random bytes, base64" || fail "session key shape"
if grep -qF "$sk" <<<"$out" || grep -qF "$sk" "$T/argv"; then fail "seed-all: the session key appears in output or argv"; else pass "seed-all: the session key is in no output and no gcloud argv"; fi
[[ $(grep 'versions add' "$T/argv" | grep -vc -- '--data-file=-') -eq 0 ]] && pass "seed-all: every value reaches gcloud via --data-file" || fail "seed-all: a versions add without --data-file"

n=$(adds); : >"$T/seeds"; : >"$T/argv"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
[[ $rc -eq 0 && $(adds) -eq $n ]] && pass "seed-all: a second run adds 0 versions" || fail "seed-all re-run: rc=$rc added $(( $(adds) - n )) $out"
[[ $(seed_calls) -eq 0 && $(access_calls) -eq 0 ]] && pass "seed-all: a second run calls no seed and 0 'versions access'" || fail "seed-all re-run: seeds=$(seed_calls) access=$(access_calls)"

rm -f "$T/store/$P-"* "$T/store/.adds"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0 FAIL_SEED=mail); rc=$?
[[ $rc -eq 1 && ! -f "$T/store/$P-mail-smtp-password" && -f "$T/store/$P-auth-google-client-secret" ]] &&
  grep -q '^NEED .*do_spl_mail_secret_seed' <<<"$out" && grep -q "EMPTY   $P-mail-smtp-password" <<<"$out" &&
  pass "seed-all: a failing seed is listed as NEED, the others still seed, exit 1" || fail "seed-all failing seed: rc=$rc $out"

[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call: $(grep -v -- '--account=' "$T/argv" | sed -n 1,2p)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
