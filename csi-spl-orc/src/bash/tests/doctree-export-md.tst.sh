#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: an md page moves into a qto doc (do_spl_doctree_import_md) and the
#          qto doc is written back to its md file (do_spl_doctree_export_md),
#          SPL-1607, spec 137 (SPL-1745). The desk's spool binary is a
#          stateful fake of the hub side of `spool doctree` (create / edit /
#          add / delete / head / read, the outline derived as the hub derives
#          it); its `export` runs the COMPILED spool (`doctree export --from`
#          the fake's read answer), so the Markdown is the Go exporter's,
#          not a copy of it (spec 137 T032).
#   1. both actions exist (red before they landed)
#   2. import DRY_RUN=1 (the default) makes no spool call
#   3. import refuses: a path that is not a repo-relative .md, a section
#      number the doc would not derive; no spool call
#   4. import: one create, the preamble on the hidden root, one heading per
#      section at its level; the map row; the md file now says
#      "generated from qto doc <id>; edit it there"
#   5. the export keeps every section and its text: only the generated-from
#      line and the dot after a top-level number differ from the page
#   6. export twice = no diff, and an unchanged doc leaves the file untouched
#      (its mtime too)
#   7. CONTROL: an edited node changes the md, in that section only
#   8. import refuses a page already in the map
#   9. T032: the export ran the compiled spool
#  10. T012/T012a: unnumbered headings ('## Overview', and every heading
#      under one) import with --unnumbered and export with no number
#  11. T013: a 5-level outline ('##' .. '######') round-trips, no level folded
#  12. T014: YAML front matter lands in the root's attrs.front_matter and is
#      written back on top of the page
#  13. T015: a '````' fence holding '```' and a '## ' line stays one body
#  14. T016: a write that fails deletes the created doc: nothing left, no
#      map row, the page untouched
#  15. T017: a page at the repo root (README.md) imports and exports
#  16. T030a: QTO_FS=repo imports a page that is already an export into the
#      repo tree: every spool call carries SPOOL_DOCTREE_FS=repo, the map row
#      a third column "repo", the md one generated-from line (the new doc's);
#      the export reads the column; a bad QTO_FS or column is refused
#  17. SPL-1612: the compiled export opens with the preamble (the root's
#      body); a preamble with a second '# ' line and a fenced '## ' line
#      round-trips byte-stable; an older spool's export (no preamble) still
#      composes the same page
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

export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain: the export is tested with the compiled spool"; exit 1; }
SPOOL_GO="$T/spool-go"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$SPOOL_GO" ./cmd/spool) ||
  { echo "FAIL: spool build"; exit 1; }

D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool/a-177" "$D/keys" "$T/state/dev/bin"
cat >"$T/state/dev/bin/spool" <<'EOF_STUB'
#!/usr/bin/env python3
import json, os, shlex, subprocess, sys
st = os.environ["DT_STATE"]
db = json.load(open(st)) if os.path.exists(st) else {"items": []}
open(os.environ["CALLS"], "a").write(shlex.join(sys.argv[1:]) + "\n")
open(os.environ["CALLS"] + ".fs", "a").write(os.environ.get("SPOOL_DOCTREE_FS", "") + "\n")
a = sys.argv[2:]
def flag(n):
    return a[a.index(n) + 1] if n in a else ""
def outline():
    # the hub's (store outlineOf): an item with attrs.numbered false, and every
    # item under one, has no outline and is not counted among its siblings
    c, num, out = [], [True], []
    for it in db["items"]:
        d = it["depth"]
        c, num = c[:d], num[:d]
        while len(c) < d: c.append(0)
        on = num[-1] and it["attrs"].get("numbered") is not False
        if on: c[-1] += 1
        num.append(on)
        out.append(dict(it, parent="r00t", outline=".".join(map(str, c)) if on else ""))
    return out
def root():
    return {"id": "r00t", "parent": "", "depth": 0, "body": db["root_body"], "attrs": db["root_attrs"]}
v = a[0]
if v == "add" and os.environ.get("DT_FAIL_AT") == str(len(db["items"]) + 1):
    sys.exit("422: refused (planted failure)")
if v == "create":
    db = {"id": "d0c", "title": flag("--title"), "root_body": "", "root_attrs": {}, "items": []}
    print(json.dumps({"id": "d0c", "root": "r00t", "rev": 1}))
elif v == "edit":
    body, f = open(flag("--file")).read(), flag("--field")
    if f.startswith("attrs."):
        (db["root_attrs"] if a[2] == "r00t" else [it for it in db["items"] if it["id"] == a[2]][0]["attrs"])[f[6:]] = body
    elif a[2] == "r00t": db["root_body"] = body
    else: [it.update({f: body}) for it in db["items"] if it["id"] == a[2]]
elif v == "add":
    body = open(flag("--file")).read() if "--file" in a else ""
    attrs = {"numbered": False} if "--unnumbered" in a else {}
    db["items"].append({"id": "i%d" % len(db["items"]), "depth": int(flag("--level")), "title": flag("--title"), "body": body, "attrs": attrs})
elif v == "delete":
    db = {"items": [], "deleted": a[1]}
elif v == "head":
    print(json.dumps({"id": a[1], "title": db["title"], "root": "r00t"}))
elif v == "read":
    print(json.dumps({"items": [root()] + outline()}))
elif v == "export":
    rd = st + ".read.json"
    json.dump({"items": [root()] + outline()}, open(rd, "w"))
    open(os.environ["CALLS"] + ".go", "a").write("go doctree export " + a[1] + "\n")
    sys.exit(subprocess.run([os.environ["SPOOL_GO"], "doctree", "export", a[1], "--from", rd]).returncode)
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
  : >"$T/calls.go"
  : >"$T/calls.fs"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
'"$act" in_orc APP_PATH="$R" TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 \
    CALLS="$T/calls" DT_STATE="$T/dt.json" SPOOL_GO="$SPOOL_GO" "$@" >"$T/o" 2>&1
  rc=$?
}
calls() { sed 's/^doctree //' "$T/calls"; }
GEN='> Generated from qto doc `d0c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.'

# roundtrip <label> <page rel> <want diff> [VAR=value]... - import the page
# (its own map and doc state), then diff it against the copy taken before
roundtrip() {
  local label="$1" page="$2" want="$3" n="$4"; shift 4
  cp "$R/$page" "$T/rt.orig"
  run do_spl_doctree_import_md MD_PATH="$page" DRY_RUN=0 QTO_MAP="$T/map.$n" DT_STATE="$T/dt.$n.json" "$@"
  local d
  d="$(diff "$T/rt.orig" "$R/$page" | grep '^[<>]' | sed 's/ *$//')"
  if [[ $rc -eq 0 && "$d" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (rc=$rc): $(cat "$T/o") / diff: $d"
  fi
}

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
for bad in /etc/x.md ../x.md csi-spl-doc/../../x.md csi-spl-doc/doc/md/runbook-x.txt .md; do
  run do_spl_doctree_import_md MD_PATH="$bad" DRY_RUN=0
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'must be a repo-relative .md file' "$T/o" &&
    pass "import refuses '$bad'" || fail "path '$bad' (rc=$rc): $(cat "$T/o")"
done
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
grep -qxF "$GEN" "$R/$PAGE" &&
  pass "the md file says it is generated from the qto doc" || fail "no generated-from line: $(head -3 "$R/$PAGE")"

# --- 9. T032: the compiled spool wrote the Markdown ------------------------------------------------
[[ "$(cat "$T/calls.go")" == "go doctree export d0c" ]] &&
  pass "T032: the export ran the compiled spool (doctree export --from)" || fail "T032: no compiled export: $(cat "$T/calls.go")"

# --- 5. nothing lost -------------------------------------------------------------------------------
d="$(diff "$T/page.orig" "$R/$PAGE" | grep '^[<>]' | sed 's/ *$//')"
want_d="> $GEN
>
< ## 1. The job
> ## 1 The job
< ## 2. The commands
> ## 2 The commands
< ## 3. Traps
> ## 3 Traps"
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

# --- 10. T012 / T012a: unnumbered headings ----------------------------------------------------------
P="csi-spl-doc/doc/md/unnumbered.md"
cat >"$R/$P" <<'EOF_MD'
# Unnumbered

## Overview

Why it exists.

### Notes

Under an unnumbered heading.

## 1. Goals

### 1.1 First

One.

## Appendix

### 2. Not a section number here

Kept as the title.
EOF_MD
roundtrip "T012/T012a: unnumbered headings round-trip with no number" "$P" "> $GEN
>
< ## 1. Goals
> ## 1 Goals" 10
grep -q "add d0c --kind heading --level 1 --unnumbered --title Overview" "$T/calls" &&
  grep -q "add d0c --kind heading --level 2 --unnumbered --title 'Notes'\|add d0c --kind heading --level 2 --unnumbered --title Notes" "$T/calls" &&
  grep -q "add d0c --kind heading --level 2 --unnumbered --title '2. Not a section number here'" "$T/calls" &&
  grep -q "add d0c --kind heading --level 2 --title First" "$T/calls" &&
  pass "T012: unnumbered sections (and every one under one) are added --unnumbered" ||
  fail "T012 calls: $(cat "$T/calls")"

# --- 11. T013: five heading levels ---------------------------------------------------------------------
P="csi-spl-doc/doc/md/deep.md"
cat >"$R/$P" <<'EOF_MD'
# Deep

## 1. One

### 1.1 Two

#### 1.1.1 Three

##### 1.1.1.1 Four

###### 1.1.1.1.1 Five

Deepest text.

## 2. Back up
EOF_MD
roundtrip "T013: a 5-level outline round-trips, '#####' and '######' kept" "$P" "< ## 1. One
> $GEN
>
> ## 1 One
< ## 2. Back up
> ## 2 Back up" 11

# --- 12. T014: YAML front matter ---------------------------------------------------------------------
P="csi-spl-doc/doc/md/fm.md"
cat >"$R/$P" <<'EOF_MD'
---
title: Front matter
tags: [a, b]
---

# With front matter

Preamble.

## 1. Body

Text.
EOF_MD
roundtrip "T014: the front matter is written back on top of the page" "$P" "> $GEN
>
< ## 1. Body
> ## 1 Body" 12
python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["root_attrs"]; sys.exit(a != {"front_matter": "title: Front matter\ntags: [a, b]"})' "$T/dt.12.json" &&
  pass "T014: the front matter is the root item's attrs.front_matter" || fail "T014 root attrs: $(cat "$T/dt.12.json")"

# --- 13. T015: a four-backtick fence -------------------------------------------------------------------
P="csi-spl-doc/doc/md/fence.md"
cat >"$R/$P" <<'EOF_MD'
# Fences

## 1. Example

````md
```bash
echo inner
```

## not a heading
````

After the fence.

## 2. Next
EOF_MD
roundtrip "T015: a '\`\`\`\`' fence holding '\`\`\`' and '## ' stays one body" "$P" "< ## 1. Example
> $GEN
>
> ## 1 Example
< ## 2. Next
> ## 2 Next" 13
[[ "$(calls | grep -c '^add ')" == 2 ]] && pass "T015: two sections, the fenced '## ' is text" ||
  fail "T015: $(calls | grep '^add ')"

# --- 14. T016: all or nothing -----------------------------------------------------------------------
P="csi-spl-doc/doc/md/fails.md"
cp "$T/page.orig" "$R/$P"
cp "$R/$P" "$T/fails.orig"
run do_spl_doctree_import_md MD_PATH="$P" DRY_RUN=0 QTO_MAP="$T/map.14" DT_STATE="$T/dt.14.json" DT_FAIL_AT=3
if [[ $rc -ne 0 ]] && grep -qx 'doctree delete d0c' "$T/calls" && grep -q 'rolled back' "$T/o" &&
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d.get("deleted") == "d0c" and d["items"] == []))' "$T/dt.14.json" &&
  [[ ! -e "$T/map.14" ]] && cmp -s "$T/fails.orig" "$R/$P"; then
  pass "T016: a failed write deletes the created doc: 0 items left, no map row, the page untouched"
else
  fail "T016 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls") / $(cat "$T/dt.14.json")"
fi

# --- 15. T017: a page at the repo root -----------------------------------------------------------------
cp "$T/page.orig" "$R/README.md"
roundtrip "T017: README.md at the repo root imports and exports" README.md "$want_d" 15
grep -qx "d0c	README.md" "$T/map.15" && pass "T017: the map row names README.md" || fail "T017 map: $(cat "$T/map.15" 2>&1)"

# --- 16. T030a: into the repo tree ----------------------------------------------------------------
P="csi-spl-doc/doc/md/runbook-repo.md"
sed 's/`d0c`/`old-workspace-doc`/' "$R/$PAGE" >"$R/$P"
run do_spl_doctree_import_md MD_PATH="$P" DRY_RUN=0 QTO_FS=repo QTO_MAP="$T/map.16" DT_STATE="$T/dt.16.json"
if [[ $rc -eq 0 ]] && [[ "$(sort -u "$T/calls.fs")" == repo ]] && [[ "$(wc -l <"$T/calls.fs")" -ge 8 ]] &&
  [[ "$(cat "$T/map.16")" == "d0c	$P	repo" ]] && [[ "$(grep -c '^> Generated from qto doc' "$R/$P")" == 1 ]] &&
  grep -qxF "$GEN" "$R/$P" && cmp -s "$R/$PAGE" "$R/$P"; then
  pass "T030a: QTO_FS=repo: every call fs=repo, map row 'repo', one generated-from line, the same md"
else
  fail "T030a import (rc=$rc): $(cat "$T/o") / fs: $(sort <"$T/calls.fs" | uniq -c) / map: $(cat "$T/map.16" 2>&1) / $(diff "$R/$PAGE" "$R/$P")"
fi
run do_spl_doctree_export_md QTO_MAP="$T/map.16" DT_STATE="$T/dt.16.json"
[[ $rc -eq 0 && "$(sort -u "$T/calls.fs")" == repo ]] && grep -q "unchanged (qto doc d0c)" "$T/o" &&
  pass "T030a: the export reads the map's repo column" || fail "T030a export (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.fs")"
run do_spl_doctree_export_md QTO_MAP="$T/map.10" DT_STATE="$T/dt.10.json"
[[ $rc -eq 0 && -z "$(sort -u "$T/calls.fs")" ]] && pass "CONTROL: a two-column row stays in the workspace tree" ||
  fail "T030a control (rc=$rc): $(cat "$T/calls.fs")"
run do_spl_doctree_import_md MD_PATH="$PAGE" DRY_RUN=0 QTO_FS=git QTO_MAP="$T/map.16b"
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "a qto tree is workspace or repo, not 'git'" "$T/o" &&
  pass "T030a: import refuses QTO_FS=git, no spool call" || fail "QTO_FS=git (rc=$rc): $(cat "$T/o")"
printf 'd0c\t%s\tgit\n' "$P" >"$T/map.16c"
run do_spl_doctree_export_md QTO_MAP="$T/map.16c" DT_STATE="$T/dt.16.json"
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "a qto tree is workspace or repo, not 'git'" "$T/o" &&
  pass "T030a: export refuses a map row whose tree is not workspace or repo" || fail "map git (rc=$rc): $(cat "$T/o")"

# --- 17. SPL-1612: the preamble comes from the export itself ---------------------------------------
# the compiled spool's export opens with the root's body; compose keeps it as
# it is (a second '# ' line and a fenced '## ' line stay preamble text, never
# a section), and an older spool's export (no preamble) still gets it once
P="csi-spl-doc/doc/md/preamble.md"
cat >"$R/$P" <<'EOF_MD'
# Preamble page

Read this first.

# Not a section

```text
## not a heading
```

## 1 The job

Keep moving.
EOF_MD
roundtrip "SPL-1612: a preamble with a '# ' line and a fence round-trips byte-stable" "$P" "> $GEN
>" 17
"$SPOOL_GO" doctree export d0c --from "$T/dt.17.json.read.json" >"$T/go17.md" 2>&1
[[ "$(head -1 "$T/go17.md")" == "Read this first." ]] && grep -qx '# 1 The job' "$T/go17.md" &&
  pass "SPL-1612: the spool export itself opens with the preamble" || fail "go export: $(cat "$T/go17.md")"
printf '%s\n' "$(sed -n '/^# 1 The job$/,$p' "$T/go17.md")" >"$T/old17.md"
python3 "$PROJ_ROOT/src/bash/run/spl-doctree-md.py" compose <(echo '{"title":"Preamble page"}') \
  "$T/dt.17.json.read.json" "$T/old17.md" d0c >"$T/old17.out" 2>&1
[[ "$(grep -c '^Read this first\.$' "$T/old17.out")" == 1 ]] && cmp -s "$T/old17.out" "$R/$P" &&
  pass "SPL-1612: an older spool's export (no preamble) composes the same page" ||
  fail "older spool compose: $(diff "$R/$P" "$T/old17.out")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
