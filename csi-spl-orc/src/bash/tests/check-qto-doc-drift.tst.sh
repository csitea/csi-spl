#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_qto_doc_drift (SPL-2164) fails when a md file that is a
#          qto doc's export drifts from its doc, naming the file.
#   1. the map check passes on this tree (the known-drift list included)
#   2. a fixture tree (2 rows, 2 exported files) passes
#   3. CONTROLS, each red and naming the file: a stamp that names another
#      doc; a mapped file with no stamp; a mapped file that is gone; a
#      stamped file no row names; a path mapped twice; a bad row; two stamps
#   4. the known-drift list: a listed drift is a WARN (exit 0); a listed file
#      that no longer drifts is a FAIL (the ratchet)
#   5. do_spl_doctree_export_md QTO_CHECK=1 (the hub stubbed, the real
#      composer): an equal file is OK and untouched; CONTROL: a hand edit is
#      a FAIL naming the file, with its diff, and the file is NOT rewritten;
#      every row is still read; without QTO_CHECK the same run rewrites it
#   6. the live check (QTO_DRIFT_LIVE=1) runs that compare over the map,
#      QTO_DRIFT_FS=repo only the repo rows
#   7. a git tree (SPL-2307): a GIT-IGNORED stamped md with no map row (a
#      terraform modules/README.md) is not read, the tree passes; CONTROL:
#      the same file tracked is red, naming it
#   8. the workspace (SPL-3541): CONTROLS, each red: a planted row of a
#      private workspace (csitea), a stamp naming one, a stamp naming none
#      (the old form), a stamp and row that disagree, an old two-column row,
#      a known-drift line trying to waive a workspace FAIL, a missing cnf
#      and an empty allow list (fail closed); the real map passes (case 1)
#   Nothing outside the throwaway trees is written.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$PROJ_ROOT/src/bash/run/check-qto-doc-drift.func.sh"

A=11111111-1111-4111-8111-111111111111 B=22222222-2222-4222-8222-222222222222
MAPREL=csi-spl-doc/doc/md/qto-docs.tsv

# expect <label> <want rc> <want substring> -- <env...>: one map-check run.
expect() {
  local label="$1" want="$2" grep_for="$3" out rc=0
  shift 4
  out="$(env "$@" bash -c "source '$PROJ_ROOT/src/bash/run/check-qto-doc-drift.func.sh'; do_check_qto_doc_drift" 2>&1)" || rc=$?
  if [[ "$rc" == "$want" && "$out" == *"$grep_for"* ]]; then pass "$label"; else fail "$label: rc=$rc (want $want), no '$grep_for' in: $out"; fi
}

# stamp <doc id> <title> [workspace, default system]
stamp() { printf '# %s\n\n> Generated from qto doc `%s`; edit it there. Workspace `%s`.\n\nbody\n' "$2" "$1" "${3:-system}"; }
# cnf <tree> [allow-list yaml, default [system, t1]]: the tree's cnf
cnf() { mkdir -p "$1/csi-spl-cnf/csi-spl"; printf 'env:\n  docs:\n    repo_export_tenants: %s\n' "${2:-[system, t1]}" >"$1/csi-spl-cnf/csi-spl/all.env.yaml"; }

# A tree with two exported files: a.md (doc A, repo = workspace system) and
# sub/b.md (doc B, workspace t1), and its cnf.
mk_tree() {  # <dir>
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/csi-spl-doc/doc/md" "$d/sub"
  printf '%s\ta.md\trepo\n%s\tsub/b.md\tt1\n' "$A" "$B" >"$d/$MAPREL"
  stamp "$A" "Doc A" >"$d/a.md"
  stamp "$B" "Doc B" t1 >"$d/sub/b.md"
  cnf "$d"
}

# 1. this tree
rc=0; out="$(QTO_DRIFT_TREE="$APP_ROOT" do_check_qto_doc_drift 2>&1)" || rc=$?
if (( rc == 0 )) && [[ "$out" == *"OK qto doc map:"* ]]; then pass "1 this tree passes: ${out##*OK }"; else fail "1 this tree: rc=$rc $out"; fi

# 2. the fixture
F="$T/f"; mk_tree "$F"
expect "2 a fixture tree passes" 0 "OK qto doc map: 2 rows, 2 exported md files" -- QTO_DRIFT_TREE="$F"

# 3. controls
mk_tree "$F"; stamp "$B" "Doc A" >"$F/a.md"
expect "3a CONTROL a stamp naming another doc is red" 1 "FAIL a.md: its generated-from line names qto doc $B, the map $A" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '# Doc A\n\nhand written\n' >"$F/a.md"
expect "3b CONTROL a mapped file with no stamp is red" 1 "FAIL a.md: mapped to qto doc $A, but it has no generated-from line" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; rm "$F/sub/b.md"
expect "3c CONTROL a mapped file that is gone is red" 1 "FAIL sub/b.md: mapped to qto doc $B, but the file does not exist" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; stamp 33333333-3333-4333-8333-333333333333 "Doc C" >"$F/sub/c.md"
expect "3d CONTROL a stamped file no row names is red" 1 "FAIL sub/c.md: says generated from qto doc 33333333" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '33333333-3333-4333-8333-333333333333\ta.md\trepo\n' >>"$F/$MAPREL"
expect "3e CONTROL a path mapped twice is red" 1 "FAIL a.md: qto-docs.tsv:3: the path is mapped twice" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf 'not-a-uuid\tsub/x.md\tt1\n' >>"$F/$MAPREL"
expect "3f CONTROL a bad row is red" 1 "FAIL sub/x.md: qto-docs.tsv:3: a row is <uuid> TAB" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '%s\t../up.md\tt1\n' 33333333-3333-4333-8333-333333333333 >>"$F/$MAPREL"
expect "3g CONTROL a path out of the tree is red" 1 "FAIL ../up.md: qto-docs.tsv:3: a row is" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; stamp "$A" "Doc A" >>"$F/a.md"
expect "3h CONTROL two stamps in one file are red" 1 "FAIL a.md: 2 generated-from lines" -- QTO_DRIFT_TREE="$F"

# 4. the known-drift list
mk_tree "$F"; printf '# Doc A\n\nhand written\n' >"$F/a.md"; printf '# c\na.md\twaits for its export\n' >"$F/known.tsv"
expect "4a a listed drift is a WARN, exit 0" 0 "WARN a.md: mapped to qto doc $A, but it has no generated-from line: its export never landed (known drift: waits for its export)" -- QTO_DRIFT_TREE="$F" QTO_DRIFT_KNOWN="$F/known.tsv"
mk_tree "$F"; printf 'a.md\twaits for its export\n' >"$F/known.tsv"
expect "4b CONTROL a listed file that no longer drifts is red" 1 "FAIL a.md: listed in known.tsv, but it no longer drifts" -- QTO_DRIFT_TREE="$F" QTO_DRIFT_KNOWN="$F/known.tsv"

# 5. the export in compare mode. The hub is stubbed: do_spl_desk_doctree
# answers head / read / export from $HUB/<doc>.*; the composer is the real one.
HUB="$T/hub"; mkdir -p "$HUB"
for n in A B; do
  d="${!n}"
  printf '{"title":"Doc %s","root":"r1"}\n' "$n" >"$HUB/$d.head"
  printf '{"items":[{"id":"r1","body":""},{"id":"i1","parent":"r1","title":"Intro","outline":"1","body":"hello %s"}]}\n' "$n" >"$HUB/$d.read"
  printf '# Doc %s\n\n## 1 Intro\n\nhello %s\n' "$n" "$n" >"$HUB/$d.export"
done
E="$T/e"
mk_export_tree() {
  rm -rf "$E"; mkdir -p "$E/csi-spl-doc/doc/md" "$E/sub"
  printf '%s\ta.md\trepo\n%s\tsub/b.md\tt1\n' "$A" "$B" >"$E/$MAPREL"
  cnf "$E"
  python3 "$PROJ_ROOT/src/bash/run/spl-doctree-md.py" compose "$HUB/$A.head" "$HUB/$A.read" "$HUB/$A.export" "$A" system >"$E/a.md"
  python3 "$PROJ_ROOT/src/bash/run/spl-doctree-md.py" compose "$HUB/$B.head" "$HUB/$B.read" "$HUB/$B.export" "$B" t1 >"$E/sub/b.md"
}
# run_export <env...>: the export action in a subshell with the stubbed hub;
# CALLS gets "<fs> <verb> <doc>" per hub call.
run_export() {
  env TENANT_ID=t1 "$@" APP_PATH="$E" PROJ_PATH="$PROJ_ROOT" HUB="$HUB" CALLS="$T/calls" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    do_spl_desk_doctree() {
      read -r verb doc _ <<<"$DOCTREE_ARGS"
      echo "${DOCTREE_FS:-} $verb $doc" >>"$CALLS"
      case "$verb" in head) cat "$HUB/$doc.head" ;; read) cat "$HUB/$doc.read" ;; export) cat "$HUB/$doc.export" ;; *) return 1 ;; esac
    }
    source "$PROJ_PATH/lib/bash/funcs/spl-desk-cron-tree-guard.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-doctree-export-md.func.sh"
    source "$PROJ_PATH/src/bash/run/check-qto-doc-drift.func.sh"
    if [[ -n "${VIA_DRIFT:-}" ]]; then do_check_qto_doc_drift; else do_spl_doctree_export_md; fi' 2>&1
}

mk_export_tree; before="$(stat -c %Y.%s "$E/a.md")"; sleep 1
rc=0; out="$(run_export QTO_CHECK=1)" || rc=$?
if (( rc == 0 )) && [[ "$out" == *"OK 2 md file(s) equal their qto doc's export"* && "$(stat -c %Y.%s "$E/a.md")" == "$before" ]]; then
  pass "5a QTO_CHECK=1: equal files are OK and untouched"
else fail "5a QTO_CHECK=1 equal: rc=$rc $out"; fi

mk_export_tree
python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("hello A", "hello A, by hand"))' "$E/a.md"
cp "$E/a.md" "$T/a.hand"; : >"$T/calls"
rc=0; out="$(run_export QTO_CHECK=1)" || rc=$?
if (( rc == 1 )) && [[ "$out" == *"FAIL a.md differs from qto doc $A"* && "$out" == *"-hello A, by hand"* \
      && "$out" == *"FAIL 1 of 2 md file(s) differ"* ]] && cmp -s "$E/a.md" "$T/a.hand" && grep -q "export $B" "$T/calls"; then
  pass "5b CONTROL QTO_CHECK=1: a hand edit is red, named, with its diff; not rewritten; the next row still read"
else fail "5b CONTROL QTO_CHECK=1 hand edit: rc=$rc $out"; fi

rc=0; out="$(run_export)" || rc=$?
if (( rc == 0 )) && [[ "$out" == *"OK a.md written from qto doc $A"* ]] && ! cmp -s "$E/a.md" "$T/a.hand"; then
  pass "5c without QTO_CHECK the same run rewrites the file"
else fail "5c export without QTO_CHECK: rc=$rc $out"; fi

# 6. the live check over the map
mk_export_tree
python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("hello B", "hello B, by hand"))' "$E/sub/b.md"
: >"$T/calls"
rc=0; out="$(run_export VIA_DRIFT=1 QTO_DRIFT_TREE="$E" QTO_DRIFT_LIVE=1)" || rc=$?
if (( rc == 1 )) && [[ "$out" == *"OK qto doc map: 2 rows"* && "$out" == *"FAIL sub/b.md differs from qto doc $B"* ]]; then
  pass "6a CONTROL QTO_DRIFT_LIVE=1: the map check passes, the live compare names the hand-edited file"
else fail "6a QTO_DRIFT_LIVE=1: rc=$rc $out"; fi
: >"$T/calls"
rc=0; out="$(run_export VIA_DRIFT=1 QTO_DRIFT_TREE="$E" QTO_DRIFT_LIVE=1 QTO_DRIFT_FS=repo)" || rc=$?
if (( rc == 0 )) && [[ "$out" == *"OK 1 md file(s) equal"* ]] && grep -q "^repo export $A" "$T/calls" && ! grep -q "$B" "$T/calls"; then
  pass "6b QTO_DRIFT_FS=repo reads only the repo rows, from the repo tree"
else fail "6b QTO_DRIFT_FS=repo: rc=$rc $out / $(cat "$T/calls")"; fi
rc=0; out="$(run_export VIA_DRIFT=1 QTO_DRIFT_TREE="$E" QTO_DRIFT_LIVE=1 QTO_DRIFT_FS=bogus)" || rc=$?
if (( rc == 1 )) && [[ "$out" == *"FATAL QTO_DRIFT_FS is repo or workspace, not 'bogus'"* ]]; then
  pass "6c a bad QTO_DRIFT_FS is refused"
else fail "6c QTO_DRIFT_FS=bogus: rc=$rc $out"; fi

# 7. only tracked files are read in a git tree
G="$T/g"; mk_tree "$G"; mkdir -p "$G/bin/dev"
stamp 33333333-3333-4333-8333-333333333333 "Modules" >"$G/bin/dev/README.md"
printf 'bin/\n' >"$G/.gitignore"
git -C "$G" init -q && git -C "$G" add .gitignore a.md sub csi-spl-doc
expect "7a a git-ignored stamped md with no row is skipped" 0 "OK qto doc map: 2 rows, 2 exported md files" -- QTO_DRIFT_TREE="$G"
git -C "$G" add -f bin/dev/README.md
expect "7b CONTROL the same file tracked is red" 1 "FAIL bin/dev/README.md: says generated from qto doc 33333333" -- QTO_DRIFT_TREE="$G"

# 8. the workspace (SPL-3541)
C=33333333-3333-4333-8333-333333333333
mk_tree "$F"; printf '%s\tsub/c.md\tcsitea\n' "$C" >>"$F/$MAPREL"; stamp "$C" "Doc C" csitea >"$F/sub/c.md"
expect "8a CONTROL a planted row of workspace csitea is red" 1 "FAIL sub/c.md: mapped to workspace csitea, which is not in cnf docs.repo_export_tenants (system, t1)" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; stamp "$B" "Doc B" csitea >"$F/sub/b.md"
expect "8b CONTROL a stamp naming workspace csitea is red" 1 "FAIL sub/b.md: its generated-from line names workspace csitea, which is not in cnf" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '# Doc B\n\n> Generated from qto doc `%s`; edit it there. This file is its export.\n' "$B" >"$F/sub/b.md"
expect "8c CONTROL a stamp naming no workspace (the old form) is red" 1 "FAIL sub/b.md: its generated-from line names no workspace" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; stamp "$B" "Doc B" system >"$F/sub/b.md"
expect "8d CONTROL a stamp and its row naming two workspaces is red" 1 "FAIL sub/b.md: its generated-from line names workspace system, its map row t1" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '%s\ta.md\trepo\n%s\tsub/b.md\n' "$A" "$B" >"$F/$MAPREL"
expect "8e CONTROL an old two-column row (no workspace) is red" 1 "FAIL sub/b.md: qto-docs.tsv:2: a row is <uuid> TAB <repo-relative .md> TAB <repo|workspace id>" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; printf '%s\tsub/c.md\tcsitea\n' "$C" >>"$F/$MAPREL"; stamp "$C" "Doc C" csitea >"$F/sub/c.md"; printf 'sub/c.md\twaived\n' >"$F/known.tsv"
expect "8f CONTROL the known-drift list never waives a workspace FAIL" 1 "FAIL sub/c.md: mapped to workspace csitea" -- QTO_DRIFT_TREE="$F" QTO_DRIFT_KNOWN="$F/known.tsv"
mk_tree "$F"; rm -r "$F/csi-spl-cnf"
expect "8g CONTROL a missing cnf fails closed" 1 "cnf docs.repo_export_tenants is not readable or empty" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; cnf "$F" '[]'
expect "8h CONTROL an empty allow list fails closed" 1 "cnf docs.repo_export_tenants is not readable or empty" -- QTO_DRIFT_TREE="$F"
mk_tree "$F"; cnf "$F" '[system]'
expect "8i CONTROL the same t1 row is red once t1 leaves the allow list" 1 "FAIL sub/b.md: mapped to workspace t1, which is not in cnf docs.repo_export_tenants (system)" -- QTO_DRIFT_TREE="$F"

echo "check-qto-doc-drift: $passes passed, $fails failed"
(( fails == 0 ))
