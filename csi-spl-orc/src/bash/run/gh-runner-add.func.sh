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
# @description Idempotent: a runner already configured here is kept (its env
# @description refreshed, its service started); APPLY twice = one set.
# @description Dry run unless APPLY=1. Needs sudo and gh with admin:org.
# @param GH_RUNNER_REPO - required: <owner>/<repo> the runners serve (the org is <owner>)
# @param GH_RUNNER_GROUP - required: the org runner group they join
# @param RUNNER_COUNT (optional) - how many runners this box carries, default 2
# @param GH_RUNNER_USER (optional) - the dedicated OS user, default ghrunner
# @param GH_RUNNER_ROOT (optional) - runner dirs, default /srv/gh-runner
# @param GH_RUNNER_HOME (optional) - the user's home, default /var/lib/<user>
# @param GH_RUNNER_MIN_FREE_GB (optional) - prune below this, default 8
# @param GH_RUNNER_TARBALL (optional) - a local actions-runner-linux-x64 tarball
# @param APPLY (optional) - 1 to do it; anything else prints the plan only
# @example GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> ./run -a do_gh_runner_add
# @example GH_RUNNER_REPO=<owner>/<repo> GH_RUNNER_GROUP=<group> APPLY=1 RUNNER_COUNT=2 ./run -a do_gh_runner_add
#------------------------------------------------------------------------------

# the debian packages rootless docker needs (dockerd-rootless-setuptool.sh
# ships with docker.io)
GH_RUNNER_PKGS="rootlesskit uidmap slirp4netns"
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
# drop stopped containers. Under MIN_FREE_GB free: this runner's OWN work dir
# (never the other runner's - it may be mid-job) and dangling docker objects.
# The persistent HOME caches (go, pnpm) stay - the workflows count on them.
MIN_FREE_GB="${GH_RUNNER_MIN_FREE_GB:-8}"
root="$(cd "$(dirname "$0")" && pwd)"
free_gb() { df -P --block-size=1G "$root" | awk 'NR==2{print $4}'; }
docker container prune -f --filter until=1h >/dev/null 2>&1
(( $(free_gb) < MIN_FREE_GB )) || exit 0
echo "gh-runner-cleanup: under ${MIN_FREE_GB}G free on $root, pruning"
ws="${RUNNER_WORKSPACE:-${GITHUB_WORKSPACE%/*}}"
w="${ws%/*}"
[[ "$w" == "$root"/*/_work ]] \
  && find "$w" -mindepth 1 -maxdepth 1 ! -name _tool ! -name _actions -exec rm -rf {} + 2>/dev/null
docker image prune -f >/dev/null 2>&1
docker builder prune -f >/dev/null 2>&1
echo "gh-runner-cleanup: $(free_gb)G free after"
exit 0
HOOK
}

do_gh_runner_add() {
  do_require_bin gh systemctl sudo curl tar sha256sum || return 1
  local repo="${GH_RUNNER_REPO:-}" group="${GH_RUNNER_GROUP:-}" n="${RUNNER_COUNT:-2}"
  local user="${GH_RUNNER_USER:-ghrunner}" root="${GH_RUNNER_ROOT:-/srv/gh-runner}"
  local min_free="${GH_RUNNER_MIN_FREE_GB:-8}" apply=0
  GH_RUNNER_HOME="${GH_RUNNER_HOME:-/var/lib/$user}"
  [[ "${APPLY:-0}" == 1 ]] && apply=1
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { do_log "FATAL GH_RUNNER_REPO must be <owner>/<repo> (no default)"; return 1; }
  [[ -n "$group" ]] || { do_log "FATAL GH_RUNNER_GROUP must be set (no default): the org runner group"; return 1; }
  [[ "$n" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL RUNNER_COUNT must be 1..99, got: $n"; return 1; }
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != root ]] || { do_log "FATAL bad GH_RUNNER_USER: $user"; return 1; }
  [[ "$min_free" =~ ^[0-9]+$ ]] || { do_log "FATAL GH_RUNNER_MIN_FREE_GB must be a number"; return 1; }
  local org="${repo%%/*}" branch gid g labels names

  # 1. the group: restricted to selected workflows of the default branch only
  branch="$(gh api "repos/$repo" --jq .default_branch)" && [[ -n "$branch" ]] \
    || { do_log "FATAL cannot read $repo"; return 1; }
  gid="$(gh api "orgs/$org/actions/runner-groups" --paginate --jq ".runner_groups[]|select(.name==\"$group\")|.id")"
  [[ -n "$gid" ]] || { do_log "FATAL no runner group '$group' in org $org"; return 1; }
  g="$(gh api "orgs/$org/actions/runner-groups/$gid" \
        --jq '"\(.visibility) \(.restricted_to_workflows) \(.selected_workflows|length) \([.selected_workflows[]|select(endswith("@refs/heads/'"$branch"'")|not)]|length)"')"
  [[ "$g" =~ ^selected\ true\ [1-9][0-9]*\ 0$ ]] \
    || { do_log "FATAL runner group $group must be visibility=selected, restricted to selected workflows, every one @refs/heads/$branch (got: $g)"; return 1; }
  do_log "OK runner group $group (id $gid): selected repos, workflows pinned to @refs/heads/$branch only"

  # 2. labels: copied from the runners already in the group, which must agree
  labels="$(gh api "orgs/$org/actions/runner-groups/$gid/runners" --paginate \
             --jq '.runners[]|[.labels[]|select(.type=="custom")|.name]|sort|join(",")' | sort -u)"
  [[ -n "$labels" && "$labels" != *$'\n'* ]] \
    || { do_log "FATAL the runners of $group must carry ONE custom label set, got: ${labels:-none}"; return 1; }
  names="$(gh api "orgs/$org/actions/runner-groups/$gid/runners" --paginate --jq '.runners[].name')"
  do_log "OK labels to copy (custom, from the runners already in $group): $labels"

  # 3. the plan, per runner: kept (configured here) or new
  local i name dir todo=()
  for ((i = 1; i <= n; i++)); do
    name="$(ghr_name "$i")"; dir="$root/$name"
    if sudo test -s "$dir/.runner"; then
      do_log "INFO $name: configured in $dir - kept"
    else
      grep -qx "$name" <<<"$names" && do_log "WARN $name is registered on GitHub but not configured here - it will be replaced"
      do_log "INFO $name: new, in $dir, user $user, labels $labels, group $group"
      todo+=("$name")
    fi
  done
  if ((!apply)); then
    do_log "INFO DRY_RUN would ensure: packages $GH_RUNNER_PKGS; user $user (home $GH_RUNNER_HOME 0700, no sudo, not in docker, linger, rootless docker); job-completed cleanup under ${min_free}G free; ${#todo[@]} new runner(s): ${todo[*]:-none}"
    do_log "OK DRY_RUN nothing changed. Re-run with APPLY=1."
    return 0
  fi

  # 4. the box: packages, user, rootless docker
  local p missing=()
  for p in $GH_RUNNER_PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null \
      || { do_log "FATAL apt-get install ${missing[*]} failed"; return 1; }
    do_log "OK installed ${missing[*]}"
  fi
  if ! id -u "$user" >/dev/null 2>&1; then
    sudo useradd --system --create-home --home-dir "$GH_RUNNER_HOME" --shell /bin/bash --add-subids-for-system "$user" \
      || { do_log "FATAL useradd $user failed"; return 1; }
    do_log "OK created user $user"
  fi
  sudo chmod 0700 "$GH_RUNNER_HOME" || return 1
  id -nG "$user" | tr ' ' '\n' | grep -qxE 'docker|sudo|adm|root|wheel' \
    && { do_log "FATAL $user is in a privileged group ($(id -nG "$user")) - a runner must not be root-equivalent"; return 1; }
  sudo -l -U "$user" 2>/dev/null | grep -q 'may run' \
    && { do_log "FATAL $user has sudo rights - remove them"; return 1; }
  grep -q "^$user:" /etc/subuid && grep -q "^$user:" /etc/subgid \
    || sudo usermod --add-subuids 1000000-1065535 --add-subgids 1000000-1065535 "$user" \
    || { do_log "FATAL cannot give $user a subuid range"; return 1; }
  sudo loginctl enable-linger "$user" || { do_log "FATAL loginctl enable-linger $user failed"; return 1; }
  local uid t=0; uid="$(id -u "$user")"
  until sudo test -S "/run/user/$uid/bus" || ((t++ >= 20)); do sleep 1; done
  if ! ghr_as "$user" systemctl --user is-active --quiet docker; then
    # its exit code is not the verdict: debian's copy ends with
    # `$BIN/docker version`, $BIN being contrib/, where no docker is - so it
    # fails AFTER writing and starting the unit. The unit being active is.
    ghr_as "$user" "$GH_RUNNER_SETUPTOOL" install >/dev/null 2>&1
    ghr_as "$user" systemctl --user enable --now docker >/dev/null 2>&1
    ghr_as "$user" systemctl --user is-active --quiet docker \
      || { do_log "FATAL rootless docker setup failed for $user: sudo -u $user XDG_RUNTIME_DIR=/run/user/$uid $GH_RUNNER_SETUPTOOL install"; return 1; }
    do_log "OK rootless docker running for $user"
  fi
  ghr_as "$user" env DOCKER_HOST="unix:///run/user/$uid/docker.sock" docker info >/dev/null 2>&1 \
    || { do_log "FATAL $user's rootless docker does not answer"; return 1; }

  # 5. the runner tarball (once, sha256-verified) and the cleanup hook
  sudo install -d -m 0755 -o root -g root "$root" || return 1
  local tarball="${GH_RUNNER_TARBALL:-}"
  if ((${#todo[@]})) && [[ -z "$tarball" ]]; then
    local rel ver sha url
    rel="$(gh api repos/actions/runner/releases/latest --jq '"\(.tag_name) \(.body|capture("BEGIN SHA linux-x64 -->(?<s>[0-9a-f]{64})<").s)"')" \
      || { do_log "FATAL cannot read the actions/runner release"; return 1; }
    ver="${rel%% *}"; ver="${ver#v}"; sha="${rel#* }"
    tarball="$root/actions-runner-linux-x64-$ver.tar.gz"
    url="https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-x64-$ver.tar.gz"
    sudo test -s "$tarball" || sudo curl -fsSL -o "$tarball" "$url" \
      || { do_log "FATAL download $url failed"; return 1; }
    echo "$sha  $tarball" | sudo sha256sum -c --quiet - \
      || { sudo rm -f "$tarball"; do_log "FATAL sha256 mismatch for $tarball"; return 1; }
    do_log "OK runner v$ver tarball verified (sha256 $sha)"
  fi
  ghr_job_done_hook | sudo tee "$root/job-done.sh" >/dev/null && sudo chmod 0755 "$root/job-done.sh" || return 1

  # 6. each new runner: unpack, register (the token is never logged)
  local tok
  for name in "${todo[@]}"; do
    dir="$root/$name"
    sudo install -d -m 0700 -o "$user" -g "$user" "$dir" \
      && sudo -u "$user" tar -xzf "$tarball" -C "$dir" || { do_log "FATAL cannot unpack into $dir"; return 1; }
    tok="$(gh api -X POST "orgs/$org/actions/runners/registration-token" --jq .token)" \
      && ghr_in "$dir" "$user" ./config.sh --unattended --replace --url "https://github.com/$org" \
           --token "$tok" --name "$name" --labels "$labels" --runnergroup "$group" --work _work >/dev/null \
      || { tok=""; do_log "FATAL cannot register $name"; return 1; }
    tok=""
    do_log "OK $name registered in $group"
  done

  # 7. every runner: env (restart when it changed), service installed + started
  local envf
  envf="$(printf '%s\n' "DOCKER_HOST=unix:///run/user/$uid/docker.sock" "XDG_RUNTIME_DIR=/run/user/$uid" \
    "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$root/job-done.sh" "GH_RUNNER_MIN_FREE_GB=$min_free" \
    "LANG=C.UTF-8" "PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin")"
  for ((i = 1; i <= n; i++)); do
    name="$(ghr_name "$i")"; dir="$root/$name"
    if [[ "$(sudo cat "$dir/.env" 2>/dev/null)" != "$envf" ]]; then
      sudo -u "$user" tee "$dir/.env" >/dev/null <<<"$envf" || return 1
      sudo test -s "$dir/.service" && ghr_in "$dir" root ./svc.sh stop >/dev/null
    fi
    if ! sudo test -s "$dir/.service"; then
      ghr_in "$dir" root ./svc.sh install "$user" >/dev/null || { do_log "FATAL svc.sh install failed for $name"; return 1; }
    fi
    ghr_in "$dir" root ./svc.sh start >/dev/null || { do_log "FATAL $name's service did not start"; return 1; }
  done

  # 8. verify on GitHub
  local online up; t=0
  while :; do
    online="$(gh api "orgs/$org/actions/runner-groups/$gid/runners" --paginate --jq '.runners[]|select(.status=="online")|.name')"
    up=0
    for ((i = 1; i <= n; i++)); do grep -qx "$(ghr_name "$i")" <<<"$online" && up=$((up + 1)); done
    ((up == n || t++ >= 12)) && break
    sleep 5
  done
  ((up == n)) || { do_log "FATAL only $up of $n runners of this box are online in $group"; return 1; }
  do_log "OK $n runner(s) of this box online in $group with labels $labels"
}
