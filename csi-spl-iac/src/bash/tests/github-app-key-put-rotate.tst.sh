#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 075 repo-edit T04 - do_put_github_app_key and
#   do_rotate_github_app_key, gcloud / curl / sleep stubbed (no GCP, no key):
#     1. DRY_RUN default: names the cnf slot, adds nothing, prints no key byte
#     2. DRY_RUN=0: one version added as the env's own SA, verified, no key byte
#     3. CONTROL: a file that is not a PEM private key (a public key, an SA
#        json, a key with a stray line) is refused before any gcloud call,
#        and its contents are not printed
#     4. CONTROL: SHRED=1 on dev is refused before any gcloud call
#     5. SHRED=1 on prd: DRY_RUN keeps the file; DRY_RUN=0 puts, then shreds
#     6. rotate, cnf inject "false": new version, NO hub roll, the reminder to
#        delete the old key names the App id
#     7. rotate, cnf inject "true": DRY_RUN changes nothing; DRY_RUN=0 adds the
#        version, THEN rolls the hub (run services update), as the env's SA
# The PEM in the stubs is a fixed non-key string.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
for b in jq yq; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done
require_action "$RUN/put-github-app-key.func.sh"
require_action "$RUN/rotate-github-app-key.func.sh"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
PRD_SA=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com
APP_ID="$(yq -r .env.docs.repo_edit.github_app_id "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
mkdir -p "$T/home/.gcp/.csi" "$T/bin" "$T/sm/csi-spl-dev/spool-hub-github-app-key" "$T/sm/csi-spl-prd/spool-hub-github-app-key"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf '{"type":"service_account","client_email":"%s"}\n' "$PRD_SA" >"$T/home/.gcp/.csi/key-csi-spl-prd.json"
# an app tree whose cnf has inject "true" (case 7)
mkdir -p "$T/app"; cp -r "$APP_ROOT/csi-spl-cnf" "$T/app/"
yq -i '.env.docs.repo_edit.inject = "true"' "$T/app/csi-spl-cnf/csi-spl/all.env.yaml"
# and one whose dev cnf has inject "false" (case 6; the live dev cnf injects since T13)
mkdir -p "$T/app-off"; cp -r "$APP_ROOT/csi-spl-cnf" "$T/app-off/"
yq -i '.env.docs.repo_edit.inject = "false"' "$T/app-off/csi-spl-cnf/csi-spl/dev.env.yaml"

# gcloud: secrets live as files $SM/<project>/<id>/latest; the hub revision in $REV
cat >"$T/bin/gcloud" <<'EOF2'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
p="$(arg --project "$@")"
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets describe "*) [[ -d "$SM/$p/$3" ]] ;;
  "secrets versions add "*) cp "$(arg --data-file "$@")" "$SM/$p/$4/latest" ;;
  "secrets versions access "*) cat "$SM/$p/$(arg --secret "$@")/latest" 2>/dev/null ;;
  "run services describe"*)
    if [[ "$*" == *status.url* ]]; then printf '%s\t%s\n' "$(cat "$REV")" "https://hub.example.com"; else cat "$REV"; fi ;;
  "run services update"*) echo svc-00002-new >"$REV" ;;
esac
EOF2
printf '#!/usr/bin/env bash\necho "curl|$*" >>"$STUB_LOG"; printf 200\n' >"$T/bin/curl"
printf '#!/usr/bin/env bash\n:\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*

# the armour lines are built here, so this file holds no PEM literal (no-key-material-in-tree)
RSA_KEY='RSA PRIVATE KEY'
pem() { printf -- '-----BEGIN %s-----\nRkFLRS1QRU0tQk9EWS0%s\nRkFLRS1QRU0tVEFJTA==\n-----END %s-----\n' "$RSA_KEY" "$1" "$RSA_KEY" >"$2"; }
pem AAAA "$T/key1.pem"; pem BBBB "$T/key2.pem"
LEAK='RkFLRS1QRU0'

# act <action> [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  local a="$1"; shift
  : >"$T/calls.log"; echo svc-00001-old >"$T/rev"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u SHRED -u GH_APP_SECRET HOME="$T/home" PATH="$T/bin:$PATH" \
    STUB_LOG="$T/calls.log" SM="$T/sm" REV="$T/rev" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ORG=csi APP=spl ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/{spl-gh-app-key-put,gcp-hub-restart,put-github-app-key,rotate-github-app-key}.func.sh; do source "$f"; done
    '"$a" >"$T/out" 2>&1
}
adds() { grep -c 'gcloud|secrets versions add' "$T/calls.log"; }
no_leak() { ! grep -qF "$LEAK" "$T/out" "$T/calls.log"; }

# --- 1. dry run -----------------------------------------------------------------------
act do_put_github_app_key KEY_FILE="$T/key1.pem"; rc=$?
[[ $rc == 0 && "$(adds)" == 0 ]] && grep -q 'secret spool-hub-github-app-key' "$T/out" && grep -q 'DRY_RUN would add a version to csi-spl-dev/spool-hub-github-app-key' "$T/out" \
  && pass "1. DRY_RUN default names the cnf slot and adds nothing" || fail "1. rc=$rc $(cat "$T/out")"
no_leak && pass "1. no key byte in the output or argv" || fail "1. LEAK: $(cat "$T/out")"

# --- 2. put ---------------------------------------------------------------------------
act do_put_github_app_key KEY_FILE="$T/key1.pem" DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(adds)" == 1 ]] && cmp -s "$T/key1.pem" "$T/sm/csi-spl-dev/spool-hub-github-app-key/latest" && grep -q 'new version verified by sha256' "$T/out" \
  && pass "2. DRY_RUN=0 adds one verified version" || fail "2. rc=$rc $(cat "$T/out")"
n=$(grep -c 'gcloud|secrets' "$T/calls.log"); own=$(grep 'gcloud|secrets' "$T/calls.log" | grep -c -- "--project=csi-spl-dev --account=$DEV_SA")
[[ $n -gt 0 && $n == "$own" ]] && pass "2. every secrets call as the dev SA on csi-spl-dev ($n)" || fail "2. identity: $(grep secrets "$T/calls.log")"
no_leak && pass "2. no key byte in the output or argv" || fail "2. LEAK: $(cat "$T/out")"

# --- 3. CONTROL: not a PEM private key --------------------------------------------------
printf -- '-----BEGIN PUBLIC KEY-----\nU0VDUkVULVBVQkxJQw==\n-----END PUBLIC KEY-----\n' >"$T/pub.pem"
printf '{"type":"service_account","%s":"U0VDUkVULUpTT04="}\n' "private_key" >"$T/sa.json"
printf -- '-----BEGIN %s-----\nU0VDUkVULVNUUkFZ\nnot base64 U0VDUkVULVNUUkFZ\n-----END %s-----\n' "$RSA_KEY" "$RSA_KEY" >"$T/stray.pem"
printf -- '-----BEGIN %s-----\nU0VDUkVULU5PRU5E\n' "$RSA_KEY" >"$T/noend.pem"
for f in pub.pem sa.json stray.pem noend.pem; do
  act do_put_github_app_key KEY_FILE="$T/$f" DRY_RUN=0; rc=$?
  [[ $rc == 2 && ! -s "$T/calls.log" ]] && grep -q 'not a PEM private key' "$T/out" && ! grep -q 'U0VDUkVU' "$T/out" \
    && pass "3. CONTROL: $f refused before any gcloud call, contents not shown" || fail "3. $f: rc=$rc $(cat "$T/out")"
done

# --- 4. CONTROL: SHRED on dev ---------------------------------------------------------
act do_put_github_app_key KEY_FILE="$T/key1.pem" SHRED=1 DRY_RUN=0; rc=$?
[[ $rc == 2 && ! -s "$T/calls.log" && -f "$T/key1.pem" ]] && grep -q 'SHRED=1 is the prd call only' "$T/out" \
  && pass "4. CONTROL: SHRED=1 on dev refused, nothing called, file kept" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5. SHRED on prd ------------------------------------------------------------------
act do_put_github_app_key ENV=prd KEY_FILE="$T/key1.pem" SHRED=1; rc=$?
[[ $rc == 0 && "$(adds)" == 0 && -f "$T/key1.pem" ]] && grep -q 'DRY_RUN would shred' "$T/out" \
  && pass "5. SHRED=1 DRY_RUN: nothing added, file kept" || fail "5. dry: rc=$rc $(cat "$T/out")"
act do_put_github_app_key ENV=prd KEY_FILE="$T/key1.pem" SHRED=1 DRY_RUN=0; rc=$?
[[ $rc == 0 && ! -e "$T/key1.pem" ]] && grep -q 'shredded' "$T/out" && grep -q "secrets versions add .*--project=csi-spl-prd --account=$PRD_SA" "$T/calls.log" \
  && [[ -s "$T/sm/csi-spl-prd/spool-hub-github-app-key/latest" ]] \
  && pass "5. SHRED=1 DRY_RUN=0: put on prd as the prd SA, then the file is gone" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. rotate, inject false ----------------------------------------------------------
act do_rotate_github_app_key APP_PATH="$T/app-off" KEY_FILE="$T/key2.pem" DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(adds)" == 1 ]] && cmp -s "$T/key2.pem" "$T/sm/csi-spl-dev/spool-hub-github-app-key/latest" && ! grep -q 'gcloud|run ' "$T/calls.log" \
  && grep -q 'no hub roll' "$T/out" && pass "6. rotate, inject false: new version, no hub roll" || fail "6. rc=$rc $(cat "$T/out")"
grep -q "delete the OLD private key of GitHub App $APP_ID" "$T/out" && pass "6. the reminder names App $APP_ID" || fail "6. reminder: $(cat "$T/out")"
no_leak && pass "6. no key byte in the output or argv" || fail "6. LEAK: $(cat "$T/out")"

# --- 7. rotate, inject true -----------------------------------------------------------
pem CCCC "$T/key3.pem"
act do_rotate_github_app_key APP_PATH="$T/app" KEY_FILE="$T/key3.pem"; rc=$?
[[ $rc == 0 && "$(adds)" == 0 ]] && ! grep -q 'gcloud|run services update' "$T/calls.log" && grep -q 'DRY_RUN would run: gcloud run services update' "$T/out" \
  && pass "7. rotate DRY_RUN, inject true: no version, no roll" || fail "7. dry: rc=$rc $(cat "$T/out")"
act do_rotate_github_app_key APP_PATH="$T/app" KEY_FILE="$T/key3.pem" DRY_RUN=0; rc=$?
add_at=$(grep -n 'gcloud|secrets versions add' "$T/calls.log" | cut -d: -f1); roll_at=$(grep -n 'gcloud|run services update' "$T/calls.log" | cut -d: -f1)
[[ $rc == 0 && -n "$add_at" && -n "$roll_at" && "$add_at" -lt "$roll_at" ]] \
  && grep -q "run services update .*--project=csi-spl-dev --account=$DEV_SA" "$T/calls.log" \
  && pass "7. rotate DRY_RUN=0, inject true: version added, then the hub rolled as the dev SA" || fail "7. rc=$rc add=$add_at roll=$roll_at $(cat "$T/out")"
no_leak && pass "7. no key byte in the output or argv" || fail "7. LEAK: $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
