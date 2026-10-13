#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a numbered md page moves into a qto doc (do_spl_doctree_import_md)
#          and the qto doc is written back to its md file
#          (do_spl_doctree_export_md), SPL-1607. The desk's spool binary is a
#          stateful fake of `spool doctree` (create / edit / add / head / read /
#          export, in the CLI's export format), so the round trip runs without
#          a hub.
#   1. both actions exist (red before they landed)
#   2. import DRY_RUN=1 (the default) makes no spool call
#   3. import refuses: a path off csi-spl-doc/*.md, a section number the doc
#      would not derive; no spool call
#   4. import: one create, the preamble on the hidden root, one heading per
#      section at its level; the map row; the md file now says
#      "generated from qto doc <id>; edit it there"
#   5. the export keeps every section and its text: only the generated-from
#      line and the dot after a top-level number differ from the page
#   6. export twice = no diff, and an unchanged doc leaves the file untouched
#      (its mtime too)
#   7. CONTROL: an edited node changes the md, in that section only
#   8. import refuses a page already in the map
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# The repo is a scratch copy under /tmp: DOCTREE_IN may lie only in the
# worktree, /tmp or dispatch/, and the import writes the md file and the map.
R=$(mktemp -d /tmp/doctree-export-md.XXXXXX) || { echo "FAIL: no repo dir under /tmp"; exit 1; }
trap 'rm -rf "$T" "$R"' EXIT
mkdir -p "$R/csi-spl-doc/doc/md"
D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool/a-177" "$D/keys" "$T/state/dev/bin"
cat >"$T/state/dev/bin/spool" <<'EOF_STUB'
#!/usr/bin/env python3
import json, os, shlex, sys
st = os.environ["DT_STATE"]
db = json.load(open(st)) if os.path.exists(st) else {"items": []}
open(os.environ["CALLS"], "a").write(shlex.join(sys.argv[1:]) + "\n")
a = sys.argv[2:]
def flag(n):
    return a[a.index(n) + 1] if n in a else ""
def outline():
    c, out = [], []
    for it in db["items"]:
        c = c[:it["depth"]]
        while len(c) < it["depth"]: c.append(0)
        c[-1] += 1
        out.append(dict(it, outline=".".join(map(str, c))))
    return out
v = a[0]
if v == "create":
    db = {"id": "d0c", "title": flag("--title"), "root_body": "", "items": []}
    print(json.dumps({"id": "d0c", "root": "r00t", "rev": 1}))
elif v == "edit":
    body = open(flag("--file")).read()
    if a[2] == "r00t": db["root_body"] = body
    else: [it.update({flag("--field"): body}) for it in db["items"] if it["id"] == a[2]]
elif v == "add":
    body = open(flag("--file")).read() if "--file" in a else ""
    db["items"].append({"id": "i%d" % len(db["items"]), "depth": int(flag("--level")), "title": flag("--title"), "body": body})
elif v == "head":
    print(json.dumps({"id": a[1], "title": db["title"], "root": "r00t"}))
elif v == "read":
    print(json.dumps({"items": [{"id": "r00t", "parent": "", "body": db["root_body"]}] + outline()}))
elif v == "export":
    out = []
    for it in outline():
        out += ["#" * it["depth"] + " " + it["outline"] + " " + it["title"], ""]
        if it["body"].strip(): out += [it["body"].strip(), ""]
    sys.stdout.write("\n".join(out))
json.dump(db, open(st, "w"))
EOF_STUB
chmod +x "$T/state/dev/bin/spool"
PAGE="csi-spl-doc/doc/md/runbook-x.md"
cat >"$R/$PAGE" <<'EOF_MD'
# Runbook: the x seat

Who holds it, and the conventions:

- `ORC` = the desk checkout.

## 1. The job

Keep the fleet moving.

## 2. The commands

### 2.1 Read

`spool recv`, then act.

### 2.2 Write

| verb | when |
|---|---|
| send | always |

## 3. Traps

None yet.
EOF_MD
cp "$R/$PAGE" "$T/page.orig"

# run <action> [VAR=value]... - stub calls in $T/calls, output in $T/o, rc in $rc
run() {
  local act="$1"; shift
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
'"$act" in_orc APP_PATH="$R" TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 \
    CALLS="$T/calls" DT_STATE="$T/dt.json" "$@" >"$T/o" 2>&1
  rc=$?
}
calls() { sed 's/^doctree //' "$T/calls"; }

# --- 1. the actions exist --------------------------------------------------------------------
for a in do_spl_doctree_import_md do_spl_doctree_export_md; do
  SNIPPET="declare -F $a" in_orc >/dev/null 2>&1 && pass "$a exists" || fail "$a is not defined"
done

# --- 2. dry run --------------------------------------------------------------------------------
run do_spl_doctree_import_md MD_PATH="$PAGE"
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'would create qto doc .Runbook: the x seat. with 5 sections' "$T/o" &&
  grep -q '2.2	Write' "$T/o" && pass "import DRY_RUN=1 lists the sections, no spool call" ||
  fail "import dry run (rc=$rc): $(cat "$T/o")"

# --- 3. refused ----------------------------------------------------------------------------------
run do_spl_doctree_import_md MD_PATH=README.md DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'under csi-spl-doc/' "$T/o" &&
  pass "import refuses a path off csi-spl-doc/*.md" || fail "path off csi-spl-doc (rc=$rc): $(cat "$T/o")"
sed 's/^### 2.2 Write/### 2.3 Write/' "$R/$PAGE" >"$R/csi-spl-doc/doc/md/skip.md"
run do_spl_doctree_import_md MD_PATH=csi-spl-doc/doc/md/skip.md DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "'2.3 Write' would become 2.2" "$T/o" &&
  pass "import refuses a number the qto doc would renumber" || fail "renumber (rc=$rc): $(cat "$T/o")"

# --- 4. import -------------------------------------------------------------------------------------
run do_spl_doctree_import_md MD_PATH="$PAGE" DRY_RUN=0
want_calls="create --title 'Runbook: the x seat'
edit d0c r00t --field body --file
add d0c --kind heading --level 1 --title 'The job' --file
add d0c --kind heading --level 1 --title 'The commands'
add d0c --kind heading --level 2 --title Read --file
add d0c --kind heading --level 2 --title Write --file
add d0c --kind heading --level 1 --title Traps --file
head d0c
read d0c --item r00t
export d0c"
got_calls="$(calls | sed -E 's#--file /tmp/[^ ]+#--file#')"
if [[ $rc -eq 0 && "$got_calls" == "$want_calls" ]]; then
  pass "import: create, preamble on the root, one heading per section at its level, then the export"
else
  fail "import calls (rc=$rc): $(cat "$T/o") / $got_calls"
fi
[[ "$(cat "$R/csi-spl-doc/doc/md/qto-docs.tsv")" == "d0c	$PAGE" ]] &&
  pass "the map row names the doc and the page" || fail "map: $(cat "$R/csi-spl-doc/doc/md/qto-docs.tsv" 2>&1)"
grep -qx '> Generated from qto doc `d0c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.' "$R/$PAGE" &&
  pass "the md file says it is generated from the qto doc" || fail "no generated-from line: $(head -3 "$R/$PAGE")"

# --- 5. nothing lost -------------------------------------------------------------------------------
d="$(diff "$T/page.orig" "$R/$PAGE" | grep '^[<>]' | sed 's/ *$//')"
want_d='> > Generated from qto doc `d0c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.
>
< ## 1. The job
> ## 1 The job
< ## 2. The commands
> ## 2 The commands
< ## 3. Traps
> ## 3 Traps'
[[ "$d" == "$want_d" ]] && pass "the export keeps every section and its text" || fail "round trip diff: $d"

# --- 6. idempotent -----------------------------------------------------------------------------------
cp "$R/$PAGE" "$T/export1"
touch -d '2026-01-01 00:00:00' "$R/$PAGE"
run do_spl_doctree_export_md ENV=prd
if [[ $rc -eq 0 ]] && cmp -s "$T/export1" "$R/$PAGE" && [[ "$(stat -c %Y "$R/$PAGE")" == "$(date -d '2026-01-01 00:00:00' +%s)" ]] &&
  grep -q "unchanged (qto doc d0c)" "$T/o"; then
  pass "export twice = no diff; an unchanged doc leaves the file untouched"
else
  fail "re-export (rc=$rc): $(cat "$T/o")"
fi

# --- 7. CONTROL: an edited node changes the md ----------------------------------------------------
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["items"][2]["body"]="`spool recv --ack`, then act."; json.dump(d,open(sys.argv[1],"w"))' "$T/dt.json"
run do_spl_doctree_export_md QTO_DOC=d0c
d="$(diff "$T/export1" "$R/$PAGE" | grep '^[<>]')"
[[ $rc -eq 0 && "$d" == '< `spool recv`, then act.
> `spool recv --ack`, then act.' ]] && grep -q "written from qto doc d0c" "$T/o" &&
  pass "CONTROL: an edited node changes the md, that line only" || fail "edited node (rc=$rc): $d / $(cat "$T/o")"
run do_spl_doctree_export_md QTO_DOC=nope
[[ $rc -ne 0 ]] && grep -q 'no row for qto doc nope' "$T/o" && pass "export refuses a doc with no map row" ||
  fail "unknown doc (rc=$rc): $(cat "$T/o")"

# --- 8. already imported ---------------------------------------------------------------------------
run do_spl_doctree_import_md MD_PATH="$PAGE" DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'already a qto doc export' "$T/o" &&
  pass "import refuses a page already in the map" || fail "re-import (rc=$rc): $(cat "$T/o")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
