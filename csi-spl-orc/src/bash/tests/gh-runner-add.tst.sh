#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_runner_add (spec 064 L3) with stubbed sudo, gh, systemctl,
#          id, dpkg, docker and hostname, and a real tarball whose config.sh /
#          svc.sh only record what they were asked:
#          - fail fast: no repo, no group, an unrestricted group, a group
#            workflow not pinned to the default branch, two label sets
#          - dry run (the default) changes nothing and names the plan
#          - APPLY=1 registers N runners with the group's labels, as the
#            dedicated user, with rootless docker + the cleanup hook in .env
#          - APPLY=1 twice = one set of runners (nothing re-registered)
#          - a runner user in the docker group is refused
#          - a registration token never reaches the log
#          - the workflow's img= pins are pulled once into the runner's docker
#          - the cleanup hook prunes only its OWN runner's work dir
#          - GH_RUNNER_DATA_ROOT: a NEW runner's dir lives there, linked from
#            GH_RUNNER_ROOT; an existing runner is never moved; the cleanup
#            hook prunes a linked runner's work dir too
#          - every runner unit gets the Slice=user-<uid>.slice drop-in (the
#            CPU budget's cgroup) and is restarted into it once
#          - GH_RUNNER_CPU_WEIGHT: set live on the user slice and every runner
#            unit; unset = no set-property at all; out of range is refused
#          - GH_RUNNER_GO_CACHE_ROOT: the Go cache lines in every .env; a
#            reinstall without it keeps the lines already there
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/gh-runner-add.func.sh"
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/pkg"
export STATE="$T/state" RUN_LOG="$T/run.log" MUT_LOG="$T/mut.log" SYSD_LOG="$T/sysd.log" UNIT_DIR="$T/units"

# sudo: drop -u/-U, record root-side mutations, exec the rest as this user
cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
u=root
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -u) u="$2"; shift 2 ;;
    -l) echo "User $3 is not allowed to run sudo on box."; exit 0 ;;
    *) shift ;;
  esac
done
case "$1" in
  test) [[ "$2" == -S ]] && exit 0; exec "$@" ;;
  useradd) echo "$u $*" >>"$MUT_LOG"; touch "$STATE/user"; exit 0 ;;
  usermod|loginctl|chmod|curl|apt-get) echo "$u $*" >>"$MUT_LOG"; exit 0 ;;
  install) echo "$u install ${*: -1}" >>"$MUT_LOG"; mkdir -p "${@: -1}"; exit 0 ;;
  env) a=(); for x in "$@"; do [[ "$x" == PATH=* ]] || a+=("$x"); done
       [[ "${a[*]}" == *apt-get* ]] && { echo "$u apt-get" >>"$MUT_LOG"; touch "$STATE/pkgs"; exit 0; }
       exec "${a[@]}" ;;
esac
exec "$@"
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/app --jq .default_branch") echo master ;;
  "api orgs/o/actions/runner-groups --paginate --jq"*) echo 3 ;;
  "api orgs/o/actions/runner-groups/3 --jq"*) echo "${GROUP_SHAPE:-selected true 3 0}" ;;
  "api orgs/o/actions/runner-groups/3/runners --paginate --jq"*custom*) printf '%s\n' ${LABEL_SETS:-spool-ci spool-ci spool-ci} ;;
  "api orgs/o/actions/runner-groups/3/runners --paginate --jq"*online*) cat "$STATE/reg" 2>/dev/null ;;
  "api orgs/o/actions/runner-groups/3/runners --paginate --jq"*) printf '%s\n' pc-01 pc-02; cat "$STATE/reg" 2>/dev/null ;;
  "api -X POST orgs/o/actions/runners/registration-token --jq .token") echo TOKEN-REG-SENTINEL ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -u) [[ -e "$STATE/user" ]] && echo 1500 || exit 1 ;;
  -nG) echo "${ID_GROUPS:-ghrunner}" ;;
esac
EOF
cat >"$T/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ -e "$STATE/pkgs" ]]
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == set-property ]] && { echo "systemctl $*" >>"$MUT_LOG"; exit 0; }
[[ "$1" == restart ]] && touch "$STATE/moved-$2"
[[ "$1" == restart || "$1" == daemon-reload ]] && { echo "systemctl $*" >>"$SYSD_LOG"; exit 0; }
[[ "$1 $3 $4" == "show -p ControlGroup" && -e "$STATE/moved-$2" ]] && { echo "/user.slice/user-1500.slice/$2"; exit 0; }
[[ "$1 $3 $4" == "show -p ControlGroup" ]] && { echo "/system.slice/$2"; exit 0; }
[[ "$*" == "--user is-active --quiet docker" ]] && { [[ -e "$STATE/rootless" ]]; exit; }
exit 0
EOF
cat >"$T/bin/setuptool" <<'EOF'
#!/usr/bin/env bash
echo "setuptool $*" >>"$MUT_LOG"; touch "$STATE/rootless"
EOF
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
k="$STATE/img-${3//[\/:]/_}"
case "$1 $2" in
  "image inspect") [[ -e "$k" ]]; exit ;;
  "pull -q") echo "pull $3" >>"$MUT_LOG"; touch "$k" ;;
esac
exit 0
EOF
printf '%s\n' '      run: |' '          img=postgres:16-alpine' '          img=fsouza/fake-gcs-server:1.52.2' >"$T/wf.yml"
export GH_RUNNER_WORKFLOW="$T/wf.yml"
printf '#!/usr/bin/env bash\necho box\n' >"$T/bin/hostname"
# the fake runner package
cat >"$T/pkg/config.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$PWD") config.sh $*" >>"$RUN_LOG"
while (($#)); do [[ "$1" == --name ]] && { echo "$2" >>"$STATE/reg"; echo "{}" >.runner; }; shift; done
EOF
cat >"$T/pkg/svc.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$PWD") svc.sh $*" >>"$RUN_LOG"
[[ "$1" == install ]] && echo "actions.runner.o.$(basename "$PWD").service" >.service
exit 0
EOF
chmod +x "$T/bin/"* "$T/pkg/"*
tar -czf "$T/runner.tgz" -C "$T/pkg" config.sh svc.sh
export PATH="$T/bin:$PATH"

act() {
  ( LOGF="$T/log"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    sleep() { :; }
    export GH_RUNNER_SETUPTOOL="$T/bin/setuptool"
    # shellcheck source=/dev/null
    source "$FUNC"
    GH_RUNNER_ROOT="${TEST_ROOT:-$T/srv}" GH_RUNNER_HOME="$T/home" GH_RUNNER_TARBALL="$T/runner.tgz" GH_RUNNER_UNIT_DIR="$UNIT_DIR" do_gh_runner_add ) >/dev/null 2>&1
}

GH_RUNNER_GROUP=g act && no "missing repo must fail" || ok "missing GH_RUNNER_REPO fails fast"
GH_RUNNER_REPO=o/app act && no "missing group must fail" || ok "missing GH_RUNNER_GROUP fails fast"
GROUP_SHAPE="all false 0 0" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "open group must fail" || ok "an unrestricted runner group is refused"
GROUP_SHAPE="selected true 3 1" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "non-master workflow must fail" || ok "a group workflow not pinned to @refs/heads/master is refused"
LABEL_SETS="spool-ci spool-ci,x" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "two label sets must fail" || ok "runners with differing label sets are refused"

: >"$T/log"; : >"$RUN_LOG"; : >"$MUT_LOG"
GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g RUNNER_COUNT=2 act && ok "dry run exits 0" || no "dry run failed: $(tail -2 "$T/log")"
[[ ! -s "$RUN_LOG" && ! -s "$MUT_LOG" && ! -e "$T/srv" ]] && ok "dry run changes nothing" || no "dry run changed: $(cat "$RUN_LOG" "$MUT_LOG")"
grep -q 'box-spl-01: new.*labels spool-ci, group g' "$T/log" && grep -q '2 new runner(s): box-spl-01 box-spl-02' "$T/log" \
  && ok "dry run names both runners, the copied label and the group" || no "dry plan: $(grep -E 'new|DRY' "$T/log")"

: >"$T/log"
GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "apply exits 0" || no "apply failed: $(tail -3 "$T/log")"
want="box-spl-01 config.sh --unattended --replace --url https://github.com/o --token TOKEN-REG-SENTINEL --name box-spl-01 --labels spool-ci --runnergroup g --work _work
box-spl-02 config.sh --unattended --replace --url https://github.com/o --token TOKEN-REG-SENTINEL --name box-spl-02 --labels spool-ci --runnergroup g --work _work"
[[ "$(grep config.sh "$RUN_LOG")" == "$want" ]] && ok "two runners registered on the org, in group g, with the copied label" || no "config: $(grep config.sh "$RUN_LOG")"
[[ "$(grep -c 'svc.sh install ghrunner' "$RUN_LOG")" == 2 ]] && ok "both services installed as ghrunner" || no "svc: $(cat "$RUN_LOG")"
grep -q '^root useradd --system .*ghrunner$' "$MUT_LOG" && grep -q '^setuptool install' "$MUT_LOG" && grep -q 'loginctl enable-linger ghrunner' "$MUT_LOG" \
  && ok "dedicated user, linger and rootless docker set up" || no "box setup: $(cat "$MUT_LOG")"
grep -qE 'usermod .*(-aG|-G) *docker' "$MUT_LOG" && no "ghrunner was put in the docker group" || ok "ghrunner is never added to the docker group"
grep -qx 'DOCKER_HOST=unix:///run/user/1500/docker.sock' "$T/srv/box-spl-02/.env" && grep -qx "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$T/srv/job-done.sh" "$T/srv/box-spl-02/.env" \
  && [[ -s "$T/srv/job-done.sh" ]] && grep -q "chmod 0755 $T/srv/job-done.sh" "$MUT_LOG" && ok ".env points at the rootless docker and the cleanup hook" || no ".env: $(cat "$T/srv/box-spl-02/.env")"
grep -q SENTINEL "$T/log" && no "a token reached the log" || ok "no token in the log"
[[ "$(grep '^pull ' "$MUT_LOG" | sort | tr '\n' ' ')" == "pull fsouza/fake-gcs-server:1.52.2 pull postgres:16-alpine " ]] \
  && ok "the workflow's pinned images are warmed in the runner user's docker" || no "warm: $(grep pull "$MUT_LOG")"
[[ "$(cat "$UNIT_DIR/actions.runner.o.box-spl-02.service.d/50-slice.conf" 2>/dev/null)" == $'[Service]\nSlice=user-1500.slice' ]] \
  && [[ "$(cat "$SYSD_LOG")" == $'systemctl daemon-reload\nsystemctl restart actions.runner.o.box-spl-01.service\nsystemctl restart actions.runner.o.box-spl-02.service' ]] \
  && ok "every runner unit is placed in user-1500.slice: drop-in, one reload, one restart each" || no "slice: $(cat "$SYSD_LOG"; ls -R "$UNIT_DIR" 2>&1)"
: >"$SYSD_LOG"

: >"$T/log"; : >"$RUN_LOG"; : >"$MUT_LOG"
GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "second apply exits 0" || no "second apply failed: $(tail -3 "$T/log")"
[[ ! -s "$SYSD_LOG" ]] && ok "a runner already in the slice is not reloaded or restarted" || no "second apply touched units: $(cat "$SYSD_LOG")"
[[ "$(sort "$STATE/reg" | uniq -c | awk '{print $1}' | sort -u)" == 1 && "$(wc -l <"$STATE/reg")" == 2 ]] \
  && ! grep -q config.sh "$RUN_LOG" && ok "apply twice = one set of runners (nothing re-registered)" || no "re-registered: $(cat "$RUN_LOG")"
[[ "$(grep -c -- '- kept' "$T/log")" == 2 ]] && ! grep -q 'useradd\|setuptool\|^pull ' "$MUT_LOG" && ok "existing runners, user and docker are kept" || no "kept: $(cat "$T/log" "$MUT_LOG")"
[[ "$(grep -c 'svc.sh start' "$RUN_LOG")" == 2 && "$(grep -c 'svc.sh install' "$RUN_LOG")" == 0 ]] && ok "kept services are only started" || no "svc 2nd: $(cat "$RUN_LOG")"

ID_GROUPS="ghrunner docker" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 act && no "docker-group user must fail" || ok "a runner user in the docker group is refused"

# the cleanup hook: under the threshold it prunes its own work dir only
for r in box-spl-01 box-spl-02; do mkdir -p "$T/srv/$r/_work/app/app" "$T/srv/$r/_work/_tool/go"; done
GH_RUNNER_MIN_FREE_GB=999999999 RUNNER_WORKSPACE="$T/srv/box-spl-01/_work/app" bash "$T/srv/job-done.sh" >/dev/null 2>&1
[[ ! -e "$T/srv/box-spl-01/_work/app" && -d "$T/srv/box-spl-01/_work/_tool/go" && -d "$T/srv/box-spl-02/_work/app/app" ]] \
  && ok "cleanup prunes its own work dir, keeps _tool and the other runner's" || no "cleanup: $(find "$T/srv" -path '*_work*' -maxdepth 4)"
mkdir -p "$T/srv/box-spl-01/_work/app"
GH_RUNNER_MIN_FREE_GB=0 RUNNER_WORKSPACE="$T/srv/box-spl-01/_work/app" bash "$T/srv/job-done.sh" >/dev/null 2>&1
[[ -d "$T/srv/box-spl-01/_work/app" ]] && ok "cleanup keeps the work dir while there is room" || no "pruned with room to spare"

# a data root: new runner dirs live there, linked; existing ones stay put
GH_RUNNER_DATA_ROOT=data GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "relative data root must fail" || ok "a relative GH_RUNNER_DATA_ROOT is refused"
GH_RUNNER_DATA_ROOT="$T/srv" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "data root = root must fail" || ok "GH_RUNNER_DATA_ROOT equal to GH_RUNNER_ROOT is refused"
: >"$T/log"; : >"$RUN_LOG"
GH_RUNNER_DATA_ROOT="$T/data" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "apply with a data root over existing runners exits 0" || no "apply data root (kept) failed: $(tail -3 "$T/log")"
[[ ! -L "$T/srv/box-spl-01" && ! -L "$T/srv/box-spl-02" && ! -e "$T/data/box-spl-01" ]] && ! grep -q config.sh "$RUN_LOG" \
  && ok "an existing runner is never moved to the data root" || no "moved: $(ls -l "$T/srv" "$T/data" 2>&1)"
: >"$T/log"; : >"$RUN_LOG"
TEST_ROOT="$T/srv2" GH_RUNNER_DATA_ROOT="$T/data" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=1 act && ok "apply with a data root exits 0" || no "apply data root failed: $(tail -3 "$T/log")"
[[ -L "$T/srv2/box-spl-01" && "$(readlink "$T/srv2/box-spl-01")" == "$T/data/box-spl-01" && -s "$T/data/box-spl-01/.runner" && -s "$T/data/box-spl-01/.env" ]] \
  && grep -q '^box-spl-01 config.sh .*--name box-spl-01' "$RUN_LOG" && ok "a new runner's dir is in the data root, linked from the runner root" || no "linked: $(ls -l "$T/srv2" 2>&1)"
mkdir -p "$T/data/box-spl-01/_work/app/app" "$T/data/box-spl-01/_work/_tool/go" "$T/other/x/_work/app"
GH_RUNNER_MIN_FREE_GB=999999999 RUNNER_WORKSPACE="$T/data/box-spl-01/_work/app" bash "$T/srv2/job-done.sh" >/dev/null 2>&1
GH_RUNNER_MIN_FREE_GB=999999999 RUNNER_WORKSPACE="$T/other/x/_work/app" bash "$T/srv2/job-done.sh" >/dev/null 2>&1
[[ ! -e "$T/data/box-spl-01/_work/app" && -d "$T/data/box-spl-01/_work/_tool/go" && -d "$T/other/x/_work/app" ]] \
  && ok "cleanup prunes a linked runner's work dir, never a dir outside the runner root" || no "linked cleanup: $(find "$T/data" "$T/other" -path '*_work*' -maxdepth 5)"

# CPUWeight: unset = untouched; set = the user slice + every runner unit
grep -q set-property "$MUT_LOG" && no "set-property ran with no GH_RUNNER_CPU_WEIGHT" || ok "no GH_RUNNER_CPU_WEIGHT = weights untouched"
GH_RUNNER_CPU_WEIGHT=0 GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "weight 0 must fail" || ok "GH_RUNNER_CPU_WEIGHT out of 1..10000 is refused"
: >"$T/log"; : >"$MUT_LOG"
GH_RUNNER_CPU_WEIGHT=25 GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "apply with a CPU weight exits 0" || no "apply weight failed: $(tail -3 "$T/log")"
want="systemctl set-property user-1500.slice CPUWeight=25
systemctl set-property actions.runner.o.box-spl-01.service CPUWeight=25
systemctl set-property actions.runner.o.box-spl-02.service CPUWeight=25"
[[ "$(grep set-property "$MUT_LOG")" == "$want" ]] && ok "CPUWeight set on the runner user's slice and every runner unit" || no "weight: $(grep set-property "$MUT_LOG")"

# GH_RUNNER_GO_CACHE_ROOT: the Go cache lines in every .env; a reinstall
# without it keeps them (do_setup_ghrunner_go_cache wrote them)
GH_RUNNER_GO_CACHE_ROOT=rel GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g act && no "relative go cache root must fail" || ok "a relative GH_RUNNER_GO_CACHE_ROOT is refused"
: >"$T/log"; : >"$RUN_LOG"
GH_RUNNER_GO_CACHE_ROOT="$T/gocache" GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "apply with a Go cache root exits 0" || no "apply go cache failed: $(tail -3 "$T/log")"
grep -qx "GOCACHE=$T/gocache/go-build" "$T/srv/box-spl-02/.env" && grep -qx "GOMODCACHE=$T/gocache/go/pkg/mod" "$T/srv/box-spl-02/.env" \
  && grep -q "install $T/gocache/go$" "$MUT_LOG" && grep -q 'box-spl-02 svc.sh stop' "$RUN_LOG" && ok "the Go cache lines reach every .env, the dirs are made, the runner restarted" || no "go .env: $(cat "$T/srv/box-spl-02/.env")"
: >"$T/log"; : >"$RUN_LOG"
GH_RUNNER_REPO=o/app GH_RUNNER_GROUP=g APPLY=1 RUNNER_COUNT=2 act && ok "reinstall without a Go cache root exits 0" || no "reinstall failed: $(tail -3 "$T/log")"
grep -qx "GOPATH=$T/gocache/go" "$T/srv/box-spl-01/.env" && ! grep -q 'svc.sh stop' "$RUN_LOG" \
  && ok "a reinstall keeps the Go cache lines and restarts nothing" || no "kept go: $(cat "$T/srv/box-spl-01/.env" "$RUN_LOG")"

# the downloaded tarball's path is the only thing on stdout, even when do_log
# writes to stdout (the real one does: the path once carried the OK line)
mkdir -p "$T/tb"; echo fake >"$T/tb/actions-runner-linux-x64-9.9.9.tar.gz"
tb_sha="$(sha256sum "$T/tb/actions-runner-linux-x64-9.9.9.tar.gz" | cut -d' ' -f1)"
got="$( gh() { echo "v9.9.9 $tb_sha"; }
        do_log() { echo "$*"; }
        # shellcheck source=/dev/null
        source "$FUNC"; unset GH_RUNNER_TARBALL; GHR_ROOT="$T/tb" ghr_tarball 2>/dev/null )"
[[ "$got" == "$T/tb/actions-runner-linux-x64-9.9.9.tar.gz" ]] && ok "ghr_tarball prints only the tarball path on stdout" || no "ghr_tarball stdout: $got"

echo "=== gh-runner-add: $fails failure(s)"
[[ "$fails" -eq 0 ]]
