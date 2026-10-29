#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_fleet_desk_box (spec 158 row T6), driven against a stub hub:
#          a local HTTP server that answers the three fleet-desk doors and
#          records every request it gets. The real spl_hub_operator_call runs
#          (curl, the -K header file); only gcloud and the cnf are stubbed.
#   1. add / remove with no DRY_RUN print the change and send nothing
#   2. bad input (a bad BOX_ID, no BOX_ID, a bad command, DRY_RUN=2) is
#      refused before any request
#   3. list (the default) GETs the doors and prints each box
#   4. add PUTs the box with the bearer token: 201 added, 200 already listed
#   5. remove DELETEs it: 204
#   6. the hub's refusals fail: 409 no_live_pin (RED CONTROL of the hub
#      rule: the box with no live pin is not added), 404, 403
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

cat >"$T/hub.py" <<'PY'
import http.server, json, sys
log, portfile = sys.argv[1], sys.argv[2]
ITEMS = [{"box_id": "desk-a", "added_by": "HUM-10", "added_at": "2026-10-29T00:00:00Z", "live_pin": True}]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body=None):
        with open(log, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, self.headers.get("Authorization", "-")))
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_GET(self):
        self.answer(200, {"items": ITEMS}) if self.path == "/v1/operator/fleet-desks" else self.answer(404, {"error": "not_found"})
    def do_PUT(self):
        box = self.path.rsplit("/", 1)[-1]
        if box == "no-pin":
            return self.answer(409, {"error": "no_live_pin", "detail": "box no-pin holds no live pin in the operator workspace"})
        if box == "not-sa":
            return self.answer(403, {"error": "forbidden"})
        self.answer(200 if box == "desk-a" else 201, {"box_id": box, "added_by": "sa", "live_pin": True})
    def do_DELETE(self):
        self.answer(404, {"error": "not_found"}) if self.path.endswith("/gone") else self.answer(204)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$T/hub.py" "$T/reqs" "$T/port" &
hub_pid=$!
trap 'kill "$hub_pid" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
[[ -s "$T/port" ]] || { echo "FAIL: the stub hub did not start"; exit 1; }
HUB="http://127.0.0.1:$(cat "$T/port")"

run() {
  : >"$T/reqs"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev HUB="$HUB" STATE="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev SPL_STATE_DIR="$STATE"; }
    spl_hub_operator_url() { SPL_HUB_URL="$HUB"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    gcloud() { echo stub-id-token; }
    do_spl_fleet_desk_box' >"$T/o" 2>&1
}

# --- 1. dry run ---------------------------------------------------------------
run FLEET_DESK_CMD=add BOX_ID=desk-b; rc=$?
[[ $rc -eq 0 && ! -s "$T/reqs" ]] && grep -q "DRY_RUN would PUT $HUB/v1/operator/fleet-desks/desk-b (add fleet desk box desk-b)" "$T/o" \
  && pass "1. add with no DRY_RUN prints and sends nothing" || fail "1. dry add: rc=$rc $(cat "$T/reqs" "$T/o")"
run FLEET_DESK_CMD=remove BOX_ID=desk-b; rc=$?
[[ $rc -eq 0 && ! -s "$T/reqs" ]] && grep -q "DRY_RUN would DELETE" "$T/o" \
  && pass "1. remove with no DRY_RUN prints and sends nothing" || fail "1. dry remove: rc=$rc $(cat "$T/reqs" "$T/o")"

# --- 2. refusals before any request ---------------------------------------------
for bad in "FLEET_DESK_CMD=add BOX_ID=Desk_B" "FLEET_DESK_CMD=add BOX_ID=" "FLEET_DESK_CMD=remove BOX_ID=-x" \
  "FLEET_DESK_CMD=purge BOX_ID=desk-b" "FLEET_DESK_CMD=add BOX_ID=desk-b DRY_RUN=2"; do
  # shellcheck disable=SC2086 # word-split on purpose: one case is several VAR=value words
  run DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/reqs" ]] && pass "2. $bad refused before any request" || fail "2. $bad: rc=$rc $(cat "$T/reqs" "$T/o")"
done

# --- 3. list --------------------------------------------------------------------
run; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'GET /v1/operator/fleet-desks Bearer stub-id-token' "$T/reqs" \
  && grep -q '^OK dev fleet desk boxes: 1' "$T/o" && grep -q 'desk-a  live_pin=true  added_by=HUM-10' "$T/o" \
  && pass "3. list GETs with the SA's id token and prints each box" || fail "3. list: rc=$rc $(cat "$T/reqs" "$T/o")"

# --- 4. add ---------------------------------------------------------------------
run FLEET_DESK_CMD=add BOX_ID=desk-b DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'PUT /v1/operator/fleet-desks/desk-b Bearer stub-id-token' "$T/reqs" \
  && grep -q '^OK dev fleet desk box desk-b added (sa@example.iam.gserviceaccount.com)' "$T/o" \
  && pass "4. add PUTs the box: 201 added" || fail "4. add: rc=$rc $(cat "$T/reqs" "$T/o")"
run FLEET_DESK_CMD=add BOX_ID=desk-a DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'desk-a was already listed: nothing changed' "$T/o" \
  && pass "4. add of a listed box: 200, nothing changed" || fail "4. add again: rc=$rc $(cat "$T/o")"

# --- 5. remove ------------------------------------------------------------------
run FLEET_DESK_CMD=remove BOX_ID=desk-b DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'DELETE /v1/operator/fleet-desks/desk-b Bearer stub-id-token' "$T/reqs" \
  && grep -q '^OK dev fleet desk box desk-b removed' "$T/o" \
  && pass "5. remove DELETEs the box: 204" || fail "5. remove: rc=$rc $(cat "$T/reqs" "$T/o")"

# --- 6. hub refusals --------------------------------------------------------------
run FLEET_DESK_CMD=add BOX_ID=no-pin DRY_RUN=0; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused no-pin (409): box no-pin holds no live pin in the operator workspace' "$T/o" \
  && pass "6. 409 no_live_pin fails with the hub's detail" || fail "6. 409: rc=$rc $(cat "$T/o")"
run FLEET_DESK_CMD=remove BOX_ID=gone DRY_RUN=0; rc=$?
[[ $rc -eq 1 ]] && grep -q 'gone is not a fleet desk box of dev (404)' "$T/o" && pass "6. 404 on remove fails" || fail "6. 404: rc=$rc $(cat "$T/o")"
run FLEET_DESK_CMD=add BOX_ID=not-sa DRY_RUN=0; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "6. 403 names the operator allowlist" || fail "6. 403: rc=$rc $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
