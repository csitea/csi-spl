#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_runner_retire_offline with stubbed gh and systemctl, and
#          do_gh_runner_remove stubbed (its own test is gh-runner-remove.tst.sh):
#          - fail fast: no GH_RUNNER_ORG
#          - guard: SPOOL_CI_RUNNER unset or naming self-hosted refuses, and
#            nothing is handed to do_gh_runner_remove
#          - only OFFLINE runners WITH a unit on this box are handed over;
#            an online runner and an offline one with no unit here are listed
#          - each runner is listed with its id, status and unit state
#          - a workflow whose runs-on names self-hosted is warned; a comment
#            that names it is not
#          - control: with the guard removed, an unset variable passes
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
F="$PROJ_ROOT/src/bash/run/gh-runner-retire-offline.func.sh"
bash -n "$F" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app/.github/workflows"
printf '%s\n' 'jobs:' '  a:' '    runs-on: [self-hosted, spool-ci]' >"$T/app/.github/workflows/99_smoke.yml"
printf '%s\n' '# was self-hosted once' 'jobs:' '  a:' '    runs-on: ubuntu-latest' >"$T/app/.github/workflows/20_x.yml"
cat >"$T/bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
  list-units) printf '%s\n' "actions.runner.o.r-on.service loaded active running X" ;;
  list-unit-files) printf '%s\n' "actions.runner.o.r-01.service enabled enabled" \
                                 "actions.runner.o.r-02.service enabled enabled" \
                                 "actions.runner.o.r-on.service enabled enabled" ;;
  is-enabled) echo enabled ;;
  is-active) [[ "$2" == *r-on* ]] && echo active || echo inactive ;;
esac
EOF2
cat >"$T/bin/gh" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r/actions/variables/SPOOL_CI_RUNNER --jq .value")
     [[ -n "${FAKE_VAR:-}" ]] || { echo "HTTP 404" >&2; exit 1; }; echo "$FAKE_VAR" ;;
  "api orgs/o/actions/runners --paginate --jq"*)
     printf '%s\n' "11 r-01 offline false" "12 r-02 offline false" "13 r-on online false" "14 far-01 offline false" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
EOF2
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

act() {
  # APP_PATH and GH_RUNNER_REPO are read by the sourced action
  # shellcheck disable=SC2034
  ( LOGF="$T/log"; APP_PATH="$T/app"; GH_RUNNER_REPO=o/r
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    ghrm_units() { systemctl list-unit-files | awk -v p="actions.runner.$1." 'index($1,p)==1 {n=substr($1,length(p)+1); sub(/\.service$/,"",n); print n}'; }
    do_gh_runner_remove() { echo "remove org=$GH_RUNNER_ORG names=$GH_RUNNER_NAMES" >>"$T/handed"; }
    # shellcheck source=../run/gh-runner-retire-offline.func.sh
    source "$F"
    if [[ -n "${NO_GUARD:-}" ]]; then ghro_guard() { :; }; fi
    do_gh_runner_retire_offline ) >/dev/null 2>&1
}
reset() { : >"$T/log"; rm -f "$T/handed"; }

reset; act && no "missing org must fail" || ok "missing GH_RUNNER_ORG fails fast"

reset; GH_RUNNER_ORG=o act && no "unset SPOOL_CI_RUNNER must fail" || ok "SPOOL_CI_RUNNER unset: refused"
[[ ! -e "$T/handed" ]] && ok "refused: nothing handed to do_gh_runner_remove" || no "handed: $(cat "$T/handed")"

reset; FAKE_VAR='["self-hosted","spool-ci"]' GH_RUNNER_ORG=o act && no "self-hosted variable must fail" || ok "SPOOL_CI_RUNNER naming self-hosted: refused"
[[ ! -e "$T/handed" ]] && ok "refused: nothing handed (self-hosted variable)" || no "handed: $(cat "$T/handed")"

reset; FAKE_VAR='"ubuntu-latest"' GH_RUNNER_ORG=o act && ok "hosted variable: exits 0" || no "failed: $(tail -2 "$T/log")"
[[ "$(cat "$T/handed" 2>/dev/null)" == "remove org=o names=r-01 r-02" ]] && ok "only the offline runners with a unit here are handed over" || no "handed: $(cat "$T/handed" 2>/dev/null)"
grep -q 'id=13 name=r-on status=online .*(enabled/active)' "$T/log" && ok "an online runner is listed with its unit state" || no "r-on line: $(grep r-on "$T/log")"
grep -q 'id=14 name=far-01 status=offline .*unit=- (no unit on this box)' "$T/log" && ok "an offline runner with no unit here is listed only" || no "far-01 line: $(grep far-01 "$T/log")"
grep -q 'id=11 name=r-01 status=offline .*actions.runner.o.r-01.service (enabled/inactive)' "$T/log" && ok "an offline runner is listed with its unit" || no "r-01 line: $(grep r-01 "$T/log")"
grep -q 'WARN 99_smoke.yml: 1 runs-on' "$T/log" && ok "a runs-on self-hosted workflow is warned" || no "no warn for 99_smoke"
grep -q 'WARN 20_x.yml' "$T/log" && no "a comment naming self-hosted was warned" || ok "a comment naming self-hosted is not warned"

# control: the guard is what refuses; without it an unset variable goes through
reset; NO_GUARD=1 GH_RUNNER_ORG=o act && [[ -e "$T/handed" ]] && ok "control: with the guard removed, unset SPOOL_CI_RUNNER is handed over" || no "control: the refusal does not come from the guard"

echo "=== gh-runner-retire-offline: $fails failure(s)"
[[ "$fails" -eq 0 ]]
