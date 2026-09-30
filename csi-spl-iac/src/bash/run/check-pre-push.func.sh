#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE pre-push gate that runs what the deploy pipeline blocks on
# @description AND that runs on bare metal here: the csi-spl-api suite that
# @description workflow 20 gates the hub deploy on (gofmt, go vet, go test
# @description -race, hub-pg on a local Postgres container, hub-gcs), the WUI
# @description unit tests + typecheck that workflow 30 gates the WUI deploy on,
# @description the csi-spl-iac suite, and the distribution-hygiene sweep. A break
# @description is then caught in the lane that wrote it, not after it has stalled
# @description every deploy. (The csi-spl-orc / csi-spl-cnf conf-validator suites
# @description need python/container deps absent at push time, so they are NOT
# @description gated here -- run those through their container path.)
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

# pnpm is often a user-local install (~/.local/bin) not on the minimal PATH a
# git hook or a `sudo -u <box-user> env` shell sees, so resolve it explicitly
# before deciding it is missing.
_pp_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then printf 'pnpm'; return 0; fi
  local p
  for p in "$HOME/.local/bin/pnpm" /usr/local/bin/pnpm /usr/bin/pnpm; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# A suite can HANG (tf-steps render is network-bound and has hung an agent for
# hours). Every part runs under a hard timeout so the hook can never block a
# push forever: `timeout` returns 124, which the runner reports as a FAIL named
# "TIMED OUT", never a hang.
_pp_timeout="${PRE_PUSH_PART_TIMEOUT:-600}"
# hygiene is ~1 s and cannot hang, so it runs directly (no timeout, no subshell).
_pp_part_hygiene() { HYGIENE_TREE="$1" do_check_dist_hygiene; }
_pp_part_api()     { timeout -k 10 "$_pp_timeout" bash "$1/csi-spl-api/src/bash/tests/run-all-tests.sh"; }
_pp_part_iac()     { timeout -k 10 "$_pp_timeout" bash "$1/csi-spl-iac/src/bash/tests/run-all-tests.sh"; }
# The payment-vendor gate READS csi-spl-wui (it greps it) but LIVES in the api
# suite, so a WUI-only change used to skip it and a vendor word ("stripe") in a
# .vue comment reached trunk and failed hub deploy 20 twice. It is a fast,
# tree-relative grep, so run it whenever WUI changed -- selected by the tree it
# reads, not the tree it lives in.
_pp_part_wui_vendor() { bash "$1/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh"; }
_pp_part_wui() {
  local wui="$1/csi-spl-wui" pn
  [[ -d "$wui" ]] || { do_log "WARN pre-push: no csi-spl-wui at $wui -- skipping the WUI gate"; return 0; }
  pn="$(_pp_pnpm)" || { do_log "FATAL pre-push: pnpm not found (checked PATH, ~/.local/bin, /usr/local/bin) -- cannot run the WUI gate"; return 1; }
  timeout -k 10 "$_pp_timeout" bash -c '
    cd "$1/csi-spl-wui" || exit 1
    export PATH="$HOME/.local/bin:$PATH"
    if [[ ! -d node_modules ]]; then
      echo "pre-push: WUI node_modules absent (fresh worktree) -- pnpm install --frozen-lockfile"
      "$2" install --frozen-lockfile || exit 1
    fi
    "$2" run test:unit || exit 1
    "$2" run typecheck  || exit 1
  ' _ "$1" "$pn"
}

# A single origin/master worktree, built lazily on the first failure and reused,
# so a FAILED part can be re-run against trunk: a failure that ALSO fails on
# trunk is pre-existing (someone else's red) and must NOT block this push -- that
# is the mutual-hook deadlock that stopped a fix from ever landing.
_PP_BASE_WT=""
_pp_baseline_tree() {  # <tree> <base>
  [[ -n "$_PP_BASE_WT" ]] && { printf '%s' "$_PP_BASE_WT"; return 0; }
  git -C "$1" rev-parse --verify -q "$2^{commit}" >/dev/null 2>&1 || return 1
  local tmp; tmp="$(mktemp -d 2>/dev/null)" || return 1
  if git -C "$1" worktree add --detach -q "$tmp" "$2" >/dev/null 2>&1; then
    _PP_BASE_WT="$tmp"; printf '%s' "$tmp"; return 0
  fi
  rmdir "$tmp" 2>/dev/null; return 1
}
_pp_baseline_cleanup() {  # <tree>
  [[ -n "$_PP_BASE_WT" ]] || return 0
  git -C "$1" worktree remove --force "$_PP_BASE_WT" >/dev/null 2>&1 || rm -rf "$_PP_BASE_WT"
  _PP_BASE_WT=""
}

# Run one part against the working tree; on failure, re-run it against the
# baseline (origin/master) and only BLOCK when it passes there -- a failure that
# also exists on trunk is reported (WARN) but never blocks, so a fix can land on
# a red trunk (no mutual-hook deadlock). rc 124 is a timeout, reported as such.
_pp_run() {  # <label> <fn> <tree> <base>
  local label="$1" fn="$2" tree="$3" base="$4"
  local start="$SECONDS" rc=0
  do_log "INFO pre-push: ==> $label"
  "$fn" "$tree" || rc=$?
  local el=$((SECONDS - start))
  if [[ "$rc" -eq 0 ]]; then
    _PP_NAMES+=("$label"); _PP_STAT+=("PASS"); _PP_SECS+=("$el")
    do_log "INFO pre-push: PASS $label (${el}s)"
    return 0
  fi
  local note="rc=$rc"; [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && note="TIMED OUT after ${_pp_timeout}s"
  # Pre-existing on trunk? Re-run the SAME part against origin/master.
  local bwt brc=0
  if bwt="$(_pp_baseline_tree "$tree" "$base")"; then
    do_log "INFO pre-push: $label failed ($note) -- re-checking it on $base to see if it is your break or trunk's"
    "$fn" "$bwt" || brc=$?
  else
    do_log "WARN pre-push: could not build a $base baseline for $label -- treating the failure as NEW"
    brc=0
  fi
  if [[ "$brc" -ne 0 ]]; then
    _PP_NAMES+=("$label (PRE-EXISTING on $base)"); _PP_STAT+=("WARN"); _PP_SECS+=("$el")
    do_log "WARN pre-push: $label fails on your tree AND on $base ($note) -- pre-existing trunk failure, NOT blocking your push"
  else
    _PP_NAMES+=("$label"); _PP_STAT+=("FAIL"); _PP_SECS+=("$el"); _PP_FAILED=$((_PP_FAILED + 1))
    do_log "FATAL pre-push: FAIL $label ($note) -- a NEW failure your commits introduce"
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

  # The gated suites are exactly the ones a deploy is blocked on AND that run on
  # bare metal here: distribution-hygiene, the csi-spl-api suite (workflow 20's
  # hub-deploy gate), the csi-spl-iac suite, and the WUI unit tests + typecheck
  # (workflow 30's wui-deploy gate). The csi-spl-orc and csi-spl-cnf suites lean
  # on the conf-validator's python/container deps that are NOT present at push
  # time, so gating on them would refuse pushes for an environment gap rather
  # than a defect; run those through their container path, not this hook.
  local sel_hygiene=1 sel_api=0 sel_iac=0 sel_wui=0
  if [[ "$mode" == full ]]; then
    sel_api=1 sel_iac=1 sel_wui=1
  else
    local changed f
    if ! changed="$(_pp_changed "$tree" "$base")"; then
      do_log "WARN pre-push: cannot diff against '$base' (unknown ref?) -- widening to FULL so no gate is skipped silently"
      mode=full; sel_api=1 sel_iac=1 sel_wui=1
    else
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
          csi-spl-api/*|csi-spl-rdb/*|.version) sel_api=1 ;;
          csi-spl-cnf/*|csi-spl-iac/*|.github/workflows/*) sel_iac=1 ;;
          csi-spl-wui/*)                        sel_wui=1 ;;
        esac
      done <<< "$changed"
    fi
  fi

  local parts="hygiene"
  [[ "$sel_iac" == 1 ]] && parts+=" iac"
  [[ "$sel_wui" == 1 ]] && parts+=" wui wui-vendor"
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

  [[ "$sel_hygiene" == 1 ]] && _pp_run "distribution-hygiene" _pp_part_hygiene "$tree" "$base"
  [[ "$sel_iac" == 1 ]] && _pp_run "csi-spl-iac suite" _pp_part_iac "$tree" "$base"
  [[ "$sel_wui" == 1 ]] && _pp_run "csi-spl-wui payment-vendor gate" _pp_part_wui_vendor "$tree" "$base"
  [[ "$sel_wui" == 1 ]] && _pp_run "csi-spl-wui unit + typecheck" _pp_part_wui "$tree" "$base"
  if [[ "$sel_api" == 1 ]]; then
    if _pp_pg_available; then
      do_log "INFO pre-push: hub-pg will RUN (local initdb or cached postgres:16-alpine present)"
    else
      do_log "WARN pre-push: hub-pg will SKIP -- no local postgres and no cached postgres:16-alpine; the Postgres store/hub/auth tests CI runs are NOT covered locally"
      if [[ "${PRE_PUSH_REQUIRE_PG:-0}" == 1 ]]; then
        _PP_NAMES+=("hub-pg coverage (PRE_PUSH_REQUIRE_PG)"); _PP_STAT+=("FAIL"); _PP_SECS+=("0"); _PP_FAILED=$((_PP_FAILED + 1))
      fi
    fi
    _pp_run "csi-spl-api suite (gofmt, vet, race, hub-pg, hub-gcs)" _pp_part_api "$tree" "$base"
  fi

  _pp_baseline_cleanup "$tree"

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
