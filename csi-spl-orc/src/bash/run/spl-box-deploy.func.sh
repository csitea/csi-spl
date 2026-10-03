#!/bin/bash
#------------------------------------------------------------------------------
# @description Bring this Linux box from a main checkout to a running server
# @description side, and back (specs/071 section 5, lane B). It ORCHESTRATES
# @description the actions that exist and re-implements none of them:
# @description   install  1. the prerequisites of 5.1 (refuses, naming every
# @description               missing one); BOX_DEPLOY_PKGS=1 installs the
# @description               missing tools with the box's package manager
# @description            2. the spool binary through spl_host_spool
# @description            3. the crons through their own installers (3.2),
# @description               DRY_RUN passed through; the first that fails
# @description               stops the run and is named
# @description            4. POOL_CMD=start do_spl_pool_ctl (spec 071 lane A)
# @description            5. POOL_CMD=status: non-zero when a row is stopped
# @description   remove   POOL_CMD=stop, then each installer's remove action,
# @description            in reverse; the state dir, keys and spool root stay
# @description   check    read-only: each prerequisite's verdict, the binary
# @description            verdict, the plan, the tagged cron lines, the status
# @description Idempotent: a second install on a deployed box changes no
# @description crontab line and no binary, and says so. No literal host, user
# @description or domain: the box tag is spl_desk_box_default, the user $USER,
# @description the paths $HOME / $APP_PATH / $SPOOL_ROOT, the rest the cnf.
# @description Dry run unless DRY_RUN=0 (every installer then prints its plan).
# @param ENV - required: dev or prd
# @param BOX_DEPLOY_CMD (optional) - check (default) | install | remove
# @param DRY_RUN (optional) - 1 (default) or 0; check ignores it
# @param BOX_DEPLOY_TOOLS (optional) - the tools 5.1 needs, default
# @param   "python3 yq flock curl setsid tmux git go crontab"
# @param BOX_DEPLOY_PKGS (optional) - 1 installs the missing tools (sudo, the
# @param   box's package manager) and provisions a missing spool root; DRY_RUN=0 only
# @param BOX_DEPLOY_KEY (optional) - default $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json
# @param ROOT_KEY_JSON (optional) - the tenant root key, needed on a desk's first seat
# @param BOX_DEPLOY_CRONTAB (optional, tests) - the crontab command, default crontab
# @param BOX_DEPLOY_ALLOW_WORKTREE (optional, tests) - 1 accepts a linked worktree
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=dev ./run -a do_spl_box_deploy
# @example ENV=dev BOX_DEPLOY_CMD=install ./run -a do_spl_box_deploy
# @example ENV=dev BOX_DEPLOY_CMD=install DRY_RUN=0 ./run -a do_spl_box_deploy
# @example ENV=dev BOX_DEPLOY_CMD=remove DRY_RUN=0 ./run -a do_spl_box_deploy
#------------------------------------------------------------------------------
do_spl_box_deploy() {
  local cmd="${BOX_DEPLOY_CMD:-check}" dry="${DRY_RUN:-1}" v
  case "$cmd" in install|check|remove) ;; *) do_log "FATAL BOX_DEPLOY_CMD must be install, check or remove, got: '$cmd'"; return 1 ;; esac
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$cmd" == check ]] && dry=1
  for v in ENV HOME USER APP_PATH PROJ_PATH; do
    [[ -n "${!v:-}" ]] || { do_log "FATAL $v must be set (no default)"; return 1; }
  done
  spl_require_cloud_env || return 1
  local ct="${BOX_DEPLOY_CRONTAB:-crontab}" box before after rc=0
  box="$(spl_desk_box_default)"
  echo "BOX deploy $cmd: ENV=$ENV box=$box user=$USER APP_PATH=$APP_PATH SPOOL_ROOT=${SPOOL_ROOT:-/var/spool-hub} DRY_RUN=$dry"

  BOX_DEPLOY_REFUSED=""
  box_deploy_prereqs "$cmd" "$dry" || return 1

  if [[ "$cmd" == check ]]; then
    echo "STEP binary: $(spl_host_spool_verdict "$SPL_STATE_DIR/bin/spool")"
    echo "STEP installers: $(box_deploy_installers | tr '\n' ' ')"
    echo "STEP cron lines tagged csi-spl now:"
    { $ct -l 2>/dev/null || true; } | grep -o '# csi-spl:[a-z0-9:-]*$' | sed 's/^/  /'
    box_deploy_pool status 1 || true
    return 0
  fi

  before="$(box_deploy_fingerprint)"
  if [[ "$cmd" == remove ]]; then
    box_deploy_pool stop "$dry" || return 1
    box_deploy_run_installers remove "$dry" || return 1
  else
    box_deploy_binary "$dry" || return 1
    box_deploy_run_installers install "$dry" || return 1
    box_deploy_pool start "$dry" || return 1
    box_deploy_pool status "$dry" || rc=1
  fi
  after="$(box_deploy_fingerprint)"

  if [[ "$dry" == 1 ]]; then
    [[ "$before" == "$after" ]] || { do_log "FAIL DRY_RUN changed the crontab or the binary"; return 1; }
    [[ -z "$BOX_DEPLOY_REFUSED" ]] || { do_log "FAIL DRY_RUN nothing was touched, but a DRY_RUN=0 run refuses: missing$BOX_DEPLOY_REFUSED"; return 1; }
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return "$rc"
  fi
  if [[ "$before" == "$after" ]]; then
    echo "OK nothing changed: the crontab and the spool binary were already as $cmd leaves them"
  else
    echo "DONE changed: the crontab and/or the spool binary ($cmd)"
  fi
  [[ "$rc" == 0 ]] && do_log "OK box deploy $cmd done (ENV=$ENV, box $box)"
  return "$rc"
}

# box_deploy_fingerprint: the crontab and the spool binary (its .src stamp and
# mtime), so a run can say whether it changed either
box_deploy_fingerprint() {
  { ${BOX_DEPLOY_CRONTAB:-crontab} -l 2>/dev/null || true
    cat "$SPL_STATE_DIR/bin/spool.src" 2>/dev/null
    stat -c %Y "$SPL_STATE_DIR/bin/spool" 2>/dev/null; } | md5sum
}

# box_deploy_prereqs <cmd> <dry>: one "PREREQ <name> ok|missing|todo <detail>"
# line each (spec 071 5.1). install refuses when any is missing, naming every
# one (a DRY_RUN=1 install warns, plans on and fails at the end, into
# BOX_DEPLOY_REFUSED); remove needs the cnf only; check never refuses.
box_deploy_prereqs() {
  local cmd="$1" dry="$2" bad="" t missing gd cd branch key tmp
  local tools="${BOX_DEPLOY_TOOLS:-python3 yq flock curl setsid tmux git go crontab}"
  local root="${SPOOL_ROOT:-/var/spool-hub}"
  tmp="$(mktemp)"

  missing="$(box_deploy_missing_tools "$tools")"
  if [[ -n "$missing" && "${BOX_DEPLOY_PKGS:-0}" == 1 && "$cmd" == install ]]; then
    # shellcheck disable=SC2086
    box_deploy_install_pkgs "$dry" $missing || { rm -f "$tmp"; return 1; }
    [[ "$dry" == 0 ]] && missing="$(box_deploy_missing_tools "$tools")"
  fi
  if [[ -z "$missing" ]]; then echo "PREREQ tools ok $tools"
  else echo "PREREQ tools missing$(for t in $missing; do printf ' %s' "$t"; done) (BOX_DEPLOY_PKGS=1 installs them)"; bad+=" tools"; fi

  gd="$(git -C "$APP_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$APP_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  branch="$(git -C "$APP_PATH" symbolic-ref -q --short HEAD 2>/dev/null)"
  if [[ -z "$gd" ]]; then echo "PREREQ checkout missing $APP_PATH is not a git checkout"; bad+=" checkout"
  elif [[ "$gd" != "$cd" && "${BOX_DEPLOY_ALLOW_WORKTREE:-0}" != 1 ]]; then
    echo "PREREQ checkout missing $APP_PATH is a linked worktree: every installer refuses one, deploy from the main checkout"; bad+=" checkout"
  elif [[ "$gd" == "$cd" && "$branch" != "${DESK_CRON_TRUNK:-master}" ]]; then
    echo "PREREQ checkout missing $APP_PATH is on '${branch:-a detached HEAD}', not on ${DESK_CRON_TRUNK:-master}"; bad+=" checkout"
  else echo "PREREQ checkout ok $APP_PATH on ${branch:-a detached HEAD}"; fi

  # into variables, not through $(...): spl_desk_cron_src sets SPL_DESK_CRON_*
  if spl_desk_cron_src >"$tmp" 2>&1; then
    if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then echo "PREREQ cron-checkout todo $SPL_DESK_CRON_SRC (do_spl_desk_install_service creates it)"
    else echo "PREREQ cron-checkout ok $SPL_DESK_CRON_SRC"; fi
  else echo "PREREQ cron-checkout missing $(tr '\n' ' ' <"$tmp")"; bad+=" cron-checkout"; fi

  if [[ ! -d "$root" && "${BOX_DEPLOY_PKGS:-0}" == 1 && "$cmd" == install ]]; then
    if [[ "$dry" == 0 ]]; then do_provision_spool_root || { rm -f "$tmp"; do_log "FATAL do_provision_spool_root failed"; return 1; }
    else echo "PLAN spool-root: ./run -a do_provision_spool_root"; fi
  fi
  if [[ -d "$root" && -w "$root" ]]; then echo "PREREQ spool-root ok $root ($(stat -c '%a %U:%G' "$root"))"
  else echo "PREREQ spool-root missing $root does not exist or $USER cannot write it (./run -a do_provision_spool_root)"; bad+=" spool-root"; fi

  if do_spl_cloud_cnf >"$tmp" 2>&1; then echo "PREREQ cnf ok $SPL_CNF"
  else echo "PREREQ cnf missing $(tr '\n' ' ' <"$tmp")"; bad+=" cnf"; fi
  rm -f "$tmp"

  key="${BOX_DEPLOY_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-${SPL_ORG_APP:-}-$ENV.json}"
  if [[ -s "$key" ]]; then echo "PREREQ key ok $key (present; never read here)"
  else echo "PREREQ key missing $key"; bad+=" key"; fi
  if [[ -z "${ROOT_KEY_JSON:-}" ]]; then echo "PREREQ root-key todo ROOT_KEY_JSON unset (needed on a desk's first seat only)"
  elif [[ -s "$ROOT_KEY_JSON" ]]; then echo "PREREQ root-key ok $ROOT_KEY_JSON (present; never read here)"
  else echo "PREREQ root-key missing ROOT_KEY_JSON=$ROOT_KEY_JSON"; bad+=" root-key"; fi

  [[ -z "$bad" || "$cmd" == check ]] && return 0
  [[ "$cmd" == remove && "$bad" != *cnf* ]] && return 0
  if [[ "$dry" == 1 && "$bad" != *cnf* ]]; then
    echo "WARN missing prerequisite(s):$bad - a DRY_RUN=0 run refuses; the plan follows"
    BOX_DEPLOY_REFUSED="$bad"; return 0
  fi
  do_log "FATAL missing prerequisite(s):$bad - nothing changed"
  return 1
}

# box_deploy_missing_tools <tools>: the ones that do not resolve on the cron
# PATH, measured by the reconcile's own check (desk-reconcile-cron.sh
# --check-tools: the cron PATH plus the Go selector)
box_deploy_missing_tools() {
  local out
  out="$(DESK_CRON_TOOLS="$1" bash "$PROJ_PATH/src/bash/scripts/desk-reconcile-cron.sh" --check-tools 2>&1)" && return 0
  sed -n 's/.*these tools are not on the PATH: *//p' <<<"$out" | head -1
}

# box_deploy_install_pkgs <dry> <tool>...: the box's package manager, via sudo.
# go is the toolchain package; the Go selector then picks the newest go.
box_deploy_install_pkgs() {
  local dry="$1" t pm="" pkgs=""
  shift
  for t in apt-get dnf yum apk zypper; do command -v "$t" >/dev/null 2>&1 && { pm="$t"; break; }; done
  [[ -n "$pm" ]] || { do_log "FATAL no package manager found (apt-get dnf yum apk zypper): install $* by hand"; return 1; }
  for t in "$@"; do
    case "$t:$pm" in
      setsid:*|flock:*) t=util-linux ;;
      crontab:apt-get) t=cron ;;
      crontab:*) t=cronie ;;
      go:apt-get) t=golang-go ;;
      go:*) t=golang ;;
    esac
    [[ " $pkgs " == *" $t "* ]] || pkgs+=" $t"
  done
  if [[ "$dry" == 1 ]]; then echo "PLAN tools: sudo $pm install -y$pkgs"; return 0; fi
  echo "DO tools: sudo $pm install -y$pkgs"
  # shellcheck disable=SC2086
  sudo "$pm" install -y $pkgs || { do_log "FATAL sudo $pm install -y$pkgs failed"; return 1; }
}

# box_deploy_binary <dry>: step 2, the one build (spl_host_spool keeps a
# current binary and refuses a downgrade)
box_deploy_binary() {
  local verdict
  verdict="$(spl_host_spool_verdict "$SPL_STATE_DIR/bin/spool")"
  if [[ "$1" == 1 ]]; then echo "PLAN binary: spl_host_spool -> $SPL_STATE_DIR/bin/spool ($verdict)"; return 0; fi
  echo "DO binary: spl_host_spool ($verdict)"
  spl_host_spool || { do_log "FATAL step binary: spl_host_spool failed"; return 1; }
  echo "OK binary: $SPL_SPOOL"
}

# box_deploy_installers: the installers of spec 071 3.2 for this box, in
# install order. Once spec 068 L10 has applied (peer/crons.applied) the peer
# crons stand in for the two rotations and the sweep.
box_deploy_installers() {
  echo desk-service
  if [[ -e "${SPOOL_ROOT:-/var/spool-hub}/peer/crons.applied" ]]; then
    printf '%s\n' peer-restart peer-distill peer-ensure
  else
    printf '%s\n' unanswered-sweep orch-rotate dispatch-rotate
  fi
  printf '%s\n' agent-id-reap agent-identity agent-boot-restore box-crons weekly-full-scan
  if declare -F do_spl_pool_serve_install_cron >/dev/null; then echo pool-serve; fi
}

# box_deploy_run_installers <install|remove> <dry>: each installer in a
# subshell with its own action variable; remove goes in reverse
box_deploy_run_installers() {
  local act="$1" dry="$2" n
  local -a list=() rev=()
  mapfile -t list < <(box_deploy_installers)
  if [[ "$act" == remove ]]; then
    for ((n = ${#list[@]} - 1; n >= 0; n--)); do rev+=("${list[$n]}"); done
    list=("${rev[@]}")
  fi
  declare -F do_spl_pool_serve_install_cron >/dev/null || echo "SKIP installer pool-serve: not built yet (spec 070 L3)"
  for n in "${list[@]}"; do
    echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) installer $n ($act)"
    box_deploy_installer "$n" "$act" "$dry" || { do_log "FATAL installer $n ($act) failed - the run stops here"; return 1; }
  done
}

# box_deploy_installer <name> <install|remove> <dry>
box_deploy_installer() {
  local n="$1" act="$2" dry="$3" un=0
  [[ "$act" == remove ]] && un=1
  (
    export DRY_RUN="$dry" ENV
    case "$n" in
      desk-service) DESK_SERVICE_ACTION="$act" do_spl_desk_install_service ;;
      unanswered-sweep) SWEEP_CRON_ACTION="$act" do_spl_unanswered_sweep_install_cron ;;
      orch-rotate) ROTATE_CRON_ACTION="$act" do_spl_orch_rotate_install_cron ;;
      dispatch-rotate) ROTATE_CRON_ACTION="$act" do_spl_dispatch_rotate_install_cron ;;
      peer-restart) PEER_CRON_ACTION="$act" do_spl_peer_restart_install_cron ;;
      peer-distill) PEER_CRON_ACTION="$act" do_spl_peer_distill_install_cron ;;
      peer-ensure) PEER_CRON_ACTION="$act" do_spl_peer_ensure_install_cron ;;
      agent-id-reap) REAP_CRON_ACTION="$act" do_spl_agent_id_reap_install_cron ;;
      agent-identity) IDENTITY_UNINSTALL="$un" do_spl_agent_identity_install ;;
      agent-boot-restore) BOOT_CRON_ACTION="$act" do_spl_agent_boot_restore_install_cron ;;
      box-crons) BOX_CRONS_ACTION="$act" do_install_box_crons ;;
      weekly-full-scan)
        if ! declare -F do_install_weekly_full_scan_cron >/dev/null; then
          # shellcheck disable=SC1090
          source "$APP_PATH/${SPL_ORG_APP:?}-iac/src/bash/run/install-weekly-full-scan-cron.func.sh" || exit 1
        fi
        WEEKLY_SCAN_CRON_ACTION="$act" do_install_weekly_full_scan_cron ;;
      pool-serve) POOL_SERVE_CRON_ACTION="$act" do_spl_pool_serve_install_cron ;;
      *) do_log "FATAL unknown installer $n"; exit 1 ;;
    esac
  )
}

# box_deploy_pool <start|stop|status> <dry>: do_spl_pool_ctl by its contract
# (spec 071 section 4). status fails a DRY_RUN=0 run when a row is stopped.
box_deploy_pool() {
  local verb="$1" dry="$2" out rc bad
  if ! declare -F do_spl_pool_ctl >/dev/null; then
    if [[ "$dry" == 1 ]]; then echo "WARN pool $verb: do_spl_pool_ctl is not in this checkout yet (spec 071 lane A)"; return 0; fi
    do_log "FATAL pool $verb: do_spl_pool_ctl is not in this checkout yet (spec 071 lane A)"; return 1
  fi
  echo "$([[ "$dry" == 1 && "$verb" != status ]] && echo PLAN || echo DO) pool: ENV=$ENV POOL_CMD=$verb DRY_RUN=$dry do_spl_pool_ctl"
  out="$(export ENV DRY_RUN="$dry" POOL_CMD="$verb"; do_spl_pool_ctl 2>&1)"; rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  /'
  [[ "$rc" == 0 ]] || { do_log "FATAL pool $verb failed (rc $rc)"; return 1; }
  [[ "$verb" == status ]] || return 0
  bad="$(awk '$2 == "stopped" { printf " %s", $1 }' <<<"$out")"
  [[ -z "$bad" ]] && { echo "OK pool status: every row the box runs is running"; return 0; }
  [[ "$dry" == 1 ]] && { echo "INFO pool status: stopped now:$bad (DRY_RUN started nothing)"; return 0; }
  do_log "FAIL pool status: not running after start:$bad"
  return 1
}
