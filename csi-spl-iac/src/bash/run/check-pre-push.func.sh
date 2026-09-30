#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE pre-push gate that runs exactly what the deploy pipeline runs
# @description before it ships: the csi-spl-api suite that workflow 20 gates the
# @description hub deploy on (gofmt, go vet, go test -race, hub-pg on a local
# @description Postgres container, hub-gcs), the WUI unit tests + typecheck that
# @description workflow 30 gates the WUI deploy on, and the csi-spl-iac /
# @description csi-spl-orc / csi-spl-cnf suites + the distribution-hygiene sweep
# @description that 10_ci-quality turns trunk red on. A break is then caught in
# @description the lane that wrote it, not after it has stalled every deploy.
# @description Each part prints PASS/FAIL with its wall time; a final table sums
# @description them and the exit code is non-zero if any part failed.
# @description Two modes: FAST (default) runs only the suites whose tree changed
# @description vs PRE_PUSH_BASE (origin/master); FULL runs every suite. When the
# @description base ref is unknown FAST falls back to FULL rather than skip a
# @description gate silently.
# @description hub-pg needs a local Postgres (initdb) or the cached
# @description postgres:16-alpine image; when neither is present it SKIPS inside
# @description the suite and this action WARNS loudly (the classic "green on the
# @description in-memory store, red on CI Postgres" gap) -- set
# @description PRE_PUSH_REQUIRE_PG=1 to make that skip a FAILURE.
# @param PRE_PUSH_MODE (optional) - fast (default) | full
# @param PRE_PUSH_BASE (optional) - diff base for fast mode, default origin/master
# @param PRE_PUSH_REQUIRE_PG (optional) - 1 = a skipped hub-pg (no Postgres) FAILS
# @param PRE_PUSH_PLAN (optional) - 1 = print the selected parts and exit 0
# @param PRE_PUSH_TREE (optional) - checkout root, default $APP_PATH
# @example ./run -a do_check_pre_push
# @example PRE_PUSH_MODE=full ./run -a do_check_pre_push
# @example PRE_PUSH_PLAN=1 ./run -a do_check_pre_push
#------------------------------------------------------------------------------

# Union of what this push would carry: commits ahead of the base, plus staged,
# unstaged and untracked working-tree changes (so it is useful before a commit
# too). Returns 1 when the base ref is unknown, so the caller can widen to FULL.
_pp_changed() {  # <tree> <base>
  local tree="$1" base="$2"
  git -C "$tree" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 1
  {
    git -C "$tree" diff --name-only "$base"...HEAD 2>/dev/null
    git -C "$tree" diff --name-only HEAD 2>/dev/null
    git -C "$tree" diff --name-only --cached 2>/dev/null
    git -C "$tree" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

# hub-pg.tst.sh runs iff a local Postgres server (initdb) OR the cached
# postgres:16-alpine docker image is present; otherwise it self-skips.
_pp_pg_available() {
  ls /usr/lib/postgresql/*/bin/initdb >/dev/null 2>&1 && return 0
  command -v docker >/dev/null 2>&1 && docker image inspect postgres:16-alpine >/dev/null 2>&1 && return 0
  return 1
}

_pp_part_hygiene() { HYGIENE_TREE="$1" do_check_dist_hygiene; }
_pp_part_api()     { bash "$1/csi-spl-api/src/bash/tests/run-all-tests.sh"; }
_pp_part_iac()     { bash "$1/csi-spl-iac/src/bash/tests/run-all-tests.sh"; }
_pp_part_orc()     { bash "$1/csi-spl-orc/src/bash/tests/run-all-tests.sh"; }
_pp_part_cnf()     { bash "$1/csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh"; }
_pp_part_wui() {
  local wui="$1/csi-spl-wui"
  [[ -d "$wui" ]] || { do_log "WARN pre-push: no csi-spl-wui at $wui -- skipping the WUI gate"; return 0; }
  command -v pnpm >/dev/null 2>&1 || { do_log "FATAL pre-push: pnpm not found -- cannot run the WUI gate"; return 1; }
  ( cd "$wui" || exit 1
    if [[ ! -d node_modules ]]; then
      echo "pre-push: WUI node_modules absent (fresh worktree) -- pnpm install --frozen-lockfile"
      pnpm install --frozen-lockfile || exit 1
    fi
    pnpm run test:unit || exit 1
    pnpm run typecheck  || exit 1
  )
}

# Run one part, timing it and recording PASS/FAIL into the parallel arrays.
_pp_run() {  # <label> <fn> [args...]
  local label="$1"; shift
  local start="$SECONDS" rc=0
  do_log "INFO pre-push: ==> $label"
  "$@" || rc=$?
  local el=$((SECONDS - start))
  _PP_NAMES+=("$label"); _PP_SECS+=("$el")
  if [[ "$rc" -eq 0 ]]; then
    _PP_STAT+=("PASS"); do_log "INFO pre-push: PASS $label (${el}s)"
  else
    _PP_STAT+=("FAIL"); _PP_FAILED=$((_PP_FAILED + 1))
    do_log "FATAL pre-push: FAIL $label (rc=$rc, ${el}s)"
  fi
  return 0
}

do_check_pre_push() {
  local tree="${PRE_PUSH_TREE:-$APP_PATH}"
  local mode="${PRE_PUSH_MODE:-fast}"
  local base="${PRE_PUSH_BASE:-origin/master}"
  case "$mode" in fast|full) ;; *) do_log "FATAL pre-push: PRE_PUSH_MODE must be fast or full (got '$mode')"; return 2 ;; esac
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL pre-push: $tree is not a git checkout"; return 2; }

  local sel_hygiene=1 sel_api=0 sel_iac=0 sel_orc=0 sel_cnf=0 sel_wui=0
  if [[ "$mode" == full ]]; then
    sel_api=1 sel_iac=1 sel_orc=1 sel_cnf=1 sel_wui=1
  else
    local changed f
    if ! changed="$(_pp_changed "$tree" "$base")"; then
      do_log "WARN pre-push: cannot diff against '$base' (unknown ref?) -- widening to FULL so no gate is skipped silently"
      mode=full; sel_api=1 sel_iac=1 sel_orc=1 sel_cnf=1 sel_wui=1
    else
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
          csi-spl-api/*|csi-spl-rdb/*|.version) sel_api=1 ;;
          csi-spl-cnf/*)                        sel_cnf=1; sel_iac=1 ;;
          csi-spl-iac/*|.github/workflows/*)    sel_iac=1 ;;
          csi-spl-orc/*)                        sel_orc=1 ;;
          csi-spl-wui/*)                        sel_wui=1 ;;
        esac
      done <<< "$changed"
    fi
  fi

  local parts="hygiene"
  [[ "$sel_cnf" == 1 ]] && parts+=" cnf"
  [[ "$sel_iac" == 1 ]] && parts+=" iac"
  [[ "$sel_orc" == 1 ]] && parts+=" orc"
  [[ "$sel_wui" == 1 ]] && parts+=" wui"
  [[ "$sel_api" == 1 ]] && parts+=" api"

  # A machine-readable plan line (also the whole of PLAN mode's output).
  echo "PRE_PUSH_PLAN mode=$mode parts=$parts"
  if [[ "${PRE_PUSH_PLAN:-0}" == 1 ]]; then
    do_log "INFO pre-push PLAN only (mode=$mode): $parts"
    return 0
  fi

  do_log "INFO pre-push: mode=$mode, base=$base, parts:$parts"

  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=()
  local _PP_FAILED=0

  [[ "$sel_hygiene" == 1 ]] && _pp_run "distribution-hygiene" _pp_part_hygiene "$tree"
  [[ "$sel_cnf" == 1 ]] && _pp_run "csi-spl-cnf conf-validator" _pp_part_cnf "$tree"
  [[ "$sel_iac" == 1 ]] && _pp_run "csi-spl-iac suite" _pp_part_iac "$tree"
  [[ "$sel_orc" == 1 ]] && _pp_run "csi-spl-orc suite" _pp_part_orc "$tree"
  [[ "$sel_wui" == 1 ]] && _pp_run "csi-spl-wui unit + typecheck" _pp_part_wui "$tree"
  if [[ "$sel_api" == 1 ]]; then
    if _pp_pg_available; then
      do_log "INFO pre-push: hub-pg will RUN (local initdb or cached postgres:16-alpine present)"
    else
      do_log "WARN pre-push: hub-pg will SKIP -- no local postgres and no cached postgres:16-alpine; the Postgres store/hub/auth tests CI runs are NOT covered locally"
      if [[ "${PRE_PUSH_REQUIRE_PG:-0}" == 1 ]]; then
        _PP_NAMES+=("hub-pg coverage (PRE_PUSH_REQUIRE_PG)"); _PP_STAT+=("FAIL"); _PP_SECS+=("0"); _PP_FAILED=$((_PP_FAILED + 1))
      fi
    fi
    _pp_run "csi-spl-api suite (gofmt, vet, race, hub-pg, hub-gcs)" _pp_part_api "$tree"
  fi

  echo ""
  echo "==================== pre-push summary (mode=$mode) ===================="
  local i
  for i in "${!_PP_NAMES[@]}"; do
    printf '  %-4s %5ss  %s\n' "${_PP_STAT[$i]}" "${_PP_SECS[$i]}" "${_PP_NAMES[$i]}"
  done
  echo "======================================================================"

  if [[ "$_PP_FAILED" -gt 0 ]]; then
    do_log "FATAL pre-push: $_PP_FAILED part(s) FAILED -- do not push until green"
    return 1
  fi
  do_log "INFO pre-push: all parts PASSED -- safe to push"
  return 0
}
