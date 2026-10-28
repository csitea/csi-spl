#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_live_proof_render (spec 157 Rule 4, row B2, SPL-4068)
#          builds the **Live** proof table of an owner post from git, the
#          served builds and CI, and what it prints passes the desk post guard
#          spl_desk_live_proof (how-to-post.md rules 14 and 16).
#
#   Runs against a SYNTHETIC repo with a bare origin; its cnf, iac and
#   .github are symlinks to this checkout's, so do_check_deploy_lag resolves
#   the real cnf and build inputs. The env probes are file:// fixtures and gh
#   is a stub: no network, no GCP, nothing mutated.
#     1. RED CONTROL LIVE_CHECKED omitted          -> rc 1, REFUSED, no table
#     2. RED CONTROL LIVE_NOT_CHECKED omitted      -> rc 1, REFUSED, no table
#        (and blank: whitespace is not a case)
#     3. RED CONTROL a sha not on origin/master    -> rc 2, REFUSED: not on master
#     4. a sha that is no commit                   -> rc 1
#     5. CONTROL prd serves the commit before it   -> rc 3, **Landed, not live
#        yet**, prd lag; the guard lets it through (not a **Live** opening)
#     6. GREEN: a hub commit, dev and prd serve a LATER commit (ancestry, not
#        string equality) -> rc 0, **Live**, hub served served green, the
#        checked lines; the guard passes it (rc 0)
#     7. a doc-only commit -> **Live**, `no deploy` cells; the guard passes it
#     8. CI: a failed run reads red, a run in progress running, gh failing
#        unknown
#   RENDER_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${RENDER_FUNC:-$PROJ_ROOT/src/bash/run/spl-desk-live-proof-render.func.sh}"

REPO="$T/repo"; ORIGIN="$T/origin.git"
git init -q --bare -b master "$ORIGIN"
git init -q -b master "$REPO"
git -C "$REPO" remote add origin "$ORIGIN"
ln -s "$APP_ROOT/csi-spl-cnf" "$REPO/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac" "$REPO/csi-spl-iac"
ln -s "$APP_ROOT/.github" "$REPO/.github"
# commit <rel-path> <age in minutes> <message>
commit() {
  local rel="$1" mins="$2" msg="$3" when
  when="$(date -u -d "-$mins minutes" +%Y-%m-%dT%H:%M:%S%z)"
  mkdir -p "$REPO/$(dirname "$rel")"; echo "$RANDOM" >>"$REPO/$rel"
  git -C "$REPO" add -- "$rel"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$REPO" -c user.name="FirstName LastName" -c user.email=lane@example.com commit -qm "$msg"
  git -C "$REPO" rev-parse HEAD
}
C_BASE=$(commit csi-spl-api/src/go/a.go 600 "base")
C_HUB=$(commit  csi-spl-api/src/go/b.go 400 "feat: a hub input")
C_DOC=$(commit  csi-spl-doc/x.md 300 "docs: only docs")
C_LATER=$(commit csi-spl-api/src/go/c.go 200 "feat: a later hub input")
git -C "$REPO" push -q origin master
C_LOCAL=$(commit csi-spl-doc/v.md 50 "docs: not pushed")

# gh stub: `gh run list` prints $GH_RUNS (status conclusion lines); any other
# call (do_check_deploy_lag's landing-time `gh api`) fails, so ages read %ct.
mkdir -p "$T/stub"
# shellcheck disable=SC2016 # the stub expands its own args at run time
printf '#!/bin/sh\n[ "$1 $2" = "run list" ] || exit 1\n[ "$GH_FAIL" = 1 ] && exit 1\nprintf "%%b" "$GH_RUNS"\n' >"$T/stub/gh"
chmod +x "$T/stub/gh"

fixture() { printf '{"commit":"%s"}' "$1" >"$T/fx-$1.json"; echo "file://$T/fx-$1.json"; }

# render <sha> <dev served> <prd served> [VAR=value]... -> rc; stdout in $T/out, stderr in $T/err
render() {
  local sha="$1" dev="$2" prd="$3"; shift 3
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" PATH="$T/stub:$PATH" \
    SHA="$sha" LIVE_CHECKED="hub /version on dev and prd" LIVE_NOT_CHECKED=none FETCH_FRESH_MAX_AGE=0 \
    GH_RUNS='completed success\ncompleted skipped\n' GH_FAIL=0 \
    LAG_HUB_URL_DEV="$(fixture "$dev")" LAG_WUI_URL_DEV="$(fixture "$dev")" \
    LAG_HUB_URL_PRD="$(fixture "$prd")" LAG_WUI_URL_PRD="$(fixture "$prd")" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || { echo "FATAL cannot source $0" >&2; exit 97; }
    do_spl_desk_live_proof_render' "$FUNC" >"$T/out" 2>"$T/err"
}
# guard <dev served> <prd served>: the desk post guard, unstubbed, on the rendered post -> rc
guard() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" LANE_WT="$REPO" SPL_STATE_DIR="$T/state" PATH="$T/stub:$PATH" \
    FETCH_FRESH_MAX_AGE=0 GH_FAIL=1 BODY="$(cat "$T/out")" \
    LAG_HUB_URL_DEV="$(fixture "$1")" LAG_WUI_URL_DEV="$(fixture "$1")" \
    LAG_HUB_URL_PRD="$(fixture "$2")" LAG_WUI_URL_PRD="$(fixture "$2")" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_desk_live_proof "$BODY"' 2>"$T/guard"
}
# refused <label> <want rc> <must-name>: rc, the REFUSED line and no table
refused() {
  local label="$1" want="$2" name="$3"
  if (( rc == want )) && grep -q "REFUSED.*$name" "$T/err" && [[ ! -s "$T/out" ]]; then pass "$label"
  else fail "$label: rc=$rc want $want, out='$(cat "$T/out")', err='$(tail -3 "$T/err")'"; fi
}
has() { # <label> <regex>: the rendered post matches
  if grep -qE -- "$2" "$T/out"; then pass "$1"; else fail "$1: /$2/ not in '$(cat "$T/out")'"; fi
}

# --- 1..4 the refusals, red controls first ------------------------------------------
render "$C_HUB" "$C_LATER" "$C_LATER" LIVE_CHECKED=; rc=$?
refused "1. RED CONTROL: LIVE_CHECKED omitted is refused, no table" 1 'missing: LIVE_CHECKED$'
if grep -q 'how-to-post.md rule 16' "$T/err"; then pass "1. the refusal names how-to-post.md rule 16"
else fail "1. no rule named in: $(cat "$T/err")"; fi
render "$C_HUB" "$C_LATER" "$C_LATER" LIVE_NOT_CHECKED=; rc=$?
refused "2. RED CONTROL: LIVE_NOT_CHECKED omitted is refused (never defaulted to none)" 1 'missing: LIVE_NOT_CHECKED$'
render "$C_HUB" "$C_LATER" "$C_LATER" LIVE_NOT_CHECKED='  '; rc=$?
refused "2. a blank LIVE_NOT_CHECKED is refused too" 1 'missing: LIVE_NOT_CHECKED$'
render "$C_LOCAL" "$C_LATER" "$C_LATER"; rc=$?
refused "3. RED CONTROL: a sha not on origin/master is refused" 2 'not on master'
render deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$C_LATER" "$C_LATER"; rc=$?
refused "4. a sha that is no commit is refused" 1 'is not a commit'

# --- 5. lagging deploy -------------------------------------------------------------
render "$C_HUB" "$C_LATER" "$C_BASE"; rc=$?
if (( rc == 3 )); then pass "5. CONTROL prd serving the commit before it: rc 3"; else fail "5. rc=$rc want 3: $(cat "$T/out") $(tail -3 "$T/err")"; fi
has "5. header is **Landed, not live yet** naming prd" '^\*\*Landed, not live yet\*\*: .*not served: prd hub lag\.$'
has "5. the hub row shows dev served, prd lag" "^\| hub \| ${C_HUB:0:9} \(\`[^\`]+\`\) \| served \| lag \| green \|$"
guard "$C_LATER" "$C_BASE"; rc=$?
if (( rc == 0 )); then pass "5. the post guard lets a Landed post through"; else fail "5. guard rc=$rc: $(cat "$T/guard")"; fi

# --- 6. green: served = ancestry ----------------------------------------------------
render "$C_HUB" "$C_LATER" "$C_LATER"; rc=$?
if (( rc == 0 )); then pass "6. GREEN: dev and prd serve a later commit: rc 0"; else fail "6. rc=$rc: $(cat "$T/out") $(tail -3 "$T/err")"; fi
has "6. header is **Live**" "^\*\*Live\*\*: ${C_HUB:0:9} on origin/master"
has "6. the table head" '^\| target \| commit / version \| dev \| prd \| CI \|$'
has "6. the hub row: served served green" "^\| hub \| ${C_HUB:0:9} \(\`no tag\`\) \| served \| served \| green \|$"
has "6. checked: carries LIVE_CHECKED" '^checked: hub /version on dev and prd$'
has "6. not checked: carries LIVE_NOT_CHECKED" '^not checked: none$'
guard "$C_LATER" "$C_LATER"; rc=$?
if (( rc == 0 )); then pass "6. the post guard passes the rendered **Live** post"; else fail "6. guard rc=$rc: $(cat "$T/guard")"; fi
git -C "$REPO" tag v1.2.3 "$C_LATER"
render "$C_HUB" "$C_LATER" "$C_LATER"; rc=$?
has "6. the version is the first release tag that contains it" "^\| hub \| ${C_HUB:0:9} \(\`v1\.2\.3\`\) \|"

# --- 7. doc only --------------------------------------------------------------------
render "$C_DOC" "$C_BASE" "$C_BASE"; rc=$?
if (( rc == 0 )); then pass "7. a doc-only commit served nowhere is still **Live**: rc 0"; else fail "7. rc=$rc: $(cat "$T/out")"; fi
has "7. its row says no deploy" "^\| doc \| ${C_DOC:0:9} \| no deploy \| no deploy \| green \|$"
guard "$C_BASE" "$C_BASE"; rc=$?
if (( rc == 0 )); then pass "7. the post guard passes it"; else fail "7. guard rc=$rc: $(cat "$T/guard")"; fi

# --- 8. CI column -------------------------------------------------------------------
render "$C_DOC" "$C_BASE" "$C_BASE" GH_RUNS='completed success\ncompleted failure\n'
has "8. a failed run reads red" '\| red \|$'
render "$C_DOC" "$C_BASE" "$C_BASE" GH_RUNS='completed success\nin_progress \n'
has "8. a run in progress reads running" '\| running \|$'
render "$C_DOC" "$C_BASE" "$C_BASE" GH_FAIL=1
has "8. gh failing reads unknown" '\| unknown \|$'
render "$C_DOC" "$C_BASE" "$C_BASE" GH_RUNS=''
has "8. no run reads no runs" '\| no runs \|$'

if [[ $fails -ne 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "PASS: all spl-desk-live-proof-render assertions"
