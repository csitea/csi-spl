#!/bin/bash
#------------------------------------------------------------------------------
# @description Register N self-hosted GitHub Actions runners on THIS box (spec
# @description 064 L3): org runners in GH_RUNNER_GROUP, the same restricted
# @description runner group and the same custom labels as the runners already
# @description in it (read from the GitHub API, never typed in), as systemd
# @description units. Names are <short hostname>-spl-NN.
# @description Isolation: every runner runs as ONE dedicated OS user
# @description (GH_RUNNER_USER) with a 0700 home, no sudo and NOT in the
# @description `docker` group (that group is root on the box, so it could read
# @description any key); its jobs get a ROOTLESS docker daemon of their own.
# @description Disk: a job-completed hook removes stopped containers and, when
# @description the runner root has under GH_RUNNER_MIN_FREE_GB free, that
# @description runner's own work dir (re-cloned next job) and dangling docker
# @description images / build cache. Persistent HOME caches are left alone.
# @description The group must be restricted to selected workflows, each pinned
# @description to @refs/heads/<default branch> (spec 044 FR-OS-005: no PR job
# @description reaches a self-hosted runner) - otherwise it refuses.
# @description Warm: the images 10_ci-quality.yml pins (its img= lines) are
# @description pulled into the runner user's docker, so no gate SKIPs cold.
# @description Boot: the rootless docker user unit is enabled (linger brings
# @description up only enabled units) and every runner unit restarts after an
# @description exit (drop-in Restart=always); do_check_gh_runner checks both.
# @description Idempotent: a runner already configured here is kept (its env
# @description refreshed, its service started); APPLY twice = one set.
# @description Dry run unless APPLY=1. Needs sudo and gh with admin:org.
# @param GH_RUNNER_REPO - required: <owner>/<repo> the runners serve (the org is <owner>)
# @param GH_RUNNER_GROUP - required: the org runner group they join
# @param RUNNER_COUNT (optional) - how many runners this box carries, default 2
# @param GH_RUNNER_USER (optional) - the dedicated OS user, default ghrunner
# @param GH_RUNNER_ROOT (optional) - runner dirs, default /srv/gh-runner
# @param GH_RUNNER_DATA_ROOT (optional) - a NEW runner's dir is made here (a
# @param   bigger disk) and linked from GH_RUNNER_ROOT/<name>; existing runners
# @param   stay where they are. Default: none, new dirs go in GH_RUNNER_ROOT
# @param GH_RUNNER_HOME (optional) - the user's home, default /var/lib/<user>
# @param GH_RUNNER_GO_CACHE_ROOT (optional) - the runners' Go caches live here
# @param   (GOCACHE <root>/go-build, GOPATH <root>/go), set in every runner's
# @param   .env and made as the runner user. Default: none, a runner keeps the
# @param   GO* lines its .env already has (do_setup_ghrunner_go_cache's)
# @param GH_RUNNER_MIN_FREE_GB (optional) - prune below this, default 8
# @param GH_RUNNER_CPU_WEIGHT (optional) - 1..10000: the systemd CPUWeight of
# @param   every runner unit and of the runner user's slice (its rootless
# @param   docker), set live and kept (systemctl set-property). Below the
# @param   default 100, a box that also hosts agent lanes gives them the CPU
# @param   first when it is saturated; an idle CPU is still all the runners'.
# @param   Default: none, the weights are left as they are
# @param GH_RUNNER_UNIT_DIR (optional) - where the slice drop-ins go, default
# @param   /etc/systemd/system. Every runner unit is placed in the runner
# @param   user's slice (Slice=user-<uid>.slice), the one cgroup that
# @param   do_apply_gh_runner_cpu_budget gives its CPUQuota
# @param GH_RUNNER_TARBALL (optional) - a local actions-runner-linux-x64 tarball
# @param GH_RUNNER_WORKFLOW (optional) - the workflow whose img= pins are warmed
# @param APPLY (optional) - 1 to do it; anything else prints the plan only
# @example GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> ./run -a do_gh_runner_add
# @example GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> APPLY=1 RUNNER_COUNT=2 ./run -a do_gh_runner_add
# @example GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> GH_RUNNER_DATA_ROOT=<data-disk>/gh-runner APPLY=1 RUNNER_COUNT=6 ./run -a do_gh_runner_add
#------------------------------------------------------------------------------

# the debian packages rootless docker needs (dockerd-rootless-setuptool.sh
# ships with docker.io), and the fonts the browser e2e draws in: the WUI ships
# no webfont, so a box with only DejaVu lays every card out wider than the
# others (card-edge-inset red on sat-spl-* only, 2026-10-03); Liberation Sans
# is that test's MEASURE_FONT
declare -F ghrb_place >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/apply-gh-runner-cpu-budget.func.sh"

GH_RUNNER_PKGS="rootlesskit uidmap slirp4netns fonts-noto-core fonts-liberation"
GH_RUNNER_SETUPTOOL="${GH_RUNNER_SETUPTOOL:-/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh}"

# ghr_as <user> <cmd...> - run as the runner user, on its own systemd --user bus
ghr_as() {
  local u="$1" uid; shift
  uid="$(id -u "$u")"
  sudo -u "$u" env HOME="$GH_RUNNER_HOME" XDG_RUNTIME_DIR="/run/user/$uid" \
    PATH="/usr/share/docker.io/contrib:/usr/bin:/bin:/usr/sbin:/sbin" "$@"
}

# ghr_in <dir> <user|root> <cmd...> - run inside a runner dir (0700, its user)
ghr_in() {
  local dir="$1" user="$2"; shift 2
  sudo -u "$user" bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

# ghr_name <i> - the runner name of slot i on this box
ghr_name() { printf '%s-spl-%02d' "$(hostname -s)" "$1"; }

# ghr_job_done_hook - the job-completed hook (runs as the runner user)
ghr_job_done_hook() {
  cat <<'HOOK'
#!/bin/bash
# job-completed hook of the self-hosted runners (do_gh_runner_add). Always:
# drop stopped containers. Under MIN_FREE_GB free (on the root's disk or on
# the work dir's, which differ for a runner linked into a data disk): this
# runner's OWN work dir (never the other runner's - it may be mid-job) and
# dangling docker objects. The persistent HOME caches (go, pnpm) stay - the
# workflows count on them.
MIN_FREE_GB="${GH_RUNNER_MIN_FREE_GB:-8}"
root="$(cd "$(dirname "$0")" && pwd)"
free_gb() { df -P --block-size=1G "$1" | awk 'NR==2{print $4}'; }
docker container prune -f --filter until=1h >/dev/null 2>&1
ws="${RUNNER_WORKSPACE:-${GITHUB_WORKSPACE%/*}}"
w="${ws%/*}"
low=0
(( $(free_gb "$root") < MIN_FREE_GB )) && low=1
[[ -d "$w" ]] && (( $(free_gb "$w") < MIN_FREE_GB )) && low=1
((low)) || exit 0
echo "gh-runner-cleanup: under ${MIN_FREE_GB}G free, pruning"
# only a work dir of a runner of this root, also when that runner is a link
n="${w%/_work}"; n="${n##*/}"
[[ "$w" == */_work && -n "$n" && -d "$w" && "$(readlink -f "$root/$n/_work")" == "$(readlink -f "$w")" ]] \
  && find "$w" -mindepth 1 -maxdepth 1 ! -name _tool ! -name _actions -exec rm -rf {} + 2>/dev/null
docker image prune -f >/dev/null 2>&1
docker builder prune -f >/dev/null 2>&1
echo "gh-runner-cleanup: $(free_gb "$root")G free on $root after"
exit 0
HOOK
}

# The steps below share the GHR_* variables do_gh_runner_add sets.

# ghr_check_group - the group is restricted to selected workflows of the
# default branch only (FR-OS-005); sets GHR_GID, GHR_LABELS (copied from the
# runners already in it, which must agree) and GHR_NAMES
ghr_check_group() {
  local branch g
  branch="$(gh api "repos/$GHR_REPO" --jq .default_branch)" && [[ -n "$branch" ]] \
    || { do_log "FATAL cannot read $GHR_REPO"; return 1; }
  GHR_GID="$(gh api "orgs/$GHR_ORG/actions/runner-groups" --paginate --jq ".runner_groups[]|select(.name==\"$GHR_GROUP\")|.id")"
  [[ -n "$GHR_GID" ]] || { do_log "FATAL no runner group '$GHR_GROUP' in org $GHR_ORG"; return 1; }
  g="$(gh api "orgs/$GHR_ORG/actions/runner-groups/$GHR_GID" \
        --jq '"\(.visibility) \(.restricted_to_workflows) \(.selected_workflows|length) \([.selected_workflows[]|select(endswith("@refs/heads/'"$branch"'")|not)]|length)"')"
  [[ "$g" =~ ^selected\ true\ [1-9][0-9]*\ 0$ ]] \
    || { do_log "FATAL runner group $GHR_GROUP must be visibility=selected, restricted to selected workflows, every one @refs/heads/$branch (got: $g)"; return 1; }
  do_log "OK runner group $GHR_GROUP (id $GHR_GID): selected repos, workflows pinned to @refs/heads/$branch only"
  GHR_LABELS="$(gh api "orgs/$GHR_ORG/actions/runner-groups/$GHR_GID/runners" --paginate \
             --jq '.runners[]|[.labels[]|select(.type=="custom")|.name]|sort|join(",")' | sort -u)"
  [[ -n "$GHR_LABELS" && "$GHR_LABELS" != *$'\n'* ]] \
    || { do_log "FATAL the runners of $GHR_GROUP must carry ONE custom label set, got: ${GHR_LABELS:-none}"; return 1; }
  GHR_NAMES="$(gh api "orgs/$GHR_ORG/actions/runner-groups/$GHR_GID/runners" --paginate --jq '.runners[].name')"
  do_log "OK labels to copy (custom, from the runners already in $GHR_GROUP): $GHR_LABELS"
}

# ghr_plan - per runner: kept (configured here) or new (into GHR_TODO)
ghr_plan() {
  local i name dir
  GHR_TODO=()
  for ((i = 1; i <= GHR_N; i++)); do
    name="$(ghr_name "$i")"; dir="$GHR_ROOT/$name"
    if sudo test -s "$dir/.runner"; then
      do_log "INFO $name: configured in $dir - kept"
    else
      grep -qx "$name" <<<"$GHR_NAMES" && do_log "WARN $name is registered on GitHub but not configured here - it will be replaced"
      do_log "INFO $name: new, in $dir${GHR_DATA_ROOT:+ -> $GHR_DATA_ROOT/$name}, user $GHR_USER, labels $GHR_LABELS, group $GHR_GROUP"
      GHR_TODO+=("$name")
    fi
  done
}

# ghr_setup_user - packages, the dedicated user (never root-equivalent),
# linger, its rootless docker; sets GHR_UID
ghr_setup_user() {
  local p missing=() u="$GHR_USER" t=0
  for p in $GH_RUNNER_PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null \
      || { do_log "FATAL apt-get install ${missing[*]} failed"; return 1; }
    do_log "OK installed ${missing[*]}"
  fi
  if ! id -u "$u" >/dev/null 2>&1; then
    sudo useradd --system --create-home --home-dir "$GH_RUNNER_HOME" --shell /bin/bash --add-subids-for-system "$u" \
      || { do_log "FATAL useradd $u failed"; return 1; }
    do_log "OK created user $u"
  fi
  sudo chmod 0700 "$GH_RUNNER_HOME" || return 1
  id -nG "$u" | tr ' ' '\n' | grep -xE 'docker|sudo|adm|root|wheel' >/dev/null \
    && { do_log "FATAL $u is in a privileged group ($(id -nG "$u")) - a runner must not be root-equivalent"; return 1; }
  sudo -l -U "$u" 2>/dev/null | grep 'may run' >/dev/null && { do_log "FATAL $u has sudo rights - remove them"; return 1; }
  grep -q "^$u:" /etc/subuid && grep -q "^$u:" /etc/subgid \
    || sudo usermod --add-subuids 1000000-1065535 --add-subgids 1000000-1065535 "$u" \
    || { do_log "FATAL cannot give $u a subuid range"; return 1; }
  sudo loginctl enable-linger "$u" || { do_log "FATAL loginctl enable-linger $u failed"; return 1; }
  GHR_UID="$(id -u "$u")"
  until sudo test -S "/run/user/$GHR_UID/bus" || ((t++ >= 20)); do sleep 1; done
  if ! ghr_as "$u" systemctl --user is-active --quiet docker; then
    # its exit code is not the verdict: debian's copy ends with
    # `$BIN/docker version`, $BIN being contrib/, where no docker is - so it
    # fails AFTER writing and starting the unit. The unit being active is.
    ghr_as "$u" "$GH_RUNNER_SETUPTOOL" install >/dev/null 2>&1
    ghr_as "$u" systemctl --user enable --now docker >/dev/null 2>&1
    ghr_as "$u" systemctl --user is-active --quiet docker \
      || { do_log "FATAL rootless docker setup failed for $u: sudo -u $u XDG_RUNTIME_DIR=/run/user/$GHR_UID $GH_RUNNER_SETUPTOOL install"; return 1; }
    do_log "OK rootless docker running for $u"
  fi
  # ENABLED, not only running: linger starts the user manager at boot, but it
  # brings up only enabled units (sat 2026-10-08: docker started by hand once,
  # disabled, so after the reboot every job hit "Cannot connect")
  if ! ghr_as "$u" systemctl --user is-enabled --quiet docker; then
    ghr_as "$u" systemctl --user enable docker >/dev/null 2>&1
    if ! ghr_as "$u" systemctl --user is-enabled --quiet docker; then
      do_log "FATAL cannot enable $u's rootless docker unit: it would not come back after a boot"; return 1
    fi
    do_log "OK rootless docker of $u enabled: it starts at boot"
  fi
  ghr_docker docker info >/dev/null 2>&1 || { do_log "FATAL $u's rootless docker does not answer"; return 1; }
}

# ghr_docker <cmd...> - run against the runner user's rootless docker
ghr_docker() { ghr_as "$GHR_USER" env DOCKER_HOST="unix:///run/user/$GHR_UID/docker.sock" "$@"; }

# ghr_warm_images - pull every image the self-hosted workflow pins (its
# `img=` lines) into the runner user's docker: a gate that finds no cached
# image SKIPS, and CI turns a skip into a failure (hub-pg on a fresh runner)
ghr_warm_images() {
  local wf="${GH_RUNNER_WORKFLOW:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../.github/workflows/10_ci-quality.yml}"
  local img i imgs
  [[ -f "$wf" ]] || { do_log "WARN no workflow at $wf - no image warmed"; return 0; }
  imgs="$(sed -nE 's/^[[:space:]]*img=([A-Za-z0-9._\/-]+:[A-Za-z0-9._-]+)[[:space:]]*$/\1/p' "$wf" | sort -u)"
  for img in $imgs; do
    ghr_docker docker image inspect "$img" >/dev/null 2>&1 && continue
    for i in 1 2 3; do ghr_docker docker pull -q "$img" >/dev/null 2>&1 && break; sleep $((i * 10)); done
    ghr_docker docker image inspect "$img" >/dev/null 2>&1 || { do_log "FATAL cannot pull $img for $GHR_USER"; return 1; }
    do_log "OK $img cached for $GHR_USER"
  done
}

# ghr_tarball - echo a sha256-verified runner tarball (downloaded once); its
# log lines go to stderr: the caller captures stdout as the path
ghr_tarball() {
  [[ -n "${GH_RUNNER_TARBALL:-}" ]] && { echo "$GH_RUNNER_TARBALL"; return 0; }
  local rel ver sha url tarball
  rel="$(gh api repos/actions/runner/releases/latest --jq '"\(.tag_name) \(.body|capture("BEGIN SHA linux-x64 -->(?<s>[0-9a-f]{64})<").s)"')" \
    || { do_log "FATAL cannot read the actions/runner release" >&2; return 1; }
  ver="${rel%% *}"; ver="${ver#v}"; sha="${rel#* }"
  tarball="$GHR_ROOT/actions-runner-linux-x64-$ver.tar.gz"
  url="https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-x64-$ver.tar.gz"
  sudo test -s "$tarball" || sudo curl -fsSL --connect-timeout 30 --max-time 1800 --speed-limit 1024 --speed-time 60 -o "$tarball" "$url" \
    || { do_log "FATAL download $url failed" >&2; return 1; }
  echo "$sha  $tarball" | sudo sha256sum -c --quiet - \
    || { sudo rm -f "$tarball"; do_log "FATAL sha256 mismatch for $tarball" >&2; return 1; }
  do_log "OK runner v$ver tarball verified (sha256 $sha)" >&2
  echo "$tarball"
}

# ghr_register - unpack + register each GHR_TODO runner (token never logged)
ghr_register() {
  ((${#GHR_TODO[@]})) || return 0
  local tarball name dir tok
  tarball="$(ghr_tarball)" || return 1
  for name in "${GHR_TODO[@]}"; do
    dir="$GHR_ROOT/$name"
    if [[ -n "$GHR_DATA_ROOT" ]] && ! sudo test -e "$dir"; then
      sudo install -d -m 0755 -o root -g root "$GHR_DATA_ROOT" \
        && sudo install -d -m 0700 -o "$GHR_USER" -g "$GHR_USER" "$GHR_DATA_ROOT/$name" \
        && sudo ln -s "$GHR_DATA_ROOT/$name" "$dir" || { do_log "FATAL cannot link $dir to $GHR_DATA_ROOT/$name"; return 1; }
    fi
    sudo install -d -m 0700 -o "$GHR_USER" -g "$GHR_USER" "$dir" \
      && sudo -u "$GHR_USER" tar -xzf "$tarball" -C "$dir" || { do_log "FATAL cannot unpack into $dir"; return 1; }
    tok="$(gh api -X POST "orgs/$GHR_ORG/actions/runners/registration-token" --jq .token)" \
      && ghr_in "$dir" "$GHR_USER" ./config.sh --unattended --replace --url "https://github.com/$GHR_ORG" \
           --token "$tok" --name "$name" --labels "$GHR_LABELS" --runnergroup "$GHR_GROUP" --work _work >/dev/null \
      || { tok=""; do_log "FATAL cannot register $name"; return 1; }
    tok=""
    do_log "OK $name registered in $GHR_GROUP"
  done
}

# ghr_go_env_lines <root> - the .env lines that put the Go caches in <root>
ghr_go_env_lines() {
  printf '%s\n' "GOCACHE=$1/go-build" "GOPATH=$1/go" "GOMODCACHE=$1/go/pkg/mod"
}

# ghr_go_dirs <user> <root> - make the Go cache dirs, owned by the runner user
ghr_go_dirs() {
  sudo install -d -m 0755 -o "$1" -g "$1" "$2" "$2/go-build" "$2/go" \
    || { do_log "FATAL cannot make the Go cache dirs in $2 for $1"; return 1; }
}

# ghr_go_env_of <dir> - the Go cache lines a runner's .env should carry:
# GH_RUNNER_GO_CACHE_ROOT's when set, else the ones it already has (a
# reinstall keeps what do_setup_ghrunner_go_cache wrote)
ghr_go_env_of() {
  if [[ -n "${GH_RUNNER_GO_CACHE_ROOT:-}" ]]; then
    ghr_go_env_lines "$GH_RUNNER_GO_CACHE_ROOT"
  else
    sudo cat "$1/.env" 2>/dev/null | grep -E '^(GOCACHE|GOPATH|GOMODCACHE)=' || true
  fi
}

# ghr_services - every runner: .env (restart when it changed), service
# installed + started
ghr_services() {
  local i name dir envf base go
  base="$(printf '%s\n' "DOCKER_HOST=unix:///run/user/$GHR_UID/docker.sock" "XDG_RUNTIME_DIR=/run/user/$GHR_UID" \
    "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$GHR_ROOT/job-done.sh" "GH_RUNNER_MIN_FREE_GB=$GHR_MIN_FREE" \
    "LANG=C.UTF-8" "PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin")"
  if [[ -n "${GH_RUNNER_GO_CACHE_ROOT:-}" ]]; then ghr_go_dirs "$GHR_USER" "$GH_RUNNER_GO_CACHE_ROOT" || return 1; fi
  for ((i = 1; i <= GHR_N; i++)); do
    name="$(ghr_name "$i")"; dir="$GHR_ROOT/$name"
    go="$(ghr_go_env_of "$dir")"
    envf="$base${go:+$'\n'$go}"
    if [[ "$(sudo cat "$dir/.env" 2>/dev/null)" != "$envf" ]]; then
      sudo -u "$GHR_USER" tee "$dir/.env" >/dev/null <<<"$envf" || return 1
      sudo test -s "$dir/.service" && ghr_in "$dir" root ./svc.sh stop >/dev/null
    fi
    if ! sudo test -s "$dir/.service"; then
      ghr_in "$dir" root ./svc.sh install "$GHR_USER" >/dev/null || { do_log "FATAL svc.sh install failed for $name"; return 1; }
    fi
    ghr_in "$dir" root ./svc.sh start >/dev/null || { do_log "FATAL $name's service did not start"; return 1; }
  done
}

# ghr_slice - every runner unit in the runner user's slice, beside its rootless
# docker, so one CPUQuota there (do_apply_gh_runner_cpu_budget) holds all CI
ghr_slice() {
  local i unit; local -a units=()
  for ((i = 1; i <= GHR_N; i++)); do
    unit="$(sudo cat "$GHR_ROOT/$(ghr_name "$i")/.service")"
    [[ "$unit" == actions.runner.*.service ]] || { do_log "FATAL no unit for $(ghr_name "$i") (${unit:-no .service})"; return 1; }
    units+=("$unit")
  done
  DRY_RUN=0 CPU_BUDGET_UNIT_DIR="${GH_RUNNER_UNIT_DIR:-/etc/systemd/system}" ghrb_init &&
    ghrb_place "user-$GHR_UID.slice" "${units[@]}"
}

# ghr_restart - every runner unit restarts after its service exits by itself
# (the runner's service script exits 0 when its listener does), a drop-in
# written only when it differs, one daemon-reload, no restart (a reload is
# enough for Restart=). A `systemctl stop` (the CPU budget parking a runner,
# a person) is never undone by it: systemd restarts only an exit
ghr_restart() {
  local i unit d want reload=0
  want="$(printf '[Service]\nRestart=always\nRestartSec=30')"
  d="${GH_RUNNER_UNIT_DIR:-/etc/systemd/system}"
  for ((i = 1; i <= GHR_N; i++)); do
    unit="$(sudo cat "$GHR_ROOT/$(ghr_name "$i")/.service")"
    [[ "$unit" == actions.runner.*.service ]] || { do_log "FATAL no unit for $(ghr_name "$i") (${unit:-no .service})"; return 1; }
    [[ "$(sudo cat "$d/$unit.d/60-restart.conf" 2>/dev/null)" == "$want" ]] && continue
    if ! { sudo mkdir -p "$d/$unit.d" && sudo tee "$d/$unit.d/60-restart.conf" >/dev/null <<<"$want"; }; then
      do_log "FATAL cannot write the restart drop-in of $unit"; return 1
    fi
    reload=1
  done
  ((reload)) || return 0
  sudo systemctl daemon-reload || { do_log "FATAL daemon-reload failed"; return 1; }
  do_log "OK every runner unit restarts after an exit (Restart=always, RestartSec=30)"
}

# ghr_cpu_weight - GHR_CPU_WEIGHT on every runner unit and the runner user's
# slice; nothing when it is unset
ghr_cpu_weight() {
  [[ -n "$GHR_CPU_WEIGHT" ]] || return 0
  local i unit
  sudo systemctl set-property "user-$GHR_UID.slice" CPUWeight="$GHR_CPU_WEIGHT" \
    || { do_log "FATAL cannot set CPUWeight on user-$GHR_UID.slice"; return 1; }
  for ((i = 1; i <= GHR_N; i++)); do
    unit="$(sudo cat "$GHR_ROOT/$(ghr_name "$i")/.service")"
    [[ "$unit" == actions.runner.*.service ]] && sudo systemctl set-property "$unit" CPUWeight="$GHR_CPU_WEIGHT" \
      || { do_log "FATAL cannot set CPUWeight on the unit of $(ghr_name "$i") (${unit:-no .service})"; return 1; }
  done
  do_log "OK CPUWeight $GHR_CPU_WEIGHT on user-$GHR_UID.slice and $GHR_N runner unit(s)"
}

# ghr_verify - every runner of this box is online in the group
ghr_verify() {
  local online up i t=0
  while :; do
    online="$(gh api "orgs/$GHR_ORG/actions/runner-groups/$GHR_GID/runners" --paginate --jq '.runners[]|select(.status=="online")|.name')"
    up=0
    for ((i = 1; i <= GHR_N; i++)); do grep -qx "$(ghr_name "$i")" <<<"$online" && up=$((up + 1)); done
    ((up == GHR_N || t++ >= 12)) && break
    sleep 5
  done
  ((up == GHR_N)) || { do_log "FATAL only $up of $GHR_N runners of this box are online in $GHR_GROUP"; return 1; }
  do_log "OK $GHR_N runner(s) of this box online in $GHR_GROUP with labels $GHR_LABELS"
}

do_gh_runner_add() {
  do_require_bin gh systemctl sudo curl tar sha256sum || return 1
  GHR_REPO="${GH_RUNNER_REPO:-}" GHR_GROUP="${GH_RUNNER_GROUP:-}" GHR_N="${RUNNER_COUNT:-2}"
  GHR_USER="${GH_RUNNER_USER:-ghrunner}" GHR_ROOT="${GH_RUNNER_ROOT:-/srv/gh-runner}"
  GHR_DATA_ROOT="${GH_RUNNER_DATA_ROOT:-}" GHR_CPU_WEIGHT="${GH_RUNNER_CPU_WEIGHT:-}"
  GHR_MIN_FREE="${GH_RUNNER_MIN_FREE_GB:-8}" GH_RUNNER_HOME="${GH_RUNNER_HOME:-/var/lib/$GHR_USER}"
  [[ "$GHR_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { do_log "FATAL GH_RUNNER_REPO must be <owner>/<repo> (no default)"; return 1; }
  [[ -n "$GHR_GROUP" ]] || { do_log "FATAL GH_RUNNER_GROUP must be set (no default): the org runner group"; return 1; }
  [[ "$GHR_N" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL RUNNER_COUNT must be 1..99, got: $GHR_N"; return 1; }
  [[ "$GHR_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$GHR_USER" != root ]] || { do_log "FATAL bad GH_RUNNER_USER: $GHR_USER"; return 1; }
  [[ "$GHR_MIN_FREE" =~ ^[0-9]+$ ]] || { do_log "FATAL GH_RUNNER_MIN_FREE_GB must be a number"; return 1; }
  [[ -z "$GHR_DATA_ROOT" || ( "$GHR_DATA_ROOT" == /* && "$GHR_DATA_ROOT" != "$GHR_ROOT" ) ]] \
    || { do_log "FATAL GH_RUNNER_DATA_ROOT must be an absolute path other than GH_RUNNER_ROOT"; return 1; }
  [[ -z "$GHR_CPU_WEIGHT" || ( "$GHR_CPU_WEIGHT" =~ ^[1-9][0-9]{0,4}$ && "$GHR_CPU_WEIGHT" -le 10000 ) ]] \
    || { do_log "FATAL GH_RUNNER_CPU_WEIGHT must be 1..10000, got: $GHR_CPU_WEIGHT"; return 1; }
  [[ -z "${GH_RUNNER_GO_CACHE_ROOT:-}" || ( "$GH_RUNNER_GO_CACHE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$GH_RUNNER_GO_CACHE_ROOT" != *..* ) ]] \
    || { do_log "FATAL GH_RUNNER_GO_CACHE_ROOT must be an absolute path, got: $GH_RUNNER_GO_CACHE_ROOT"; return 1; }
  GHR_ORG="${GHR_REPO%%/*}"
  ghr_check_group || return 1
  ghr_plan
  if [[ "${APPLY:-0}" != 1 ]]; then
    do_log "INFO DRY_RUN would ensure: packages $GH_RUNNER_PKGS; user $GHR_USER (home $GH_RUNNER_HOME 0700, no sudo, not in docker, linger, rootless docker enabled at boot, workflow images cached); runner units Restart=always; job-completed cleanup under ${GHR_MIN_FREE}G free; Go caches in ${GH_RUNNER_GO_CACHE_ROOT:-the current .env of each runner}; CPUWeight ${GHR_CPU_WEIGHT:-unchanged}; units in user-<uid>.slice; ${#GHR_TODO[@]} new runner(s): ${GHR_TODO[*]:-none}"
    do_log "OK DRY_RUN nothing changed. Re-run with APPLY=1."
    return 0
  fi
  ghr_setup_user && ghr_warm_images || return 1
  sudo install -d -m 0755 -o root -g root "$GHR_ROOT" || return 1
  ghr_job_done_hook | sudo tee "$GHR_ROOT/job-done.sh" >/dev/null && sudo chmod 0755 "$GHR_ROOT/job-done.sh" || return 1
  ghr_register && ghr_services && ghr_slice && ghr_restart && ghr_cpu_weight && ghr_verify
}
