#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_gh_runner (read-only) with stubbed sudo, systemctl, id,
#          docker and hostname:
#          - every runner active, Restart=always, docker enabled + answering: OK
#          - a runner the CPU budget parked is PARKED, not a failure
#          - a stopped runner nobody parked, Restart=no, a disabled docker
#            unit, a docker socket that does not answer: FAIL, exit 1
#          - no runner unit: OK, exit 0
#          - it changes nothing (no systemctl verb other than list/show/is-enabled)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-gh-runner.func.sh"
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export STATE="$T/state" SYS_LOG="$T/sys.log" CPU_BUDGET_STATE_DIR="$T/state"

cat >"$T/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
exec "$@"
EOF2
# units: $STATE/units, one "<name> <ActiveState> <Restart>" per line
cat >"$T/bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >>"$SYS_LOG"
case "$1" in
  list-units) awk '{print "actions.runner.o." $1 ".service loaded " $2 " x"}' "$STATE/units" 2>/dev/null; exit 0 ;;
  show) n="${2#actions.runner.o.}"; n="${n%.service}"
        case "$4" in
          ActiveState) awk -v n="$n" '$1==n{print $2}' "$STATE/units" ;;
          Restart) awk -v n="$n" '$1==n{print $3}' "$STATE/units" ;;
          User) echo ghrunner ;;
        esac; exit 0 ;;
  --user) [[ "$*" == "--user is-enabled --quiet docker" ]] && { [[ -e "$STATE/enabled" ]]; exit; } ;;
esac
exit 0
EOF2
cat >"$T/bin/docker" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == info && -e "$STATE/answers" ]]
EOF2
printf '#!/usr/bin/env bash\necho 1500\n' >"$T/bin/id"
printf '#!/usr/bin/env bash\necho box\n' >"$T/bin/hostname"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# shellcheck source=/dev/null
chk() { ( source "$FUNC"; do_check_gh_runner ) >"$T/out" 2>&1; }

printf '%s\n' 'box-spl-01 active always' 'box-spl-02 active always' >"$STATE/units"
touch "$STATE/enabled" "$STATE/answers"
chk && grep -q '^CHECK gh-runner OK: 2 runner(s) on box' "$T/out" && [[ "$(grep -c '^OK box-spl-0[12]: service active' "$T/out")" == 2 ]] \
  && ok "healthy runners: one OK line each, CHECK OK, exit 0" || no "healthy: $(cat "$T/out")"

printf '%s\n' 'box-spl-01 active always' 'box-spl-02 inactive always' >"$STATE/units"
echo actions.runner.o.box-spl-02.service >"$STATE/parked"
chk && grep -q '^OK box-spl-02: service PARKED' "$T/out" && ok "a runner the CPU budget parked is PARKED, not a failure" || no "parked: $(cat "$T/out")"
rm -f "$STATE/parked"
chk && no "a stopped runner nobody parked must fail" || { grep -q '^FAIL box-spl-02: service inactive' "$T/out" && ok "a stopped runner nobody parked fails" || no "stopped: $(cat "$T/out")"; }

printf '%s\n' 'box-spl-01 active no' 'box-spl-02 active always' >"$STATE/units"
chk && no "Restart=no must fail" || { grep -q '^FAIL box-spl-01: Restart=no' "$T/out" && grep -q '^OK box-spl-02' "$T/out" && ok "a runner without Restart=always fails, the other stays OK" || no "restart: $(cat "$T/out")"; }

printf '%s\n' 'box-spl-01 active always' >"$STATE/units"
rm -f "$STATE/enabled"
chk && no "disabled docker must fail" || { grep -q 'docker unit of ghrunner NOT enabled' "$T/out" && grep -q '^CHECK gh-runner FAIL: 1 of 1' "$T/out" && ok "a disabled rootless docker unit fails (gone after a boot)" || no "disabled: $(cat "$T/out")"; }
touch "$STATE/enabled"; rm -f "$STATE/answers"
chk && no "silent docker must fail" || { grep -q 'docker socket /run/user/1500/docker.sock does not answer' "$T/out" && ok "a docker socket that does not answer fails" || no "socket: $(cat "$T/out")"; }

: >"$STATE/units"
chk && grep -q '^CHECK gh-runner OK: no runner unit on box' "$T/out" && ok "no runner unit: OK, exit 0" || no "none: $(cat "$T/out")"

changed="$(grep -vE '^(list-units|show|--user is-enabled)' "$SYS_LOG")"
[[ -n "$changed" ]] && no "it changed something: $(grep -vE '^(list-units|show|--user is-enabled)' "$SYS_LOG")" || ok "read-only: only list-units, show, is-enabled"

echo "=== check-gh-runner: $fails failure(s)"
[[ "$fails" -eq 0 ]]
