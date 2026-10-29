#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 10 ci distribution-hygiene Sweep refuses a HIDDEN workspace
#          (SPL-1874) although no hidden name is in git: its patterns come from
#          the private overlay (CI: secret SPL_PRIVATE_CNF_YAML; a box: the
#          overlay file). Run through do_check_dist_hygiene, i.e. the
#          workflow's OWN Sweep step, over a throwaway checkout carrying the
#          overlay library and a SYNTHETIC overlay:
#   1. a clean tree -> rc 0, the sweep ran ("ok - hidden workspace")
#   2. CONTROL: a planted hidden slug (a throwaway file) -> rc 1, file:line
#      named, the slug itself never printed
#   3. a forms_only slug: the plain word passes, a workspace-list entry fails
#   4. the overlay as the CI secret (SPL_PRIVATE_CNF_YAML) works the same
#   5. no overlay: a warning on a pull request (rc 0), a FAIL on a master push
#      (SPL_PRIVATE_REQUIRED=1) - never a silent pass
#   6. a slug at the end of a non-ASCII word ("xí<slug>", "<slug>é") passes,
#      the bare slug beside it is red, both from a caller in LC_ALL=C (SPL-4249)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-dist-hygiene.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/spl-private-cnf.func.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$FUNC"

# the slugs are assembled at run time: this file carries none of them
a="zq""-hidden-a"; b="zq""-word"
cat >"$T/overlay.yaml" <<EOF
workspaces:
  ws-hidden-01: $a
  ws-hidden-02: $b
forms_only:
  - $b
EOF

# check [VAR=value ...] -> rc; output in $T/out
check() {
  env -u SPL_PRIVATE_CNF_YAML -u SPL_PRIVATE_REQUIRED "$@" HYGIENE_TREE="$T/tree" HYGIENE_WORKFLOW="$WF" APP_PATH="$T/tree" bash -c '
    do_log() { echo "$*"; }
    source "'"$FUNC"'"
    do_check_dist_hygiene' >"$T/out" 2>&1
}
plant() { printf '%s\n' "$2" >"$T/tree/$1"; git -C "$T/tree" add "$1"; }

mkdir -p "$T/tree/csi-spl-iac/lib/bash/funcs" "$T/tree/csi-spl-cnf/csi-spl"
git -C "$T/tree" init -q
cp "$LIB" "$T/tree/csi-spl-iac/lib/bash/funcs/"
printf 'env:\n  dns:\n    BASE_DOMAIN: example.test\n' >"$T/tree/csi-spl-cnf/csi-spl/all.env.yaml"
plant README.md 'a generic line'
git -C "$T/tree" add -A

# --- 1. clean -------------------------------------------------------------------
check SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^ok - hidden workspace' "$T/out" && pass "1. a clean tree passes and the hidden sweep RAN" ||
  { fail "1. clean rc=$rc"; sed 's/^/    | /' "$T/out"; }

# --- 2. CONTROL: a planted hidden slug ---------------------------------------------
plant planted.md "a note about $a and its bill"
check SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -ne 0 ]] && grep -q '::error::hygiene: hidden workspace' "$T/out" && grep -q '\./planted\.md:1' "$T/out" &&
  pass "2. CONTROL: a planted hidden slug turns the gate red, file:line named" || { fail "2. planted rc=$rc"; sed 's/^/    | /' "$T/out"; }
grep -qF "$a" "$T/out" && fail "2. the hidden slug reached the output" || pass "2. the slug itself is never printed"
git -C "$T/tree" rm -q --cached planted.md && rm "$T/tree/planted.md"

# --- 3. a forms_only slug ---------------------------------------------------------
plant word.md "run the $b binary from filepath.Join(root, \"$b\", \"pins\")"
check SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -eq 0 ]] && pass "3. a forms_only slug as the plain word passes" || { fail "3. word rc=$rc"; sed 's/^/    | /' "$T/out"; }
plant list.yaml "    workspaces: [t1, $b, e2e]"
check SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -ne 0 ]] && grep -q '\./list\.yaml:1' "$T/out" && pass "3. CONTROL: the same slug as a workspace-list entry is red" ||
  { fail "3. list rc=$rc"; sed 's/^/    | /' "$T/out"; }
plant host.txt "https://$b.example.test/x"
git -C "$T/tree" rm -q --cached list.yaml && rm "$T/tree/list.yaml"
check SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -ne 0 ]] && grep -q '\./host\.txt:1' "$T/out" && pass "3. CONTROL: the same slug as a tenant host is red" ||
  { fail "3. host rc=$rc"; sed 's/^/    | /' "$T/out"; }
git -C "$T/tree" rm -q --cached host.txt word.md && rm "$T/tree/host.txt" "$T/tree/word.md"

# --- 4. the overlay as the CI secret ---------------------------------------------------
plant planted.md "$a"
check SPL_PRIVATE_CNF="$T/none.yaml" SPL_PRIVATE_CNF_YAML="$(cat "$T/overlay.yaml")"; rc=$?
[[ $rc -ne 0 ]] && grep -q '\./planted\.md:1' "$T/out" && pass "4. the secret's overlay sweeps the same" ||
  { fail "4. secret rc=$rc"; sed 's/^/    | /' "$T/out"; }
git -C "$T/tree" rm -q --cached planted.md && rm "$T/tree/planted.md"

# --- 5. no overlay ---------------------------------------------------------------------
check SPL_PRIVATE_CNF="$T/none.yaml"; rc=$?
[[ $rc -eq 0 ]] && grep -q '::warning::hygiene: hidden workspaces NOT swept' "$T/out" &&
  pass "5. no overlay on a pull request: a warning, rc 0" || { fail "5. pr rc=$rc"; sed 's/^/    | /' "$T/out"; }
check SPL_PRIVATE_CNF="$T/none.yaml" SPL_PRIVATE_REQUIRED=1; rc=$?
[[ $rc -ne 0 ]] && grep -q '::error::hygiene: no private overlay' "$T/out" &&
  pass "5. CONTROL: no overlay on a master push FAILS, never a silent pass" || { fail "5. push rc=$rc"; sed 's/^/    | /' "$T/out"; }

# --- 6. Unicode word boundary, whatever the caller's locale (SPL-4249) ----------------
plant es.md "una lí$a y $b, ${a}é al final"
check LC_ALL=C SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^ok - hidden workspace' "$T/out" &&
  pass "6. a slug inside a non-ASCII word passes under LC_ALL=C" || { fail "6. accented rc=$rc"; sed 's/^/    | /' "$T/out"; }
plant es.md "una lí$a y el $a aquí"
check LC_ALL=C SPL_PRIVATE_CNF="$T/overlay.yaml"; rc=$?
[[ $rc -ne 0 ]] && grep -q '\./es\.md:1' "$T/out" &&
  pass "6. CONTROL: the bare slug on the same line is red under LC_ALL=C" || { fail "6. bare rc=$rc"; sed 's/^/    | /' "$T/out"; }
git -C "$T/tree" rm -q --cached es.md && rm "$T/tree/es.md"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all hygiene-hidden-workspaces.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in hygiene-hidden-workspaces.tst.sh"
fi
[[ $fails -eq 0 ]]
