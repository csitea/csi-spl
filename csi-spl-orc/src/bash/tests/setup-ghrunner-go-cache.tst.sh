#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_ghrunner_go_cache with stubbed sudo, systemctl, ps, id and
#          go, fixture runner dirs whose svc.sh only records what it was asked:
#          - bad knobs are refused (DRY_RUN, a relative root)
#          - dry run (the default) changes nothing and names every runner
#          - DRY_RUN=0: every runner's .env gets GOCACHE / GOPATH /
#            GOMODCACHE under the root (its other lines kept), each idle one
#            is restarted, the runner user's go env -w names the new cache
#            (what the prune cron reads), the old GOPATH is copied, then the
#            old build cache and GOPATH (read-only module files too) dropped
#          - DRY_RUN=0 twice = nothing restarted the second time
#          - a busy runner (a Runner.Worker in its cgroup) is never restarted
#            nor rewritten, the run fails, and the old caches are kept
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/setup-ghrunner-go-cache.func.sh"
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
export STATE="$T/state" RUN_LOG="$T/run.log"

# sudo: drop -u and its user, run the rest as this user
cat >"$T/bin/sudo" <<'S'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
[[ "$1" == install ]] && { a=(); for x in "${@:2}"; do [[ "$x" == /* ]] && a+=("$x"); done; mkdir -p "${a[@]}"; exit; }
exec "$@"
S
# systemctl show -> the cgroup of the unit; ps -> Runner.Worker for a busy pid
cat >"$T/bin/systemctl" <<'S'
#!/usr/bin/env bash
[[ "$1" == show ]] && { echo "/system.slice/${@: -1}"; exit 0; }
exit 0
S
cat >"$T/bin/ps" <<'S'
#!/usr/bin/env bash
for p in ${4//,/ }; do grep -qx "$p" "$STATE/busy" 2>/dev/null && echo Runner.Worker || echo runsvc.sh; done
S
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && echo 999\n' >"$T/bin/id"
# go env -w K=V... records into $HOME/goenv; go env K reads it back
cat >"$T/bin/go" <<'S'
#!/usr/bin/env bash
f="$HOME/goenv"
if [[ "$2" == -w ]]; then shift 2; printf '%s\n' "$@" >>"$f"; echo "go env -w $*" >>"$RUN_LOG"; exit 0; fi
grep "^$2=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

mk_runner() {
  local d="$T/srv/$1"
  mkdir -p "$d" "$T/cg/system.slice/actions.runner.o.$1.service"
  echo '{}' >"$d/.runner"
  echo "actions.runner.o.$1.service" >"$d/.service"
  printf '%s\n' "DOCKER_HOST=unix:///run/user/999/docker.sock" "LANG=C.UTF-8" >"$d/.env"
  echo "$2" >"$T/cg/system.slice/actions.runner.o.$1.service/cgroup.procs"
  printf '#!/usr/bin/env bash\necho "%s svc.sh $*" >>"$RUN_LOG"\n' "$1" >"$d/svc.sh"
  chmod +x "$d/svc.sh"
}
mk_runner box-spl-01 101
mk_runner box-spl-02 202
H="$T/home"
mkdir -p "$H/.cache/go-build/00" "$H/go/pkg/mod/example.com/m@v1"
echo cached >"$H/.cache/go-build/00/a"
echo module >"$H/go/pkg/mod/example.com/m@v1/go.mod"
chmod -R a-w "$H/go/pkg/mod/example.com"
R="$T/data/gh-runner-go"

act() {
  ( do_log() { printf '%s\n' "$*" >>"$T/log"; }
    do_require_bin() { :; }
    sleep() { :; }
    # shellcheck source=/dev/null
    source "$FUNC"
    GH_RUNNER_ROOT="$T/srv" GH_RUNNER_HOME="$H" GH_RUNNER_GO_CACHE_ROOT="${ROOT:-$R}" \
      GH_RUNNER_GO_BIN=go GH_RUNNER_CGROUP_FS="$T/cg" GH_RUNNER_IDLE_WAIT_S="${WAIT:-0}" do_setup_ghrunner_go_cache ) >/dev/null 2>&1
}

DRY_RUN=2 act && no "DRY_RUN=2 must fail" || ok "DRY_RUN other than 0/1 is refused"
ROOT=rel/dir act && no "relative root must fail" || ok "a relative GH_RUNNER_GO_CACHE_ROOT is refused"

: >"$T/log"; : >"$RUN_LOG"
act && ok "dry run exits 0" || no "dry run failed: $(tail -3 "$T/log")"
[[ ! -e "$R" && ! -s "$RUN_LOG" && "$(grep -c GOCACHE "$T/srv/box-spl-01/.env")" == 0 && -d "$H/.cache/go-build" ]] \
  && ok "dry run changes nothing" || no "dry run changed: $(cat "$RUN_LOG"; ls "$T/data" 2>&1)"
grep -q 'box-spl-01: new-paths,idle-restart' "$T/log" && grep -q 'box-spl-02: new-paths,idle-restart' "$T/log" \
  && ok "dry run names every runner and what it would do" || no "plan: $(grep box-spl "$T/log")"

: >"$T/log"; : >"$RUN_LOG"
echo 202 >"$STATE/busy"
DRY_RUN=0 act && no "a busy runner must fail the run" || ok "a runner still busy after the wait fails the run"
grep -qx "GOCACHE=$R/go-build" "$T/srv/box-spl-01/.env" && ! grep -q GOCACHE "$T/srv/box-spl-02/.env" \
  && ! grep -q 'box-spl-02 svc.sh' "$RUN_LOG" && grep -q 'box-spl-01 svc.sh start' "$RUN_LOG" \
  && ok "the idle runner is switched, the busy one is neither rewritten nor restarted" || no "busy: $(cat "$RUN_LOG")"
[[ -s "$H/.cache/go-build/00/a" && -s "$H/go/pkg/mod/example.com/m@v1/go.mod" ]] \
  && ok "the old caches are kept while a runner still uses them" || no "old cache dropped too early"

: >"$T/log"; : >"$RUN_LOG"; : >"$STATE/busy"
DRY_RUN=0 act && ok "apply exits 0" || no "apply failed: $(tail -3 "$T/log")"
want="DOCKER_HOST=unix:///run/user/999/docker.sock
LANG=C.UTF-8
GOCACHE=$R/go-build
GOPATH=$R/go
GOMODCACHE=$R/go/pkg/mod"
[[ "$(cat "$T/srv/box-spl-01/.env")" == "$want" && "$(cat "$T/srv/box-spl-02/.env")" == "$want" ]] \
  && ok "every runner's .env names the new caches and keeps its other lines" || no ".env: $(cat "$T/srv/box-spl-02/.env")"
[[ "$(cat "$RUN_LOG" | grep svc.sh)" == "box-spl-02 svc.sh stop
box-spl-02 svc.sh start" ]] && ok "only the runner not yet switched is restarted" || no "svc: $(cat "$RUN_LOG")"
grep -q "go env -w GOCACHE=$R/go-build GOPATH=$R/go GOMODCACHE=$R/go/pkg/mod" "$RUN_LOG" \
  && [[ "$(HOME="$H" go env GOCACHE)" == "$R/go-build" ]] && ok "the runner user's go env names the new cache (the prune cron follows it)" \
  || no "go env: $(cat "$RUN_LOG")"
[[ -s "$R/go/pkg/mod/example.com/m@v1/go.mod" && -d "$R/go-build" ]] && ok "the old GOPATH's modules are copied to the new one" || no "seed: $(find "$R" -maxdepth 3)"
[[ ! -e "$H/.cache/go-build" && ! -e "$H/go" ]] && ok "the old build cache and GOPATH are dropped once every runner switched" || no "old left: $(find "$H" -maxdepth 3)"

: >"$T/log"; : >"$RUN_LOG"
DRY_RUN=0 act && ok "second apply exits 0" || no "second apply failed: $(tail -3 "$T/log")"
! grep -q svc.sh "$RUN_LOG" && [[ "$(grep -c '^GOCACHE=' "$T/srv/box-spl-01/.env")" == 1 ]] \
  && ok "apply twice = nothing restarted, one GOCACHE line" || no "second apply: $(cat "$RUN_LOG")"
grep -q 'box-spl-01: kept' "$T/log" && ok "a switched runner is reported kept" || no "kept: $(grep box-spl "$T/log")"

echo "=== setup-ghrunner-go-cache: $fails failure(s)"
[[ "$fails" -eq 0 ]]
