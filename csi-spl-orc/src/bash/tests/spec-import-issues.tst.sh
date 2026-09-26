#!/usr/bin/env bash
# Parser for do_spl_spec_import_issues: two sample tasks.md files, plus a
# smoke parse of the real spec tree (unique ids, titles, source lines).
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
PY="$PROJ_ROOT/src/bash/scripts/spec-import-issues.py"
FIX="$TEST_DIR/fixtures/spec-import"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

[[ -f "$PY" ]] && pass "parser script is present" || fail "parser script missing"
bash -n "$PROJ_ROOT/src/bash/run/spl-spec-import-issues.func.sh" && pass "action parses" || fail "action syntax"

out=$(python3 "$PY" parse --specs "$FIX") || { echo "$out"; fail "parse fixtures"; exit 1; }
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
items = {(i["dir"], i["id"]): i for i in doc["items"]}

def need(key, status, label, title_has, parent=""):
    it = items.get(key)
    if not it:
        print(f"FAIL: missing {key}")
        return 1
    ok = True
    if it["status"] != status:
        print(f"FAIL: {key} status {it['status']} != {status}"); ok = False
    if it["labels"] != [label]:
        print(f"FAIL: {key} labels {it['labels']} != [{label}]"); ok = False
    if title_has not in it["title"]:
        print(f"FAIL: {key} title {it['title']!r} lacks {title_has!r}"); ok = False
    if not it["title"].startswith("[" + it["spec"] + " " + it["id"] + "]"):
        print(f"FAIL: {key} title prefix {it['title']!r}"); ok = False
    if len(it["title"]) > 255:
        print(f"FAIL: {key} title length"); ok = False
    if it["parent_id"] != parent:
        print(f"FAIL: {key} parent {it['parent_id']!r} != {parent!r}"); ok = False
    if "Source: csi-spl-doc/specs/" not in it["description"]:
        print(f"FAIL: {key} description has no Source line"); ok = False
    if ok:
        print(f"PASS: {key[1]} {status} {label}")
    return 0 if ok else 1

rc = 0
rc |= need(("001-sample-checklist", "T001"), "done", "task", "Copy the runner from the donor.")
rc |= need(("001-sample-checklist", "T002"), "in_progress", "task", "The gate is half done.")
rc |= need(("001-sample-checklist", "T003"), "backlog", "task", "nothing built yet.")
rc |= need(("001-sample-checklist", "T004"), "done", "bug", "Fix the stale comment")
rc |= need(("001-sample-checklist", "T004.s1"), "backlog", "subtask", "Remove the comment itself.", "T004")
rc |= need(("001-sample-checklist", "T004.s2"), "done", "subtask", "Confirm the render is clean.", "T004")
rc |= need(("001-sample-checklist", "T005"), "canceled", "task", "the old door is not built.")
rc |= need(("001-sample-checklist", "T040"), "in_progress", "task", "The box is unticked")
rc |= need(("026-sample-mixed", "T001"), "done", "task", "publish the contract before building")
rc |= need(("026-sample-mixed", "T010"), "canceled", "task", "retire the old column")
rc |= need(("026-sample-mixed", "T020"), "done", "task", "phase two switch")
rc |= need(("026-sample-mixed", "P2-1"), "done", "task", "phase 2 hub switch")
rc |= need(("026-sample-mixed", "T030"), "backlog", "task", "owner decision on the tier")
prose = [i for i in doc["items"] if "Highlighting" in i["title"] or i["id"].startswith("T004.s") and "Highlighting" in i["description"] and i["kind"] == "subtask"]
# the prose bullet stays in T004's description and is not its own issue
if any(i["kind"] == "subtask" and "Highlighting" in i["title"] for i in doc["items"]):
    print("FAIL: prose bullet became a subtask"); rc |= 1
else:
    print("PASS: prose bullet is not a subtask")
subs = [i for i in doc["items"] if i["dir"] == "001-sample-checklist" and i["kind"] == "subtask"]
if len(subs) != 2:
    print(f"FAIL: expected 2 subtasks, got {len(subs)}"); rc |= 1
else:
    print("PASS: two subtasks under T004")
# idempotent plan: an existing identical issue is not created again
t001 = items[("001-sample-checklist", "T001")]
listed = {"result": {"issues": [
    {"key": "SPL-19", "title": "Spec 001 - sample checklist", "labels": ["epic"], "parent": "", "status": "in_progress", "description": ""},
    {"key": "SPL-20", "title": "Spec 026 - sample mixed", "labels": ["epic"], "parent": "", "status": "in_progress", "description": ""},
    {"key": "SPL-90", "title": t001["title"], "labels": ["task"], "parent": "SPL-19", "status": t001["status"], "description": t001["description"]},
    {"key": "SPL-91", "title": items[("001-sample-checklist", "T003")]["title"], "labels": ["task"], "parent": "SPL-19",
     "status": "done", "description": items[("001-sample-checklist", "T003")]["description"]},
], "labels": [{"id": "epic"}, {"id": "bug"}]}}
import pathlib, tempfile, os
sys.path.insert(0, os.path.dirname(os.path.realpath(os.environ.get("PYFILE", ""))))
# call reconcile via the loaded module path passed as argv later — done below if rc else
open("/tmp/spec-import-fixture-plan.json","w").write(json.dumps(doc))
open("/tmp/spec-import-fixture-list.json","w").write(json.dumps(listed))
sys.exit(rc)
PY
rc_py=$?
[[ $rc_py -eq 0 ]] && pass "fixture assertions" || fail "fixture assertions (rc=$rc_py)"

python3 - <<PY
import importlib.util, json
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
plan = json.load(open("/tmp/spec-import-fixture-plan.json"))
listed = json.load(open("/tmp/spec-import-fixture-list.json"))
doc = mod.reconcile(plan, listed, __import__("pathlib").Path("/tmp/spec-import-fixture-desc"))
ops = {(o["spec"], o["id"]): o for o in doc["ops"]}
ok = True
if ops[("001", "T001")]["action"] != "skip":
    print("FAIL: identical T001 should be unchanged, got", ops[("001","T001")]["action"]); ok = False
else:
    print("PASS: identical existing issue is not created again")
if ops[("001", "T003")]["action"] != "update" or "status" not in ops[("001","T003")]["changes"]:
    print("FAIL: T003 status drift should update", ops[("001","T003")]); ok = False
else:
    print("PASS: a drifted status is an update")
if ops[("001", "T002")]["action"] != "create" or ops[("001","T002")]["parent_key"] != "SPL-19":
    print("FAIL: T002 should be created under SPL-19", ops.get(("001","T002"))); ok = False
else:
    print("PASS: a new task is created under the spec epic")
sub = ops[("001", "T004.s1")]
if sub["action"] != "create" or sub["parent_item"] != "001-sample-checklist/T004":
    print("FAIL: subtask parent", sub); ok = False
else:
    print("PASS: subtask points at its task until that task has a key")
# second reconcile once the creates exist: zero creates
for op in list(doc["ops"]):
    if op["action"] != "create":
        continue
    listed["result"]["issues"].append({
        "key": "SPL-200", "title": op["title"], "labels": op["labels"], "parent": op["parent_key"] or "SPL-19",
        "status": op["status"], "description": open(op["description_path"], encoding="utf-8").read(),
    })
doc2 = mod.reconcile(plan, listed, __import__("pathlib").Path("/tmp/spec-import-fixture-desc"))
creates = [o for o in doc2["ops"] if o["action"] == "create"]
if creates:
    print("FAIL: second run created", [(c["spec"], c["id"]) for c in creates]); ok = False
else:
    print("PASS: second run creates 0")
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "reconcile idempotence" || fail "reconcile idempotence"

# real tree: the parser keeps every spec readable. Floor, not an exact count —
# tasks.md grows under other lanes.
python3 - <<PY || fails=$((fails + 1))
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
doc = mod.parse_tree(Path("$APP_ROOT/csi-spl-doc/specs"))
items = doc["items"]
ok = True
if len(items) < 700:
    print(f"FAIL: real tree parsed {len(items)} entries, floor is 700"); ok = False
else:
    print(f"PASS: real tree parsed {len(items)} entries")
seen = set()
for it in items:
    key = (it["dir"], it["id"])
    if key in seen:
        print("FAIL: duplicate", key); ok = False
    seen.add(key)
    if it["status"] not in ("backlog", "todo", "in_progress", "in_review", "done", "canceled"):
        print("FAIL: bad status", key, it["status"]); ok = False
    if not it["title"].startswith("[" + it["spec"] + " "):
        print("FAIL: title", it["title"]); ok = False
    if len(it["title"]) > 255 or len(it["description"]) > 20000:
        print("FAIL: size", key); ok = False
    if "Source: csi-spl-doc/specs/" not in it["description"]:
        print("FAIL: source", key); ok = False
if ok:
    print("PASS: real-tree ids, titles, statuses and source lines")
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "real-tree smoke" || fail "real-tree smoke"

# offline action prints a report and does not need a hub
# shellcheck disable=SC1091
do_log() { printf '%s\n' "$*"; }
# shellcheck disable=SC1090
source "$PROJ_ROOT/src/bash/run/spl-spec-import-issues.func.sh"
off=$(SPEC_IMPORT_OFFLINE=1 SPEC_DIR="$FIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_import_issues 2>&1) || true
[[ "$off" == *"| 001 |"* && "$off" == *"| 026 |"* && "$off" == *"Sample titles:"* ]] && pass "offline action prints the table" || { fail "offline action"; printf '%s\n' "$off" | head -n 20; }

echo "=== $([[ $fails -eq 0 ]] && echo 'spec-import-issues: ALL PASS' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
