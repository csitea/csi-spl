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
#   5. no BODY_HTML_FILE / ATTACH_FILE: the message is byte for byte the
#      text/plain one it always was
#   6. BODY_HTML_FILE: multipart/alternative, the html decodes to the same
#      sha256, no line over 998 octets
#   7. ATTACH_FILE: multipart/mixed, the file decodes to the same sha256;
#      both = mixed(alternative, file); a non-ASCII name is RFC 2231 encoded
#   8. a missing / unreadable / over-cap file and an over-cap message are
#      FATAL before any cloud call
#   9. DRY_RUN=1 prints the part tree, never the HTML or the file content
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

# --- 5..9. HTML body and attachment --------------------------------------------
command -v python3 >/dev/null || { echo "FAIL: no python3 to decode the MIME parts"; exit 1; }
# mime_tree <msg> -> one line per part: depth, type, file name (spaces as _),
# sha256 of the decoded payload (leaves only)
mime_tree() {
  python3 -I -c '
import email, hashlib, sys
from email import policy
m = email.message_from_binary_file(open(sys.argv[1], "rb"), policy=policy.compat32)
def walk(p, d):
    if p.is_multipart():
        print(d, p.get_content_type(), "-", "-")
        for c in p.get_payload(): walk(c, d + 1)
    else:
        fn = p.get_filename() or "-"
        print(d, p.get_content_type(), fn.replace(" ", "_"), hashlib.sha256(p.get_payload(decode=True)).hexdigest())
walk(m, 0)' "$1"
}
sha() { sha256sum <"$1" | cut -d' ' -f1; }
{ printf '<!doctype html><html><body><h1>Scrum HTMLMARK</h1><p>'; head -c 6000 /dev/zero | tr '\0' 'x'; printf '</p><p>Здравей</p></body></html>\n'; } >"$T/body.html"
head -c 3000 /dev/urandom >"$T/report.pdf"
printf 'ATTACHMARK\n' >"$T/Отчет é.md"

# 5. neither param: the message is exactly the text/plain one
run_send "${ARGS[@]}" DRY_RUN=0
printf 'From: %s\r\nTo: tester@example.com\r\nSubject: Test box: how to log in\r\nDate: %s\r\nMessage-ID: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\nHello,\r\n\r\nline two\r\n' \
  "$(sed -n 's/^From: \(.*\)\r$/\1/p' "$T/msg")" "$(sed -n 's/^Date: \(.*\)\r$/\1/p' "$T/msg")" "$(sed -n 's/^Message-ID: \(.*\)\r$/\1/p' "$T/msg")" >"$T/want"
cmp -s "$T/want" "$T/msg" && pass "5. neither param: the message is byte for byte the text/plain one" || fail "5. plain message changed: $(diff <(cat -A "$T/want") <(cat -A "$T/msg"))"

# 6. HTML body
run_send "${ARGS[@]}" DRY_RUN=0 BODY_HTML_FILE="$T/body.html"; rc=$?
mime_tree "$T/msg" >"$T/tree"
[[ $rc -eq 0 && "$(cut -d' ' -f1,2 "$T/tree" | tr '\n' ' ')" == "0 multipart/alternative 1 text/plain 1 text/html " ]] \
  && grep -qx "1 text/plain - $(sha "$T/body.txt")" "$T/tree" && grep -qx "1 text/html - $(sha "$T/body.html")" "$T/tree" \
  && pass "6. BODY_HTML_FILE: multipart/alternative(text, html), the html decodes to the same sha256" || fail "6. html: rc=$rc $(cat "$T/tree" "$T/out")"
LC_ALL=C awk '{ sub(/\r$/, "") } length($0) > 998 { bad = 1 } END { exit bad }' "$T/msg" && pass "6. no line over 998 octets (a 6000-char html line)" || fail "6. a line is over 998 octets"

# 7. attachment alone, then both, then a non-ASCII name
run_send "${ARGS[@]}" DRY_RUN=0 ATTACH_FILE="$T/report.pdf"; rc=$?
mime_tree "$T/msg" >"$T/tree"
[[ $rc -eq 0 && "$(cut -d' ' -f1,2 "$T/tree" | tr '\n' ' ')" == "0 multipart/mixed 1 text/plain 1 application/pdf " ]] \
  && grep -qx "1 application/pdf report.pdf $(sha "$T/report.pdf")" "$T/tree" && grep -q $'^Content-Disposition: attachment; filename="report.pdf"\r$' "$T/msg" \
  && pass "7. ATTACH_FILE: mixed(text, file), the file decodes to the same sha256" || fail "7. attach: rc=$rc $(cat "$T/tree" "$T/out")"
run_send "${ARGS[@]}" DRY_RUN=0 BODY_HTML_FILE="$T/body.html" ATTACH_FILE="$T/Отчет é.md"; rc=$?
mime_tree "$T/msg" >"$T/tree"
[[ $rc -eq 0 && "$(cut -d' ' -f1,2 "$T/tree" | tr '\n' ' ')" == "0 multipart/mixed 1 multipart/alternative 2 text/plain 2 text/html 1 text/markdown " ]] \
  && grep -qx "2 text/html - $(sha "$T/body.html")" "$T/tree" && grep -qx "1 text/markdown Отчет_é.md $(sha "$T/Отчет é.md")" "$T/tree" \
  && pass "7. both: mixed(alternative(text, html), file), each decodes to its sha256" || fail "7. both: rc=$rc $(cat "$T/tree" "$T/out")"
LC_ALL=C grep -q "^Content-Disposition: attachment; filename\*=UTF-8''%D0%9E%D1%82%D1%87%D0%B5%D1%82%20%C3%A9.md"$'\r$' "$T/msg" \
  && ! LC_ALL=C grep -aq '[^ -~'$'\r'']' <(sed -n '/^Content-Type: text\/markdown/,/^\r$/p' "$T/msg") \
  && pass "7. a non-ASCII file name is RFC 2231 / 2047 encoded, its headers ASCII only" || fail "7. name: $(grep -a 'Content-Disposition\|name=' "$T/msg")"

# 8. refusals before any cloud call
chmod 000 "$T/report.pdf"
[[ -r "$T/report.pdf" ]] && unread="" || unread="ATTACH_FILE=$T/report.pdf"
for bad in "BODY_HTML_FILE=$T/none.html" "ATTACH_FILE=$T/none.pdf" "ATTACH_FILE=$T" ${unread:+"$unread"} \
  "ATTACH_FILE=$T/body.html MAIL_MAX_BYTES=4000" "BODY_HTML_FILE=$T/body.html MAIL_MAX_BYTES=7000" MAIL_MAX_BYTES=0; do
  # shellcheck disable=SC2086
  run_send "${ARGS[@]}" DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" && ! -s "$T/argv" ]] && grep -q '^FATAL' "$T/out" && pass "8. $bad: FATAL before any call" || fail "8. $bad: rc=$rc $(cat "$T/calls.log" "$T/out")"
done
chmod 600 "$T/report.pdf"
run_send "${ARGS[@]}" BODY_HTML_FILE="$T/body.html" MAIL_MAX_BYTES=7000
grep -q 'FATAL the message is .* bytes, over MAIL_MAX_BYTES 7000' "$T/out" && pass "8. a message over the cap (each file under it) is refused" || fail "8. message cap: $(cat "$T/out")"

# 9. DRY_RUN=1 prints the tree, never the content
run_send "${ARGS[@]}" BODY_HTML_FILE="$T/body.html" ATTACH_FILE="$T/Отчет é.md"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -qx 'part multipart/mixed' "$T/out" && grep -q "^    part text/html.*sha256=$(sha "$T/body.html")$" "$T/out" \
  && grep -qx "  part attachment text/markdown; charset=UTF-8 (base64) name=Отчет é.md size=11 sha256=$(sha "$T/Отчет é.md")" "$T/out" && grep -qx 'To: tester@example.com' "$T/out" \
  && pass "9. DRY_RUN=1 prints the headers and the part tree" || fail "9. dry tree: rc=$rc $(cat "$T/out")"
grep -qE 'HTMLMARK|ATTACHMARK|Hello,|QVRUQUNITUFSSw|PCFkb2N0eXBl' "$T/out" && fail "9. DRY_RUN=1 printed content: $(cat "$T/out")" || pass "9. DRY_RUN=1 prints no HTML, file or body content"

echo "---"; (( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
