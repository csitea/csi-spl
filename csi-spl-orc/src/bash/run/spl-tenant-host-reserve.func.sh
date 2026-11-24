#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 158 H4 (10.4 item 1, owner scope change of 2026-11-24): a
# @description new hidden workspace gets its private-overlay placeholder with no
# @description person, minutes after the create in the WUI. Runs only on the
# @description overlay's master box (SPL_PRIVATE_MASTER_BOX, default sat; any
# @description other box is refused, it pulls instead), from a cron every
# @description minute (do_spl_private_overlay_install_cron). One pass:
# @description   1. read the open tenant_hosts rows of each env (RESERVE_ENVS)
# @description      as the env SA, with the reconcile's own filters: pending
# @description      or failed, not unpaid, not suspended / archived, not an
# @description      e2e* slug, not the apex, not listed in the env cnf
# @description   2. each such row with no placeholder: spl_private_add under
# @description      its lock, the line stamped `# reserved <ts>`
# @description   3. a reservation not yet published (this run's or an earlier
# @description      run's that failed after the add, <state>/unpublished):
# @description      do_spl_private_overlay_sync (the box's other user), then
# @description      `gh secret set SPL_PRIVATE_CNF_YAML` from stdin, then the
# @description      secret's updated_at is read back and must be this run's
# @description   4. the reserved rows' detail: `placeholder reserved <ts>`
# @description   5. a reserved row past HOST_RESERVE_HOLD (the other boxes
# @description      have pulled it) dispatches workflow 40 for its env once,
# @description      so the host is built now, not at the next 15-minute
# @description      schedule (which stays the backstop); a refused dispatch
# @description      only warns
# @description The token is read from RESERVE_GH_TOKEN_FILE, no default: a
# @description fine-grained token, this repo, secrets write (+ actions write
# @description for step 5), minted by the owner (spec 158 OD2). It goes to gh
# @description in its environment, never argv or a log. No log line names a
# @description hidden slug: counts and placeholders only. Dry run unless
# @description DRY_RUN=0: it reads the rows and says what it would do.
# @param RESERVE_GH_TOKEN_FILE (optional) - the token file; needed with DRY_RUN=0
# @param RESERVE_ENVS (optional) - the envs read, default "dev prd"
# @param RESERVE_GH_REPO (optional) - owner/repo, default from git remote origin
# @param RESERVE_STATE_DIR (optional) - default <var>/<org>/<app>/tenant-host-reserve
# @param HOST_RESERVE_HOLD (optional) - minutes before the dispatch, default 5 (as the reconcile)
# @param SPL_PRIVATE_MASTER_BOX (optional) - default sat
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_tenant_host_reserve
# @example RESERVE_GH_TOKEN_FILE=<token file> DRY_RUN=0 ./run -a do_spl_tenant_host_reserve
#------------------------------------------------------------------------------
do_spl_tenant_host_reserve() {
  do_require_bin yq psql flock gh || return 1
  local dry=1 master="${SPL_PRIVATE_MASTER_BOX:-sat}" here state repo tok_file="" tmp rc=0 e
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  here="$(spl_desk_box_default)"
  [[ "$here" == "$master" ]] ||
    { do_log "FATAL this box ($here) does not hold the master private overlay (box $master): it reserves nothing. Here the overlay is pulled: cd csi-spl-orc && DRY_RUN=0 FROM_BOX=$master ./run -a do_spl_private_overlay_pull"; return 1; }
  spl_th_private_lib && spl_private_require || return 1
  if (( ! dry )); then tok_file="$(spl_thr_token_file)" || return 1; fi
  repo="$(spl_thr_repo)" || return 1
  state="${RESERVE_STATE_DIR:-}"
  [[ -n "$state" ]] || spl_var_app_subdir state tenant-host-reserve ||
    { do_log "FATAL cannot derive the reserve state dir (no tree for spl_run_paths): set RESERVE_STATE_DIR"; return 1; }
  mkdir -p "$state" || { do_log "FATAL cannot create $state"; return 1; }
  exec {SPL_THR_LOCK_FD}>"$state/reserve.lock" || return 1
  flock -n "$SPL_THR_LOCK_FD" || { do_log "INFO another reserve run holds $state/reserve.lock: this one does nothing"; return 0; }
  tmp="$(mktemp -d)" || return 1
  local envs="${RESERVE_ENVS:-dev prd}"
  for e in $envs; do
    [[ "$e" == dev || "$e" == prd ]] || { do_log "FATAL RESERVE_ENVS lists '$e': dev and prd only"; rm -rf "$tmp"; return 1; }
    ( export ENV="$e"; spl_thr_env_read "$tmp" ) || { do_log "WARN $e: open rows not read, nothing reserved there this run"; rc=1; }
  done
  spl_thr_reserve_all "$tmp" "$dry" "$envs" "$state" || { rm -rf "$tmp"; return 1; }
  local pub=0
  spl_thr_publish "$state" "$dry" "$repo" "$tok_file" "$tmp" || { rm -rf "$tmp"; return 1; }
  [[ -f "$tmp/published" ]] && pub=1
  for e in $envs; do
    [[ -f "$tmp/rows.$e" ]] || continue
    if (( ! dry && pub )); then ( export ENV="$e"; spl_thr_mark "$tmp" ) || rc=1; fi
    spl_thr_dispatch "$state" "$tmp" "$e" "$dry" "$repo" "$tok_file"
  done
  rm -rf "$tmp"
  (( rc == 0 )) && do_log "OK tenant host reserve pass done ($envs)"
  return "$rc"
}

# spl_thr_token_file -> RESERVE_GH_TOKEN_FILE when it is a readable, non-empty
# file closed to its group and other users (mode 600 or 400); FATAL naming what is missing (spec 158 OD2: the
# owner mints the token, nothing here asks for or stores one)
spl_thr_token_file() {
  local f="${RESERVE_GH_TOKEN_FILE:-}"
  [[ -n "$f" ]] || { do_log "FATAL RESERVE_GH_TOKEN_FILE is not set (no default): the owner's fine-grained token (this repo, secrets write) is read from it, spec 158 OD2. Nothing reserved" >&2; return 1; }
  [[ -r "$f" && -s "$f" && ! -L "$f" ]] || { do_log "FATAL RESERVE_GH_TOKEN_FILE $f is missing, empty, unreadable or a symlink. Nothing reserved" >&2; return 1; }
  [[ "$(stat -c %a "$f")" =~ ^[46]00$ ]] || { do_log "FATAL RESERVE_GH_TOKEN_FILE $f is open to its group or other users (mode $(stat -c %a "$f"), 600 or 400 only): chmod 600 it. Nothing reserved" >&2; return 1; }
  printf '%s\n' "$f"
}

# spl_thr_repo -> owner/repo: RESERVE_GH_REPO, else the origin remote's path
spl_thr_repo() {
  local r="${RESERVE_GH_REPO:-$(git -C "$APP_PATH" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { do_log "FATAL no owner/repo for the secret (RESERVE_GH_REPO, or a github origin remote), got '$r'" >&2; return 1; }
  printf '%s\n' "$r"
}

# spl_thr_gh <token file> <gh args...>: gh with the token in its environment only
spl_thr_gh() {
  local f="$1"; shift
  GH_TOKEN="$(<"$f")" GH_PROMPT_DISABLED=1 gh "$@"
}

# spl_thr_env_read <tmp> (in a subshell with ENV set): the env's open rows to
# <tmp>/rows.<env>, and the slugs that need a placeholder to <tmp>/cand.<env>.
# A failed read logs a fixed line and its rc only: psql / proxy text may name a
# hidden slug, and this runs from cron
spl_thr_env_read() {
  local tmp="$1" cnf rows tag t st bill act age rrc=0
  do_spl_cloud_cnf || return 1
  cnf="$(spl_th_cnf_file)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  rows="$(spl_via_proxy _spl_th_open_rows 2>/dev/null)" || rrc=$?
  (( rrc == 0 )) || { do_log "WARN $ENV: the open rows read failed (rc $rrc; its output withheld, it may name a hidden slug)"; return 1; }
  : >"$tmp/cand.$ENV"
  while read -r tag t st bill act age; do
    [[ "$tag" == row && -n "$t" ]] || continue
    printf '%s %s %s %s %s\n' "$t" "$st" "$bill" "$act" "$age" >>"$tmp/rows.$ENV"
    spl_thr_open_paid "$st" "$bill" "$act" "$t" || continue
    spl_th_is_apex "$cnf" "$t" && continue
    { spl_th_cnf_has "$cnf" "$t" || spl_th_docs_has "$cnf" "$t"; } && continue
    spl_th_new_hidden "$t" && printf '%s\n' "$t" >>"$tmp/cand.$ENV"
  done <<<"$rows"
  touch "$tmp/rows.$ENV"
}

# spl_thr_open_paid <status> <billing> <active> <slug>: the reconcile would add
# this row (pending / failed, paid, on, a valid non-e2e slug)
spl_thr_open_paid() {
  [[ "$1" == pending || "$1" == failed ]] && [[ "$2" != unpaid && "$3" == on && "$4" != e2e* ]] &&
    [[ "$4" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
}

# spl_thr_reserve_all <tmp> <dry> <envs> <state>: each candidate gets its
# stamped placeholder (spl_private_add, under the overlay lock), and
# <state>/unpublished is touched BEFORE the add, so a run that dies after it
# still publishes next time. The dry run counts them.
spl_thr_reserve_all() {
  local tmp="$1" dry="$2" envs="$3" state="$4" e t tok n ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  : >"$tmp/reserved"
  for e in $envs; do
    [[ -s "$tmp/cand.$e" ]] || continue
    n="$(sort -u "$tmp/cand.$e" | wc -l)"
    if (( dry )); then do_log "INFO DRY_RUN $e: would reserve a placeholder for $n new hidden workspace(s)"; continue; fi
    while read -r t; do
      touch "$state/unpublished" || return 1
      tok="$(spl_private_add "$t" "reserved $ts")" || { do_log "FATAL $e: the overlay add failed (nothing published)"; return 1; }
      do_log "INFO $e: $tok reserved $ts in the private overlay"
    done < <(sort -u "$tmp/cand.$e")
  done
  return 0
}

# spl_thr_publish <state> <dry> <repo> <token file> <tmp>: while a reservation
# is unpublished (<state>/unpublished), sync the box's other user, set the
# secret from stdin and read its
# updated_at back. Touches <tmp>/published on success.
spl_thr_publish() {
  local state="$1" dry="$2" repo="$3" tf="$4" tmp="$5" f t0 up
  f="$(spl_private_cnf_path)"
  [[ -e "$state/unpublished" ]] || return 0
  if (( dry )); then do_log "INFO DRY_RUN a reservation is unpublished: would sync the box users and set secret SPL_PRIVATE_CNF_YAML of $repo"; return 0; fi
  if [[ -z "${SPL_PRIVATE_CNF:-}" ]]; then
    DRY_RUN=0 SYNC_FROM_USER="$(id -un)" do_spl_private_overlay_sync || { do_log "FATAL the box users' overlays are not equal: secret not set"; return 1; }
  fi
  t0="$(date -u +%s)"
  spl_thr_gh "$tf" secret set SPL_PRIVATE_CNF_YAML -R "$repo" <"$f" >/dev/null ||
    { do_log "FATAL gh secret set SPL_PRIVATE_CNF_YAML ($repo) failed: CI does not know the new placeholder; retried next run"; return 1; }
  up="$(spl_thr_gh "$tf" api "repos/$repo/actions/secrets/SPL_PRIVATE_CNF_YAML" --jq .updated_at 2>/dev/null)"
  up="$(date -u -d "$up" +%s 2>/dev/null)" && (( up >= t0 - 1 )) ||
    { do_log "FATAL the secret's updated_at ($up) is not this run's ($t0): not confirmed; retried next run"; return 1; }
  rm -f "$state/unpublished"
  touch "$tmp/published"
  do_log "OK secret SPL_PRIVATE_CNF_YAML of $repo set and read back (updated_at $(date -u -d "@$up" +%FT%TZ))"
}

# spl_thr_mark <tmp> (subshell, ENV set): every open row of the env whose
# placeholder carries a reservation still in its hold gets the detail
# `placeholder reserved <ts> (<tok>)`, after the publish that made it known; a
# failed write logs the placeholder and rc only (psql text may name the slug)
spl_thr_mark() {
  local tmp="$1" t st bill act age ts tok mrc
  do_spl_cloud_cnf && do_gcp_pin_account "$SPL_CNF" || return 1
  while read -r t st bill act age; do
    spl_thr_open_paid "$st" "$bill" "$act" "$t" || continue
    spl_th_reserve_held "$t" >/dev/null || continue
    ts="$(spl_private_reserved_at "$t")"; tok="$(spl_private_token "$t")"
    mrc=0; spl_via_proxy _spl_th_mark_sql "$t" pending "placeholder reserved $ts ($tok)" >/dev/null 2>&1 || mrc=$?
    (( mrc == 0 )) || { do_log "WARN $ENV: tenant_hosts $tok detail not written (rc $mrc; its output withheld)"; continue; }
    do_log "INFO $ENV: tenant_hosts $tok -> pending (placeholder reserved $ts)"
  done <"$tmp/rows.$ENV"
}

# spl_thr_dispatch <state> <tmp> <env> <dry> <repo> <token file>: an open row
# whose stamped placeholder is past its hold and not dispatched yet
# (<state>/dispatched, "<env> <tok>") dispatches workflow 40 for the env, once
spl_thr_dispatch() {
  local state="$1" tmp="$2" e="$3" dry="$4" repo="$5" tf="$6" t st bill act age tok ts
  local -a due=()
  while read -r t st bill act age; do
    spl_thr_open_paid "$st" "$bill" "$act" "$t" || continue
    ts="$(spl_private_reserved_at "$t" 2>/dev/null)" && [[ -n "$ts" ]] || continue
    spl_th_reserve_held "$t" >/dev/null && continue
    tok="$(spl_private_token "$t")"
    grep -qxF "$e $tok" "$state/dispatched" 2>/dev/null || due+=("$tok")
  done <"$tmp/rows.$e"
  (( ${#due[@]} )) || return 0
  if (( dry )); then do_log "INFO DRY_RUN $e: would dispatch workflow 40 for ${due[*]}"; return 0; fi
  if spl_thr_gh "$tf" workflow run 40_tenant-host-reconcile.yml -R "$repo" -f "environment=$e" >/dev/null 2>&1; then
    for tok in "${due[@]}"; do printf '%s %s\n' "$e" "$tok"; done >>"$state/dispatched"
    do_log "OK $e: workflow 40 dispatched for ${due[*]} (past the ${HOST_RESERVE_HOLD:-5} min hold)"
  else
    do_log "WARN $e: workflow 40 dispatch refused (the token needs actions write): its 15-minute schedule adds ${due[*]}"
  fi
}
