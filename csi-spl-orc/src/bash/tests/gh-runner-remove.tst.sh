#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_runner_remove with stubbed systemctl, sudo and gh:
#          - fail fast: no GH_RUNNER_ORG, a GH_RUNNER_NAMES name with no unit
#          - only the org's units are picked (never actions.runner.o-x.*)
#          - DRY_RUN=1 stops nothing and runs nothing in a runner dir
#          - DRY_RUN=0 per runner: waits while busy, then stop, disable,
#            `config.sh remove` (org remove-token) as the unit's user
#          - the runner dir is never removed; a token never reaches the log
#          - a runner still listed in the org afterwards fails the action
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/gh-runner-remove.func.sh" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-units) printf '%s\n' "actions.runner.o.r-01.service loaded active running X" \
                            "actions.runner.o.r-02.service loaded active running X" \
                            "actions.runner.o-x.r-09.service loaded active running X" ;;
  show) n="${5#actions.runner.o.}"; case "$3" in WorkingDirectory) echo "/srv/runners/${n%.service}" ;; User) echo runuser ;; esac ;;
esac
EOF
cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == test ]]; then exit 0; fi
if [[ "$1" == systemctl ]]; then echo "root systemctl $2 $3" >>"$RUN_LOG"; exit 0; fi
if [[ "$1" == -u ]]; then u="$2"; shift 2; fi
# bash -c 'cd "$1" && shift && exec "$@"' _ <dir> <cmd...>
[[ "$1" == bash ]] && { shift 4; d="$1"; shift; echo "${u:-root}@$(basename "$d") $*" >>"$RUN_LOG"; exit 0; }
echo "other: $*" >>"$RUN_LOG"
exit 0
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api orgs/o/actions/runners --paginate --jq"*".busy"*)
     n=$(cat "$GH_STATE/busy" 2>/dev/null || echo 0); if ((n > 0)); then echo $((n - 1)) >"$GH_STATE/busy"; echo true; else echo false; fi ;;
  "api -X POST orgs/o/actions/runners/remove-token --jq .token") echo TOKEN-REMOVE-SENTINEL ;;
  "api orgs/o/actions/runners --paginate --jq .runners[].name") echo other-01; cat "$GH_STATE/stale" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" RUN_LOG="$T/run.log" GH_STATE="$T/state"

act() {
  ( LOGF="$T/log"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    sleep() { :; }
    source "$PROJ_ROOT/src/bash/run/gh-runner-remove.func.sh"
    do_gh_runner_remove ) >/dev/null 2>&1
}

act && no "missing org must fail" || ok "missing GH_RUNNER_ORG fails fast"
GH_RUNNER_ORG=o GH_RUNNER_NAMES=r-07 act && no "an unknown name must fail" || ok "a name with no unit here fails fast"

: >"$RUN_LOG"; : >"$T/log"
GH_RUNNER_ORG=o act && ok "dry run exits 0" || no "dry run failed: $(tail -2 "$T/log")"
[[ ! -s "$RUN_LOG" ]] && ok "dry run stops nothing, runs nothing in a runner dir" || no "dry run ran: $(cat "$RUN_LOG")"
grep -q 'would drain.*r-01' "$T/log" && grep -q 'would drain.*r-02' "$T/log" && ok "every unit of the org is picked" || no "picked: $(grep would "$T/log")"
grep -q 'r-09' "$T/log" && no "a unit of another org (o-x) was picked" || ok "only GH_RUNNER_ORG's units are picked"

: >"$RUN_LOG"; : >"$T/log"; echo 2 >"$T/state/busy"
GH_RUNNER_ORG=o GH_RUNNER_NAMES=r-01 DRY_RUN=0 act && ok "apply exits 0" || no "apply failed: $(tail -2 "$T/log")"
want="root systemctl stop actions.runner.o.r-01.service
root systemctl disable actions.runner.o.r-01.service
runuser@r-01 ./config.sh remove --token TOKEN-REMOVE-SENTINEL"
[[ "$(cat "$RUN_LOG")" == "$want" ]] && ok "stop, disable, deregister as the unit's user - in order, r-01 only" || no "sequence: $(cat "$RUN_LOG")"
[[ "$(cat "$T/state/busy")" == 0 ]] && ok "it waited while the runner was busy" || no "did not wait for busy"
grep -qE 'rm |uninstall' "$RUN_LOG" && no "the runner dir or unit was removed" || ok "the dir and unit file are kept (rollback)"
grep -q SENTINEL "$T/log" && no "a token reached the log" || ok "no token in the log"

echo r-02 >"$T/state/stale"; : >"$T/log"
GH_RUNNER_ORG=o DRY_RUN=0 act && no "a runner left in the org must fail" || ok "a runner still listed in the org fails the action"

echo "=== gh-runner-remove: $fails failure(s)"
[[ "$fails" -eq 0 ]]
