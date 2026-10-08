#!/usr/bin/env bash
# mistral (vibe) post_tool ping (spec 093 7.3, spec 110 3.4): a `post_tool`
# entry of vibe's hooks.toml. vibe's own wire protocol, not claude's: the
# event is `hook_event_name: "post_tool"` on stdin and the reply is snake
# case, `hook_specific_output.additional_context`, which vibe appends to the
# tool output the model reads (vibe 2.26.0 source, core/hooks/_post_tool.py).
# After a tool call: a random token there, recorded under HOOK_PING_DIR.
# Any other event prints {}. Always exits 0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.inc.sh
source "$here/lib.inc.sh"

spl_hp_mistral_main() {
  local raw ev tok ask
  raw="$(cat || true)"
  ev="$(spl_hp_event "$raw")"
  [[ "$ev" == post_tool ]] || { spl_hp_emit_empty; return 0; }
  tok="$(spl_hp_mint)"
  ask="$(spl_hp_ask "$tok")"
  spl_hp_record "$tok" "$ask" || true
  jq -nc --arg ask "$ask" \
    '{decision:"allow",hook_specific_output:{additional_context:$ask}}' \
    || spl_hp_emit_empty
}

spl_hp_mistral_main
exit 0
