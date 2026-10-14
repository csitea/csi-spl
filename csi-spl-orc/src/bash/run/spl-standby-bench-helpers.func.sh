#!/bin/bash
# Helpers for spl-standby-bench.func.sh (split to stay under 80 lines each)

_spl_standby_bench_validate_env() {
  [[ "${ENV:-}" == dev || ( "${ENV:-}" == prd && -n "${BENCH_PRD_CONFIRM:-}" ) ]] || { do_log "FATAL ENV must be dev or prd with BENCH_PRD_CONFIRM set (opt-in), got: '${ENV:-}'"; return 1; }
  if [[ "${ENV:-}" == prd ]]; then
    [[ "${BENCH_CONCURRENCY:-1}" -le 3 ]] || { do_log "FATAL BENCH_CONCURRENCY must be <= 3 on prd, got: '${BENCH_CONCURRENCY:-1}'"; return 1; }
    [[ "${BENCH_N:-20}" -le 50 ]] || { do_log "FATAL BENCH_N must be <= 50 on prd, got: '${BENCH_N:-20}'"; return 1; }
  fi
  local dry=1 d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 1; }
  [[ "$d" == 0 ]] && dry=0
  export DRY_RUN_DETECTED="$dry"
}

_spl_standby_bench_validate_params() {
  local n="${BENCH_N:-20}" effort="${BENCH_EFFORT:-low}" thinking="${BENCH_THINKING:-off}" budget="${BENCH_BUDGET_S:-0.9}" tmo="${BENCH_CALL_TIMEOUT:-60}" concurrency="${BENCH_CONCURRENCY:-1}"
  local models="${BENCH_MODELS:-claude:haiku claude:sonnet grok:grok-4.7-build-fast grok:grok-4.7}"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 20 )) || { do_log "FATAL BENCH_N must be >= 20, got: '$n'"; return 1; }
  [[ "${ENV:-}" == prd ]] && (( n <= 50 )) || (( n <= 500 ))
  [[ "$effort" =~ ^(low|medium|high)$ ]] || { do_log "FATAL BENCH_EFFORT must be low, medium or high, got: '$effort'"; return 1; }
  [[ "$thinking" =~ ^(on|off)$ ]] || { do_log "FATAL BENCH_THINKING must be on or off, got: '$thinking'"; return 1; }
  [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { do_log "FATAL BENCH_BUDGET_S must be seconds, got: '$budget'"; return 1; }
  [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo >= 1 )) || { do_log "FATAL BENCH_CALL_TIMEOUT must be whole seconds >= 1, got: '$tmo'"; return 1; }
  [[ "$concurrency" =~ ^[0-9]+$ ]] && (( concurrency >= 1 )) || { do_log "FATAL BENCH_CONCURRENCY must be whole >= 1, got: '$concurrency'"; return 1; }
  local m
  for m in $models; do
    [[ "$m" =~ ^(claude|grok):[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL BENCH_MODELS entry is not <claude|grok>:<model>: '$m'"; return 1; }
  done
  export BENCH_N_DETECTED="$n" BENCH_EFFORT_DETECTED="$effort" BENCH_THINKING_DETECTED="$thinking" \
    BENCH_BUDGET_S_DETECTED="$budget" BENCH_CALL_TIMEOUT_DETECTED="$tmo" BENCH_CONCURRENCY_DETECTED="$concurrency" \
    BENCH_MODELS_DETECTED="$models"
}

_spl_standby_bench_resolve_agent_user() {
  # the agents run as the agent user, never as the human's (spec 070 L1 brief)
  local agent_user="${SPOOL_AGENT_USER:-}" box_env="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  [[ -n "$agent_user" || ! -r "$box_env" ]] || agent_user="$(sed -n 's/^\(export \)\{0,1\}SPOOL_AGENT_USER=//p' "$box_env" | tail -1 | tr -d "\"'")"
  [[ -n "$agent_user" ]] || { do_log "FATAL the agent user is unknown: set SPOOL_AGENT_USER (or SPOOL_AGENT_USER= in $box_env)"; return 1; }
  [[ "$(id -un)" == "$agent_user" ]] || { do_log "FATAL run the bench as the agent user ($agent_user), not as $(id -un): its agents run as the user that starts them"; return 1; }
  export AGENT_USER_DETECTED="$agent_user"
}

_spl_standby_bench_check_vendors() {
  local models="$1"
  local -a plan=() skipped=()
  local vendor have_claude=0 have_grok=0 login
  command -v claude >/dev/null 2>&1 && have_claude=1
  if command -v grok >/dev/null 2>&1; then
    # captured first: `grok models | grep -q` dies of SIGPIPE under pipefail
    login="$(timeout 30 grok models 2>&1)" || true
    [[ "${login,,}" == *"logged in"* ]] && have_grok=1 || skipped+=("grok: CLI present, not logged in ($(head -1 <<<"$login" | cut -c1-120))")
  fi
  (( have_claude )) || skipped+=("claude: no CLI on PATH")
  for m in $models; do
    vendor="${m%%:*}"
    if [[ "$vendor" == claude && $have_claude -eq 1 ]] || [[ "$vendor" == grok && $have_grok -eq 1 ]]; then plan+=("$m"); else skipped+=("$m: vendor not available"); fi
  done
  # mistral's CLI is vibe (spec 110): named by its kind in the report
  for vendor in qwen gemini agy codex vibe; do
    command -v "$vendor" >/dev/null 2>&1 && skipped+=("${vendor/#vibe/mistral (vibe)}: CLI present, no headless adapter in L1")
  done
  local s
  for s in "${skipped[@]}"; do do_log "INFO skip $s"; done
  (( ${#plan[@]} )) || { do_log "FATAL no vendor CLI available for BENCH_MODELS='$models'"; return 1; }
  export PLAN_DETECTED="${plan[*]}" SKIPPED_DETECTED="${skipped[*]}"
}

_spl_standby_bench_dry_run() {
  local plan_str="$1" agent_user="$2" n="$3" effort="$4" thinking="$5" budget="$6"
  local state="${SPL_STATE_DIR:-$HOME/.local/share/csi-spl/cloud/$ENV}/standby-bench"
  local report="${BENCH_REPORT:-$PROJ_PATH/../csi-spl-doc/specs/070-three-second-response/standby-bench.md}"
  do_log "INFO DRY_RUN would: start one standby per ${plan_str} as $agent_user, a warm-up turn, then $n call responses each (effort $effort, thinking $thinking, budget ${budget}s p95 first token)"
  do_log "INFO DRY_RUN would write the rows under $state and the report to $report"
  do_log "OK DRY_RUN nothing was started. Re-run with DRY_RUN=0 to bench."
  return 0
}

_spl_standby_bench_run() {
  local plan_str="$1" agent_user="$2" n="$3" effort="$4" thinking="$5" budget="$6" tmo="$7" models="$8" skipped_str="$9"
  local state="${SPL_STATE_DIR:-$HOME/.local/share/csi-spl/cloud/$ENV}/standby-bench"
  local report="${BENCH_REPORT:-$PROJ_PATH/../csi-spl-doc/specs/070-three-second-response/standby-bench.md}"
  mkdir -p "$state" || return 1
  local stamp sha dirty="" cwd rc=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  # read-only git on this tree, which may belong to another user (a lane worktree)
  sha="$(git -c safe.directory='*' -C "$PROJ_PATH" rev-parse HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -c safe.directory='*' -C "$PROJ_PATH/.." status --porcelain 2>/dev/null)" ]] || dirty="+dirty"
  cwd="$(mktemp -d "${TMPDIR:-/tmp}/spl-standby-bench.XXXXXX")" || return 1
  local claude_ver="-" grok_ver="-" have_claude=0 have_grok=0
  command -v claude >/dev/null 2>&1 && have_claude=1
  command -v grok >/dev/null 2>&1 && have_grok=1
  (( have_claude )) && claude_ver="$(claude --version 2>/dev/null | sed -n 1p)"
  (( have_grok )) && grok_ver="$(grok --version 2>/dev/null | sed -n 1p)"
  BENCH_CWD="$cwd" BENCH_ROWS="$state/$stamp.jsonl" BENCH_REPORT_PATH="$report" BENCH_SHA="${sha}${dirty}" \
    BENCH_STAMP="$stamp" BENCH_CLAUDE_VER="$claude_ver" BENCH_GROK_VER="$grok_ver" BENCH_SKIPPED="$skipped_str" \
    python3 "$PROJ_PATH/src/bash/scripts/spl-standby-bench.py" "$n" "$effort" "$budget" "$tmo" "$thinking" $plan_str || rc=$?
  rmdir "$cwd" 2>/dev/null || rm -rf "$cwd"
  case $rc in
    0) do_log "OK the bench ran: report $report" ;;
    2) do_log "FAIL a model has fewer than 20 good calls: see $report"; return 1 ;;
    3) do_log "FATAL an agent process survived its stop: check ps"; return 1 ;;
    *) do_log "FATAL the bench driver failed (rc=$rc)"; return 1 ;;
  esac
}