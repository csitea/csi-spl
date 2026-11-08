#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_landed_repo_put writes one GitHub-only row to the box-side
# SPOOL_LANDED_REPOS_FILE (SPL-5083), the file spl_landed_repo_rows already
# reads: a lane that lands in a repo the tree must not name can then end its
# issue. Proves: a dry run writes nothing; the row lands owned by the spool
# root's owner, mode 0644, and resolves to gh:<owner>/<repo>; a re-run is a
# no-op; a name a cnf or map row has is refused; a file the resolver would not
# trust, or cannot parse, is refused untouched; a caller that is not the owner
# writes through sudo as the owner.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

S="$T/spool"; mkdir -p "$S" "$T/lr"
F="$S/landed-repos.yaml"
CNF="$T/lr/cnf.yaml"
WM="$T/lr/ws-map.tsv"
ME="$(id -un)"
printf 'env:\n  box:\n    landed_repos:\n      - {name: cnf-hub, github: example-org/cnf-hub, trunk: master}\n' >"$CNF"
printf 'ws-a\tprd\tmap-site\t%s\tmaster\thttps://alpha.example.com\tc-901\tbox-a\n' "$T/lr" >"$WM"
ROW=(LANDED_REPO_NAME=far-hub LANDED_REPO_GITHUB=example-org/far-hub LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a)

put() {  # VAR=value...: the action in a sandbox, output in $T/o, code in $rc
  SNIPPET='do_spl_landed_repo_put' in_orc SPOOL_ROOT="$S" SPOOL_LANDED_REPOS_FILE="$F" LANE_LANDED_CNF="$CNF" \
    SPOOL_WORKSPACE_REPOS_MAP="$WM" "$@" >"$T/o" 2>&1
  rc=$?
}
resolve() { SNIPPET="spl_landed_repo $1" in_orc SPOOL_ROOT="$S" SPOOL_LANDED_REPOS_FILE="$F" LANE_LANDED_CNF="$CNF" SPOOL_WORKSPACE_REPOS_MAP="$WM" 2>&1; }
sum_f() { if [[ -e "$F" ]]; then sha256sum "$F" | cut -d' ' -f1; else echo absent; fi; }
refused() {  # LABEL WANT: non-zero, the line says WANT, the file did not change
  [[ $rc -ne 0 ]] && grep -q -- "$2" "$T/o" && [[ "$(sum_f)" == "$before" ]] &&
    pass "$1" || fail "$1 (rc=$rc): $(cat "$T/o")"
}
no_temp() { ! compgen -G "$F.*" >/dev/null; }

put "${ROW[@]}"
[[ $rc -eq 0 && ! -e "$F" ]] && grep -q 'DRY_RUN would add' "$T/o" &&
  pass "a dry run (the default) writes nothing" || fail "dry run (rc=$rc): $(cat "$T/o")"

before="$(sum_f)"
put LANDED_REPO_GITHUB=example-org/far-hub LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "no LANDED_REPO_NAME: refused, no default" "LANDED_REPO_NAME must be"
put LANDED_REPO_NAME=far-hub LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "no LANDED_REPO_GITHUB: refused, no default" "LANDED_REPO_GITHUB must be"
put LANDED_REPO_NAME=far-hub LANDED_REPO_GITHUB=example-org/far-hub LANDED_REPO_BOX=box-a DRY_RUN=0
refused "no LANDED_REPO_TRUNK: refused, no default" "LANDED_REPO_TRUNK must be"
put LANDED_REPO_NAME=far-hub LANDED_REPO_GITHUB=example-org/far-hub LANDED_REPO_TRUNK=master DRY_RUN=0
refused "no LANDED_REPO_BOX: refused, no default" "LANDED_REPO_BOX must be"
put LANDED_REPO_NAME=../far-hub LANDED_REPO_GITHUB=example-org/far-hub LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "a path as the name is refused" "LANDED_REPO_NAME must be"
put LANDED_REPO_NAME=far-hub LANDED_REPO_GITHUB=https://example.com/x/y LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "a URL as github is refused" "LANDED_REPO_GITHUB must be"
SNIPPET='do_spl_landed_repo_put' in_orc SPOOL_ROOT="$S" LANE_LANDED_CNF="$CNF" "${ROW[@]}" DRY_RUN=0 >"$T/o" 2>&1; rc=$?
refused "a sandbox with no SPOOL_LANDED_REPOS_FILE is refused, never the default path" "SPOOL_LANDED_REPOS_FILE must be set"

put "${ROW[@]}" DRY_RUN=0
[[ $rc -eq 0 && -f "$F" ]] && pass "DRY_RUN=0 writes the file" || fail "write (rc=$rc): $(cat "$T/o")"
[[ "$(stat -c '%U %a' "$F" 2>/dev/null)" == "$(stat -c %U "$S") 644" ]] &&
  pass "the file is owned by the spool root's owner, mode 0644" || fail "owner/mode: $(stat -c '%U %a' "$F" 2>&1)"
[[ "$(yq -r '.env.box.landed_repos[0] | [.name, .github, .trunk, .box] | @tsv' "$F" 2>&1)" == $'far-hub\texample-org/far-hub\tmaster\tbox-a' ]] &&
  pass "the row has the cnf shape: name, github, trunk, box" || fail "row: $(cat "$F" 2>&1)"
no_temp && pass "no temp file is left behind" || fail "temp left: $(ls -a "$S")"
[[ "$(resolve far-hub)" == $'gh:example-org/far-hub\tmaster' ]] &&
  pass "spl_landed_repo resolves the row to gh:<owner>/<repo>" || fail "resolve: $(resolve far-hub)"

o="$(resolve typo-name)"
[[ "$o" != *far-hub* && "$o" == *"(src_dir names: cnf-hub and 2 workspace repo(s))"* ]] &&
  pass "a mistyped name's refusal counts a box-side row and does not name it" || fail "refusal list: $o"

before="$(sum_f)"; ino="$(stat -c %i "$F" 2>/dev/null)"
put "${ROW[@]}" DRY_RUN=0
[[ $rc -eq 0 && "$(sum_f)" == "$before" && "$(stat -c %i "$F" 2>/dev/null)" == "$ino" ]] && grep -q 'already has this row' "$T/o" &&
  pass "a re-run is a no-op: same bytes, same inode" || fail "re-run (rc=$rc): $(cat "$T/o")"

put LANDED_REPO_NAME=cnf-hub LANDED_REPO_GITHUB=example-org/fork LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "RED CONTROL a name a cnf row has is refused" "already has that name"
put LANDED_REPO_NAME=map-site LANDED_REPO_GITHUB=example-org/fork LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "RED CONTROL a name a workspace map row has is refused" "already has that name"
! grep -q 'map-site' "$T/o" && pass "the refusal does not repeat the repo's name" || fail "name in refusal: $(cat "$T/o")"
put LANDED_REPO_NAME=far-hub LANDED_REPO_GITHUB=example-org/fork LANDED_REPO_TRUNK=master LANDED_REPO_BOX=box-a DRY_RUN=0
refused "RED CONTROL the file's name at another repo is refused, not overwritten" "with other values"

put LANDED_REPO_NAME=near-hub LANDED_REPO_GITHUB=example-org/near-hub LANDED_REPO_TRUNK=main LANDED_REPO_BOX=box-b DRY_RUN=0
[[ $rc -eq 0 && "$(resolve near-hub)" == $'gh:example-org/near-hub\tmain' && "$(resolve far-hub)" == $'gh:example-org/far-hub\tmaster' ]] &&
  pass "a second row is added and the first is kept" || fail "second row (rc=$rc): $(cat "$T/o") / $(cat "$F" 2>&1)"

touch "$F"; chmod 664 "$F"; before="$(sum_f)"
put LANDED_REPO_NAME=new-hub LANDED_REPO_GITHUB=example-org/new-hub LANDED_REPO_TRUNK=main LANDED_REPO_BOX=box-a DRY_RUN=0
refused "RED CONTROL a group-writable file is refused, its rows are not copied" "not trusted"
chmod 644 "$F"

cp "$F" "$T/lr/good.yaml"
printf 'env: [unclosed\n' >"$F"; before="$(sum_f)"
put LANDED_REPO_NAME=new-hub LANDED_REPO_GITHUB=example-org/new-hub LANDED_REPO_TRUNK=main LANDED_REPO_BOX=box-a DRY_RUN=0
refused "RED CONTROL a file yq cannot parse is refused, never replaced" "cannot parse"
no_temp && pass "a refused write leaves no temp file" || fail "temp after refusal: $(ls -a "$S")"
cp "$T/lr/good.yaml" "$F"

# A caller that is not the spool root's owner: every write step goes through
# sudo as the owner. The id stub makes the caller someone else, the sudo stub
# logs and runs the command, so the file still lands.
mkdir -p "$T/stub"
printf '#!/bin/sh\n[ "$1" = -un ] && { echo other-user; exit 0; }\nexec /usr/bin/id "$@"\n' >"$T/stub/id"
printf '#!/bin/sh\necho "sudo $*" >>"$STUB_LOG"\nshift 3\nexec "$@"\n' >"$T/stub/sudo"
chmod +x "$T/stub/id" "$T/stub/sudo"; : >"$T/calls.log"
put LANDED_REPO_NAME=hop-hub LANDED_REPO_GITHUB=example-org/hop-hub LANDED_REPO_TRUNK=main LANDED_REPO_BOX=box-a DRY_RUN=0
for step in mktemp tee chmod mv; do
  grep -q "^sudo -n -u $ME $step" "$T/calls.log" && pass "not the owner: $step runs through sudo as the owner" ||
    fail "sudo $step (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"
done
rm -f "$T/stub/id" "$T/stub/sudo"
[[ "$(resolve hop-hub)" == $'gh:example-org/hop-hub\tmain' ]] && pass "not the owner: the row lands" || fail "hop row: $(cat "$F" 2>&1)"

echo "spl-landed-repo-put: $fails failure(s)"
exit "$fails"
