#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 129 G2 (phase A0) -- the distribution-hygiene Sweep (workflow
#          10, and do_check_dist_hygiene, the pre-push hygiene part, which runs
#          the same step) refuses the private spec marker in any tracked file.
#   1. a planted marker (16 hex id) in a tracked file      -> rc 1, file:line
#   2. the same marker in a tracked file of spec 129's dir  -> rc 1 (a real id
#      is never allowed, not even there)
#   3. spec 129's own description lines (placeholder id, regex) in its dir
#      -> rc 0, counted as allowed
#   4. the same description line OUTSIDE spec 129's dir     -> rc 1
#   5. the marker in an UNTRACKED file                     -> rc 0
#   CONTROL: the workflow's Sweep with the marker sweep removed lets the
#   planted marker of case 1 pass -- the refusal is that sweep, nothing else.
#   The marker is assembled at run time, so this file carries none.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-dist-hygiene.func.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
[[ -f "$WF" ]] || { echo "FAIL: no workflow at $WF"; exit 1; }

marker="spool""-private:"
spec_dir="csi-spl-doc/specs/129-private-git-specs"

check() {  # <tree> <workflow> -> rc; output in $T/out
  env HYGIENE_TREE="$1" HYGIENE_WORKFLOW="$2" APP_PATH="$1" bash -c '
    do_log() { echo "$*"; }
    source "'"$FUNC"'"
    do_check_dist_hygiene' >"$T/out" 2>&1
}
mk_tree() {  # <dir> <rel path> <line> [untracked]
  mkdir -p "$1/$(dirname "$2")" && git -C "$1" init -q
  printf 'a generic first line\n%s\n' "$3" >"$1/$2"
  [[ "${4:-}" == untracked ]] || git -C "$1" add "$2"
}
expect() {  # <want rc> <tree> <what> [<file:line the output must name>]
  local rc
  check "$2" "${WF_USE:-$WF}"; rc=$?
  if [[ $rc -eq $1 ]] && { [[ -z "${4:-}" ]] || grep -qF "./$4" "$T/out"; }; then
    pass "$3 (rc $rc)"
  else
    fail "$3: want rc $1${4:+ naming $4}, got rc $rc"; sed 's/^/    | /' "$T/out"
  fi
}

hexid="$(printf '%016x' 1234567890123)"
mk_tree "$T/t1" docs/p001-x/spec.md "<!-- ${marker} ${hexid} -->"
expect 1 "$T/t1" "a planted private marker in a tracked file is refused" docs/p001-x/spec.md:2

mk_tree "$T/t2" "$spec_dir/copy.md" "<!-- ${marker} ${hexid} -->"
expect 1 "$T/t2" "a real marker id is refused even inside spec 129's dir" "$spec_dir/copy.md:2"

mk_tree "$T/t3" "$spec_dir/spec.md" "- every file carries \`<!-- ${marker} <id> -->\` on line 1, e.g. \`${marker} [0-9a-f]{16}\`"
expect 0 "$T/t3" "spec 129's own description line (placeholder id, regex) passes through the allow-line"
grep -q 'allowed - private spec marker' "$T/out" \
  && pass "the spec 129 line is counted as allowed, not missed" \
  || { fail "the spec 129 line was not counted as allowed"; sed 's/^/    | /' "$T/out"; }

mk_tree "$T/t4" csi-spl-doc/doc/md/notes.md "- every file carries \`<!-- ${marker} <id> -->\` on line 1"
expect 1 "$T/t4" "the same description line outside spec 129's dir is refused" csi-spl-doc/doc/md/notes.md:2

mk_tree "$T/t5" docs/p001-x/spec.md "<!-- ${marker} ${hexid} -->" untracked
printf 'clean\n' >"$T/t5/README.md"; git -C "$T/t5" add README.md
expect 0 "$T/t5" "an UNTRACKED file carrying the marker is not swept"

# CONTROL: the marker sweep removed from the workflow -> case 1 passes.
grep -q 'sweep "private spec marker' "$WF" || { fail "no marker sweep line in $WF"; }
sed '/sweep "private spec marker/,+1d' "$WF" >"$T/wf-no-marker.yml"
WF_USE="$T/wf-no-marker.yml" expect 0 "$T/t1" "CONTROL: without the marker sweep the planted marker passes"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all hygiene-private-marker.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in hygiene-private-marker.tst.sh"
fi
[[ $fails -eq 0 ]]
