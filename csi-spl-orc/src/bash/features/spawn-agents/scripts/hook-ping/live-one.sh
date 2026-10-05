#!/usr/bin/env bash
# One live ping trial. Writes the harness reply text to stdout.
# HOOK_PING_DIR, HOOK_PING_BIN and the harness name (argv 1) are required.
# Grok runs under an isolated HOME so the user's hook files stay untouched.
# Qwen and agy keep HOME and load a workspace hook file in the trial dir.
set -uo pipefail

# Sourced by the module test for the agy hooks document. The trial runs only
# when this file is executed.
spl_hp_agy_hooks_file() {
  local post="$1" pre="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  # PostToolUse is grouped: a flat handler is loaded and then never called.
  jq -nc --arg post "$post" --arg pre "$pre" \
    '{ping:{PostToolUse:[{matcher:"*",hooks:[{type:"command",command:$post,timeout:10}]}],PreInvocation:[{type:"command",command:$pre,timeout:10}]}}' \
    >"$dest"
}

spl_hp_live_main() {
  h="${1:?harness}"
  bin="${HOOK_PING_BIN:?}"
  dir="${HOOK_PING_DIR:?}"
  real="${HOOK_PING_REAL_HOME:-$HOME}"
  root="$(cd "$(dirname "$0")" && pwd)"
  work="$dir/work"
  prompt='Use the shell once to run exactly: echo hook-ping-tool
After the tool returns, a hook message names a ping token shaped ping- plus 16 hex digits. Reply with that token alone and no other text.'
  mkdir -p "$work"
  case "$h" in
    grok) spl_hp_live_grok ;;
    qwen) spl_hp_live_qwen ;;
    agy) spl_hp_live_agy ;;
    *) echo "hook-ping live bad-harness $h" >&2; return 2 ;;
  esac
}

spl_hp_live_cmd() {
  local script="$1"
  shift
  printf 'env HOOK_PING_DIR=%q %q' "$dir" "$script"
  local a
  for a in "$@"; do printf ' %q' "$a"; done
}

spl_hp_live_grok() {
  local home="$dir/home" cmd
  mkdir -p "$home/.grok/hooks"
  if [[ -f "$real/.grok/auth.json" ]]; then
    ln -sfn "$real/.grok/auth.json" "$home/.grok/auth.json"
  fi
  cmd="$(spl_hp_live_cmd "$root/grok.sh")"
  jq -nc --arg cmd "$cmd" \
    '{hooks:{PostToolUse:[{hooks:[{type:"command",command:$cmd,timeout:10}]}]}}' \
    >"$home/.grok/hooks/ping.json"
  HOME="$home" "$bin" --cwd "$work" --leader-socket "$dir/leader.sock" \
    --always-approve --max-turns 8 --output-format json --single "$prompt"
}

spl_hp_live_qwen() {
  local cmd
  mkdir -p "$work/.qwen"
  cmd="$(spl_hp_live_cmd "$root/qwen.sh")"
  jq -nc --arg cmd "$cmd" \
    '{hooks:{PostToolUse:[{hooks:[{type:"command",command:$cmd,timeout:10}]}]}}' \
    >"$work/.qwen/settings.json"
  (cd "$work" && "$bin" --approval-mode yolo --max-tool-calls 4 \
    --output-format json "$prompt")
}

spl_hp_live_agy() {
  local post pre
  post="$(spl_hp_live_cmd "$root/agy.sh" PostToolUse)"
  pre="$(spl_hp_live_cmd "$root/agy.sh" PreInvocation)"
  spl_hp_agy_hooks_file "$post" "$pre" "$work/.agents/hooks.json"
  (cd "$work" && "$bin" --disable-slash-commands --effort low \
    --dangerously-skip-permissions --output-format json \
    --add-dir "$work" --print="$prompt")
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  spl_hp_live_main "$@"
fi
