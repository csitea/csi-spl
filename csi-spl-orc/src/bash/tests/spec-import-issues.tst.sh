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

FIX_TMP=$(mktemp -d)
export FIX_TMP
trap 'rm -rf "$FIX_TMP"' EXIT
out=$(python3 "$PY" parse --specs "$FIX") || { echo "$out"; fail "parse fixtures"; exit 1; }
python3 - "$out" <<'PY'
import json, os, sys
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
rc |= need(("001-sample-checklist", "T002"), "wip", "task", "The gate is half done.")
rc |= need(("001-sample-checklist", "T003"), "eval", "task", "nothing built yet.")
rc |= need(("001-sample-checklist", "T004"), "done", "bug", "Fix the stale comment")
rc |= need(("001-sample-checklist", "T004.s1"), "eval", "subtask", "Remove the comment itself.", "T004")
rc |= need(("001-sample-checklist", "T004.s2"), "done", "subtask", "Confirm the render is clean.", "T004")
rc |= need(("001-sample-checklist", "T005"), "diss", "task", "the old door is not built.")
rc |= need(("001-sample-checklist", "T040"), "wip", "task", "The box is unticked")
rc |= need(("026-sample-mixed", "T001"), "done", "task", "publish the contract before building")
rc |= need(("026-sample-mixed", "T010"), "diss", "task", "retire the old column")
rc |= need(("026-sample-mixed", "T020"), "done", "task", "phase two switch")
rc |= need(("026-sample-mixed", "P2-1"), "done", "task", "phase 2 hub switch")
rc |= need(("026-sample-mixed", "T030"), "eval", "task", "owner decision on the tier")
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
    {"key": "SPL-19", "title": "Spec 001 - sample checklist", "labels": ["epic"], "parent": "", "status": "wip", "description": ""},
    {"key": "SPL-20", "title": "Spec 026 - sample mixed", "labels": ["epic"], "parent": "", "status": "wip", "description": ""},
    {"key": "SPL-90", "title": t001["title"], "labels": ["task"], "parent": "SPL-19", "status": t001["status"], "description": t001["description"]},
    {"key": "SPL-91", "title": items[("001-sample-checklist", "T003")]["title"], "labels": ["task"], "parent": "SPL-19",
     "status": "done", "description": items[("001-sample-checklist", "T003")]["description"]},
], "labels": [{"id": "epic"}, {"id": "bug"}]}}
import pathlib, tempfile, os
sys.path.insert(0, os.path.dirname(os.path.realpath(os.environ.get("PYFILE", ""))))
# call reconcile via the loaded module path passed as argv later — done below if rc else
open(os.environ["FIX_TMP"]+"/plan.json","w").write(json.dumps(doc))
open(os.environ["FIX_TMP"]+"/list.json","w").write(json.dumps(listed))
sys.exit(rc)
PY
rc_py=$?
[[ $rc_py -eq 0 ]] && pass "fixture assertions" || fail "fixture assertions (rc=$rc_py)"

python3 - <<PY
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
plan = json.load(open(os.environ["FIX_TMP"]+"/plan.json"))
listed = json.load(open(os.environ["FIX_TMP"]+"/list.json"))
doc = mod.reconcile(plan, listed, __import__("pathlib").Path(os.environ["FIX_TMP"]+"/desc"))
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
doc2 = mod.reconcile(plan, listed, __import__("pathlib").Path(os.environ["FIX_TMP"]+"/desc"))
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
    if it["status"] not in mod.HUB_STATUSES:
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

# Epic-scoped read (SPL-963): the importer must NOT list the whole tenant (a big
# done set closes the hub socket). It reads the epics, scopes the child list to
# THIS plan's epics, and merges. select_epic_refs picks only the wanted specs'
# epics; merge_lists unions the issue rows deduped by key.
python3 - "$FIX_TMP" <<PY
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
tmp = sys.argv[1]
plan = json.load(open(tmp + "/plan.json"))  # fixtures: specs 001 and 026
# a KIND=epic reply: epics summary over the whole tenant + the epic rows + labels
epics_reply = {"op": "list", "result": {
    "prefix": "SPL",
    "epics": [
        {"key": "SPL-19", "number": 19, "title": "Spec 001 - sample checklist", "status": "wip"},
        {"key": "SPL-20", "number": 20, "title": "Spec 026 - sample mixed", "status": "wip"},
        {"key": "SPL-77", "number": 77, "title": "Spec 099 - unrelated epic", "status": "done"},
    ],
    "issues": [
        {"key": "SPL-19", "title": "Spec 001 - sample checklist", "labels": ["epic"], "parent": "", "status": "wip"},
        {"key": "SPL-20", "title": "Spec 026 - sample mixed", "labels": ["epic"], "parent": "", "status": "wip"},
        {"key": "SPL-77", "title": "Spec 099 - unrelated epic", "labels": ["epic"], "parent": "", "status": "done"},
    ],
    "labels": [{"id": "epic"}, {"id": "task"}],
}}
ok = True
refs = mod.select_epic_refs(plan, epics_reply)
if sorted(refs) != ["SPL-19", "SPL-20"]:
    print("FAIL: select_epic_refs picked", refs, "(want the plan's epics only, not SPL-77)"); ok = False
else:
    print("PASS: epic scope is only this plan's specs (SPL-77/099 excluded)")
# a narrowed plan (only 026) scopes to only SPL-20
one = {"specs": [s for s in plan["specs"] if s["spec"] == "026"], "items": []}
if mod.select_epic_refs(one, epics_reply) != ["SPL-20"]:
    print("FAIL: narrowed plan scope", mod.select_epic_refs(one, epics_reply)); ok = False
else:
    print("PASS: a narrowed plan scopes to one epic")
# merge_lists: base (epics reply) + a per-epic child reply, deduped by key
child_reply = {"op": "list", "result": {"issues": [
    {"key": "SPL-90", "title": "[001 T001] a task", "labels": ["task"], "parent": "SPL-19", "status": "done"},
    {"key": "SPL-19", "title": "Spec 001 - sample checklist", "labels": ["epic"], "parent": "", "status": "wip"},
]}}
open(tmp + "/mrg-epics.json", "w").write(json.dumps(epics_reply))
open(tmp + "/mrg-child.json", "w").write(json.dumps(child_reply))
merged = mod.merge_lists([tmp + "/mrg-epics.json", tmp + "/mrg-child.json"])
keys = [i["key"] for i in merged["result"]["issues"]]
if keys.count("SPL-19") == 1 and "SPL-90" in keys and "SPL-77" in keys:
    print("PASS: merge unions child rows and dedups the epic row")
else:
    print("FAIL: merge keys", keys); ok = False
if (merged["result"].get("labels") or []) != [{"id": "epic"}, {"id": "task"}]:
    print("FAIL: merge dropped labels", merged["result"].get("labels")); ok = False
else:
    print("PASS: merge keeps the base labels")
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "epic-scoped read" || fail "epic-scoped read"

# offline action prints a report and does not need a hub
# shellcheck disable=SC1091
do_log() { printf '%s\n' "$*"; }
# shellcheck disable=SC1090
source "$PROJ_ROOT/src/bash/run/spl-spec-import-issues.func.sh"
off=$(SPEC_IMPORT_OFFLINE=1 SPEC_DIR="$FIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_import_issues 2>&1) || true
[[ "$off" == *"| 001 |"* && "$off" == *"| 026 |"* && "$off" == *"Sample titles:"* ]] && pass "offline action prints the table" || { fail "offline action"; printf '%s\n' "$off" | head -n 20; }

# SPEC_IMPORT_SPECS filters the OFFLINE run too (it used to be ignored, planning
# every spec — a "056 only" run would then have created ~1000 issues).
off1=$(SPEC_IMPORT_OFFLINE=1 SPEC_IMPORT_SPECS=026 SPEC_DIR="$FIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_import_issues 2>&1) || true
[[ "$off1" == *"| 026 |"* && "$off1" != *"| 001 |"* ]] && pass "offline honours SPEC_IMPORT_SPECS" || { fail "offline SPEC_IMPORT_SPECS ignored"; printf '%s\n' "$off1" | head -n 20; }

# The same filter on the LIVE dry-run path (parse --only), where the plan.json
# is built: only the wanted spec's rows survive.
onlyj=$(python3 "$PY" parse --specs "$FIX" --only 026)
python3 - "$onlyj" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
specs = {s["spec"] for s in doc["specs"]}
items = {i["spec"] for i in doc["items"]}
if specs == {"026"} and items == {"026"} and doc["items"]:
    print("PASS: parse --only 026 keeps only 026")
    sys.exit(0)
print("FAIL: parse --only leaked", specs, items); sys.exit(1)
PY
[[ $? -eq 0 ]] && pass "live filter parse --only" || fail "live filter parse --only"

# A planted first-set status name must fail the suite: the read-only issue list
# and the create/update calls speak the hub's set (eval|todo|wip|diss|...), so a
# legacy name (backlog/in_progress/in_review/canceled) in the action or emitted
# by the parser is a regression.
if grep -Eq 'ISSUE_STATUS=[^#]*\b(backlog|in_progress|in_review|canceled)\b' \
     "$PROJ_ROOT/src/bash/run/spl-spec-import-issues.func.sh"; then
  fail "action's ISSUE_STATUS carries a legacy status name"
else
  pass "action's ISSUE_STATUS is the hub's current set"
fi

# An empty ref must not shift the columns. Tab would collapse it; the
# action separates fields with a unit separator for that reason.
line=$(python3 -c 'import base64; t=base64.b64encode(b"Hello [001]").decode(); print("\x1f".join(["create","001/T001","","SPL-1","","done","task","/tmp/d.md",t]))')
IFS=$'\x1f' read -r action item ref pkey pitem status labels desc title_b64 <<<"$line"
title=$(printf '%s\n' "$title_b64" | base64 -d)
if [[ "$action" == create && -z "$ref" && "$pkey" == SPL-1 && -z "$pitem" && "$status" == done && "$title" == "Hello [001]" ]]; then
  pass "empty fields survive the row read"
else
  fail "row read shifted: action=$action ref=$ref pkey=$pkey pitem=$pitem status=$status title=$title"
fi

echo "=== $([[ $fails -eq 0 ]] && echo 'spec-import-issues: ALL PASS' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
