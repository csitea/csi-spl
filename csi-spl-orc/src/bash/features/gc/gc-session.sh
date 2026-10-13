#!/usr/bin/env bash
# gc-session.sh - the command of a GC window (do_spl_gc GC_CMD=start, owner
# HUM-10 t1 91a36ace): resolve the slot's CLI, trust the workdir, start ONE
# interactive session as the agent user with the fixed GC prompt
# (gc-prompt.md next to this file), and return. No `exec bash` after it: when
# the CLI exits the window closes, so a pass that ends leaves nothing behind.
#
# Usage: gc-session.sh <VENDOR> <FALLBACK> <RUN_ID> <WORKDIR>
#   VENDOR / FALLBACK  claude | grok | agy | qwen (mistral needs a price cap:
#                      not a GC vendor); the fallback when VENDOR's CLI is
#                      not installed on this box
# GC_SESSION_PRINT=1 prints the launch line instead of running it (tests).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SA="$HERE/../spawn-agents"
# shellcheck source=../spawn-agents/lib/spool-env.inc.sh
. "$SA/lib/spool-env.inc.sh"
spool_env_resolve

vendor="${1:?VENDOR required}" fallback="${2:?FALLBACK required}" rid="${3:?RUN_ID required}" workdir="${4:?WORKDIR required}"
bin_of() {
  case "$1" in claude) printf '%s' "${CLAUDE_BIN:-}" ;; grok) printf '%s' "${GROK_BIN:-}" ;;
    agy) printf '%s' "${AGY_BIN:-}" ;; qwen) printf '%s' "${QWEN_BIN:-}" ;; *) return 1 ;; esac
}
# Which CLIs the agent user can start, probed the way the CLI is exec'd
# (spool_vendor_clis: `command -v` in its login shell). A *_BIN is often the
# bare name (no <agent home>/.local/bin/<cli>), so `[ -x "$bin" ]` refused
# every CLI on sat: the first pass, 20261013T2200Z, slept 30 s and closed.
# A failed probe (exit 1) is "unknown": try the slot's vendor anyway.
if clis="$(spool_vendor_clis)"; then has() { [[ ",$clis," == *",$1,"* ]]; }; else has() { true; }; fi
bin="$(bin_of "$vendor" || true)"
if [ -z "$bin" ] || ! has "$vendor"; then
  echo "gc-session: no $vendor CLI on this box (${bin:-unset}): $fallback instead"
  vendor="$fallback"; bin="$(bin_of "$vendor" || true)"
fi
[ -n "$bin" ] && has "$vendor" || { echo "gc-session: no $vendor CLI either: no GC this slot" >&2; sleep 30; exit 3; }
perm="$(spool_claude_perm_flags "$vendor")" || exit 2
case "$vendor" in
  claude) args="--name 'gc@${SPOOL_BOX_TAG:-box}' $perm" ;;
  agy|qwen) args="$perm --prompt-interactive" ;;
  *) args="$perm" ;;
esac
orc="$(cd "$HERE/../../../.." && pwd)"
prompt="You are the GC (garbage collector) agent of box ${SPOOL_BOX_TAG:-this box}, pass ${rid}, running as ${vendor}. Read ${HERE}/gc-prompt.md and follow it EXACTLY: it is your complete instructions. Every action runs as: cd ${orc} && sudo -u ${SPOOL_BOX_USER} env SPOOL_ROOT=${SPOOL_ROOT} DRY_RUN=0 GC_CMD=<cmd> ./run -a do_spl_gc"
esc=""
spool_dq_escape esc "$prompt"
cmd="export ${SPOOL_CLI_ENV} SPOOL_ROOT='${SPOOL_ROOT}' GC_RUN_ID='${rid}'; cd '${workdir}' && '${bin}' ${args} \"${esc}\""
if [ "${GC_SESSION_PRINT:-0}" = 1 ]; then printf '%s\n' "$cmd"; exit 0; fi
bash "$SA/scripts/trust-workdir.sh" --settle "$workdir" "$SPOOL_AGENT_USER" "$vendor" >/dev/null 2>&1 || true
spool_agent_exec "$cmd"
