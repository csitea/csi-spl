#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_list reads a list of more than 1000 issues whole, one
# page at a time (t1 1457bb6f). On prd t1 the unpaged done list closed the hub
# socket ("hub unreachable: socket closed"): the answer is one frame and the
# client reads at most 1 MiB (maxFrameBytes, internal/hubclient/hubclient.go),
# about 1000 rows. The stub hub below closes the socket on any answer over 1000
# rows, so a list that is not paged fails here as it failed on prd.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
# fakeissue: `spool issue list --as A [--limit N] [--cursor C] ...` over
# FAKE_ROWS issues SPL-1..SPL-<n>. No --limit is the whole list, as on the hub;
# the cursor is the offset of the next row.
cat >"$T/fakeissue" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write("|".join(args) + "|\n")
opt = {args[i]: args[i + 1] for i in range(len(args) - 1) if args[i].startswith("--")}
rows = int(os.environ["FAKE_ROWS"])
start = int(opt.get("--cursor", "0"))
end = min(rows, start + int(opt["--limit"])) if "--limit" in opt else rows
if end - start > 1000:
    sys.stderr.write("spool: hub unreachable: socket closed\n")
    raise SystemExit(1)
issues = [{"key": "SPL-%d" % n, "number": n, "status": "done"} for n in range(start + 1, end + 1)]
print(json.dumps({"issues": issues, "next_cursor": str(end) if end < rows else "", "total": rows}))
FAKE
chmod +x "$T/fakeissue"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
base=(FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_ASSIGNEE= ISSUE_STATUS=done)

# count FILE ROWS: "<rows> <unique keys> <in order 0|1> <next_cursor>" of the
# one JSON document do_spl_issue_list printed.
count() {
  python3 - "$1" "$2" <<'PY'
import json, sys
docs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.startswith("{")]
res = docs[-1]["result"] if docs else {}
keys = [i["key"] for i in res.get("issues", [])]
want = ["SPL-%d" % n for n in range(1, int(sys.argv[2]) + 1)]
print(len(keys), len(set(keys)), int(keys == want), res.get("next_cursor", "-") or "empty")
PY
}

# list ROWS LIMIT PAGES: the default page (LIMIT '') or ISSUE_LIMIT=LIMIT
# reads all ROWS in PAGES list calls, each carrying --limit.
list() {
  local rows="$1" lim="$2" pages="$3" rc got calls
  local -a extra=()
  [[ -n "$lim" ]] && extra=(ISSUE_LIMIT="$lim")
  : >"$T/issue.log"
  SNIPPET="${ISS}do_spl_issue_list" in_orc "${base[@]}" "${extra[@]}" FAKE_ROWS="$rows" DRY_RUN=0 >"$T/o" 2>&1
  rc=$?
  got=$(count "$T/o" "$rows" 2>&1)
  calls=$(grep -c '^issue|list|' "$T/issue.log")
  [[ $rc -eq 0 && "$got" == "$rows $rows 1 empty" && "$calls" -eq "$pages" ]] &&
    [[ "$(grep -c '|--limit|' "$T/issue.log")" -eq "$pages" ]] &&
    pass "$rows issues, page ${lim:-default}: $pages list calls, $rows rows, $rows unique keys, in order" ||
    fail "$rows issues, page ${lim:-default} (rc=$rc, rows/unique/order/cursor '$got', calls $calls): $(tail -3 "$T/o")"
}

list 1205 "" 13
list 1205 500 3
list 1001 "" 11
list 1000 "" 10

# Control: the same stub refuses the unpaged read the list made before
# 95d376a04, so the cases above prove paging rather than a lenient stub.
: >"$T/issue.log"
SNIPPET="${ISS}spl_desk_issue_run list --status done" in_orc "${base[@]}" FAKE_ROWS=1205 >"$T/o" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'socket closed' "$T/o" && ! grep -q '|--limit|' "$T/issue.log" &&
  pass "control: one unpaged read of 1205 issues closes the stub socket" ||
  fail "control (rc=$rc): the stub let an unpaged 1205-row read through: $(tail -3 "$T/o")"

echo "issue-list-paging: $fails failure(s)"
(( fails == 0 ))
