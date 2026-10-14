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
# @param ENV - required: dev or prd (opt-in with BENCH_PRD_CONFIRM, concurrency <= 3, n <= 50)
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
# @example ENV=prd BENCH_PRD_CONFIRM=1 BENCH_CONCURRENCY=2 DRY_RUN=0 ./run -a do_spl_standby_bench
#------------------------------------------------------------------------------

# Source helpers (split to stay under 80 lines each)
source "${BASH_SOURCE[0]%/*}/spl-standby-bench-helpers.func.sh"

do_spl_standby_bench() {
  do_require_bin python3 || return 1
  _spl_standby_bench_validate_env || return 1
  _spl_standby_bench_validate_params || return 1
  _spl_standby_bench_resolve_agent_user || return 1
  _spl_standby_bench_check_vendors "${BENCH_MODELS_DETECTED}" || return 1

  if (( DRY_RUN_DETECTED )); then
    _spl_standby_bench_dry_run "${PLAN_DETECTED}" "${AGENT_USER_DETECTED}" "${BENCH_N_DETECTED}" "${BENCH_EFFORT_DETECTED}" "${BENCH_THINKING_DETECTED}" "${BENCH_BUDGET_S_DETECTED}"
    return 0
  fi

  _spl_standby_bench_run "${PLAN_DETECTED}" "${AGENT_USER_DETECTED}" "${BENCH_N_DETECTED}" "${BENCH_EFFORT_DETECTED}" "${BENCH_THINKING_DETECTED}" "${BENCH_BUDGET_S_DETECTED}" "${BENCH_CALL_TIMEOUT_DETECTED}" "${BENCH_MODELS_DETECTED}" "${SKIPPED_DETECTED}"
}