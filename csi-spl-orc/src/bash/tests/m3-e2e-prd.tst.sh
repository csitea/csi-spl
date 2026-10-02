#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_m3_e2e ENV=prd mode (CLE-3396), offline (no cloud call):
#   1. prd refuses every tenant but a test tenant (t1, acme, e2ex) BEFORE any
#      gcloud / spool / curl call. CONTROL: the stubs log a call when one runs.
#   2. prd with no tenant key JSON and no M3_CREATE_TENANT=1 stops, no call
#   3. an existing <tenants dir>/e2e.*.json is picked (the newest)
#   4. the humans are plus-addresses of the cnf relay mailbox, fixed per state
#      dir; the relay password lands in a 0600 file, read with --account, and
#      is in no output
#   5. m3-e2e.py: the IMAP reader returns the token of a NEW verify mail only,
#      and its evidence carries the page but never the token
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/stub" "$T/tenants"
for b in curl docker spool; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/prd" STUB_LOG="$T/calls.log" \
    SPL_TENANTS_DIR="$T/tenants" PATH="$T/stub:$PATH" ENV=prd GCP_ACCOUNT=stub-sa@example.com "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    gcloud() {
      echo "gcloud $*" >>"$STUB_LOG"
      case "$*" in
        "secrets versions access latest "*) echo "relay-app-password-s3cret" ;;
        *) return 1 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. only a test tenant runs on prd ------------------------------------------------
for bad in t1 acme e2ex e2e-; do
  : >"$T/calls.log"
  if out=$(SNIPPET=do_spl_m3_e2e in_orc TENANT_ID=$bad 2>&1); then
    fail "prd accepts tenant $bad"
  elif [[ -s "$T/calls.log" ]]; then
    fail "prd tenant $bad: a call ran before the refusal: $(head -1 "$T/calls.log")"
  else
    grep -q "test tenant" <<<"$out" && pass "prd refuses tenant $bad, no call" || fail "refusal text for $bad: $out"
  fi
done
: >"$T/calls.log"
SNIPPET='gcloud x || true; spool y' in_orc >/dev/null 2>&1
[[ $(wc -l <"$T/calls.log") == 2 ]] && pass "CONTROL: the stubs log a call" || fail "CONTROL stubs: $(cat "$T/calls.log")"

# --- 2. no key JSON, no create flag --------------------------------------------------
: >"$T/calls.log"
if out=$(SNIPPET=do_spl_m3_e2e in_orc 2>&1); then
  fail "prd ran with no tenant key"
else
  grep -q "M3_CREATE_TENANT=1" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "no key JSON: stops, names M3_CREATE_TENANT, no call" \
    || fail "no key JSON: $out / $(cat "$T/calls.log")"
fi

# --- 3. the newest key JSON of the tenant --------------------------------------------
echo '{}' >"$T/tenants/e2e.20260101T000000Z.json"; echo '{}' >"$T/tenants/e2e.20260919T000000Z.json"
echo '{}' >"$T/tenants/e2e-b.20270101T000000Z.json"
out=$(SNIPPET='do_spl_cloud_cnf && spl_m3_prd_prepare e2e && echo "KEY=$ROOT_KEY_JSON"' in_orc 2>&1)
grep -qx "KEY=$T/tenants/e2e.20260919T000000Z.json" <<<"$out" && pass "picks the newest e2e.*.json" || fail "key pick: $out"

# --- 4. humans + relay password -------------------------------------------------------
st="$T/state/prd/m3-e2e/e2e"; mkdir -p "$st"
: >"$T/calls.log"
snip='do_spl_cloud_cnf && spl_m3_prd_humans '"$st"' && echo "H=$M3_HUMAN_EMAIL O=$M3_OUTSIDER_EMAIL U=$M3_IMAP_USER I=$M3_IMAP_HOST"'
out1=$(SNIPPET="$snip" in_orc 2>&1); out2=$(SNIPPET="$snip" in_orc 2>&1)
user=$(grep -o 'U=[^ ]*' <<<"$out1" | cut -d= -f2)
h1=$(grep -o 'H=[^ ]*' <<<"$out1" | cut -d= -f2); h2=$(grep -o 'H=[^ ]*' <<<"$out2" | cut -d= -f2)
o1=$(grep -o 'O=[^ ]*' <<<"$out1" | cut -d= -f2)
[[ "$user" == *@* && "$h1" == "${user%@*}+spl-e2e-"*"@${user#*@}" && "$o1" == "${user%@*}+spl-e2e-out-"*"@${user#*@}" ]] \
  && pass "plus-addresses of the relay mailbox" || fail "addresses: $out1"
[[ -n "$h1" && "$h1" == "$h2" ]] && pass "the human is fixed per state dir" || fail "human moved: $h1 vs $h2"
grep -q 'I=imap\.' <<<"$out1" && pass "IMAP host derived from the SMTP host" || fail "imap host: $out1"
[[ -f "$st/imap-pass" && "$(stat -c %a "$st/imap-pass")" == 600 && "$(cat "$st/imap-pass")" == relay-app-password-s3cret ]] \
  && pass "relay password in a 0600 file" || fail "imap-pass file: $(stat -c %a "$st/imap-pass" 2>&1)"
grep -q s3cret <<<"$out1$out2" && fail "the relay password reached the output" || pass "the relay password is in no output"
grep 'secrets versions access' "$T/calls.log" | grep -qv -- '--account=' && fail "a secret read without --account" \
  || { grep -q -- 'secrets versions access latest --secret=.* --account=stub-sa@example.com' "$T/calls.log" \
       && pass "secret read pins --account" || fail "no secret read: $(cat "$T/calls.log")"; }
SNIPPET="M3_IMAP_PASS_FILE=$st/imap-pass spl_m3_imap_forget" in_orc >/dev/null 2>&1
[[ ! -e "$st/imap-pass" ]] && pass "spl_m3_imap_forget removes the password file" || fail "imap-pass left behind"

# --- 5. the IMAP reader ----------------------------------------------------------------
mkdir -p "$T/py"; echo pw >"$T/py/pass"
out=$(M3_STATE="$T/py" M3_IMAP_USER=box@example.com M3_IMAP_PASS_FILE="$T/py/pass" M3_IMAP_TIMEOUT=3 \
  python3 -B - "$PROJ_ROOT/src/bash/scripts/m3-e2e.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m3", sys.argv[1]); m3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m3)
TOK_OLD, TOK_NEW = "a" * 64, "b" * 64
def mail(tok):
    return ("From: relay <noreply@example.com>\r\nTo: box+x@example.com\r\nSubject: Confirm your email\r\n"
            "Message-ID: <m-%s@example.com>\r\nContent-Type: text/plain\r\n\r\nopen:\r\n"
            "https://app.example.com/verify-email?token=%s\r\n" % (tok[:4], tok)).encode()
BOX = {b"1": mail(TOK_OLD), b"2": mail(TOK_NEW)}
class Fake:
    def __init__(self, *a, **k): pass
    def login(self, u, p): assert p == "pw"
    def select(self, *a, **k): pass
    def uid(self, cmd, *a):
        if cmd == "SEARCH": return "OK", [b" ".join(sorted(BOX))]
        return "OK", [(b"x", BOX[a[0]])]
    def logout(self): pass
m3.imaplib.IMAP4_SSL = Fake
m3.http = lambda method, url, *a, **k: (404, {"Content-Type": "text/html"}, None)
tok, ev = m3.imap_verify_token("box+x@example.com", {b"1"})
print("NEW" if tok == TOK_NEW else "WRONG %s" % tok[:4])
print("LEAK" if TOK_NEW in str(ev) or TOK_OLD in str(ev) else "CLEAN")
print("PAGE %s %s" % (ev.get("link_page"), ev.get("link_page_status")))
tok, ev = m3.imap_verify_token("box+x@example.com", {b"1", b"2"})
print("NONE" if tok == "" and "no verify mail" in ev.get("mail", "") else "UNEXPECTED %s" % tok[:4])
PY
)
grep -qx NEW <<<"$out" && pass "IMAP: the NEW mail's token" || fail "IMAP token: $out"
grep -qx CLEAN <<<"$out" && pass "IMAP evidence carries no token" || fail "IMAP evidence leaks: $out"
grep -qx "PAGE https://app.example.com/verify-email 404" <<<"$out" && pass "IMAP evidence: link page + status" || fail "page: $out"
grep -qx NONE <<<"$out" && pass "IMAP: an old mail only -> no token (CONTROL)" || fail "old-only: $out"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
