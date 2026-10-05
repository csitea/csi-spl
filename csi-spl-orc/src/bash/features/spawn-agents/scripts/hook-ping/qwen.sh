#!/usr/bin/env bash
# qwen PostToolUse ping (spec 093 7.3). Same contract as grok: a random token
# in additionalContext after a tool call, recorded under HOOK_PING_DIR.
# Any other event prints {}. Always exits 0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.inc.sh
source "$here/lib.inc.sh"

spl_hp_qwen_main() {
  local raw ev tok ask
  raw="$(cat || true)"
  ev="$(spl_hp_event "$raw")"
  spl_hp_is_post "$ev" || { spl_hp_emit_empty; return 0; }
  tok="$(spl_hp_mint)"
  ask="$(spl_hp_ask "$tok")"
  spl_hp_record "$tok" "$ask" || true
  jq -nc --arg ask "$ask" \
    '{decision:"allow",hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ask}}' \
    || spl_hp_emit_empty
}

spl_hp_qwen_main
exit 0
