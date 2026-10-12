#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_mail_send sends ONE mail over the cnf relay, gcloud and curl
#   stubbed:
#   1. DRY_RUN (default) calls no cloud, dials no SMTP, prints the message
#   2. bad input is refused before any call
#   3. DRY_RUN=0 reads the relay password as the env SA (--account), keeps it
#      out of curl argv and the output, requires STARTTLS, mails the one
#      recipient and reports the Message-ID it set
#   4. a relay refusal is a FATAL, exit 1; an unreadable password sends nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

PRD_SA=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com
FAKE_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
printf '{"type":"service_account","client_email":"%s"}\n' "$PRD_SA" >"$T/home/.gcp/.csi/key-csi-spl-prd.json"
printf 'Hello,\n\nline two\n' >"$T/body.txt"

cat >"$T/stub/gcloud" <<STUB
#!/usr/bin/env bash
echo "gcloud \$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) [[ "\${STUB_PW:-yes}" == yes ]] && echo "$FAKE_PW" ;;
esac
exit 0
STUB
cat >"$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T_ARGV"
echo "curl $*" >>"$STUB_LOG"
while (( $# )); do
  case "$1" in
    --upload-file) cp "$2" "$T_MSG"; shift 2;;
    --netrc-file) cp "$2" "$T_NETRC"; shift 2;;
    *) shift;;
  esac
done
[[ "${STUB_SMTP:-ok}" == ok ]] || { echo "curl: (55) 550 relay refused" >&2; exit 55; }
exit 0
STUB
chmod +x "$T/stub/"*

run_send() {
  : >"$T/calls.log"; : >"$T/argv"; rm -f "$T/msg" "$T/netrc"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    T_ARGV="$T/argv" T_MSG="$T/msg" T_NETRC="$T/netrc" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=prd "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_mail_send' >"$T/out" 2>&1 </dev/null
}
ARGS=(TO=tester@example.com "SUBJECT=Test box: how to log in" BODY_FILE="$T/body.txt")

# --- 1. dry run ---------------------------------------------------------------
run_send "${ARGS[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would mail this message to tester@example.com' "$T/out" \
  && grep -qx 'To: tester@example.com' "$T/out" && grep -qx 'Subject: Test box: how to log in' "$T/out" && grep -qx 'line two' "$T/out" \
  && pass "1. DRY_RUN: no cloud call, no SMTP; prints the whole message" || fail "1. dry: rc=$rc $(cat "$T/calls.log" "$T/out")"

# --- 2. refusals --------------------------------------------------------------
for bad in TO=nope TO='a@b.c,d@e.f' SUBJECT= BODY_FILE="$T/none.txt" DRY_RUN=2; do
  run_send "${ARGS[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc $(cat "$T/out")"
done

# --- 3. real run --------------------------------------------------------------
run_send "${ARGS[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "secrets versions access latest --secret=csi-spl-hub-mail-smtp-password --project=csi-spl-prd --account=$PRD_SA" "$T/calls.log" \
  && pass "3. the relay password is read as the env SA with --account" || fail "3. secret read: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -q -- '--ssl-reqd' "$T/argv" && grep -q -- '--mail-rcpt tester@example.com' "$T/argv" && grep -q 'smtp://smtp\.' "$T/argv" \
  && pass "3. curl dials the cnf relay with STARTTLS required, one recipient" || fail "3. curl argv: $(cat "$T/argv")"
grep -qF "$FAKE_PW" "$T/argv" "$T/out" && fail "3. the password leaked into argv or output" || pass "3. the password is in no argv and no output"
grep -qF "password $FAKE_PW" "$T/netrc" && pass "3. the password reaches curl via the netrc file" || fail "3. netrc: $(cat "$T/netrc" 2>/dev/null)"
mid="$(sed -n 's/^Message-ID: \(.*\)\r$/\1/p' "$T/msg")"
[[ -n "$mid" ]] && grep -qF "message_id $mid" "$T/out" && grep -q $'^line two\r$' "$T/msg" \
  && pass "3. the Message-ID it set is reported; the body has CRLF line ends" || fail "3. message id: $(cat "$T/out")"
owner="$(yq -r '.env.gcp.gcp_account_owner_email // "no-owner-in-cnf"' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")"
grep -qF "$owner" "$T/calls.log" && fail "3. the owner account was used" || pass "3. the owner account appears in no call"

# non-ASCII subject is RFC 2047 encoded
run_send TO=tester@example.com "SUBJECT=Тестова машина" BODY_FILE="$T/body.txt"; rc=$?
grep -qx 'Subject: =?UTF-8?B?0KLQtdGB0YLQvtCy0LAg0LzQsNGI0LjQvdCw?=' "$T/out" \
  && pass "3. a non-ASCII subject is RFC 2047 encoded" || fail "3. subject: $(grep Subject "$T/out")"

# --- 4. failures --------------------------------------------------------------
run_send "${ARGS[@]}" DRY_RUN=0 STUB_SMTP=refuse; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FATAL the relay .* refused the mail' "$T/out" && pass "4. a relay refusal is FATAL, exit 1" || fail "4. refuse: rc=$rc $(cat "$T/out")"
run_send "${ARGS[@]}" DRY_RUN=0 STUB_PW=no; rc=$?
[[ $rc -eq 1 ]] && ! grep -q '^curl' "$T/calls.log" && pass "4. no readable password: nothing sent, exit 1" || fail "4. no pw: rc=$rc $(cat "$T/calls.log")"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
