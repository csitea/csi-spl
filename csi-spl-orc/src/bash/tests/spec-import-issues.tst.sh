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
    if "Source: fixtures/spec-import/" not in it["description"]:
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

if python3 - <<PY
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
then pass "reconcile idempotence"; else fail "reconcile idempotence"; fi

# real tree: the parser keeps every spec readable. Floor, not an exact count —
# tasks.md grows under other lanes.
if python3 - <<PY
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
then pass "real-tree smoke"; else fail "real-tree smoke"; fi

# A foreign spec tree may wrap the id in bold and lead with an [FR-nnn] tag:
# `- [X] **T001** [FR-009] text` (pas-psf). The id must still be captured and
# the tag dropped from the title; the Source line names that tree's doc repo.
if python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
text = "\n".join([
    "# Tasks: Framework hardening",
    "## Phase 1",
    "- [X] **T001** [FR-009] Fork the runner from the donor.",
    "- [ ] **T006** [n/a] No task here yet.",
    "- [~] **T007a** [FR-001, FR-012] Half-built work in flight.",
])
items = {i.tid: i for i in mod.parse_tasks(text, "007", "pas-psf-doc/specs/007-x/tasks.md")}
ok = True
for tid, status, has in (("T001", "done", "Fork the runner"), ("T006", "eval", "No task"), ("T007a", "wip", "Half-built work")):
    it = items.get(tid)
    if not it:
        print(f"FAIL: bold id {tid} not parsed"); ok = False; continue
    if it.status != status:
        print(f"FAIL: {tid} status {it.status} != {status}"); ok = False
    if not it.title.startswith(f"[007 {tid}] "):
        print(f"FAIL: {tid} title {it.title!r}"); ok = False
    if "**" in it.title or "[FR" in it.title or "[n/a]" in it.title:
        print(f"FAIL: {tid} title keeps markup/tag {it.title!r}"); ok = False
    if has not in it.title:
        print(f"FAIL: {tid} title lacks {has!r}: {it.title!r}"); ok = False
if ok:
    print("PASS: bold-wrapped ids parse, markup and [tag] stripped from the title")
raise SystemExit(0 if ok else 1)
PY
then pass "bold id parsing"; else fail "bold id parsing"; fi

# SPEC_IMPORT_LABELS tags every issue on top of task/bug/subtask, in the plan,
# so reconcile's needed_labels and the create call both carry it, deduped.
python3 - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
doc = {"specs": [], "items": [
    {"labels": ["task"]}, {"labels": ["bug"]}, {"labels": ["task", "security"]},
]}
mod.add_labels(doc, "security, ")
ok = True
if doc["items"][0]["labels"] != ["task", "security"]:
    print("FAIL: task not tagged", doc["items"][0]["labels"]); ok = False
if doc["items"][1]["labels"] != ["bug", "security"]:
    print("FAIL: bug not tagged", doc["items"][1]["labels"]); ok = False
if doc["items"][2]["labels"] != ["task", "security"]:
    print("FAIL: existing security duplicated", doc["items"][2]["labels"]); ok = False
if mod.add_labels({"items": [{"labels": ["task"]}]}, "")["items"][0]["labels"] != ["task"]:
    print("FAIL: empty SPEC_IMPORT_LABELS changed labels"); ok = False
print("PASS: extra labels tag every issue, deduped, empty is a no-op") if ok else None
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "extra labels" || fail "extra labels"

# needed_labels covers any tag, not just task/bug/subtask, so a live create of a
# SPEC_IMPORT_LABELS-tagged issue can register the label first; missing_epics and
# the report name what to create and how.
python3 - <<PY
import importlib.util
from pathlib import Path
import tempfile
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
ok = True
plan = {"specs": [
    {"spec": "001", "dir": "001-alpha", "heading": "Alpha feature", "parsed": 1, "t_parsed": 1, "subtasks": 0, "pinned": ""},
    {"spec": "002", "dir": "002-beta", "heading": "Beta feature", "parsed": 1, "t_parsed": 1, "subtasks": 0, "pinned": ""},
], "items": [
    {"spec": "001", "dir": "001-alpha", "id": "T001", "key": "001-alpha/T001", "kind": "task",
     "status": "done", "title": "[001 T001] a task", "labels": ["task", "security"],
     "description": "x\n\nSource: pas-psf-doc/specs/001-alpha/tasks.md", "parent_id": ""},
]}
# only spec 001 has an epic; 002 is missing
listed = {"result": {"epics": [{"key": "SPL-9", "title": "Spec 001 - Alpha feature"}],
    "issues": [{"key": "SPL-9", "title": "Spec 001 - Alpha feature", "labels": ["epic"], "parent": "", "status": "wip"}],
    "labels": [{"id": "epic"}]}}
miss = mod.missing_epics(plan, listed)
if miss != [("002", "Beta feature")]:
    print("FAIL: missing_epics", miss); ok = False
else:
    print("PASS: missing_epics names the spec without an epic + its heading")
with tempfile.TemporaryDirectory() as tmp:
    rec = mod.reconcile(plan, listed, Path(tmp) / "desc")
    if "security" not in rec["needed_labels"]:
        print("FAIL: needed_labels drops the SPEC_IMPORT_LABELS tag", rec["needed_labels"]); ok = False
    else:
        print("PASS: needed_labels carries the extra tag (security)")
    report = mod.report_md(rec)
    if 'ISSUE_KIND=epic ISSUE_TITLE="Spec 002 - Beta feature"' in report and "SPEC_IMPORT_CREATE_EPIC=1" in report:
        print("PASS: report prints the create-epic command + the CREATE_EPIC hint")
    else:
        print("FAIL: report missing the epic-create guidance"); ok = False
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "missing-epic guidance" || fail "missing-epic guidance"

# The epic heading is cleaned of git-spec boilerplate; a spec with no task rows
# is never MISSING and never auto-created (an empty epic helps no one).
python3 - <<PY
import importlib.util, tempfile, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
ok = True
with tempfile.TemporaryDirectory() as tmp:
    d = Path(tmp) / "001-x"; d.mkdir()
    (d / "spec.md").write_text("# Feature Specification: GCP Infrastructure Bootstrap\n")
    if mod._heading_of(d) != "GCP Infrastructure Bootstrap":
        print("FAIL: heading not cleaned:", mod._heading_of(d)); ok = False
    else:
        print("PASS: heading boilerplate stripped")
    d2 = Path(tmp) / "012-y"; d2.mkdir()
    (d2 / "spec.md").write_text("# Re-platform onto csi-rel (fork-morph)\n")
    if mod._heading_of(d2) != "Re-platform onto csi-rel (fork-morph)":
        print("FAIL: non-boilerplate heading changed:", mod._heading_of(d2)); ok = False
    else:
        print("PASS: a plain heading is left as is")
    d3 = Path(tmp) / "052-social-authentication-google-facebook"; d3.mkdir()
    (d3 / "runbook.md").write_text("# A runbook, not the spec name\n")
    if mod._heading_of(d3) != "Social authentication google facebook":
        print("FAIL: no-spec.md fallback heading:", mod._heading_of(d3)); ok = False
    else:
        print("PASS: a dir with no spec.md is titled from its name")
# a spec with 0 parsed rows is not MISSING and not in the create list
plan = {"specs": [
    {"spec": "002", "dir": "002-empty", "heading": "Empty", "parsed": 0, "t_parsed": 0, "subtasks": 0, "pinned": ""},
], "items": []}
listed = {"result": {"epics": [], "issues": [], "labels": []}}
if mod.missing_epics(plan, listed) != []:
    print("FAIL: an empty spec was queued for an epic", mod.missing_epics(plan, listed)); ok = False
else:
    print("PASS: an empty spec gets no auto-epic")
with tempfile.TemporaryDirectory() as t2:
    rec = mod.reconcile(plan, listed, Path(t2) / "desc")
    if rec["missing_epics"]:
        print("FAIL: empty spec flagged MISSING", rec["missing_epics"]); ok = False
    else:
        print("PASS: empty spec not flagged MISSING")
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "heading clean + empty-spec skip" || fail "heading clean + empty-spec skip"

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
[[ "$off" == *"| 001 |"* && "$off" == *"| 026 |"* && "$off" == *"Sample titles:"* ]] && pass "offline action prints the table" || { fail "offline action"; printf '%s\n' "$off" | sed -n 1,20p; }

# SPEC_IMPORT_SPECS filters the OFFLINE run too (it used to be ignored, planning
# every spec — a "056 only" run would then have created ~1000 issues).
off1=$(SPEC_IMPORT_OFFLINE=1 SPEC_IMPORT_SPECS=026 SPEC_DIR="$FIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_import_issues 2>&1) || true
[[ "$off1" == *"| 026 |"* && "$off1" != *"| 001 |"* ]] && pass "offline honours SPEC_IMPORT_SPECS" || { fail "offline SPEC_IMPORT_SPECS ignored"; printf '%s\n' "$off1" | sed -n 1,20p; }

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

# SPEC_IMPORT_DOCS (CLE-77860): every other document of a spec dir becomes a
# "doc" issue under its epic (status done, label doc, split in parts when
# long), a doc-only spec gets an epic, the epic's description is the index,
# personal data is scrubbed, and a second reconcile changes nothing.
DOCFIX="$TEST_DIR/fixtures/spec-import-docs"
python3 - "$DOCFIX" <<PY
import importlib.util, json, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("imp", "$PY")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
ok = True
def check(cond, good, bad):
    global ok
    if cond:
        print("PASS:", good)
    else:
        print("FAIL:", bad); ok = False
mod.REDACT[:] = ["devbox-user"]
plan = mod.parse_tree(Path(sys.argv[1]), docs=True)
items = {(i["spec"], i["id"]): i for i in plan["items"]}
docs = [i for i in plan["items"] if i["kind"] == "doc"]
check([i["id"] for i in docs if i["spec"] == "001"] == ["doc-spec.md", "doc-plan.md", "doc-contracts-api.md", "doc-restore.sh"],
      "docs: spec.md and plan.md first, then by path, tasks.md never a doc",
      [i["id"] for i in docs])
check(all(i["status"] == "done" and i["labels"] == ["doc"] for i in docs), "docs are done + label doc", docs)
sp = items[("001", "doc-spec.md")]
check(sp["title"] == "[001 doc-spec.md] spec.md - Feature Specification: Sample feature", "doc title", sp["title"])
check("The sample feature exists" in sp["description"] and "Source: fixtures/spec-import-docs/001-sample-feature/spec.md" in sp["description"],
      "doc description carries the text and its Source line", sp["description"])
check("first.last@" not in sp["description"] and "<EMAIL>" in sp["description"], "a first.last@ address is scrubbed", sp["description"])
check("ops@example.com" in sp["description"] and "sa-run@sample-dev.iam.gserviceaccount.com" in sp["description"],
      "role and service-account addresses are kept", sp["description"])
check("devbox-user" not in sp["description"] and "<REDACTED>" in sp["description"], "a --redact word is scrubbed", sp["description"])
sh = items[("001", "doc-restore.sh")]
check("\`\`\`bash\n#!/usr/bin/env bash" in sh["description"], "a script is filed fenced", sh["description"])
rows = {r["spec"]: r for r in plan["specs"]}
check(rows["002"]["parsed"] == 0 and rows["002"]["docs"] == 1, "doc-only spec counts its doc", rows["002"])
idx = rows["001"]["epic_description"]
check("[001 doc-contracts-api.md]" in idx and "**Tasks** - 2 issue(s)" in idx, "epic index lists docs + task count", idx)
src = "a" * 25 + "\n" + "b\n" * 30
cut = mod.split_parts(src, 20)
check("".join(cut) == src and all(len(c) <= 20 for c in cut) and cut[0] == "a" * 20 and cut[2].startswith("b"),
      "split_parts cuts at line boundaries (a long line hard), loses nothing", cut)
big = mod.split_parts("line\n" * 9000, mod.DOC_PART_MAX)
check(len(big) == 3 and all(len(b) <= mod.DOC_PART_MAX for b in big), "a long doc is split in parts", [len(b) for b in big])
# no tenant epic yet: both specs are MISSING (002 has docs only)
empty = {"result": {"epics": [], "issues": [], "labels": []}}
check(mod.missing_epics(plan, empty) == [("001", "Sample feature"), ("002", "Docs only")],
      "a doc-only spec gets an auto-epic", mod.missing_epics(plan, empty))
listed = {"result": {"issues": [
    {"key": "S-1", "title": "Spec 001 - Sample feature", "labels": ["epic"], "kind": "epic", "parent": "", "status": "wip", "description": ""},
    {"key": "S-2", "title": "Spec 002 - Docs only", "labels": ["epic"], "kind": "epic", "parent": "", "status": "eval", "description": ""},
], "labels": [{"id": "epic"}, {"id": "task"}]}}
with tempfile.TemporaryDirectory() as tmp:
    rec = mod.reconcile(plan, listed, Path(tmp) / "desc")
    ops = {(o["spec"], o["id"]): o for o in rec["ops"]}
    ep = ops[("001", "epic")]
    check(ep["action"] == "update" and ep["ref"] == "S-1" and ep["kind"] == "epic" and not ep["parent_key"],
          "an empty epic description is updated to the index", ep)
    check(ops[("002", "doc-spec.md")]["action"] == "create" and ops[("002", "doc-spec.md")]["parent_key"] == "S-2",
          "a doc is created under its spec epic", ops[("002", "doc-spec.md")])
    check("doc" in rec["needed_labels"], "label doc is registered", rec["needed_labels"])
    n = 100
    for o in rec["ops"]:
        body = open(o["description_path"], encoding="utf-8").read()
        if o["kind"] == "epic":
            next(i for i in listed["result"]["issues"] if i["key"] == o["ref"])["description"] = body
            continue
        n += 1
        listed["result"]["issues"].append({"key": f"S-{n}", "title": o["title"], "labels": o["labels"], "kind": "issue",
            "parent": o["parent_key"], "status": o["status"], "description": body})
    rec2 = mod.reconcile(plan, listed, Path(tmp) / "desc2")
    moved = [(o["spec"], o["id"], o["action"]) for o in rec2["ops"] if o["action"] != "skip"]
    check(not moved, "a second run changes 0 (docs, tasks and epic index)", moved)
    check("| docs |" in mod.report_md(rec2), "report has a docs column", mod.report_md(rec2)[:200])
mod.REDACT[:] = []
plain = mod.parse_tree(Path(sys.argv[1]))
check(not any(i["kind"] == "doc" for i in plain["items"]) and "epic_description" not in plain["specs"][0],
      "without --docs nothing changes", plain["specs"][0])
raise SystemExit(0 if ok else 1)
PY
[[ $? -eq 0 ]] && pass "doc import" || fail "doc import"

offd=$(SPEC_IMPORT_OFFLINE=1 SPEC_IMPORT_DOCS=1 SPEC_DIR="$DOCFIX" PROJ_PATH="$PROJ_ROOT" do_spl_spec_import_issues 2>&1) || true
[[ "$offd" == *"| 002 | 0 | 0 | 0 | 1 |"* ]] && pass "offline SPEC_IMPORT_DOCS counts docs" || { fail "offline SPEC_IMPORT_DOCS"; printf '%s\n' "$offd" | sed -n 1,20p; }

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
line=$(python3 -c 'import base64; t=base64.b64encode(b"Hello [001]").decode(); print("\x1f".join(["create","001/T001","","SPL-1","","done","task","/tmp/d.md","task",t]))')
IFS=$'\x1f' read -r action item ref pkey pitem status labels desc kind title_b64 <<<"$line"
title=$(printf '%s\n' "$title_b64" | base64 -d)
if [[ "$action" == create && -z "$ref" && "$pkey" == SPL-1 && -z "$pitem" && "$status" == done && "$kind" == task && "$title" == "Hello [001]" ]]; then
  pass "empty fields survive the row read"
else
  fail "row read shifted: action=$action ref=$ref pkey=$pkey pitem=$pitem status=$status title=$title"
fi

echo "=== $([[ $fails -eq 0 ]] && echo 'spec-import-issues: ALL PASS' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
