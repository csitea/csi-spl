#!/usr/bin/env bash
# test-timeout: 300 -- 20..39 s on green CI, 66..112 s solo at load 70..110 on 16 cores (c-411, n=3); the 120 s default killed it twice
#------------------------------------------------------------------------------
# Purpose: the controls CLE-77824 promised for the diff-scoped, cached, loud
#          pre-push gate -- end to end through do_check_pre_push, with STUB parts
#          (a part passes iff <tree>/<its dir>/flag says 'good', and appends its
#          name to a run counter), so nothing heavy runs.
#     1. green trunk + a NEW break in a touched part     -> REFUSED (rc 1, FAIL logged)
#     2. red trunk + a fix                               -> ALLOWED (rc 0)
#     3. red trunk + still red                           -> ALLOWED, WARN-pre-existing logged with the trunk sha
#     4. a push touching only csi-spl-orc                -> runs the orc part, neither iac nor api (SKIP-untouched logged)
#     5. a rebase over commits that touch OTHER parts    -> the green api verdict is RE-USED (no re-run)
#        ... and a change under csi-spl-api re-runs it
#     6. yq missing                                      -> FAIL naming yq, the part never runs
#     7. a part that exits 127 (command not found) on
#        HEAD and trunk alike                            -> FAIL, never a pre-existing WARN
#     8. every part writes exactly one verdict line with a duration
#     9. a push that only EDITS e2e/bench files      -> the wui part never runs
#        (a new/deleted e2e file or a ci-skip.txt edit still runs it)
#    10. wui cache HIT over non-wui and e2e/bench-edit commits
#    11. wui cache MISS over wui src, e2e names, ci-skip.txt and a hub file a
#        unit test reads; that hub file also SELECTS the part (CLE-77946)
#    12. (2026-10-04, c-231) a push touching no wui input -- api + a spec
#        tasks.md, a dir a unit test names only as FIXTURE data -- does not run
#        the wui part, before or after trunk gains a wui commit mid-push
#    13. (c-226) a green wui verdict survives a rebase over a spec tasks.md and a
#        cnf tfvars; a templated read (csi-spl-cnf/csi-spl/${env}.env.json) is a
#        glob: its files select and key the part, the rest of that dir does not
#    14. (c-502) a push touching ONLY csi-spl-cnf/csi-spl/** runs the cnf render
#        part, not the iac suite; CONTROL: cnf + a .sh, and cnf + conf-validator
#        code (csi-spl-cnf/src), still run the iac suite and not the cnf part
#    15. the real cnf part (do_tpl_gen stubbed): an unchanged render PASSES, a
#        stale one FAILS naming the env; CONTROL: no tpl-gen venv is a FAIL
#    16. (2026-10-10, c-786) a push changing ONE spec .md selects no wui part,
#        though a build module reads that dir under a PARAMETER
#        (sync-roadmap.mjs: existsSync(join(repo, 'csi-spl-doc/specs')));
#        CONTROL: a dir read under a checkout constant (join(WUI,
#        '../csi-spl-doc/doc/help'), join(REPO, '.github/workflows', wf))
#        still selects it
#------------------------------------------------------------------------------
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
# node and pnpm only feed the wui cache key a version string (_pp_key,
# _pp_tree_key), and each `pnpm -v` starts Node: 46 per run, ~10 of the 30 s
# idle; a loaded CI runner killed the file at 300 s (c-729, wf 10 job
# 113993661903). Fixed stubs give the same key on both sides of every case.
mkdir -p "$ROOT/tools"
for t in node pnpm; do printf '#!/bin/sh\necho v0-stub\n' >"$ROOT/tools/$t"; chmod +x "$ROOT/tools/$t"; done
export PATH="$ROOT/tools:$PATH"

do_log() { :; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

# Stub parts: count every run, pass iff <tree>/<dir>/flag contains 'good'.
COUNT="$ROOT/count"
_stub() { echo "$1" >>"$COUNT"; grep -q good "$2/$1/flag" 2>/dev/null || { echo "FAIL: $1 flag is not good"; return 1; }; }
_pp_part_api() { _stub csi-spl-api "$1"; }
_pp_part_iac() { _stub csi-spl-iac "$1"; }
_pp_part_wui() { echo csi-spl-wui-unit >>"$COUNT"; grep -q good "$1/csi-spl-wui/flag" 2>/dev/null; }
_pp_part_wui_vendor() { _stub csi-spl-wui "$1"; }
_pp_part_cnf() { echo cnf-render >>"$COUNT"; }
_pp_part_orc() { _stub csi-spl-orc "$1"; }
runs() { grep -cx "$1" "$COUNT" 2>/dev/null || true; }

# A repo whose 'trunk' branch plays origin/master; HEAD is a lane branch.
mkrepo() {  # <dir>
  local R="$1"
  git init -q "$R"
  for d in csi-spl-api csi-spl-iac csi-spl-wui csi-spl-orc; do mkdir -p "$R/$d"; echo good >"$R/$d/flag"; done
  git -C "$R" add -A; git -C "$R" commit -qm seed
  git -C "$R" branch trunk
  git -C "$R" checkout -q -b lane
}
# The stub repos carry no toolchain scaffold, so the tool preflight is stubbed
# to "nothing missing" -- except in case 6, which runs the real one (TOOLS=real).
# The lint parts (scanners) have their own test, check-pre-push-lint.tst.sh;
# here the lint planner selects none, so only the suite routing is under test.
gate() {  # <repo> [env...] -> rc; per-part log in $R.log
  local R="$1" pre='_pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }'; shift
  [ "${TOOLS:-stub}" = real ] && pre='_ppl_plan() { _PPL_SELECTED=""; }'
  ( env "$@" PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$R.log" PRE_PUSH_CACHE="$R.cache" \
      bash -c '. "$0"; '"$pre"'; '"$(declare -f do_log do_check_dist_hygiene _stub _pp_part_api _pp_part_iac _pp_part_wui _pp_part_wui_vendor _pp_part_cnf _pp_part_orc)"'; COUNT="'"$COUNT"'"; do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
}
verdict() { awk -v p="$2" '$3=="PART" && $4==p {v=$5} END{print v}' "$1.log"; }

# 1. green trunk + a NEW break in api -> REFUSED
R="$ROOT/r1"; mkrepo "$R" >/dev/null 2>&1
echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "break api"
gate "$R"; eq "1. green trunk + NEW api break -> REFUSED" 1 "$?"
eq "1. ... logged FAIL for api" FAIL "$(verdict "$R" api)"
grep -q 'PART api FAIL .*trunk=[0-9a-f]*-green' "$R.log" \
  && pass "1. ... as a NEW failure (trunk green)" || fail "1. ... as a NEW failure (trunk green)" "$(cat "$R.log")"

# 2. red trunk + a fix -> ALLOWED
R="$ROOT/r2"; mkrepo "$R" >/dev/null 2>&1
git -C "$R" checkout -q trunk; echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk red"
git -C "$R" checkout -q lane; git -C "$R" reset -q --hard trunk
echo good >"$R/csi-spl-api/flag"; echo fix >"$R/csi-spl-api/fix.go"; git -C "$R" add -A; git -C "$R" commit -qm fix
gate "$R"; eq "2. red trunk + a fix -> ALLOWED" 0 "$?"
eq "2. ... logged PASS for api" PASS "$(verdict "$R" api)"

# 3. red trunk + still red -> ALLOWED with WARN-pre-existing naming the trunk sha
R="$ROOT/r3"; mkrepo "$R" >/dev/null 2>&1
git -C "$R" checkout -q trunk; echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk red"
git -C "$R" checkout -q lane; git -C "$R" reset -q --hard trunk
echo x >"$R/csi-spl-api/other.go"; git -C "$R" add -A; git -C "$R" commit -qm unrelated
gate "$R"; eq "3. red trunk + still red -> ALLOWED" 0 "$?"
tsha="$(git -C "$R" rev-parse --short trunk)"
grep -q "PART api WARN-pre-existing .* trunk=$tsha" "$R.log" \
  && pass "3. ... logged WARN-pre-existing with trunk=$tsha" || fail "3. ... logged WARN-pre-existing with the trunk sha" "$(cat "$R.log")"

# 4. orc-only push -> no iac, no api
R="$ROOT/r4"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo y >"$R/csi-spl-orc/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm orc
gate "$R"; eq "4. orc-only push -> passes" 0 "$?"
eq "4. ... the iac suite never ran" 0 "$(runs csi-spl-iac)"
eq "4. ... the api suite never ran" 0 "$(runs csi-spl-api)"
eq "4. ... the orc part ran once" 1 "$(runs csi-spl-orc)"
eq "4. ... api logged SKIP-untouched" SKIP-untouched "$(verdict "$R" api)"
eq "4. ... iac logged SKIP-untouched" SKIP-untouched "$(verdict "$R" iac)"

# 5. rebase over unrelated commits re-uses the green api verdict
R="$ROOT/r5"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo a >"$R/csi-spl-api/a.go"; git -C "$R" add -A; git -C "$R" commit -qm api
gate "$R"; eq "5. first api push -> green" 0 "$?"
eq "5. ... the api suite ran once" 1 "$(runs csi-spl-api)"
git -C "$R" checkout -q trunk; echo w >"$R/csi-spl-wui/w.ts"; echo o >"$R/csi-spl-orc/o.sh"
git -C "$R" add -A; git -C "$R" commit -qm "someone else's wui+orc"; git -C "$R" checkout -q lane
git -C "$R" rebase -q trunk
gate "$R"; eq "5. after a rebase over unrelated commits -> green" 0 "$?"
eq "5. ... the api suite did NOT re-run (verdict re-used)" 1 "$(runs csi-spl-api)"
eq "5. ... logged PASS-cached for api" PASS-cached "$(verdict "$R" api)"
git -C "$R" checkout -q trunk; echo b >"$R/csi-spl-api/b.go"; git -C "$R" add -A; git -C "$R" commit -qm "someone else's api"
git -C "$R" checkout -q lane; git -C "$R" rebase -q trunk
gate "$R"; eq "5. after a rebase over another api change -> green" 0 "$?"
eq "5. ... the api suite DID re-run (its paths changed)" 2 "$(runs csi-spl-api)"
echo dirty >>"$R/csi-spl-api/a.go"
gate "$R"; eq "5. ... and a dirty api file re-runs it too (uncacheable)" 3 "$(runs csi-spl-api)"

# 6. yq missing -> FAIL naming yq; the iac part never runs
R="$ROOT/r6"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo y >"$R/csi-spl-iac/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm iac
NB="$ROOT/noyq"; mkdir -p "$NB"
for t in bash env git sha1sum cut grep date mkdir wc tail mv paste sort head cat id dirname basename mktemp timeout sed rm awk tr jq python3 ls; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NB/$t"
done
TOOLS=real gate "$R" PATH="$NB" PRE_PUSH_EXTRA_PATH=; eq "6. yq missing -> REFUSED" 1 "$?"
eq "6. ... the iac suite never ran" 0 "$(runs csi-spl-iac)"
grep -q 'PART iac FAIL .*missing-tool=yq' "$R.log" \
  && pass "6. ... the log names the missing tool (yq)" || fail "6. ... the log names the missing tool" "$(cat "$R.log")"
out="$( PATH="$NB" _pp_missing_tools iac "$R" )"
# ... while a STRIPPED PATH (yq present on the box, absent from PATH) is healed
mkdir -p "$ROOT/yqdir"; printf '#!/bin/sh\nexit 0\n' >"$ROOT/yqdir/yq"; chmod +x "$ROOT/yqdir/yq"
: >"$COUNT"; R6b="$ROOT/r6b"; mkrepo "$R6b" >/dev/null 2>&1
echo y >"$R6b/csi-spl-iac/a.sh"; git -C "$R6b" add -A; git -C "$R6b" commit -qm iac
TOOLS=real gate "$R6b" PATH="$NB" PRE_PUSH_EXTRA_PATH="$ROOT/yqdir"
grep -q 'PART iac FAIL .*missing-tool=yq' "$R6b.log" \
  && fail "6. a tool in an install dir missing from PATH is found" "$(cat "$R6b.log")" || pass "6. a tool in an install dir missing from PATH is found (PATH healed)"
case "$out" in yq\ --\ install*) pass "6. ... and the message says how to install it" ;; *) fail "6. ... the message names yq and the fix" "$out" ;; esac

# 7. rc 127 on HEAD and on trunk alike -> FAIL, never WARN
R="$ROOT/r7"; mkrepo "$R" >/dev/null 2>&1
echo z >"$R/csi-spl-api/z.go"; git -C "$R" add -A; git -C "$R" commit -qm api
( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$R.log" PRE_PUSH_CACHE="$R.cache" \
    bash -c '. "$0"; do_log(){ :; }; do_check_dist_hygiene(){ return 0; }; _pp_missing_tools(){ :; }; _ppl_plan(){ _PPL_SELECTED=""; }; _pp_part_api(){ return 127; }; do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
eq "7. rc 127 on HEAD and trunk -> REFUSED (not a pre-existing WARN)" 1 "$?"
grep -q 'PART api FAIL .*rc=127' "$R.log" && pass "7. ... logged FAIL rc=127" || fail "7. ... logged FAIL rc=127" "$(cat "$R.log")"

# 8. one verdict line per part, each with a duration
R="$ROOT/r1"
for p in hygiene iac wui-vendor wui api; do
  n="$(awk -v p="$p" '$3=="PART" && $4==p' "$R.log" | wc -l)"
  eq "8. one verdict line for $p" 1 "$n"
done
awk '$3=="PART" && $6 !~ /^[0-9]+s$/ {bad=1} END{exit bad}' "$R.log" \
  && pass "8. every verdict line carries a duration" || fail "8. every verdict line carries a duration" "$(cat "$R.log")"

# 9..11 (CLE-77946): the wui part is keyed on what unit + typecheck READ.
# A wui repo: a src file, an e2e test, ci-skip.txt, a bench file, and a unit
# test that reads one hub Go file (an external input).
mkwui() {  # <dir>
  local R="$1"; mkrepo "$R"
  mkdir -p "$R/csi-spl-wui/src" "$R/csi-spl-wui/tests/e2e" "$R/csi-spl-wui/tests/bench" "$R/csi-spl-wui/tests/unit" "$R/csi-spl-api/internal/msg"
  echo a >"$R/csi-spl-wui/src/a.ts"; echo e >"$R/csi-spl-wui/tests/e2e/x.test.mjs"
  : >"$R/csi-spl-wui/tests/e2e/ci-skip.txt"; echo b >"$R/csi-spl-wui/tests/bench/b.bench.mjs"
  echo m >"$R/csi-spl-api/internal/msg/msg.go"
  printf "// a comment naming csi-spl-orc/never-read.sh\nconst src = readFileSync(join(REPO, 'csi-spl-api/internal/msg/msg.go'), 'utf8')\n" >"$R/csi-spl-wui/tests/unit/u.test.mjs"
  # fixture data naming real directories (docs.test.mjs), and a templated read
  mkdir -p "$R/csi-spl-doc/specs/073-x" "$R/csi-spl-cnf/csi-spl/dev/tf"
  echo t >"$R/csi-spl-doc/specs/073-x/tasks.md"; echo '{}' >"$R/csi-spl-cnf/csi-spl/dev.env.json"; echo v >"$R/csi-spl-cnf/csi-spl/dev/tf/a.tfvars"
  printf "assert.deepEqual(dirs, ['csi-spl-doc', 'csi-spl-doc/specs'])\nconst env = JSON.parse(readFileSync(join(REPO, \`csi-spl-cnf/csi-spl/\${e}.env.json\`)))\n" >"$R/csi-spl-wui/tests/unit/v.test.mjs"
  # build modules (src/node): a dir read under a parameter, a message naming
  # it, and two dirs read under checkout constants (sync-roadmap/-help shapes)
  mkdir -p "$R/csi-spl-wui/src/node/roadmap" "$R/csi-spl-doc/doc/help" "$R/.github/workflows"
  echo h >"$R/csi-spl-doc/doc/help/how-to-post.md"; echo w >"$R/.github/workflows/10_ci.yml"
  printf "  if (!existsSync(action) || !existsSync(join(repo, 'csi-spl-doc/specs'))) {\n    console.log(\`(\${existsSync(action) ? 'no csi-spl-doc/specs' : 'no'})\`)\nexport const HELP_SRC = join(WUI, '../csi-spl-doc/doc/help')\n  const src = readFileSync(join(REPO, '.github/workflows', wf), 'utf8')\n" >"$R/csi-spl-wui/src/node/roadmap/m.mjs"
  git -C "$R" add -A; git -C "$R" commit -qm wui-seed
  git -C "$R" branch -f trunk HEAD
}
trunk_commit() {  # <repo> <path> <content> -- someone else's commit on trunk, then rebase the lane
  git -C "$1" checkout -q trunk; mkdir -p "$(dirname "$1/$2")"; echo "$3" >>"$1/$2"
  git -C "$1" add -A; git -C "$1" commit -qm "trunk: $2"; git -C "$1" checkout -q lane; git -C "$1" rebase -q trunk
}

# 9. a push that only EDITS an e2e / bench file -> the wui part never runs
R="$ROOT/r9"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo edit >>"$R/csi-spl-wui/tests/e2e/x.test.mjs"; echo edit >>"$R/csi-spl-wui/tests/bench/b.bench.mjs"
git -C "$R" commit -qam "e2e + bench edit only"
gate "$R"; eq "9. e2e/bench-edit-only push -> passes" 0 "$?"
eq "9. ... the wui part never ran" 0 "$(runs csi-spl-wui-unit)"
eq "9. ... wui logged SKIP-untouched" SKIP-untouched "$(verdict "$R" wui)"
trunk_commit "$R" csi-spl-wui/src/b.ts "someone else's wui src"
gate "$R"; eq "9. ... and after a rebase over another lane's wui src change it still never runs" 0 "$(runs csi-spl-wui-unit)"
echo dirty >>"$R/csi-spl-wui/tests/e2e/x.test.mjs"
gate "$R"; eq "9. ... nor with an uncommitted e2e edit on top" 0 "$(runs csi-spl-wui-unit)"
git -C "$R" checkout -q -- csi-spl-wui/tests/e2e/x.test.mjs
# ... but a NEW e2e file (unit reads the e2e file names) or a ci-skip.txt edit does select it
echo n >"$R/csi-spl-wui/tests/e2e/new.test.mjs"; git -C "$R" add -A; git -C "$R" commit -qm "new e2e test"
gate "$R"; eq "9. a push ADDING an e2e test runs the wui part" 1 "$(runs csi-spl-wui-unit)"
R="$ROOT/r9b"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo "x.test.mjs  flaky" >>"$R/csi-spl-wui/tests/e2e/ci-skip.txt"; git -C "$R" commit -qam "skip x"
gate "$R"; eq "9. a push editing ci-skip.txt runs the wui part" 1 "$(runs csi-spl-wui-unit)"
R="$ROOT/r9c"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
git -C "$R" rm -q csi-spl-wui/tests/e2e/x.test.mjs; git -C "$R" commit -qm "drop e2e test"
gate "$R"; eq "9. a push DELETING an e2e test runs the wui part" 1 "$(runs csi-spl-wui-unit)"

# 10. cache HIT: a green wui verdict survives a rebase over commits that change
#     nothing the part reads (non-wui files, e2e/bench edits)
R="$ROOT/r10"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo mine >>"$R/csi-spl-wui/src/a.ts"; git -C "$R" commit -qam "my wui change"
gate "$R"; eq "10. first wui push -> green" 0 "$?"
eq "10. ... the wui part ran once" 1 "$(runs csi-spl-wui-unit)"
trunk_commit "$R" csi-spl-orc/o.sh "someone else's orc"
trunk_commit "$R" csi-spl-api/a.go "someone else's api (not read by a unit test)"
gate "$R"; eq "10. rebase over non-wui commits -> green" 0 "$?"
eq "10. ... the wui part did NOT re-run" 1 "$(runs csi-spl-wui-unit)"
eq "10. ... logged PASS-cached" PASS-cached "$(verdict "$R" wui)"
trunk_commit "$R" csi-spl-wui/tests/e2e/x.test.mjs "someone else's e2e edit"
trunk_commit "$R" csi-spl-wui/tests/bench/b.bench.mjs "someone else's bench edit"
gate "$R"; eq "10. rebase over e2e/bench edits -> still a cache hit" 1 "$(runs csi-spl-wui-unit)"
eq "10. ... logged PASS-cached" PASS-cached "$(verdict "$R" wui)"

# 11. cache MISS: anything the part reads re-runs it
trunk_commit "$R" csi-spl-wui/src/b.ts "someone else's wui src"
gate "$R"; eq "11. rebase over a wui src change -> re-runs" 2 "$(runs csi-spl-wui-unit)"
trunk_commit "$R" csi-spl-wui/tests/e2e/y.test.mjs "someone else's NEW e2e test"
gate "$R"; eq "11. rebase over a new e2e file (its name is read) -> re-runs" 3 "$(runs csi-spl-wui-unit)"
trunk_commit "$R" csi-spl-wui/tests/e2e/ci-skip.txt "y.test.mjs reason"
gate "$R"; eq "11. rebase over a ci-skip.txt edit -> re-runs" 4 "$(runs csi-spl-wui-unit)"
trunk_commit "$R" csi-spl-api/internal/msg/msg.go "a field a unit test reads"
gate "$R"; eq "11. rebase over a hub file a unit test reads -> re-runs" 5 "$(runs csi-spl-wui-unit)"
echo dirty >>"$R/csi-spl-wui/src/a.ts"
gate "$R"; eq "11. a dirty wui src file -> re-runs (uncacheable)" 6 "$(runs csi-spl-wui-unit)"
# ... and that external read SELECTS the part on a push of its own
R="$ROOT/r11b"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo x >>"$R/csi-spl-api/internal/msg/msg.go"; git -C "$R" commit -qam "api msg.go"
gate "$R"; eq "11. an api push changing a file a wui unit test reads runs the wui part" 1 "$(runs csi-spl-wui-unit)"
R="$ROOT/r11c"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo x >"$R/csi-spl-orc/never-read.sh"; git -C "$R" add -A; git -C "$R" commit -qm "orc file only named in a comment"
gate "$R"; eq "11. a path only named in a unit-test COMMENT does not select it" 0 "$(runs csi-spl-wui-unit)"

# 12. c-231: api + a spec tasks.md edit; trunk gains a wui commit mid-push
R="$ROOT/r12"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo x >>"$R/csi-spl-api/a.go"; echo ticked >>"$R/csi-spl-doc/specs/073-x/tasks.md"
git -C "$R" add -A; git -C "$R" commit -qm "api + spec tasks.md"
gate "$R"; eq "12. api + spec tasks.md push -> passes" 0 "$?"
eq "12. ... the wui part never ran (a fixture dir is not a wui input)" 0 "$(runs csi-spl-wui-unit)"
git -C "$R" checkout -q trunk; echo z >>"$R/csi-spl-wui/src/a.ts"; git -C "$R" commit -qam "someone else's wui"; git -C "$R" checkout -q lane
gate "$R"; eq "12. ... trunk gained a wui commit (not yet rebased) -> still no wui run" 0 "$(runs csi-spl-wui-unit)"
git -C "$R" rebase -q trunk
gate "$R"; eq "12. ... after the rebase over it -> still no wui run (scope = this push's commits)" 0 "$(runs csi-spl-wui-unit)"
eq "12. ... wui logged SKIP-untouched" SKIP-untouched "$(verdict "$R" wui)"

# 13. c-226: a wui push, then rebases over files the part does not read
R="$ROOT/r13"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo mine >>"$R/csi-spl-wui/src/a.ts"; git -C "$R" commit -qam "my wui change"
gate "$R"; eq "13. first wui push -> green" 1 "$(runs csi-spl-wui-unit)"
trunk_commit "$R" csi-spl-doc/specs/073-x/tasks.md "someone else's tasks.md tick"
trunk_commit "$R" csi-spl-cnf/csi-spl/dev/tf/a.tfvars "someone else's tfvars"
gate "$R"; eq "13. rebase over a spec tasks.md + a cnf tfvars -> cache hit" 1 "$(runs csi-spl-wui-unit)"
eq "13. ... logged PASS-cached" PASS-cached "$(verdict "$R" wui)"
trunk_commit "$R" csi-spl-cnf/csi-spl/dev.env.json "a value the unit test reads"
gate "$R"; eq "13. rebase over the templated read (dev.env.json) -> re-runs" 2 "$(runs csi-spl-wui-unit)"
R="$ROOT/r13b"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo '{"a":1}' >"$R/csi-spl-cnf/csi-spl/prd.env.json"; git -C "$R" add -A; git -C "$R" commit -qm "a NEW env json"
gate "$R"; eq "13. a push adding a file the templated read matches selects the wui part" 1 "$(runs csi-spl-wui-unit)"

# 14. cnf-only -> the render part, never the iac suite; anything else -> iac
mkcnf() {  # <dir>
  mkrepo "$1"; mkdir -p "$1/csi-spl-cnf/csi-spl/dev/tf" "$1/csi-spl-cnf/src/python"
  echo 'a: 1' >"$1/csi-spl-cnf/csi-spl/dev.env.yaml"; echo 'a = 1' >"$1/csi-spl-cnf/csi-spl/dev/tf/s.vars.tfvars"
  echo 'x = 1' >"$1/csi-spl-cnf/src/python/v.py"
  git -C "$1" add -A; git -C "$1" commit -qm cnf-seed; git -C "$1" branch -f trunk HEAD
}
R="$ROOT/r14"; mkcnf "$R" >/dev/null 2>&1; : >"$COUNT"
echo 'a: 2' >"$R/csi-spl-cnf/csi-spl/dev.env.yaml"; echo 'a = 2' >"$R/csi-spl-cnf/csi-spl/dev/tf/s.vars.tfvars"
git -C "$R" commit -qam "cnf value + its render"
gate "$R"; eq "14. cnf-only push -> passes" 0 "$?"
eq "14. ... the cnf render part ran" 1 "$(runs cnf-render)"
eq "14. ... the iac suite never ran" 0 "$(runs csi-spl-iac)"
eq "14. ... iac logged SKIP-untouched" SKIP-untouched "$(verdict "$R" iac)"
eq "14. ... cnf logged PASS" PASS "$(verdict "$R" cnf)"
R="$ROOT/r14b"; mkcnf "$R" >/dev/null 2>&1; : >"$COUNT"
echo 'a: 2' >"$R/csi-spl-cnf/csi-spl/dev.env.yaml"; echo y >"$R/csi-spl-iac/a.sh"
git -C "$R" add -A; git -C "$R" commit -qm "cnf + a .sh"
gate "$R"; eq "14. CONTROL: cnf + .sh push -> the iac suite ran" 1 "$(runs csi-spl-iac)"
eq "14. ... and the cnf part did not" 0 "$(runs cnf-render)"
R="$ROOT/r14c"; mkcnf "$R" >/dev/null 2>&1; : >"$COUNT"
echo 'x = 2' >"$R/csi-spl-cnf/src/python/v.py"; git -C "$R" commit -qam "conf-validator code"
gate "$R"; eq "14. CONTROL: csi-spl-cnf/src code -> the iac suite ran" 1 "$(runs csi-spl-iac)"
eq "14. ... and the cnf part did not" 0 "$(runs cnf-render)"

# 15. the real cnf part: a fake do_tpl_gen renders tf/s.vars.tfvars and
#     <env>.env.json from <env>.env.yaml
R="$ROOT/r15"; mkcnf "$R" >/dev/null 2>&1
TG="$ROOT/tpl-gen"; mkdir -p "$TG/src/python/tpl-gen/.venv/bin"
printf '#!/bin/sh\n' >"$TG/src/python/tpl-gen/.venv/bin/python"; chmod +x "$TG/src/python/tpl-gen/.venv/bin/python"
for e in dev prd; do
  mkdir -p "$R/csi-spl-cnf/csi-spl/$e/tf"; echo 'a: 1' >"$R/csi-spl-cnf/csi-spl/$e.env.yaml"
  echo 'a = 1' >"$R/csi-spl-cnf/csi-spl/$e/tf/s.vars.tfvars"; echo '{"a": 1}' >"$R/csi-spl-cnf/csi-spl/$e.env.json"
done
git -C "$R" add -A; git -C "$R" commit -qm envs
real_cnf() {  # -> rc of the real _pp_part_cnf on $R (not the stub above); output in $R.out
  # shellcheck source=../run/check-pre-push.func.sh
  ( . "$FUNC"
    do_tpl_gen() {
      local d="$APP_PATH/csi-spl-cnf/csi-spl" v; v="$(sed -n 's/^a: //p' "$d/$ENV.env.yaml")"
      echo "a = $v" >"$d/$ENV/tf/s.vars.tfvars"; echo "{\"a\": $v}" >"$d/$ENV.env.json"; }
    _pp_part_cnf "$R" ) >"$R.out" 2>&1
}
TPL_GEN_PATH="$TG" real_cnf; eq "15. an up-to-date render -> PASS" 0 "$?"
eq "15. ... and leaves the tree clean" "" "$(git -C "$R" status --porcelain)"
echo 'a: 7' >"$R/csi-spl-cnf/csi-spl/prd.env.yaml"; git -C "$R" commit -qam "prd value, render forgotten"
TPL_GEN_PATH="$TG" real_cnf; eq "15. CONTROL: a stale prd render -> FAIL" 1 "$?"
grep -q '^FAIL: tpl-gen render prd -- ' "$R.out" && pass "15. ... naming prd" || fail "15. ... naming prd" "$(cat "$R.out")"
grep -q 'render dev' "$R.out" && fail "15. ... and not dev" "$(cat "$R.out")" || pass "15. ... and not dev"
grep -qx 'a = 7' "$R/csi-spl-cnf/csi-spl/prd/tf/s.vars.tfvars" && pass "15. ... the fresh render is left to commit" || fail "15. ... the fresh render is left to commit"
git -C "$R" commit -qam "prd render"
TPL_GEN_PATH="$ROOT/none" real_cnf; eq "15. CONTROL: no tpl-gen venv -> FAIL" 1 "$?"
eq "15. ... and the preflight names it" tpl-gen "$(_pp_missing_tools cnf "$R" | grep -o '^tpl-gen')"

# 16. c-786: a spec-only push; the dirs a build module reads for real still count
R="$ROOT/r16"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
ext=" $(_pp_wui_external "$R") "
[[ "$ext" != *" csi-spl-doc/specs "* ]] && pass "16. a dir read under a parameter is no wui input" || fail "16. a dir read under a parameter is no wui input" "$ext"
[[ "$ext" == *" csi-spl-doc/doc/help "* && "$ext" == *" .github/workflows "* ]] \
  && pass "16. CONTROL: dirs read under REPO / WUI are wui inputs" || fail "16. CONTROL: dirs read under REPO / WUI are wui inputs" "$ext"
echo ticked >>"$R/csi-spl-doc/specs/073-x/tasks.md"; git -C "$R" commit -qam "one spec file"
gate "$R"; eq "16. a spec-only push -> passes" 0 "$?"
eq "16. ... the wui part never ran" 0 "$(runs csi-spl-wui-unit)"
eq "16. ... wui logged SKIP-untouched" SKIP-untouched "$(verdict "$R" wui)"
R="$ROOT/r16b"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo x >>"$R/csi-spl-doc/doc/help/how-to-post.md"; git -C "$R" commit -qam "a help doc the wui reads"
gate "$R"; eq "16. CONTROL: a push changing a help doc (join(WUI, ...)) runs the wui part" 1 "$(runs csi-spl-wui-unit)"
R="$ROOT/r16c"; mkwui "$R" >/dev/null 2>&1; : >"$COUNT"
echo x >>"$R/.github/workflows/10_ci.yml"; git -C "$R" commit -qam "a workflow the wui reads"
gate "$R"; eq "16. CONTROL: a push changing a workflow (join(REPO, ...)) runs the wui part" 1 "$(runs csi-spl-wui-unit)"

echo "-- check-pre-push-scope.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
