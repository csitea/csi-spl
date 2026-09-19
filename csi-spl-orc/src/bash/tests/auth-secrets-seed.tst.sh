#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_auth_secrets_seed (spec 010 T032) adds the session-key and
#          Google client-secret versions only when told (DRY_RUN=0), mints the
#          session key only when absent, adds the Google secret only when it
#          differs, refuses a client file for another project / client or an
#          ambiguous glob, and never puts a value in argv or output. By CALLING
#          it against a stubbed gcloud with a file-backed secret store, HOME in
#          a temp dir holding a fake client file.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

CID=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml")
NUM="${CID%%-*}"
[[ "$NUM" =~ ^[0-9]+$ ]] || { echo "FAIL: dev cnf has no numeric google client id: $CID"; exit 1; }
SECRET="GOCSPX-test-$RANDOM-$RANDOM"
CD="$T/home/.gcp/.csi/.spl"; mkdir -p "$CD" "$T/store"
client() {  # <file> <project_id> <client_id> <secret>
  printf '{"web":{"client_id":"%s","project_id":"%s","client_secret":"%s"}}\n' "$3" "$2" "$4" >"$1"
}
client "$CD/client_secret_$NUM-x.apps.googleusercontent.com.json" csi-spl-dev "$CID" "$SECRET"

run_seed() {  # [VAR=value ...] -> stdout+stderr of the action; gcloud argv in $T/argv
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" STORE="$T/store" \
      ARGV="$T/argv" ENV=dev GCP_ACCOUNT=stub-sa@example.com "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "auth print-access-token"*) echo "ya29.stub_token_value_long_enough" ;;
        "projects describe"*) echo "'"$NUM"'" ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*) local s="$4"; cat >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_auth_secrets_seed' 2>&1
}
SK=csi-spl-hub-auth-session-key GS=csi-spl-hub-auth-google-client-secret
adds() { grep -c . "$T/store/.adds" 2>/dev/null || echo 0; }

out=$(run_seed); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 ]] && pass "default is a dry run: nothing added" || fail "dry run: rc=$rc adds=$(adds) $out"

out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -eq 0 && -f "$T/store/$GS" && -f "$T/store/$SK" ]] && pass "DRY_RUN=0 adds both versions" || fail "real run: rc=$rc $out"
[[ "$(cat "$T/store/$GS")" == "$SECRET" ]] && pass "the google version == the file's client_secret (no newline)" || fail "google version differs"
[[ "$(base64 -d <"$T/store/$SK" | wc -c)" -eq 48 ]] && pass "the session key is 48 random bytes, base64" || fail "session key is $(base64 -d <"$T/store/$SK" 2>/dev/null | wc -c) bytes"
if grep -qF "$SECRET" <<<"$out" || grep -qF "$(cat "$T/store/$SK")" <<<"$out"; then fail "a value appears in the output"; else pass "no value in the output"; fi
if grep -qF "$SECRET" "$T/argv" || grep -qF "$(cat "$T/store/$SK")" "$T/argv"; then fail "a value appears in gcloud argv"; else pass "no value in gcloud argv"; fi
[[ $(grep -vc -- '--account=stub-sa@example.com' "$T/argv") -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned gcloud call"

sk_before=$(cat "$T/store/$SK"); n=$(adds)
out=$(run_seed DRY_RUN=0)
[[ $(adds) -eq $n && "$(cat "$T/store/$SK")" == "$sk_before" ]] && pass "a re-run adds nothing (idempotent)" || fail "re-run added: $(adds) vs $n"

client "$CD/client_secret_$NUM-x.apps.googleusercontent.com.json" csi-spl-dev "$CID" "$SECRET-rotated"
out=$(run_seed DRY_RUN=0)
[[ "$(cat "$T/store/$GS")" == "$SECRET-rotated" && "$(cat "$T/store/$SK")" == "$sk_before" ]] \
  && pass "a changed client secret is re-added, the session key is kept" || fail "rotation: $out"

n=$(adds)
client "$CD/client_secret_$NUM-x.apps.googleusercontent.com.json" csi-spl-prd "$CID" "$SECRET"
out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "a client file for another project is refused, nothing added" || fail "wrong project: rc=$rc"

client "$CD/client_secret_$NUM-x.apps.googleusercontent.com.json" csi-spl-dev "999-other.apps.googleusercontent.com" "$SECRET"
out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "a client_id that differs from cnf is refused" || fail "wrong client id: rc=$rc"

client "$CD/client_secret_$NUM-x.apps.googleusercontent.com.json" csi-spl-dev "$CID" "$SECRET"
client "$CD/client_secret_$NUM-y.apps.googleusercontent.com.json" csi-spl-dev "$CID" "$SECRET"
out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -ne 0 && $(adds) -eq $n ]] && pass "two matching client files are refused (ambiguous)" || fail "ambiguous glob: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
