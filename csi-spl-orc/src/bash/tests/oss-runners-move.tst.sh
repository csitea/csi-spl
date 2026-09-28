#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_runners_move (spec 044 / SPL-64, CLE-35070) with stubbed
#          systemctl, sudo and gh:
#          - fail fast: missing repos, the same repo twice, a PUBLIC target
#          - only the units of OSS_RUNNER_FROM are picked (never o-app-ops.*)
#          - DRY_RUN=1 runs nothing inside a runner dir
#          - DRY_RUN=0 per runner: waits while busy, then stop, uninstall,
#            remove (FROM token), config on TO with the SAME name + custom
#            labels, install as the unit's user, start - in that order
#          - a registration token never reaches the log
#          - a runner still listed on FROM afterwards fails the action
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/oss-runners-move.func.sh" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-units) printf '%s\n' "actions.runner.o-app.r-01.service loaded active running X" \
                            "actions.runner.o-app-ops.r-09.service loaded active running X" ;;
  show) case "$3" in WorkingDirectory) echo "/srv/runners/${5#*.o-app.}" | sed 's/\.service$//' ;; User) echo runuser ;; esac ;;
esac
EOF
cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == test ]]; then exit 0; fi
if [[ "$1" == -u ]]; then u="$2"; shift 2; fi
# bash -c 'cd "$1" && shift && exec "$@"' _ <dir> <cmd...>
[[ "$1" == bash ]] && { shift 4; d="$1"; shift; echo "${u:-root}@$(basename "$d") $*" >>"$RUN_LOG"; exit 0; }
exit 0
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/app-ops --jq .private") echo "${TO_PRIVATE:-true}" ;;
  "api repos/o/app/actions/runners --paginate --jq"*"labels"*) echo spool-ci ;;
  "api repos/o/app/actions/runners --paginate --jq"*".busy"*)
     n=$(cat "$GH_STATE/busy" 2>/dev/null || echo 0); if ((n > 0)); then echo $((n - 1)) >"$GH_STATE/busy"; echo true; else echo false; fi ;;
  "api -X POST repos/o/app/actions/runners/remove-token --jq .token") echo TOKEN-REMOVE-SENTINEL ;;
  "api -X POST repos/o/app-ops/actions/runners/registration-token --jq .token") echo TOKEN-REG-SENTINEL ;;
  "api repos/o/app-ops/actions/runners --paginate --jq"*) echo r-01 ;;
  "api repos/o/app/actions/runners --paginate --jq"*) cat "$GH_STATE/stale" 2>/dev/null ;;
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
    source "$PROJ_ROOT/src/bash/run/oss-runners-move.func.sh"
    do_oss_runners_move ) >/dev/null 2>&1
}

OSS_RUNNER_TO=o/app-ops act && no "missing FROM must fail" || ok "missing OSS_RUNNER_FROM fails fast"
OSS_RUNNER_FROM=o/app OSS_RUNNER_TO=o/app act && no "same repo must fail" || ok "the same repo twice fails fast"
TO_PRIVATE=false OSS_RUNNER_FROM=o/app OSS_RUNNER_TO=o/app-ops act && no "public target must fail" || ok "a public target repo is refused"

: >"$RUN_LOG"
OSS_RUNNER_FROM=o/app OSS_RUNNER_TO=o/app-ops act && ok "dry run exits 0" || no "dry run failed: $(tail -2 "$T/log")"
[[ ! -s "$RUN_LOG" ]] && ok "dry run runs nothing in a runner dir" || no "dry run ran: $(cat "$RUN_LOG")"
grep -q 'would move r-01 (/srv/runners/r-01, user runuser, labels spool-ci)' "$T/log" && ok "the unit's dir, user, labels are read" || no "unit facts: $(grep would "$T/log")"
grep -q 'r-09' "$T/log" && no "a unit of another repo (o-app-ops) was picked" || ok "only OSS_RUNNER_FROM's units are picked"

: >"$RUN_LOG"; : >"$T/log"; echo 2 >"$T/state/busy"
OSS_RUNNER_FROM=o/app OSS_RUNNER_TO=o/app-ops DRY_RUN=0 act && ok "apply exits 0" || no "apply failed: $(tail -2 "$T/log")"
want="root@r-01 ./svc.sh stop
root@r-01 ./svc.sh uninstall
runuser@r-01 ./config.sh remove --token TOKEN-REMOVE-SENTINEL
runuser@r-01 ./config.sh --unattended --replace --url https://github.com/o/app-ops --token TOKEN-REG-SENTINEL --name r-01 --labels spool-ci --work _work
root@r-01 ./svc.sh install runuser
root@r-01 ./svc.sh start"
[[ "$(cat "$RUN_LOG")" == "$want" ]] && ok "stop, uninstall, remove, re-register (same name + labels), install, start - in order" || no "sequence: $(cat "$RUN_LOG")"
[[ "$(cat "$T/state/busy")" == 0 ]] && ok "it waited while the runner was busy" || no "did not wait for busy"
grep -q SENTINEL "$T/log" && no "a token reached the log" || ok "no token in the log"

echo r-01 >"$T/state/stale"
OSS_RUNNER_FROM=o/app OSS_RUNNER_TO=o/app-ops DRY_RUN=0 act && no "a runner left on FROM must fail" || ok "a runner still on FROM fails the action"

echo "=== oss-runners-move: $fails failure(s)"
[[ "$fails" -eq 0 ]]
