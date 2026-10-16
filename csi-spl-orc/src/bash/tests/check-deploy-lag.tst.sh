#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_deploy_lag -- the COMMIT-level guard that a lane cannot
#          close "done" while an env still serves an older commit. It asks the
#          question do_check_hub_deploy cannot: that one compares the live image
#          with the image CNF NAMES, so it is green whenever a lane lands hub
#          source without bumping env.hub.image.tag.
#
#   Branch coverage runs against a SYNTHETIC git repo (this repo is checked out
#   at depth 1 in CI, so no test may lean on its history), with the probe URL
#   overridden to a file:// fixture -- no network, no GCP, nothing mutated:
#     1. served == sha                                  -> current, rc 0
#     2. served is a descendant of sha (env ahead)      -> current, rc 0
#     3. served behind, but nothing the component is
#        built FROM changed since                       -> current n=0, rc 0
#     4. CONTROL, the artificial lag: a real input
#        commit, older than the grace                   -> lagging, rc 3
#     5. the same lag INSIDE the grace period           -> pending, rc 0
#     6. the age is the OLDEST unserved input commit's, not the newest
#     7. no endpoint / junk body / commit not in this
#        checkout / served not an ancestor              -> unknown, rc 1
#     8. SPL-2272: the WUI inputs are workflow 30's own `on.push.paths`, read
#        from the workflow: a blog-post-only commit (d587d79f8's shape) is a
#        WUI input (pending n=1), an orc-only commit is not (current n=0, the
#        "no deploy" of spl_desk_live_proof); `*` keeps GitHub's one level
#   Then, shallow-safe, the real action end to end (cnf resolution, both
#   components, exit code) and its argument validation.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# --- a synthetic repo shaped like this one ------------------------------------
# csi-spl-api/src/go = a hub input; csi-spl-doc = an input of nothing.
REPO="$T/repo"
mkdir -p "$REPO/csi-spl-api/src/go" "$REPO/csi-spl-doc"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
# commit <rel-path> <message> <age in minutes>
commit() {
  local rel="$1" msg="$2" mins="$3" when
  when="$(date -u -d "-$mins minutes" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)" || when=""
  mkdir -p "$REPO/$(dirname "$rel")"; echo "$msg" >>"$REPO/$rel"
  git -C "$REPO" add -- "$rel"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$REPO" commit -qm "$msg"
  git -C "$REPO" rev-parse HEAD
}
C_BASE=$(commit csi-spl-api/src/go/a.go       "base hub source"       600)
C_DOC=$(commit  csi-spl-doc/x.md              "docs only"             500)
C_OLD=$(commit  csi-spl-api/src/go/b.go       "OLD unserved hub input" 400)
C_NEW=$(commit  csi-spl-api/src/go/c.go       "NEW unserved hub input"  10)
C_FRESH=$(git -C "$REPO" rev-parse HEAD)
# a commit on a side branch: NOT an ancestor of master's head, and master's
# head is not an ancestor of it -- the "an env is serving something that is not
# on this line of history" shape
git -C "$REPO" checkout -q -b side "$C_BASE"
C_SIDE=$(commit csi-spl-api/src/go/s.go       "side branch hub input" 300)
git -C "$REPO" checkout -q master

fixture() { printf '{"commit":"%s","built_at":"2026-09-20T00:00:00Z"}' "$1" >"$T/$2.json"; echo "file://$T/$2.json"; }

# one _spl_lag_one call: <label> <url> <sha> <grace> <want rc> <want word>
lag_one() {
  local label="$1" url="$2" sha="$3" grace="$4" want="$5" word="$6"
  local out rc
  out=$(env APP_PATH="$REPO" ENV=dev bash -c '
    do_log() { echo "$*" >&2; }
    source "$0"
    _spl_lag_one hub "$1" "$2" "$3" 15 csi-spl-api/src/go .version
  ' "$PROJ_ROOT/src/bash/run/check-deploy-lag.func.sh" "$url" "$sha" "$grace" 2>"$T/err"); rc=$?
  if [[ $rc -eq $want && "$out" == "dev hub $word "* ]]; then pass "$label ($word, rc $rc)"
  else fail "$label: rc=$rc want $want, out='$out' err='$(tail -1 "$T/err")'"; fi
  printf '%s' "$out" >"$T/last"
}

lag_one "served == the commit under test" "$(fixture "$C_FRESH" same)" "$C_FRESH" 45 0 current
lag_one "the env is AHEAD of the commit under test" "$(fixture "$C_FRESH" ahead)" "$C_OLD" 45 0 current
lag_one "behind, but only docs changed since" "$(fixture "$C_DOC" docs)" "$C_DOC" 45 0 current
lag_one "CONTROL: a real hub input, older than the grace -> RED" "$(fixture "$C_BASE" lag)" "$C_FRESH" 45 3 lagging
lag_one "the same lag inside a wide grace period" "$(fixture "$C_BASE" lag)" "$C_FRESH" 1000 0 pending

# 3. "behind, nothing of MINE changed": served C_BASE, sha C_DOC -> n=0
lag_one "behind by a docs-only commit -> n=0, not lag" "$(fixture "$C_BASE" b2)" "$C_DOC" 45 0 current
grep -q 'n=0' "$T/last" && pass "it says n=0" || fail "no n=0 in: $(cat "$T/last")"

# 6. the age is the OLDEST unserved input commit's (C_OLD, ~400m), not C_NEW's (~10m)
lag_one "age is the oldest unserved input commit's" "$(fixture "$C_DOC" oldest)" "$C_FRESH" 45 3 lagging
if grep -q "oldest=${C_OLD:0:8}" "$T/last" && grep -qE 'age=(3[0-9][0-9]|4[0-9][0-9])m' "$T/last"; then
  pass "it names oldest=${C_OLD:0:8} and an age of hours, not minutes"
else fail "wrong oldest/age: $(cat "$T/last")"; fi
grep -q 'n=2' "$T/last" && pass "n counts both unserved input commits" || fail "no n=2 in: $(cat "$T/last")"

# 7. the four "cannot tell" shapes
lag_one "no endpoint there" "file://$T/does-not-exist.json" "$C_FRESH" 45 1 unknown
printf 'not json at all' >"$T/junk.json"
lag_one "a body with no .commit" "file://$T/junk.json" "$C_FRESH" 45 1 unknown
lag_one "a commit this checkout does not have (shallow clone)" \
  "$(fixture 0000000000000000000000000000000000000000 absent)" "$C_FRESH" 45 1 unknown
grep -q 'fetch-depth 0' "$T/last" && pass "it names the shallow-clone cause" || fail "no shallow hint: $(cat "$T/last")"
lag_one "served is NOT on this line of history" "$(fixture "$C_SIDE" fwd)" "$C_FRESH" 45 1 unknown
grep -q 'not an ancestor' "$T/last" && pass "it says why" || fail "no reason in: $(cat "$T/last")"

# 8. SPL-2272: WUI inputs come from workflow 30 itself, not a hand-kept copy.
#    A synthetic repo carrying THIS checkout's workflow 30; the probe asks
#    _spl_served_needs_deploy's question: "if the parent were served, would
#    this commit be behind?" (lagging = needs a deploy, n=0 = no deploy).
WF30="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
REPO="$T/repo-wui"
mkdir -p "$REPO/.github/workflows"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
cp "$WF30" "$REPO/.github/workflows/"
git -C "$REPO" add .github && git -C "$REPO" commit -qm "wf 30" --date="-700 minutes"
W_BASE=$(commit csi-spl-orc/README.md                                "base"             600)
W_BLOG=$(commit csi-spl-doc/blog/posts/en/2026-10-16-amazing-world.md "a blog post only" 500)
W_ORC=$(commit  csi-spl-orc/src/bash/run/some-desk.func.sh           "orc only"         400)
W_CNF=$(commit  csi-spl-cnf/csi-spl/deep/x.env.json                  "cnf, two levels"  300)
W_SCR=$(commit  csi-spl-orc/src/bash/scripts/wui-deploy-guard.sh     "a wf 30 script"   200)
wui_one() { # <label> <served> <sha> <want rc> <want word>
  local out rc
  out=$(env APP_PATH="$REPO" ENV=dev bash -c '
    do_log() { echo "$*" >&2; }
    source "$0"
    mapfile -t p < <(_spl_wui_input_paths "$APP_PATH")
    (( ${#p[@]} )) || { echo "no wui paths"; exit 9; }
    _spl_lag_one wui "$1" "$2" 99999999 15 "${p[@]}"
  ' "$PROJ_ROOT/src/bash/run/check-deploy-lag.func.sh" "$(fixture "$2" "w-${2:0:8}")" "$3" 2>"$T/err"); rc=$?
  local n=n=1; [[ "$5" == current ]] && n=n=0
  if [[ $rc -eq $4 && "$out" == "dev wui $5 "* && "$out" == *" $n "* ]]; then pass "$1 ($5 $n, rc $rc)"
  else fail "$1: rc=$rc want $4 $5, out='$out' err='$(tail -1 "$T/err")'"; fi
}
want_paths=$(yq -r '.on.push.paths[]' "$WF30" | sed 's/^/:(glob)/')
got_paths=$(APP_PATH="$APP_ROOT" bash -c 'do_log() { :; }; source "$0"; _spl_wui_input_paths "$APP_PATH"' \
  "$PROJ_ROOT/src/bash/run/check-deploy-lag.func.sh")
[[ -n "$got_paths" && "$got_paths" == "$want_paths" ]] && pass "8. the WUI inputs are workflow 30's on.push.paths, one for one" ||
  fail "8. WUI inputs differ from workflow 30: got '$got_paths' want '$want_paths'"
grep -qx ':(glob)csi-spl-doc/blog/posts/\*\*' <<<"$got_paths" && pass "8. csi-spl-doc/blog/posts/** is among them" ||
  fail "8. no blog posts path in: $got_paths"
wui_one "8. RED CONTROL: a blog-post-only commit IS a WUI input" "$W_BASE" "$W_BLOG" 0 pending
wui_one "8. an orc-only commit is no WUI input (needs 'no deploy')" "$W_BLOG" "$W_ORC" 0 current
wui_one "8. '*' stays one level, as on GitHub: a nested cnf file is no input" "$W_ORC" "$W_CNF" 0 current
wui_one "8. a wf 30 orc script IS a WUI input" "$W_CNF" "$W_SCR" 0 pending

# --- the real action, end to end ---------------------------------------------
# Shallow-safe: the fixtures name THIS checkout's HEAD, so no history is walked.
head_sha=$(git -C "$APP_ROOT" rev-parse HEAD 2>/dev/null)
if [[ -z "$head_sha" ]]; then
  echo "SKIP: $APP_ROOT is not a git checkout -- the end-to-end assertions need one"
else
  hub_url=$(fixture "$head_sha" e2e_hub); wui_url=$(fixture "$head_sha" e2e_wui)
  action() { # <label> <want rc> <grep> [env...]
    local label="$1" want="$2" want_re="$3"; shift 3
    local out rc
    out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev \
          LAG_HUB_URL="$hub_url" LAG_WUI_URL="$wui_url" "$@" bash -c '
      set -uo pipefail
      do_log() { echo "$*" >&2; }
      for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
      do_check_deploy_lag' 2>"$T/err"); rc=$?
    if [[ $rc -eq $want ]] && grep -qE "$want_re" <<<"$out$(cat "$T/err")"; then pass "$label (rc $rc)"
    else fail "$label: rc=$rc want $want, out='$out' err='$(tail -2 "$T/err")'"; fi
  }
  action "both components current against the real dev cnf" 0 '^dev hub current .*\n?.*dev wui current|dev wui current'
  action "COMPONENT=hub asks only the hub" 0 'dev hub current' COMPONENT=hub
  action "COMPONENT=junk is refused" 1 'COMPONENT must be hub, wui or all' COMPONENT=junk
  action "a non-numeric GRACE_MINUTES is refused" 1 'GRACE_MINUTES must be' GRACE_MINUTES=soon
  action "a SHA that is not a commit here is refused" 1 'is not a commit in' SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
fi

[[ $fails -eq 0 ]] && echo "PASS: all check-deploy-lag assertions" || { echo "FAILED: $fails"; exit 1; }
