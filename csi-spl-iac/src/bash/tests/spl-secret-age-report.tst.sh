#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_age_report (security round 1 row 6, SPL-1967) reports
#          every secret's enabled versions and every user-managed SA key with
#          its age, from metadata only, as the env's project SA.
#   1. max ages null (the committed cnf): EMPTY, MULTI and NO-EXPIRY flagged,
#      nothing OVER, exit 0, the header says the owner decides
#   2. every gcloud call as the dev project SA on csi-spl-dev, in a private
#      CLOUDSDK_CONFIG; no `versions access` (no value is ever read)
#   3. CONTROL: max ages set below the ages -> OVER on the old version and the
#      old key, exit 1 (fails when the max-age check is removed)
#   4. a disabled key is never OVER
#   5. a max age that is not whole days -> refused before any gcloud call
#   6. a versions list that fails -> non-zero, never an empty row
#   7. per_secret (SPL-2657): a secret's own max age beats the class one,
#      both ways, and is shown in its row; a per_secret value that is not
#      whole days -> refused before any gcloud call
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-secret-age-report.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/app/csi-spl-cnf"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
v() { printf '{"name":"projects/1/secrets/%s/versions/%s","state":"%s","createTime":"%s"}' "$1" "$2" "$3" "$4"; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets list"*) echo '[{"name":"projects/1/secrets/a-key"},{"name":"projects/1/secrets/b-empty"},{"name":"projects/1/secrets/c-multi"}]' ;;
  "secrets versions list a-key"*) echo "[$(v a-key 1 ENABLED 2026-10-10T08:00:00.1Z)]" ;;
  "secrets versions list b-empty"*) echo "[$(v b-empty 1 DISABLED 2026-09-01T08:00:00Z)]" ;;
  "secrets versions list c-multi"*) [[ -n "${STUB_FAIL:-}" ]] && exit 1
    echo "[$(v c-multi 2 ENABLED 2026-10-01T08:00:00Z),$(v c-multi 1 ENABLED 2026-09-01T08:00:00Z)]" ;;
  "iam service-accounts list"*) echo '[{"email":"sa-one@csi-spl-dev.iam.gserviceaccount.com"}]' ;;
  "iam service-accounts keys list"*)
    echo '[{"name":"projects/p/serviceAccounts/sa-one/keys/abcdef0123456789","validAfterTime":"2026-09-17T00:00:00Z","validBeforeTime":"9999-12-31T23:59:59Z","disabled":false},
           {"name":"projects/p/serviceAccounts/sa-one/keys/0011223344556677","validAfterTime":"2026-08-01T00:00:00Z","validBeforeTime":"2027-08-01T00:00:00Z","disabled":true}]' ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" ENV=dev SECRET_AGE_NOW=2026-10-15T00:00:00Z "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-secret-age-report.func.sh; do source "$f"; done
    do_spl_secret_age_report' >"$T/out" 2>&1
}
set_max() { yq -i ".env.secrets.max_age_days.secret_version = $1 | .env.secrets.max_age_days.sa_key = $2" "$T/app/csi-spl-cnf/csi-spl/all.env.yaml"; }
row() { grep -F "| $1 |" "$T/out"; }

# --- 1. max ages not set ---------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && grep -q '^OVER: 0$' "$T/out" && pass "1. max ages null: exit 0, nothing OVER" || fail "1. rc=$rc $(cat "$T/out")"
grep -q 'max age not set: the owner decides' "$T/out" && pass "1. the header says the max age is the owner's" || fail "1. header: $(head -3 "$T/out")"
[[ "$(row b-empty)" == *"| 0 | - | EMPTY |"* ]] && pass "1. 0 enabled versions -> EMPTY" || fail "1. empty: $(row b-empty)"
[[ "$(row c-multi)" == *"| 2 | 1: 2026-09-01, 43, 2: 2026-10-01, 13 | MULTI |"* ]] \
  && pass "1. 2 enabled versions -> MULTI, each with its number, create date and age" || fail "1. multi: $(row c-multi)"
[[ "$(row a-key)" == *"| 1 | 1: 2026-10-10, 4 |  |"* ]] && pass "1. one young enabled version -> no flag" || fail "1. a-key: $(row a-key)"
grep -q '| sa-one@csi-spl-dev.iam.gserviceaccount.com | abcdef01 | 2026-09-17 | 28 | never | NO-EXPIRY |' "$T/out" \
  && pass "1. a key: id prefix only, created, age, never expires" || fail "1. key: $(cat "$T/out")"
! grep -q 'abcdef0123456789' "$T/out" && pass "1. the full key id is never printed" || fail "1. full key id printed"

# --- 2. identity, no value ----------------------------------------------------------
n=$(grep -cE '\|(secrets|iam) ' "$T/calls.log"); m=$(grep -E '\|(secrets|iam) ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -eq 6 && $n -eq $m ]] && pass "2. all $n metadata calls as the dev project SA on csi-spl-dev" || fail "2. identity: $n vs $m $(cat "$T/calls.log")"
cfg=$(awk -F'|' '/\|secrets / {print $1; exit}' "$T/calls.log")
[[ -n "$cfg" && "$cfg" != "<unset>" && "$cfg" != "$T/home/.config/gcloud" && ! -e "$cfg" ]] \
  && pass "2. a private CLOUDSDK_CONFIG, removed afterwards" || fail "2. config: '$cfg'"
! grep -q 'versions access' "$T/calls.log" && pass "2. no versions access: no value is read" || fail "2. a value was read"

# --- 3. CONTROL: max ages set ---------------------------------------------------------
set_max 30 20; act; rc=$?
[[ $rc -eq 1 ]] && grep -q '^OVER: 2$' "$T/out" && pass "3. CONTROL: max ages 30/20 -> 2 OVER, exit 1" || fail "3. rc=$rc $(cat "$T/out")"
[[ "$(row c-multi)" == *"| MULTI OVER | 30 |" ]] && pass "3. the 43-day-old enabled version is OVER 30" || fail "3. multi: $(row c-multi)"
grep -q '| abcdef01 | 2026-09-17 | 28 | never | NO-EXPIRY OVER |' "$T/out" && pass "3. the 28-day-old key is OVER 20" || fail "3. key: $(cat "$T/out")"
# --- 4. disabled key ----------------------------------------------------------------
grep -q '| 00112233 | 2026-08-01 | 75 | 2027-08-01 | DISABLED |' "$T/out" && pass "4. a disabled key is never OVER" || fail "4. disabled: $(cat "$T/out")"

# --- 5. bad max age -----------------------------------------------------------------
set_max '"90d"' null; act; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '|secrets ' "$T/calls.log" && grep -q 'must be positive whole days' "$T/out" \
  && pass "5. max age '90d' -> refused before any gcloud call" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. a failing list ----------------------------------------------------------------
set_max null null; act STUB_FAIL=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'cannot list the versions of c-multi' "$T/out" && ! grep -q '^| c-multi' "$T/out" \
  && pass "6. a failing versions list -> non-zero, no row" || fail "6. rc=$rc $(cat "$T/out")"

# --- 7. per-secret max age ----------------------------------------------------------
set_per() { yq -i ".env.secrets.max_age_days.per_secret = $1" "$T/app/csi-spl-cnf/csi-spl/all.env.yaml"; }
set_max null null; set_per '{"a-key": 3}'; act; rc=$?
[[ $rc -eq 1 ]] && grep -q '^OVER: 1$' "$T/out" && [[ "$(row a-key)" == *"| OVER | 3 |" ]] && [[ "$(row c-multi)" == *"| MULTI | - |" ]] \
  && pass "7. class null, a-key 3 d -> only the 4-day-old a-key is OVER" || fail "7. per rc=$rc $(cat "$T/out")"
set_max 30 null; set_per '{"c-multi": 60}'; act; rc=$?
[[ $rc -eq 0 ]] && [[ "$(row c-multi)" == *"| MULTI | 60 |" ]] && [[ "$(row a-key)" == *"|  | 30 |" ]] \
  && pass "7. class 30, c-multi 60 d -> its 43-day-old version is not OVER" || fail "7. beats rc=$rc $(cat "$T/out")"
set_per '{"a-key": "90d"}'; act; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '|secrets ' "$T/calls.log" && grep -q 'per_secret must map a secret id to positive whole days, not: a-key' "$T/out" \
  && pass "7. per_secret '90d' -> refused before any gcloud call" || fail "7. bad rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
