#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lang_review_gct (SPL-6174), hermetic: a stub Cloud
#          Translation v3 server on 127.0.0.1, a stubbed gcloud, a fake SA key.
#   1. a locale change against the base: one row per new / changed key and per
#      key whose en source changed, in every locale (an en change asks them
#      all); match when the text equals the fresh en -> lang reference, else
#      differs; the back translation is filled; the report
#      <out>/<run id>.json is written, the run id is <yyyymmddThhmmssZ>-<8hex>,
#      the 'Lang-review: gct <run id>' line is printed, exit 0
#   2. the placeholders survive: they go out as translate="no", so a stub
#      that renames a bare {name} (as the real API did: "Hei {nimi}") leaves
#      the reference's {name} alone
#   3. identity: gcloud mints the token as the key's client_email (--account)
#      in a throwaway CLOUDSDK_CONFIG with the key by
#      CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE; the request carries it as
#      'Authorization: Bearer'; the token is in no output and no report, the
#      project is the key's project_id
#   4. RED: a locale string whose {placeholder} differs from en -> mark
#      placeholder, exit 1, the report written, no Lang-review line
#   5. RED: the API refuses (403) -> exit 2, its status and message and the
#      grant it needs printed, no report
#   6. RED: no SA key -> exit 2 before gcloud or the API is called
#   7. LANG_GCT_FILES names one file: only its rows
#   8. round trip: the action's report and line, committed with the change,
#      pass the gate's checker (csi-spl-iac lang-review-gct-check.py)
#   9. the action resolves through the real ./run loader
#  10. RED: gcloud cannot mint the token -> exit 2, its reason printed
#  11. RED: a non-https endpoint (not 127.0.0.1) -> exit 2, no request
#  12. round trip of an en-only change: the en-changed rows of every locale
#      holding the key pass the gate's checker
#  13. another repo's tree (SPL-6208): locales in x-wui/i18n/locales
#      (a) LANG_GCT_FILES there, no LANG_GCT_LOCALES -> the dir is derived,
#          exit 0, the report under x-wui/i18n/lang-review/
#      (b) the same with LANG_GCT_LOCALES set explicitly
#      (c) RED: LANG_GCT_FILES in two dirs, no LANG_GCT_LOCALES -> exit 2,
#          both dirs named, no report, the API not called
#      (d) csi-spl's default unchanged: no LANG_GCT_FILES / _LOCALES /
#          _OUT_DIR -> the report under csi-spl-wui/i18n/lang-review/
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }
FI_HI='Moi {name}'

TOKEN="ya29.canaryGct${RANDOM}${RANDOM}x${RANDOM}"
L=csi-spl-wui/i18n/locales
mkdir -p "$T/stub" "$T/out" "$T/r/$L"
: >"$T/calls.log"

# the fake SA key
KEY="$T/key-csi-spl-dev.json"
printf '{"type":"service_account","project_id":"csi-spl-dev","client_email":"sa@csi-spl-dev.iam.gserviceaccount.com"}\n' >"$KEY"
chmod 600 "$KEY"

# stub gcloud: logs argv and the env it was given; prints the token only for
# print-access-token as the key's account under a private config
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $* CFG=${CLOUDSDK_CONFIG:-} CRED=${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" >>"$STUB_LOG"
[[ -n "${FAKE_GCLOUD_ERR:-}" ]] && { echo "$FAKE_GCLOUD_ERR" >&2; exit 1; }
[[ "$1 $2 $3" == "auth print-access-token --account=sa@csi-spl-dev.iam.gserviceaccount.com" ]] || exit 1
[[ -d "${CLOUDSDK_CONFIG:-}" && "$CLOUDSDK_CONFIG" != "$HOME/.config/gcloud" ]] || exit 1
echo "$FAKE_TOKEN"
EOF
chmod +x "$T/stub/gcloud"

# stub Cloud Translation v3: path, auth match (never the token itself) and
# body to the log; an answer per string from the map (dst|text), else
# "[dst] text" with every bare {name} renamed {nimi} (spans kept)
cat >"$T/server.py" <<'EOF'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log, portfile, token = sys.argv[1], sys.argv[2], sys.argv[3]
MAP = {"fi|Save": "Tallenna", "fi|Bye": "Heippa"}
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        auth = self.headers.get("Authorization") == "Bearer " + token
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth_ok": auth, "body": body}) + "\n")
        if os.environ.get("FAKE_GCT_STATUS") == "403":
            self.send_response(403); self.end_headers()
            self.wfile.write(b'{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Cloud Translation API has not been used"}}')
            return
        out = []
        for c in body["contents"]:
            k = body["targetLanguageCode"] + "|" + c
            out.append({"translatedText": MAP.get(k, "[" + body["targetLanguageCode"] + "] " + re.sub(r'(?<!">)\{name\}', "{nimi}", c))})
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"translations": out}).encode())
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
open(portfile + ".tmp", "w").write(str(s.server_port)); os.rename(portfile + ".tmp", portfile)
s.serve_forever()
EOF
SRV_PID=""
start_server() {  # [FAKE_GCT_STATUS=...]
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null && wait "$SRV_PID" 2>/dev/null
  rm -f "$T/port"; : >"$T/api.log"
  env "$@" python3 -I "$T/server.py" "$T/api.log" "$T/port" "$TOKEN" &
  SRV_PID=$!
  wait_event 10 test -s "$T/port" || fail "the stub server started"
}
trap '[[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"' EXIT

# the base: two keys in en, fi, sv
R="$T/r"
git init -q "$R"
printf '{"a":{"hi":"Hello {name}","bye":"Bye"}}\n' >"$R/$L/en.json"
printf '{"a":{"hi":"Hei {name}","bye":"Hei hei"}}\n' >"$R/$L/fi.json"
printf '{"a":{"hi":"Hej {name}","bye":"Hej då"}}\n' >"$R/$L/sv.json"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
# the change: a new key everywhere, fi changes 'bye' and 'hi'
change() {  # [fi hi text]
  printf '{"a":{"hi":"Hello {name}","bye":"Bye","new":"Save"}}\n' >"$R/$L/en.json"
  printf '{"a":{"hi":"%s","bye":"Näkemiin","new":"Tallenna"}}\n' "${1:-$FI_HI}" >"$R/$L/fi.json"
  printf '{"a":{"hi":"Hej {name}","bye":"Hej då","new":"Spara"}}\n' >"$R/$L/sv.json"
}

gct() {  # [VAR=value]... -> rc; output in $T/o
  rm -rf "$T/out"; mkdir -p "$T/out"
  IN_ORC_RUN=spl-lang-review-gct SNIPPET=do_spl_lang_review_gct in_orc FAKE_TOKEN="$TOKEN" GCP_SA_KEY_FILE="$KEY" \
    LANG_GCT_TREE="$R" LANG_GCT_BASE=HEAD LANG_GCT_OUT_DIR="$T/out" \
    LANG_GCT_ENDPOINT="http://127.0.0.1:$(cat "$T/port")" "$@" </dev/null >"$T/o" 2>&1
}
rep() {  # -> the one report in $T/out, or nothing
  local f
  for f in "$T/out"/*.json; do [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }; done
  return 0
}
jrow() {  # <file stem> <key> <field> -> the field of that row of the report
  jq -r --arg f "$L/$1.json" --arg k "$2" --arg x "$3" '.rows[] | select(.file == $f and .key == $k) | .[$x]' "$(rep)"
}

# 1. the report
start_server; change; gct
rc=$?; [[ "$rc" == 0 ]] && pass "1. a clean change -> exit 0" || fail "1. exit 0" "rc=$rc $(cat "$T/o")"
id="$(sed -n 's/^Lang-review: gct //p' "$T/o")"
[[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] && pass "1. prints 'Lang-review: gct <run id>' ($id)" || fail "1. the line" "$(cat "$T/o")"
[[ -f "$T/out/$id.json" ]] && pass "1. writes <out>/<run id>.json" || fail "1. the report file" "$(ls "$T/out")"
[[ "$(jq -r '.engine + " " + .run_id' "$(rep)")" == "gct $id" ]] && pass "1. the report is the gct report of that run" || fail "1. engine/run_id" "$(head -c 300 "$(rep)")"
rows="$(jq -r '[.rows[] | .file + " " + .key + " " + .why] | sort | join(",")' "$(rep)")"
want="$L/fi.json a.bye changed,$L/fi.json a.hi changed,$L/fi.json a.new new,$L/sv.json a.new new"
[[ "$rows" == "$want" ]] && pass "1. one row per new/changed key, en.json itself not a row" || fail "1. rows" "$rows"
[[ "$(jrow "fi" a.new mark)" == match ]] && pass "1. text == reference -> match" || fail "1. match" "$(jrow "fi" a.new mark)"
[[ "$(jrow "fi" a.bye mark) $(jrow "fi" a.bye reference)" == "differs Heippa" ]] && pass "1. text != reference -> differs, the reference kept" || fail "1. differs" "$(jrow "fi" a.bye mark) $(jrow "fi" a.bye reference)"
[[ "$(jrow sv a.new back)" == "[en] Spara" ]] && pass "1. the back translation lang -> en is filled" || fail "1. back" "$(jrow sv a.new back)"
[[ "$(jq -r '.summary | "\(.rows) \(.match) \(.differs) \(.placeholder)"' "$(rep)")" == "4 1 3 0" ]] && pass "1. the summary counts" || fail "1. summary" "$(jq -c .summary "$(rep)")"
# en changed 'bye'? no: an en key change in the base diff asks every locale
printf '{"a":{"hi":"Hello {name}","bye":"Goodbye","new":"Save"}}\n' >"$R/$L/en.json"; gct
[[ "$(jrow sv a.bye why)" == en-changed ]] && pass "1. a changed en source lists the unchanged sv key as en-changed" || fail "1. en-changed" "$(jq -c '.rows' "$(rep)")"

# 2. placeholders survive
change; gct
[[ "$(jrow "fi" a.hi reference)" == "[fi] Hello {name}" ]] && pass "2. the reference keeps {name} (sent as translate=no)" || fail "2. placeholder kept" "$(jrow "fi" a.hi reference)"
grep -q 'Hello <span translate=\\"no\\">{name}</span>' "$T/api.log" && pass "2. ... the request wraps it" || fail "2. ... wraps" "$(head -c 400 "$T/api.log")"
grep -q '"mimeType": "text/html"' "$T/api.log" && pass "2. ... as text/html" || fail "2. ... html" "$(head -c 300 "$T/api.log")"

# 3. identity and the token
grep -q '^gcloud auth print-access-token --account=sa@csi-spl-dev.iam.gserviceaccount.com CFG=/' "$T/calls.log" &&
  pass "3. the token is minted as the key's client_email" || fail "3. --account" "$(cat "$T/calls.log")"
grep -q " CRED=$KEY$" "$T/calls.log" && pass "3. ... with the key by CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" || fail "3. CRED" "$(cat "$T/calls.log")"
grep -q "CFG=$HOME/.config/gcloud " "$T/calls.log" && fail "3. never the shared config" "$(cat "$T/calls.log")" || pass "3. never the shared config"
[[ "$(jq -s 'all(.auth_ok)' "$T/api.log")" == true ]] && pass "3. every request carries 'Authorization: Bearer <token>'" || fail "3. auth" "$(jq -c .auth_ok "$T/api.log")"
grep -q '"path": "/v3/projects/csi-spl-dev/locations/global:translateText"' "$T/api.log" && pass "3. v3 translateText in the key's project" || fail "3. path" "$(head -c 200 "$T/api.log")"
grep -rqF "$TOKEN" "$T/o" "$T/out" && fail "3. the token is in no output or report" || pass "3. the token is in no output or report"

# 4. RED: a placeholder differs
change 'Moi {nimi}'; gct
eq "4. a {placeholder} differs from en -> exit 1" 1 "$?"
eq "4. ... the row is marked placeholder" placeholder "$(jrow "fi" a.hi mark)"
grep -q '^Lang-review: gct' "$T/o" && fail "4. ... no Lang-review line" "$(cat "$T/o")" || pass "4. ... no Lang-review line"

# 5. RED: the API refuses
start_server FAKE_GCT_STATUS=403; change; gct
eq "5. a 403 -> exit 2" 2 "$?"
grep -q 'http 403: PERMISSION_DENIED Cloud Translation API has not been used' "$T/o" && pass "5. ... prints its status and message" || fail "5. ... status" "$(cat "$T/o")"
grep -q 'roles/cloudtranslate.user' "$T/o" && pass "5. ... names the grant it needs" || fail "5. ... grant" "$(cat "$T/o")"
[[ -z "$(rep)" ]] && pass "5. ... no report" || fail "5. ... no report" "$(rep)"
start_server

# 6. RED: no SA key
: >"$T/calls.log"; : >"$T/api.log"
gct GCP_SA_KEY_FILE="$T/none.json"
eq "6. no SA key -> exit 2" 2 "$?"
grep -q 'never the owner account' "$T/o" && pass "6. ... says never the owner account" || fail "6. ... says" "$(cat "$T/o")"
[[ ! -s "$T/calls.log" && ! -s "$T/api.log" ]] && pass "6. ... neither gcloud nor the API was called" || fail "6. ... no calls" "$(cat "$T/calls.log" "$T/api.log")"

# 7. one file
change; gct LANG_GCT_FILES="$L/sv.json"
eq "7. LANG_GCT_FILES=sv.json -> only its rows" "$L/sv.json" "$(jq -r '[.rows[].file] | unique | join(",")' "$(rep)")"

# 8. round trip through the gate's checker
change; gct; id="$(sed -n 's/^Lang-review: gct //p' "$T/o")"
mkdir -p "$R/csi-spl-wui/i18n/lang-review"; cp "$T/out/$id.json" "$R/csi-spl-wui/i18n/lang-review/"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm "feat(wui): text" -m "Lang-review: gct $id"
python3 "$APP_ROOT/csi-spl-iac/src/bash/scripts/lang-review-gct-check.py" "$R" "$L" csi-spl-wui/i18n/lang-review HEAD "$id" >"$T/chk" 2>&1
eq "8. the committed report and line pass the gate's checker" 0 "$?"

# 9. the real ./run loader
( cd "$PROJ_ROOT" && env PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" FAKE_TOKEN="$TOKEN" GCP_SA_KEY_FILE="$KEY" \
    LANG_GCT_TREE="$R" LANG_GCT_BASE=HEAD~1 LANG_GCT_OUT_DIR="$T/out" LANG_GCT_ENDPOINT="http://127.0.0.1:$(cat "$T/port")" \
    ./run -a do_spl_lang_review_gct ) >"$T/run" 2>&1
eq "9. ./run -a do_spl_lang_review_gct resolves and passes" 0 "$?"
grep -q 'NOT found' "$T/run" && fail "9. ... no 'NOT found'" "$(tail -3 "$T/run")" || pass "9. ... no 'NOT found'"

# 10. RED: gcloud fails
change; gct FAKE_GCLOUD_ERR="ERROR: (gcloud.auth.print-access-token) invalid_grant: account not found"
eq "10. gcloud cannot mint the token -> exit 2" 2 "$?"
grep -q 'gcloud: ERROR: (gcloud.auth.print-access-token) invalid_grant' "$T/o" && pass "10. ... prints gcloud's reason" || fail "10. ... reason" "$(cat "$T/o")"

# 11. RED: the token never goes to a plain-http host
change; gct LANG_GCT_ENDPOINT="http://translation.example.com"
eq "11. an http endpoint off 127.0.0.1 -> exit 2" 2 "$?"
grep -q 'is not https' "$T/o" && pass "11. ... says not https" || fail "11. ... says" "$(cat "$T/o")"
grep -qF "$TOKEN" "$T/o" && fail "11. ... no token in the output" || pass "11. ... no token in the output"

# 12. round trip of an en-only change
git -C "$R" checkout -q -- . 2>/dev/null; git -C "$R" clean -qfd
printf '{"a":{"hi":"Hello {name}","bye":"Goodbye","new":"Save"}}\n' >"$R/$L/en.json"
rm -rf "$T/out"; mkdir -p "$T/out"
IN_ORC_RUN=spl-lang-review-gct SNIPPET=do_spl_lang_review_gct in_orc FAKE_TOKEN="$TOKEN" GCP_SA_KEY_FILE="$KEY" \
  LANG_GCT_TREE="$R" LANG_GCT_BASE=HEAD LANG_GCT_OUT_DIR="$T/out" \
  LANG_GCT_ENDPOINT="http://127.0.0.1:$(cat "$T/port")" </dev/null >"$T/o" 2>&1
eq "12. an en-only change -> exit 0" 0 "$?"
id="$(sed -n 's/^Lang-review: gct //p' "$T/o")"
eq "12. ... en-changed rows for fi and sv" "en-changed en-changed" "$(jq -r '[.rows[] | select(.key == "a.bye") | .why] | join(" ")' "$T/out/$id.json" 2>/dev/null)"
cp "$T/out/$id.json" "$R/csi-spl-wui/i18n/lang-review/"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm "feat(wui): en text" -m "Lang-review: gct $id"
python3 "$APP_ROOT/csi-spl-iac/src/bash/scripts/lang-review-gct-check.py" "$R" "$L" csi-spl-wui/i18n/lang-review HEAD "$id" >"$T/chk" 2>&1
eq "12. ... the committed report passes the gate's checker" 0 "$?"

# 13. another repo's tree: the locales dir is not csi-spl's
X=x-wui/i18n/locales; R2="$T/r2"
mkdir -p "$R2/$X"; git init -q "$R2"
printf '{"a":{"bye":"Bye"}}\n' >"$R2/$X/en.json"
printf '{"a":{"bye":"Hei hei"}}\n' >"$R2/$X/fi.json"
printf '{"a":{"bye":"Hej då"}}\n' >"$R2/$X/sv.json"
git -C "$R2" add -A; git -C "$R2" -c user.name=t -c user.email=t@t commit -qm base
printf '{"a":{"bye":"Bye","new":"Save"}}\n' >"$R2/$X/en.json"
printf '{"a":{"bye":"Hei hei","new":"Tallenna"}}\n' >"$R2/$X/fi.json"
printf '{"a":{"bye":"Hej då","new":"Spara"}}\n' >"$R2/$X/sv.json"
gct_tree() {  # <tree> [VAR=value]... -> rc; no LANG_GCT_OUT_DIR; output in $T/o
  local tree="$1"; shift
  IN_ORC_RUN=spl-lang-review-gct SNIPPET=do_spl_lang_review_gct in_orc FAKE_TOKEN="$TOKEN" GCP_SA_KEY_FILE="$KEY" \
    LANG_GCT_TREE="$tree" LANG_GCT_BASE=HEAD \
    LANG_GCT_ENDPOINT="http://127.0.0.1:$(cat "$T/port")" "$@" </dev/null >"$T/o" 2>&1
}
xrep() {  # <tree> <dir> -> the run id's report path, from the printed line
  local id; id="$(sed -n 's/^Lang-review: gct //p' "$T/o")"
  [[ -n "$id" ]] && printf '%s' "$1/$2/$id.json"
}
rm -rf "$R2/x-wui/i18n/lang-review"
gct_tree "$R2" LANG_GCT_FILES="$X/fi.json $X/sv.json"
eq "13a. x-wui locales, no LANG_GCT_LOCALES -> exit 0" 0 "$?"
f="$(xrep "$R2" x-wui/i18n/lang-review)"
[[ -n "$f" && -f "$f" ]] && pass "13a. ... the report under x-wui/i18n/lang-review/" || fail "13a. ... report" "$(cat "$T/o"; ls -R "$R2/x-wui")"
eq "13a. ... rows of both files" "$X/fi.json,$X/sv.json" "$(jq -r '[.rows[].file] | unique | join(",")' "$f" 2>/dev/null)"
rm -rf "$R2/x-wui/i18n/lang-review"
gct_tree "$R2" LANG_GCT_FILES="$X/fi.json" LANG_GCT_LOCALES="$X/"
eq "13b. LANG_GCT_LOCALES set explicitly -> exit 0" 0 "$?"
f="$(xrep "$R2" x-wui/i18n/lang-review)"
[[ -n "$f" && -f "$f" ]] && pass "13b. ... the report under x-wui/i18n/lang-review/" || fail "13b. ... report" "$(cat "$T/o")"
rm -rf "$R2/x-wui/i18n/lang-review"; : >"$T/api.log"
gct_tree "$R2" LANG_GCT_FILES="$X/fi.json $L/fi.json"
eq "13c. two locales dirs, no LANG_GCT_LOCALES -> exit 2" 2 "$?"
grep -qF "two locales dirs ($X, $L)" "$T/o" && pass "13c. ... names both dirs" || fail "13c. ... names both" "$(cat "$T/o")"
[[ ! -e "$R2/x-wui/i18n/lang-review" && ! -s "$T/api.log" ]] && pass "13c. ... no report, the API not called" || fail "13c. ... no report" "$(ls "$R2/x-wui/i18n"; head -c 200 "$T/api.log")"
change; gct_tree "$R"
eq "13d. csi-spl defaults -> exit 0" 0 "$?"
f="$(xrep "$R" csi-spl-wui/i18n/lang-review)"
[[ -n "$f" && -f "$f" ]] && pass "13d. ... the report under csi-spl-wui/i18n/lang-review/" || fail "13d. ... report" "$(cat "$T/o")"

echo "spl-lang-review-gct: $fails failure(s)"
((fails == 0))
