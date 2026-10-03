#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 070 L1, the standby benchmark: can a warm standby agent's
# @description call response reach its first token in ~0.9 s p95 (spec 070
# @description section 6.2, Q1, Q11)? Per vendor:model in BENCH_MODELS whose
# @description CLI is on this box (grok only when `grok models` says logged in):
# @description   1. starts ONE standby agent headless (W1) in an empty scratch dir
# @description      (no workspace): claude in print mode with stream-json in and
# @description      out, a replaced short system prompt and no tools; grok as
# @description      `grok agent stdio` (ACP), model + reasoning effort set on the
# @description      session. Both run as the agent user, never the human's
# @description   2. sends the warm-up turn (W2), not counted
# @description   3. sends BENCH_N (>= 20) call responses, one at a time: a short
# @description      synthetic topic tail + a new post, "about 80 tokens, no tool"
# @description   4. records per call: first token, last token, turn end (seconds
# @description      from the stdin write), output tokens, reported model, tools
# @description   5. stops the agent (its whole process group) before the next
# @description Writes the raw rows (JSONL) to the state dir and the report
# @description (p50 / p95 / max per vendor and model, n, the tree sha, the CLI
# @description versions, a verdict per vendor) to BENCH_REPORT. Model calls
# @description only: no hub, no spool, no cloud. Dry run unless DRY_RUN=0.
# @param ENV - required: dev (the bench is dev only, spec 070 section 10)
# @param BENCH_N (optional) - call responses per model, >= 20, default 20
# @param BENCH_MODELS (optional) - vendor:model list, default
# @param                           "claude:haiku claude:sonnet grok:grok-4.7-build-fast grok:grok-4.7"
# @param BENCH_EFFORT (optional) - low (default) | medium | high
# @param BENCH_THINKING (optional) - off (default: claude's extended thinking off, W6) | on
# @param BENCH_BUDGET_S (optional) - the first-token p95 budget, default 0.9 (hop 4)
# @param BENCH_CALL_TIMEOUT (optional) - seconds per turn, default 60
# @param BENCH_REPORT (optional) - default the spec 070 standby-bench.md in this tree
# @param SPOOL_AGENT_USER (optional) - the agent user; default from the box.env
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_standby_bench
#------------------------------------------------------------------------------
do_spl_standby_bench() {
  do_require_bin python3 || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev (the standby bench is dev only), got: '${ENV:-}'"; return 1; }
  local dry=1 d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 1; }
  [[ "$d" == 0 ]] && dry=0
  local n="${BENCH_N:-20}" effort="${BENCH_EFFORT:-low}" thinking="${BENCH_THINKING:-off}" budget="${BENCH_BUDGET_S:-0.9}" tmo="${BENCH_CALL_TIMEOUT:-60}"
  local models="${BENCH_MODELS:-claude:haiku claude:sonnet grok:grok-4.7-build-fast grok:grok-4.7}"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 20 && n <= 500 )) || { do_log "FATAL BENCH_N must be 20..500 (spec 070 L1: n >= 20), got: '$n'"; return 1; }
  [[ "$effort" =~ ^(low|medium|high)$ ]] || { do_log "FATAL BENCH_EFFORT must be low, medium or high, got: '$effort'"; return 1; }
  [[ "$thinking" =~ ^(on|off)$ ]] || { do_log "FATAL BENCH_THINKING must be on or off, got: '$thinking'"; return 1; }
  [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { do_log "FATAL BENCH_BUDGET_S must be seconds, got: '$budget'"; return 1; }
  [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo >= 1 )) || { do_log "FATAL BENCH_CALL_TIMEOUT must be whole seconds >= 1, got: '$tmo'"; return 1; }
  local m
  for m in $models; do
    [[ "$m" =~ ^(claude|grok):[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL BENCH_MODELS entry is not <claude|grok>:<model>: '$m'"; return 1; }
  done

  # the agents run as the agent user, never as the human's (spec 070 L1 brief)
  local agent_user="${SPOOL_AGENT_USER:-}" box_env="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  [[ -n "$agent_user" || ! -r "$box_env" ]] || agent_user="$(sed -n 's/^\(export \)\{0,1\}SPOOL_AGENT_USER=//p' "$box_env" | tail -1 | tr -d "\"'")"
  [[ -n "$agent_user" ]] || { do_log "FATAL the agent user is unknown: set SPOOL_AGENT_USER (or SPOOL_AGENT_USER= in $box_env)"; return 1; }
  [[ "$(id -un)" == "$agent_user" ]] || { do_log "FATAL run the bench as the agent user ($agent_user), not as $(id -un): its agents run as the user that starts them"; return 1; }

  # which vendors this box has: a CLI on PATH, and for grok a login
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
  for vendor in qwen gemini agy codex; do
    command -v "$vendor" >/dev/null 2>&1 && skipped+=("$vendor: CLI present, no headless adapter in L1")
  done
  local s
  for s in "${skipped[@]}"; do do_log "INFO skip $s"; done
  (( ${#plan[@]} )) || { do_log "FATAL no vendor CLI available for BENCH_MODELS='$models'"; return 1; }

  local state="${SPL_STATE_DIR:-$HOME/.local/share/csi-spl/cloud/$ENV}/standby-bench"
  local report="${BENCH_REPORT:-$PROJ_PATH/../csi-spl-doc/specs/070-three-second-response/standby-bench.md}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: start one standby per ${plan[*]} as $agent_user, a warm-up turn, then $n call responses each (effort $effort, thinking $thinking, budget ${budget}s p95 first token)"
    do_log "INFO DRY_RUN would write the rows under $state and the report to $report"
    do_log "OK DRY_RUN nothing was started. Re-run with DRY_RUN=0 to bench."
    return 0
  fi

  mkdir -p "$state" || return 1
  local stamp sha dirty="" cwd rc=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  # read-only git on this tree, which may belong to another user (a lane worktree)
  sha="$(git -c safe.directory='*' -C "$PROJ_PATH" rev-parse HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -c safe.directory='*' -C "$PROJ_PATH/.." status --porcelain 2>/dev/null)" ]] || dirty="+dirty"
  cwd="$(mktemp -d "${TMPDIR:-/tmp}/spl-standby-bench.XXXXXX")" || return 1
  local claude_ver="-" grok_ver="-"
  (( have_claude )) && claude_ver="$(claude --version 2>/dev/null | head -1)"
  (( have_grok )) && grok_ver="$(grok --version 2>/dev/null | head -1)"
  BENCH_CWD="$cwd" BENCH_ROWS="$state/$stamp.jsonl" BENCH_REPORT_PATH="$report" BENCH_SHA="${sha}${dirty}" \
    BENCH_STAMP="$stamp" BENCH_CLAUDE_VER="$claude_ver" BENCH_GROK_VER="$grok_ver" BENCH_SKIPPED="$(printf '%s\n' "${skipped[@]}")" \
    python3 "$PROJ_PATH/src/bash/scripts/spl-standby-bench.py" "$n" "$effort" "$budget" "$tmo" "$thinking" "${plan[@]}" || rc=$?
  rmdir "$cwd" 2>/dev/null || rm -rf "$cwd"
  case $rc in
    0) do_log "OK the bench ran: report $report" ;;
    2) do_log "FAIL a model has fewer than 20 good calls: see $report"; return 1 ;;
    3) do_log "FATAL an agent process survived its stop: check ps"; return 1 ;;
    *) do_log "FATAL the bench driver failed (rc=$rc)"; return 1 ;;
  esac
}
