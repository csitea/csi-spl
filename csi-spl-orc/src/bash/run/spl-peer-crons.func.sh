#!/bin/bash
#------------------------------------------------------------------------------
# @description Switch this box's crontab from the role rotations to the peer
# @description crons (spec 068 section 6.2, lane L6), in ONE crontab write:
# @description   installs  `# csi-spl:peer-restart`  M,M+15,M+30,M+45 * * * *
# @description             `# csi-spl:peer-distill`  M+10,M+25,M+40,M+55 * * * *
# @description             `# csi-spl:peer-ensure`   * * * * *
# @description   removes   `# csi-spl:orch-rotate`, `# csi-spl:dispatch-rotate`,
# @description             `# csi-spl:unanswered-sweep`
# @description   cuts      the lease ensure and the dispatch tick out of the
# @description             desk reconcile: it writes <spool root>/peer/crons.applied,
# @description             which desk-reconcile-cron.sh reads
# @description Every other line is kept byte for byte. M = PEER_RESTART_OFFSET
# @description (0 on the first box, 7 on the second). The new crontab is held to
# @description the acceptance check of spec 068 section 8.1 (every command line
# @description resolves to a script inside a csi-spl checkout) and printed.
# @description DRY RUN unless APPLY=1: the before -> after diff, nothing
# @description touched. APPLY=1 is the staged hand-over's step (L10), with the
# @description owner's go; it refuses a box with no seat in <spool root>/peer/seats.
# @description PEER_CRONS_CMD=check runs only the 8.1 check on the live
# @description crontab of each of PEER_CRONS_CHECK_USERS (default: this user).
# @param APPLY (optional) - 0 (default, dry run) or 1
# @param PEER_CRONS_CMD (optional) - apply (default) | check
# @param PEER_CRONS_CHECK_USERS (optional) - the users whose crontab check reads (sudo -n crontab -l -u)
# @param PEER_CRONS_FORCE (optional) - 1 = APPLY=1 on a box with no seat
# @param PEER_RESTART_OFFSET (optional) - M, as do_spl_peer_restart
# @param PEER_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/peer
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @example ./run -a do_spl_peer_crons
# @example APPLY=1 ./run -a do_spl_peer_crons
# @example PEER_CRONS_CMD=check ./run -a do_spl_peer_crons
#------------------------------------------------------------------------------
declare -F spl_peer_restart_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-restart.func.sh"
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"

SPL_PEER_CRONS=(restart distill ensure)
SPL_PEER_CRONS_OLD=(orch-rotate dispatch-rotate unanswered-sweep)

do_spl_peer_crons() {
  local cmd="${PEER_CRONS_CMD:-apply}" apply="${APPLY:-0}" tmp name old marker bad=0
  case "$cmd" in apply|check) ;; *) do_log "FATAL PEER_CRONS_CMD must be apply or check, got: '$cmd'"; return 1 ;; esac
  [[ "$apply" == 0 || "$apply" == 1 ]] || { do_log "FATAL APPLY must be 0 or 1, got: '$apply'"; return 1; }
  do_require_bin crontab || return 1
  spl_peer_cron_prep || return 1
  [[ "$cmd" == check ]] && { spl_peer_cron_check_users; return; }

  tmp="$(mktemp -d)" || return 1
  crontab -l 2>/dev/null > "$tmp/before"
  cp "$tmp/before" "$tmp/after"
  for name in "${SPL_PEER_CRONS[@]}"; do
    spl_peer_cron_build "$name" || { rm -rf "$tmp"; return 1; }
    spl_desk_cron_render "$SPL_PEER_CRON_TAG" "$SPL_PEER_CRON_LINE" < "$tmp/after" > "$tmp/next" && mv -f "$tmp/next" "$tmp/after"
    printf '%s\n' "$SPL_PEER_CRON_SCRIPT" >> "$tmp/scripts"
    printf '%s\n' "$SPL_PEER_CRON_LOGDIR" >> "$tmp/logdirs"
  done
  for old in "${SPL_PEER_CRONS_OLD[@]}"; do
    spl_desk_cron_render "$SPL_ORG_APP:$old" "" < "$tmp/after" > "$tmp/next" && mv -f "$tmp/next" "$tmp/after"
  done
  marker="$PEER_DIR/crons.applied"

  echo "$([[ "$apply" == 1 ]] && echo DO || echo PLAN) cron: the crontab before -> after"
  diff -u --label before --label after "$tmp/before" "$tmp/after" | sed 's/^/  /' || true
  cmp -s "$tmp/before" "$tmp/after" && echo "  (no change)"
  echo "$([[ "$apply" == 1 ]] && echo DO || echo PLAN) desk-reconcile: $marker $([[ -e "$marker" ]] && echo "is there already" || echo "written"): its lease ensure and dispatch tick are cut (spec 068 6.2)"
  echo "---- spec 068 8.1 on the crontab after:"
  spl_peer_cron_8_1 "$tmp/after" | sed 's/^/  /' || true

  if [[ "$apply" == 0 ]]; then
    rm -rf "$tmp"
    do_log "OK DRY_RUN nothing was touched. The switch (the staged hand-over, with the owner's go): APPLY=1 ./run -a do_spl_peer_crons"
    return 0
  fi
  if [[ -z "$(spl_peer_seats)" && "${PEER_CRONS_FORCE:-0}" != 1 ]]; then
    rm -rf "$tmp"
    do_log "FATAL no seat in $PEER_SEATS: the peer crons would restart nobody while the role rotations are gone - nothing changed (PEER_CRONS_FORCE=1 overrides)"
    return 1
  fi
  if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "${DESK_CRON_TRUNK:-master}" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$SPL_DESK_CRON_SRC" "origin/${DESK_CRON_TRUNK:-master}" ||
      { rm -rf "$tmp"; do_log "FATAL could not create the self-updating checkout $SPL_DESK_CRON_SRC - nothing changed"; return 1; }
  fi
  while IFS= read -r name; do
    [[ -x "$name" ]] || { do_log "FATAL $name is missing or not executable (is it on trunk yet?) - nothing changed"; bad=1; }
  done < "$tmp/scripts"
  while IFS= read -r name; do
    mkdir -p "$name" 2>/dev/null || { do_log "FATAL cannot create $name - nothing changed"; bad=1; }
  done < "$tmp/logdirs"
  (( bad == 0 )) || { rm -rf "$tmp"; return 1; }
  if ! crontab "$tmp/after"; then rm -rf "$tmp"; do_log "FATAL crontab refused the new file - nothing changed"; return 1; fi
  crontab -l 2>/dev/null > "$tmp/read"
  if ! cmp -s "$tmp/after" "$tmp/read"; then
    rm -rf "$tmp"; do_log "FATAL the crontab does not read back what was written"; return 1
  fi
  mkdir -p "$PEER_DIR" && echo "applied $(date -u +%FT%TZ) by do_spl_peer_crons" > "$marker" ||
    { rm -rf "$tmp"; do_log "FATAL the crontab is switched, but $marker could not be written: the desk reconcile still runs the lease steps"; return 1; }
  rm -rf "$tmp"
  do_log "OK the peer crons are in, the role rotations and the sweep are out, the desk reconcile's lease steps are cut"
}

# ---- shared by do_spl_peer_crons and the three _install_cron actions -------------

# SPL_ORG_APP, the seats file, PEER_RESTART_OFFSET and the checkout the lines
# point at (spl_desk_cron_src: <shared checkout>-desk-cron; a worktree is refused).
spl_peer_cron_prep() {
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  spl_peer_init ro || return 1
  spl_peer_restart_conf || return 1
  [[ "${DESK_CRON_TRUNK:-master}" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '${DESK_CRON_TRUNK:-}'"; return 1; }
  spl_desk_cron_src || return 1
}

# spl_peer_cron_sched NAME: the five cron fields of a peer cron.
spl_peer_cron_sched() {
  local m="$PEER_RESTART_OFFSET"
  case "$1" in
    restart) echo "$m,$((m + 15)),$((m + 30)),$((m + 45)) * * * *" ;;
    distill) echo "$(printf '%s\n' $(( (m + 10) % 60 )) $(( (m + 25) % 60 )) $(( (m + 40) % 60 )) $(( (m + 55) % 60 )) | sort -n | paste -sd,) * * * *" ;;
    ensure)  echo "* * * * *" ;;
    *) return 1 ;;
  esac
}

# spl_peer_cron_build NAME: SPL_PEER_CRON_LINE / _TAG / _SCRIPT / _LOGDIR.
# restart and distill move the checkout to trunk first, as the rotations did;
# ensure does not: a fetch every minute buys nothing the desk reconcile's
# five-minute one does not already.
spl_peer_cron_build() {
  local name="$1" sched pre="" trunk="${DESK_CRON_TRUNK:-master}"
  sched="$(spl_peer_cron_sched "$name")" || { do_log "FATAL no peer cron named '$name'"; return 1; }
  SPL_PEER_CRON_TAG="$SPL_ORG_APP:peer-$name"
  SPL_PEER_CRON_SCRIPT="$SPL_DESK_CRON_SRC/$SPL_ORG_APP-orc/src/bash/scripts/peer-$name-cron.sh"
  SPL_PEER_CRON_LOGDIR="${PEER_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/peer}"
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 && "$name" != ensure ]] &&
    pre="cd $SPL_DESK_CRON_SRC && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  SPL_PEER_CRON_LINE="$sched $pre$SPL_PEER_CRON_SCRIPT >> $SPL_PEER_CRON_LOGDIR/$name.out 2>&1 # $SPL_PEER_CRON_TAG"
}

# spl_peer_cron_install NAME: the body of do_spl_peer_<name>_install_cron.
# PEER_CRON_ACTION install (default) | remove | check (CRON_REMOVE=1 =
# remove); the tagged line replaced in place, never appended; dry run unless
# DRY_RUN=0.
spl_peer_cron_install() {
  local name="$1" act="${PEER_CRON_ACTION:-install}" current ran
  do_require_bin crontab || return 1
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in install|remove|check) ;; *) do_log "FATAL PEER_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_peer_cron_prep || return 1
  spl_peer_cron_build "$name" || return 1
  current="$(spl_desk_cron_line "$SPL_PEER_CRON_TAG")"

  if [[ "$act" == check ]]; then
    [[ -n "$current" ]] || { do_log "FAIL peer-$name is NOT installed (no line tagged $SPL_PEER_CRON_TAG)"; return 1; }
    spl_desk_cron_say "$current"
    ran="$(spl_desk_cron_script "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
    [[ "$current" == "$SPL_PEER_CRON_LINE" ]] || do_log "INFO installed with other settings than this call would write - working"
    do_log "OK peer-$name is installed and its script is executable"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_desk_cron_diff "$SPL_PEER_CRON_TAG" "$([[ "$act" == install ]] && printf '%s' "$SPL_PEER_CRON_LINE")"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$SPL_PEER_CRON_TAG" "" || return 1
    do_log "OK peer-$name is out of the crontab"
    return 0
  fi
  if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "${DESK_CRON_TRUNK:-master}" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$SPL_DESK_CRON_SRC" "origin/${DESK_CRON_TRUNK:-master}" ||
      { do_log "FATAL could not create the self-updating checkout $SPL_DESK_CRON_SRC"; return 1; }
  fi
  [[ -x "$SPL_PEER_CRON_SCRIPT" ]] || { do_log "FATAL $SPL_PEER_CRON_SCRIPT is missing or not executable (is it on trunk yet?)"; return 1; }
  mkdir -p "$SPL_PEER_CRON_LOGDIR" 2>/dev/null || { do_log "FATAL cannot create $SPL_PEER_CRON_LOGDIR"; return 1; }
  spl_desk_cron_write "$SPL_PEER_CRON_TAG" "$SPL_PEER_CRON_LINE" || return 1
  current="$(spl_desk_cron_line "$SPL_PEER_CRON_TAG")"
  [[ "$current" == "$SPL_PEER_CRON_LINE" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK peer-$name is installed as the box user:"
  spl_desk_cron_say "$SPL_PEER_CRON_LINE"
}

# ---- spec 068 section 8.1: every OD script is in the project source ---------------

# spl_peer_cron_script_of LINE: the script a crontab line runs: the first
# absolute *.sh / *.bash / *.py (quotes dropped), else a ./x after a `cd <dir>`
# resolved against that dir, else the first absolute path that is no
# directory; nothing when there is none.
spl_peer_cron_script_of() {
  local t cd_dir="" prev="" first=""
  set -f
  for t in $1; do
    t="${t//\'/}"; t="${t//\"/}"
    case "$t" in
      /*.sh|/*.bash|/*.py) set +f; printf '%s' "$t"; return 0 ;;
    esac
    [[ "$prev" == cd && "$t" == /* ]] && cd_dir="$t"
    if [[ -z "$first" ]]; then
      if [[ "$t" == ./* && -n "$cd_dir" ]]; then first="$cd_dir/${t#./}"
      elif [[ "$t" == /* && "$prev" != cd && ! -d "$t" ]]; then first="$t"; fi
    fi
    prev="$t"
  done
  set +f
  [[ -n "$first" ]] && printf '%s' "$first"
  return 0
}

# spl_peer_cron_8_1 FILE: one "FAIL 8.1 line N: <why>: <line>" per command
# line of a crontab whose script does not resolve (readlink -f) inside a
# checkout of this repo (its toplevel holds <org>-<app>-orc), then a summary
# line. Comments, blank lines and VAR=value lines are no commands. 0 = none failed.
spl_peer_cron_8_1() {
  local line n=0 bad=0 total=0 s r top why
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) || "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    total=$((total + 1)) why=""
    s="$(spl_peer_cron_script_of "$line")"
    if [[ -z "$s" ]]; then
      why="no script path"
    else
      r="$(readlink -f "$s" 2>/dev/null || true)"
      if [[ -z "$r" || ! -e "$r" ]]; then
        why="$s resolves nowhere"
      else
        top="$(git -c safe.directory='*' -C "$(dirname "$r")" rev-parse --show-toplevel 2>/dev/null || true)"
        [[ -n "$top" && -d "$top/$SPL_ORG_APP-orc" && "$r" == "$top"/* ]] || why="$r is in no $SPL_ORG_APP checkout"
      fi
    fi
    if [[ -n "$why" ]]; then bad=$((bad + 1)); printf 'FAIL 8.1 line %s: %s: %s\n' "$n" "$why" "$line"; fi
  done < "$1"
  printf '%s 8.1 %s command line(s), %s failing\n' "$( ((bad)) && echo FAIL || echo OK)" "$total" "$bad"
  (( bad == 0 ))
}

# The 8.1 check on the live crontab of each of PEER_CRONS_CHECK_USERS
# (default this user), read-only.
spl_peer_cron_check_users() {
  local u me rc=0 tmp
  me="$(id -un)"
  tmp="$(mktemp)" || return 1
  for u in ${PEER_CRONS_CHECK_USERS:-$me}; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || { do_log "FATAL not a user name: '$u'"; rm -f "$tmp"; return 1; }
    # shellcheck disable=SC2024 # the redirect writes OUR temp file, as this user, on purpose
    if [[ "$u" == "$me" ]]; then crontab -l > "$tmp" 2>/dev/null || : > "$tmp"
    else sudo -n crontab -l -u "$u" > "$tmp" 2>/dev/null || { echo "FAIL 8.1 cannot read the crontab of $u (sudo -n crontab -l -u $u)"; rc=1; continue; }
    fi
    echo "---- spec 068 8.1, the crontab of $u:"
    spl_peer_cron_8_1 "$tmp" | sed 's/^/  /'
    spl_peer_cron_8_1 "$tmp" >/dev/null || rc=1
  done
  rm -f "$tmp"
  return "$rc"
}
