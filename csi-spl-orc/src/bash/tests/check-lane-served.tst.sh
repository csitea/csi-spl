#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_lane_served -- one verdict line for "is this lane landed
#          and served" (SDLC round 1 row 09, SPL-2091). It composes
#          git-fetch-fresh.sh --landed, the %ae %ce identity rule and
#          do_check_deploy_lag; it adds the anchored trailer check and the
#          served=n/a arm for a commit that changed no build input.
#
#   Runs against a SYNTHETIC repo with a bare origin (CI checks this repo out
#   at depth 1, so no test leans on its history); its cnf and iac dirs are
#   symlinks to this checkout's, so do_check_deploy_lag resolves the real cnf.
#   The env probes are file:// fixtures: no network, no GCP, nothing mutated.
#     1. docs-only commit                    -> PASS dev=n/a prd=n/a, rc 0
#     2. hub commit served in dev and prd    -> PASS dev=served prd=served, rc 0
#     3. CONTROL incomplete deploy: prd old  -> FAIL dev=served prd=lag, rc 3
#     4. not on origin/master                -> FAIL landed=no, rc 1
#     5. another author address              -> FAIL identity=bad, rc 1
#     6. CONTROL a Co-Authored-By: line      -> FAIL trailers=found, rc 1
#     7. a body that only MENTIONS it        -> PASS (anchored, not a substring),
#        also a wrapped line starting "Claude-Session:)" (key, colon, SPACE)
#     8. an env that cannot be read          -> FAIL dev=unknown, rc 1
#     9. SHA = the checkout's HEAD           -> the --landed arm of the fetch
#    10. argument validation
#   LANE_SERVED_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${LANE_SERVED_FUNC:-$PROJ_ROOT/src/bash/run/check-lane-served.func.sh}"
EMAIL=lane@example.com

REPO="$T/repo"; ORIGIN="$T/origin.git"
git init -q --bare -b master "$ORIGIN"
git init -q -b master "$REPO"
git -C "$REPO" remote add origin "$ORIGIN"
ln -s "$APP_ROOT/csi-spl-cnf" "$REPO/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac" "$REPO/csi-spl-iac"
# do_check_deploy_lag reads the WUI inputs from workflow 30 itself (SPL-2272)
ln -s "$APP_ROOT/.github" "$REPO/.github"
# commit <rel-path> <age in minutes> <message> [author email]
commit() {
  local rel="$1" mins="$2" msg="$3" who="${4:-$EMAIL}" when
  when="$(date -u -d "-$mins minutes" +%Y-%m-%dT%H:%M:%S%z)"
  mkdir -p "$REPO/$(dirname "$rel")"; echo "$RANDOM" >>"$REPO/$rel"
  git -C "$REPO" add -- "$rel"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$REPO" -c user.name="FirstName LastName" -c user.email="$who" commit -qm "$msg"
  git -C "$REPO" rev-parse HEAD
}
C_BASE=$(commit csi-spl-api/src/go/a.go 600 "base")
C_DOC=$(commit  csi-spl-doc/x.md 500 "docs: only docs")
C_HUB=$(commit  csi-spl-api/src/go/b.go 400 "feat: a hub input")
C_BADID=$(commit csi-spl-doc/y.md 300 "docs: by someone else" other@example.com)
C_TRAIL=$(commit csi-spl-doc/z.md 200 "docs: with a trailer

Co-Authored-By: Someone <someone@example.com>")
C_MENTION=$(commit csi-spl-doc/w.md 100 "docs: says the word

This commit adds no Co-Authored-By: trailer, it only names one.")
C_WRAP=$(commit csi-spl-doc/t.md 90 "docs: a wrapped line starts with a key

It adds the anchored check (a body line STARTING with Co-Authored-By: or
Claude-Session:) and nothing else.")
git -C "$REPO" push -q origin master
C_LOCAL=$(commit csi-spl-doc/v.md 50 "docs: not pushed")
C_HEAD=$(commit csi-spl-doc/u.md 40 "docs: not pushed either, the checkout's HEAD")

fixture() { printf '{"commit":"%s"}' "$1" >"$T/fx-$1.json"; echo "file://$T/fx-$1.json"; }

# served <label> <want rc> <want verdict regex> <sha> <dev served> <prd served> [env...]
served() {
  local label="$1" want="$2" re="$3" sha="$4" dev="$5" prd="$6"; shift 6
  local out rc
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" \
        LANE_EMAIL="$EMAIL" SHA="$sha" FETCH_FRESH_MAX_AGE=0 \
        LAG_HUB_URL_DEV="$(fixture "$dev")" LAG_WUI_URL_DEV="$(fixture "$dev")" \
        LAG_HUB_URL_PRD="$(fixture "$prd")" LAG_WUI_URL_PRD="$(fixture "$prd")" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0"
    do_check_lane_served' "$FUNC" 2>"$T/err"); rc=$?
  if [[ $rc -eq $want ]] && grep -qE "$re" <<<"$out"; then pass "$label: $out"
  else fail "$label: rc=$rc want $want, out='$out' want /$re/, err='$(tail -4 "$T/err")'"; fi
}

served "docs-only commit, nothing to deploy" 0 '^PASS dev=n/a prd=n/a ' "$C_DOC" "$C_BASE" "$C_BASE"
served "hub commit served in dev and prd" 0 '^PASS dev=served prd=served ' "$C_HUB" "$C_HUB" "$C_HUB"
served "CONTROL incomplete deploy: prd still serves the old commit" 3 \
  '^FAIL dev=served prd=lag landed=yes identity=ok trailers=none ' "$C_HUB" "$C_HUB" "$C_BASE"
served "a fresh hub commit inside the grace is lag, not served" 3 'prd=lag' "$C_HUB" "$C_HUB" "$C_BASE" GRACE_MINUTES=99999
served "a commit not on origin/master (not HEAD: fetch, then is-ancestor)" 1 '^FAIL dev=n/a prd=n/a landed=no ' "$C_LOCAL" "$C_BASE" "$C_BASE"
if grep -q 'NOT-LANDED' "$T/err"; then fail "a SHA other than HEAD took the HEAD-only --landed arm"
else pass "a SHA other than HEAD is checked with merge-base, not the HEAD-only --landed"; fi
served "a commit by another address" 1 ' identity=bad ' "$C_BADID" "$C_BASE" "$C_BASE"
served "CONTROL a Co-Authored-By: trailer line" 1 ' trailers=found ' "$C_TRAIL" "$C_BASE" "$C_BASE"
served "a body that only mentions the trailer" 0 '^PASS dev=n/a prd=n/a ' "$C_MENTION" "$C_BASE" "$C_BASE"
served "a wrapped prose line that starts with 'Claude-Session:)'" 0 '^PASS dev=n/a prd=n/a ' "$C_WRAP" "$C_BASE" "$C_BASE"
served "the whole range BASE..SHA is read" 1 ' identity=bad trailers=found ' "$C_MENTION" "$C_BASE" "$C_BASE" BASE="$C_HUB"
served "an env that cannot be read" 1 '^FAIL dev=unknown prd=served ' "$C_HUB" 0000000000000000000000000000000000000000 "$C_HUB"
served "SHA = HEAD takes the --landed arm" 1 "landed=no .*sha=${C_HEAD:0:8}" HEAD "$C_BASE" "$C_BASE"
if grep -q 'NOT-LANDED: HEAD is not on origin/master' "$T/err"; then pass "the --landed arm printed its own verdict"
else fail "no git-fetch-fresh --landed line in: $(cat "$T/err")"; fi

served "a SHA that is not a commit is refused" 1 '^$' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$C_BASE" "$C_BASE"
if grep -q 'is not a commit in' "$T/err"; then pass "it says why"; else fail "no reason in: $(cat "$T/err")"; fi
served "a BASE that is not behind SHA is refused" 1 '^$' "$C_DOC" "$C_BASE" "$C_BASE" BASE="$C_HUB"
if grep -q 'not a proper ancestor' "$T/err"; then pass "it says why"; else fail "no reason in: $(cat "$T/err")"; fi

if [[ $fails -ne 0 ]]; then echo "FAILED: $fails"; exit 1; fi
echo "PASS: all check-lane-served assertions"
