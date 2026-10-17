#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_epic_backfill (SPL-2354) against a stub hub that keeps
# its issues in a JSON file, closes AND archives an open epic when a closed
# issue moves under it and none of its issues is open (SPL-1729), and refuses
# an archived epic as a parent. Cases: (a) the spec has an epic -> that epic;
# (b) the spec has none -> ONE new 'Spec NNN - <heading>' epic, created done
# when all its issues are closed; (c) no spec -> an area epic by the title
# scope or the blocker label; already linked rows and subtasks untouched; the
# e2e workspace skipped; held: a link that would close and archive an open
# epic. A dry run writes nothing; a real run leaves 0 orphans and a re-run
# plans 0 writes; ISSUE_BACKFILL_LIMIT batches. Red controls: verify fails on
# a planted orphan and on a second epic for one spec.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00" "$T/csi-spl-doc/specs/101-alpha" "$T/csi-spl-doc/specs/102-beta" "$T/csi-spl-doc/specs/103-gamma" "$T/csi-spl-doc/specs/104-delta"
printf '# Feature Specification: Alpha thing\n' >"$T/csi-spl-doc/specs/101-alpha/spec.md"
printf '# Spec 102: Beta thing\n' >"$T/csi-spl-doc/specs/102-beta/spec.md"
printf '# 103 Gamma thing\n' >"$T/csi-spl-doc/specs/103-gamma/spec.md"
printf '# Delta thing\n' >"$T/csi-spl-doc/specs/104-delta/spec.md"

# seed FILE ROW...: ROW is key|kind|level|status|epic|parent|labels|title|description
seed() {
  local f="$1"; shift
  python3 - "$f" "$@" <<'PY'
import json, sys
rows = []
for spec in sys.argv[2:]:
    k, kind, lvl, st, ep, par, lab, title, desc = spec.split("|")
    rows.append({"key": k, "kind": kind, "level": int(lvl), "status": st, "epic": ep, "parent": par,
                 "labels": [x for x in lab.split(",") if x], "title": title, "description": desc.replace("\\n", "\n"),
                 "discussions": [{"task_id": "0f8fad5b-d9cb-469f-a165-7086772895%02d" % int(k.split("-")[1])}]})
json.dump({"rows": rows, "next": 100}, open(sys.argv[1], "w"))
PY
}
SPEC=csi-spl-doc/specs
base_rows=(
  "SPL-1|epic|1|wip|||epic|Spec 101 - Alpha thing|"
  "SPL-2|issue|2|wip||||lane two|## Restart\n- spec: $SPEC/101-alpha/spec.md\n- scope: x"
  "SPL-3|issue|2|done||||lane three|see $SPEC/102-beta/plan.md and $SPEC/101-alpha"
  "SPL-4|issue|2|todo||||lane four|- spec: $SPEC/102-beta"
  "SPL-5|issue|2|done||||fix(orc, SPL-5): a fix|- spec: none, though it cites $SPEC/101-alpha"
  "SPL-6|issue|2|diss|||blocker|from_agent: c-001|Unanswered blocker from c-001 to @HUM-10"
  "SPL-7|issue|2|done|SPL-1|||already linked|- spec: $SPEC/102-beta"
  "SPL-8|issue|3|todo|SPL-1|SPL-7||a subtask|"
  "SPL-9|issue|2|done||||lane nine|- spec: $SPEC/103-gamma/spec.md"
  "SPL-10|issue|2|diss||||lane ten|- spec: $SPEC/103-gamma"
  "SPL-11|issue|2|done||||lane eleven|- spec: $SPEC/999-gone"
)

cat >"$T/fakeissue" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
op = a[1]
flags = {}
i = 2
while i < len(a):
    if a[i].startswith("--") and i + 1 < len(a):
        flags[a[i][2:]] = a[i + 1]; i += 2
    else:
        i += 1
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("|".join(a) + "|\n")
st = json.load(open(os.environ["FAKE_STATE"]))
rows = st["rows"]
live = [r for r in rows if not r.get("archived")]
by = {r["key"]: r for r in live}
CLOSED = ("done", "diss")
def save(): json.dump(st, open(os.environ["FAKE_STATE"], "w"))
if op == "list":
    print(json.dumps({"issues": [r for r in live if r["status"] == flags.get("status")], "next_cursor": ""}))
elif op == "create":
    k = "SPL-%d" % st["next"]; st["next"] += 1
    r = {"key": k, "kind": flags.get("kind", "issue"), "level": 1 if flags.get("kind") == "epic" else 2,
         "status": flags.get("status", "eval"), "epic": "", "parent": "", "labels": [],
         "title": flags["title"], "description": flags.get("description", ""),
         "discussions": [{"task_id": flags["discussions"]}] if flags.get("discussions") else []}
    if not r["discussions"] and "/t/" not in r["description"]:
        print("discussion_required", file=sys.stderr); sys.exit(1)
    rows.append(r); save()
    print(json.dumps({"issue": r}))
elif op == "update":
    r = by.get(flags["ref"])
    e = flags.get("epic")
    if r is None or (e and (e not in by or by[e]["kind"] != "epic")):
        print("not_found", file=sys.stderr); sys.exit(1)
    ans = {}
    if e is not None:
        was = r["epic"]; r["epic"] = e
        ep = by.get(e)
        if ep and r["status"] in CLOSED and was != e and ep["status"] not in CLOSED and \
                not any(x["epic"] == e and x["status"] not in CLOSED for x in live):
            ep["status"] = "done"
            for x in rows:
                if x is ep or x["epic"] == e:
                    x["archived"] = True
            ans["epic_closed"] = {"key": e, "archived": True}
    save()
    ans["issue"] = r
    print(json.dumps(ans))
else:
    print("{}")
FAKE
chmod +x "$T/fakeissue"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
base=(FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" FAKE_STATE="$T/state.json" TENANT_ID=t1 DESK_AGENT=CLE-00 SPEC_DIR="$T/csi-spl-doc/specs")

run() {
  : >"$T/issue.log"
  rm -rf "$T/plan"
  SNIPPET="${ISS}do_spl_issue_epic_backfill" in_orc "${base[@]}" ISSUE_PLAN_DIR="$T/plan" "$@" >"$T/o" 2>&1
  RC=$?
}
q() { python3 -c "import json,sys; st=json.load(open('$T/state.json')); rows=[r for r in st['rows'] if not r.get('archived')]; $1"; }

seed "$T/state.json" "${base_rows[@]}"
run
links=$(cut -f1,3,4 "$T/plan/links.tsv" | tr '\t\n' ': ')
[[ $RC -eq 0 && "$links" == "SPL-2:SPL-1:spec SPL-4:new:1:spec-new SPL-3:new:1:spec-new SPL-9:new:2:spec-new SPL-10:new:2:spec-new SPL-6:new:3:area-new SPL-5:new:4:area-new SPL-11:new:5:area-new " ]] &&
  ! grep -qE '\|(create|update)\|' "$T/issue.log" &&
  pass "dry run: (a) spec epic, (b) one new epic per spec, open issues first, (c) area by blocker label, title scope, else other; linked rows and subtasks kept; no write" ||
  fail "dry run (rc=$RC) '$links': $(cat "$T/o") / $(cat "$T/issue.log")"
epics=$(cut -f1,2,4 "$T/plan/epics.tsv" | tr '\t\n' ':|')
[[ "$epics" == "new:1:wip:Spec 102 - Beta thing|new:2:done:Spec 103 - Gamma thing|new:3:diss:Area: unanswered blockers - issues with no spec|new:4:done:Area: orchestration and agents (csi-spl-orc) - issues with no spec|new:5:done:Area: other work - issues with no spec|" ]] &&
  pass "new epics are titled from the spec heading (no repeated 'Spec NNN:'), created closed when every issue is" || fail "epics: '$epics'"
grep -q 'SPL-11: names csi-spl-doc/specs/999-gone, not in the spec tree' "$T/o" && grep -q '^- other work (1): SPL-11$' "$T/o" &&
  pass "a spec folder missing from the tree is never guessed: area, with a note; the no-spec list names the keys" || fail "no-spec list: $(cat "$T/o")"

run DRY_RUN=0
orph=$(q "print(sum(1 for r in rows if r['level']==2 and r['kind']=='issue' and not r['epic']))")
st=$(q "print(' '.join(r['key']+':'+r['status'] for r in rows if r['key'] in ('SPL-3','SPL-5','SPL-6','SPL-9','SPL-10')))")
[[ $RC -eq 0 && "$orph" == 0 && "$st" == "SPL-3:done SPL-5:done SPL-6:diss SPL-9:done SPL-10:diss" ]] &&
  [[ "$(grep -c '|create|' "$T/issue.log")" == 5 && "$(grep -c '|update|' "$T/issue.log")" == 8 ]] &&
  ! grep -q 'epic_closed\|WARN linking' "$T/o" &&
  pass "a real run creates 5 epics, links 8 issues, 0 orphans left, statuses untouched, no epic auto-closed" ||
  fail "real run (rc=$RC) orphans=$orph '$st': $(cat "$T/o")"
[[ "$(stat -c %a "$T/plan/undo.sh")" == 600 && "$(grep -c 'ISSUE_EPIC= DRY_RUN=0' "$T/plan/undo.sh")" == 8 ]] &&
  pass "the undo file (0600) unlinks each issue it linked" || fail "undo: $(cat "$T/plan/undo.sh" 2>/dev/null)"

run
[[ $RC -eq 0 && ! -s "$T/plan/links.tsv" && ! -s "$T/plan/epics.tsv" ]] && grep -q '0 orphan issues, 0 epics to create, 0 links' "$T/o" &&
  pass "a re-run on its own output plans 0 writes" || fail "re-run (rc=$RC): $(cat "$T/o")"
run ISSUE_BACKFILL_CMD=verify
[[ $RC -eq 0 ]] && grep -q '0 orphan issues, 0 duplicate epic titles' "$T/o" && pass "verify passes after the run" || fail "verify (rc=$RC): $(cat "$T/o")"

# red controls: a planted orphan, then a second epic for spec 102
python3 - "$T/state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["rows"].append({"key": "SPL-90", "kind": "issue", "level": 2, "status": "todo", "epic": "", "parent": "", "labels": [], "title": "planted", "description": ""})
json.dump(st, open(sys.argv[1], "w"))
PY
run ISSUE_BACKFILL_CMD=verify
[[ $RC -ne 0 ]] && grep -q '^orphans: SPL-90$' "$T/o" && pass "red control: verify fails on an orphan left after the run" || fail "planted orphan (rc=$RC): $(cat "$T/o")"
python3 - "$T/state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["rows"] = [r for r in st["rows"] if r["key"] != "SPL-90"]
st["rows"].append({"key": "SPL-91", "kind": "epic", "level": 1, "status": "eval", "epic": "", "parent": "", "labels": [], "title": "Spec 102 - Beta thing", "description": ""})
json.dump(st, open(sys.argv[1], "w"))
PY
run ISSUE_BACKFILL_CMD=verify
[[ $RC -ne 0 ]] && grep -qE '^duplicate epics: SPL-91=SPL-[0-9]+$' "$T/o" && pass "red control: verify fails on a second epic for the same spec" || fail "planted dup (rc=$RC): $(cat "$T/o")"

# batches: two links a run, then the rest
seed "$T/state.json" "${base_rows[@]}"
run DRY_RUN=0 ISSUE_BACKFILL_LIMIT=2
[[ $RC -eq 0 && "$(grep -c '|update|' "$T/issue.log")" == 2 && "$(grep -c '|create|' "$T/issue.log")" == 1 ]] &&
  pass "ISSUE_BACKFILL_LIMIT=2 links 2 and creates only the epic they need" || fail "limit (rc=$RC): $(cat "$T/o")"
run DRY_RUN=0 ISSUE_BACKFILL_LIMIT=0
run ISSUE_BACKFILL_CMD=verify
[[ $RC -eq 0 ]] && pass "the next batch finishes it: 0 orphans, no second epic for spec 102" || fail "batches (rc=$RC): $(cat "$T/o")"

# held: an open epic with no open issue gets only closed ones
seed "$T/state.json" "SPL-1|epic|1|wip|||epic|Spec 104 - Delta thing|" "SPL-2|issue|2|done||||lane two|- spec: $SPEC/104-delta"
run DRY_RUN=0
[[ $RC -eq 0 && ! -s "$T/plan/links.tsv" ]] && grep -q 'hold SPL-2 (done) -> SPL-1: linking closes and archives open epic SPL-1' "$T/o" &&
  ! grep -q '|update|' "$T/issue.log" && pass "held: a link that would close and archive an open epic is listed, never written" || fail "hold (rc=$RC): $(cat "$T/o")"

# e2e and bad input
run TENANT_ID=e2e DRY_RUN=0
[[ $RC -eq 0 && ! -s "$T/issue.log" ]] && grep -q 'e2e is in ISSUE_BACKFILL_SKIP' "$T/o" && pass "the e2e workspace is left alone, no hub call" || fail "e2e (rc=$RC): $(cat "$T/o")"
run ISSUE_BACKFILL_LIMIT=x
[[ $RC -ne 0 && ! -s "$T/issue.log" ]] && grep -q 'ISSUE_BACKFILL_LIMIT must be' "$T/o" && pass "a bad ISSUE_BACKFILL_LIMIT is refused before any hub call" || fail "bad limit (rc=$RC): $(cat "$T/o")"

echo "spl-issue-epic-backfill: $fails failure(s)"
(( fails == 0 ))
