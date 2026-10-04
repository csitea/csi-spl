#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 072 A13 -- the CI runner is a repo variable.
#   static: every `runs-on` of wf 10 is the one A13 expression: the variable
#           SPOOL_CI_RUNNER when set, else [self-hosted, spool-ci] on this repo
#           only, else ubuntu-latest (a fork has no self-hosted runner: a bare
#           literal label queues its gate for ever)
#   do_gh_set_ci_vars (hermetic: `gh` is a stub over a dir of variables):
#     1. DRY_RUN default: a missing variable is "would create", nothing written
#     2. DRY_RUN=0 writes it (JSON on --body) and reads it back
#     3. an equal value is "unchanged", nothing written
#     4. a different value is "would update: old -> new"
#     5. the repo comes from the origin remote (ssh and https), else refused
#   CONTROLS: a non-JSON SPOOL_CI_RUNNER is refused and writes nothing; a
#             literal self-hosted runs-on is caught by the static check.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/gh-set-ci-vars.func.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
require_action "$FUNC"

# --- static: wf 10 ------------------------------------------------------------
WANT="runs-on: \${{ vars.SPOOL_CI_RUNNER && fromJSON(vars.SPOOL_CI_RUNNER) || github.repository == 'csitea/csi-spl' && fromJSON('[\"self-hosted\",\"spool-ci\"]') || 'ubuntu-latest' }}"
runs_on() { grep -E '^[[:space:]]*runs-on:' "$1"; }
not_var() { runs_on "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -vxF "$WANT"; }
n_all=$(runs_on "$WF" | wc -l)
if ((n_all == 0)); then fail "wf 10 has no runs-on line"
elif [[ -n "$(not_var "$WF")" ]]; then fail "wf 10 runs-on lines not read from vars.SPOOL_CI_RUNNER:"; not_var "$WF" | sed 's/^/      /'
else pass "wf 10: all $n_all runs-on lines: SPOOL_CI_RUNNER, else self-hosted on this repo, else ubuntu-latest"; fi
printf 'jobs:\n  a:\n    runs-on: [self-hosted, spool-ci]\n' >"$T/ctl.yml"
[[ -n "$(not_var "$T/ctl.yml")" ]] && pass "CONTROL: a literal self-hosted runs-on is caught" \
  || fail "CONTROL: a literal self-hosted runs-on passed"

# --- the action, gh stubbed ---------------------------------------------------
mkdir -p "$T/bin" "$T/vars" "$T/app"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# variables live as files in $GH_STUB_VARS; every write is logged
case "$1 $2" in
  "api repos/"*/actions/variables/*) f="$GH_STUB_VARS/${2##*/}"; [[ -f "$f" ]] || { echo "{\"message\":\"Not Found\",\"status\":\"404\"}"; exit 1; }; cat "$f" ;;
  "api repos/"*) echo "${2#repos/}" ;;
  "variable set") echo "$*" >>"$GH_STUB_LOG"; [[ "$4" == --repo && "$6" == --body ]] || exit 2; printf '%s' "$7" >"$GH_STUB_VARS/$3" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$T/bin/gh"
git -C "$T/app" init -q && git -C "$T/app" remote add origin git@github.com:o/app.git

act() {  # runs the action in a clean shell; output in $T/out
  : >"$T/log"
  env -u SPOOL_CI_RUNNER -u GH_CI_VARS_REPO -u DRY_RUN PATH="$T/bin:$PATH" GH_STUB_VARS="$T/vars" GH_STUB_LOG="$T/log" \
    APP_PATH="$T/app" "$@" bash -c 'do_log() { echo "$*"; }; source "$1"; do_gh_set_ci_vars' _ "$FUNC" >"$T/out" 2>&1
}
DEF='["self-hosted","spool-ci"]'

act; rc=$?
[[ $rc == 0 ]] && grep -qF "o/app SPOOL_CI_RUNNER would create: $DEF" "$T/out" && [[ ! -s "$T/log" && ! -e "$T/vars/SPOOL_CI_RUNNER" ]] \
  && pass "1. dry run by default: would create $DEF, nothing written" || fail "1. dry run: rc=$rc $(cat "$T/out" "$T/log")"

act DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && grep -qxF "variable set SPOOL_CI_RUNNER --repo o/app --body $DEF" "$T/log" && grep -qF "SPOOL_CI_RUNNER set: $DEF" "$T/out" \
  && pass "2. DRY_RUN=0 sets it and reads it back" || fail "2. set: rc=$rc $(cat "$T/out" "$T/log")"

act DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && grep -qF "SPOOL_CI_RUNNER unchanged" "$T/out" && [[ ! -s "$T/log" ]] \
  && pass "3. an equal value is unchanged, nothing written" || fail "3. unchanged: rc=$rc $(cat "$T/out" "$T/log")"

act SPOOL_CI_RUNNER='"ubuntu-24.04"'; rc=$?
[[ $rc == 0 ]] && grep -qF "would update: $DEF -> \"ubuntu-24.04\"" "$T/out" && [[ ! -s "$T/log" ]] \
  && pass "4. a different value is would-update old -> new" || fail "4. update: rc=$rc $(cat "$T/out" "$T/log")"

act SPOOL_CI_RUNNER='self-hosted' DRY_RUN=0; rc=$?
[[ $rc != 0 ]] && grep -qF "is not JSON" "$T/out" && [[ ! -s "$T/log" ]] \
  && pass "CONTROL: a non-JSON value is refused, nothing written" || fail "CONTROL non-JSON: rc=$rc $(cat "$T/out" "$T/log")"

git -C "$T/app" remote set-url origin https://github.com/o2/app2.git
act; grep -qF "o2/app2 SPOOL_CI_RUNNER" "$T/out" && pass "5. repo from an https origin" || fail "5. https origin: $(cat "$T/out")"
git -C "$T/app" remote set-url origin https://git.example.com/o/app.git
act; rc=$?
[[ $rc != 0 ]] && grep -qF "set GH_CI_VARS_REPO" "$T/out" && pass "5. a non-GitHub origin with no GH_CI_VARS_REPO is refused" \
  || fail "5. non-GitHub origin: rc=$rc $(cat "$T/out")"
act GH_CI_VARS_REPO=o3/app3; grep -qF "o3/app3 SPOOL_CI_RUNNER" "$T/out" && pass "5. GH_CI_VARS_REPO wins" || fail "5. GH_CI_VARS_REPO: $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
