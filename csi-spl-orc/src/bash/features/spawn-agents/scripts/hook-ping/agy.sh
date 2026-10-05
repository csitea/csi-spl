#!/usr/bin/env bash
# agy ping (spec 093 7.3). PostToolUse only marks that a tool finished and
# prints {}. The following PreInvocation injects the token through
# injectSteps[].ephemeralMessage. argv is the event name, because an agy
# payload does not carry one. Always exits 0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.inc.sh
source "$here/lib.inc.sh"

spl_hp_agy_event() {
  local ev raw
  ev="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  raw="$(cat || true)"
  if [[ -z "$ev" ]]; then
    if jq -e 'has("invocationNum") or has("initialNumSteps")' <<<"$raw" >/dev/null 2>&1; then
      ev=preinvocation
    elif jq -e 'has("stepIdx") or has("toolCall")' <<<"$raw" >/dev/null 2>&1; then
      ev=posttooluse
    fi
  fi
  printf '%s' "$ev"
}

spl_hp_agy_post() {
  if spl_hp_dir_ok; then
    mkdir -p "$HOOK_PING_DIR" || true
    : >"$HOOK_PING_DIR/after-tool" || true
  fi
  spl_hp_emit_empty
}

spl_hp_agy_pre() {
  local tok ask
  if ! spl_hp_dir_ok || [[ ! -f "$HOOK_PING_DIR/after-tool" ]]; then
    spl_hp_emit_empty
    return 0
  fi
  rm -f "$HOOK_PING_DIR/after-tool"
  tok="$(spl_hp_mint)"
  ask="$(spl_hp_ask "$tok")"
  spl_hp_record "$tok" "$ask" || true
  jq -nc --arg ask "$ask" '{injectSteps:[{ephemeralMessage:$ask}]}' || spl_hp_emit_empty
}

ev="$(spl_hp_agy_event "${1:-}")"
case "$ev" in
  posttooluse|post_tool_use) spl_hp_agy_post ;;
  preinvocation) spl_hp_agy_pre ;;
  *) spl_hp_emit_empty ;;
esac
exit 0
