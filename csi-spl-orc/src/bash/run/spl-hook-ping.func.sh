#!/bin/bash
#------------------------------------------------------------------------------
# @description Ping one harness hook (spec 093 7.3). A hook injects a random
# @description token after one tool call; the harness must echo it. n trials,
# @description default 3. Pass is the token in the harness reply.
# @param HARNESS (optional) - grok, agy, qwen, or all (default all)
# @param N (optional) - trials per harness, default 3
# @param HOOK_PING_HARNESS_CMD (optional) - stub: injection JSON on stdin,
# @param   reply on stdout. Unset runs the installed binary (refused when
# @param   SPOOL_TEST=1).
# @param HOOK_PING_SKIP_TOOL (optional) - 1 skips the tool-call event, so the
# @param   hook must not inject (the control).
# @example HARNESS=grok N=3 ./run -a do_spl_hook_ping
# @example HOOK_PING_HARNESS_CMD=/tmp/stub.sh HARNESS=agy N=1 ./run -a do_spl_hook_ping
#------------------------------------------------------------------------------

_spl_hp_root() {
  if [[ -n "${HOOK_PING_ROOT:-}" ]]; then
    printf '%s' "$HOOK_PING_ROOT"
    return 0
  fi
  printf '%s/src/bash/features/spawn-agents/scripts/hook-ping' "${PROJ_PATH:?}"
}

spl_hook_ping_harnesses() {
  case "${HARNESS:-all}" in
    all) printf '%s\n' grok agy qwen ;;
    grok|agy|qwen) printf '%s\n' "$HARNESS" ;;
    *) printf '%s\n' "hook-ping fail bad-harness ${HARNESS}" >&2; return 2 ;;
  esac
}

spl_hook_ping_prepare() {
  if [[ -n "${HOOK_PING_STATE:-}" ]]; then
    mkdir -p "$HOOK_PING_STATE"
    return 0
  fi
  HOOK_PING_STATE="$(mktemp -d)"
  HOOK_PING_STATE_MADE=1
}

spl_hook_ping_cleanup() {
  if [[ "${HOOK_PING_STATE_MADE:-}" == 1 && "${HOOK_PING_KEEP:-}" != 1 ]]; then
    rm -rf "$HOOK_PING_STATE"
  fi
  unset HOOK_PING_STATE_MADE
}

spl_hook_ping_trial_dir() {
  local dir="$HOOK_PING_STATE/$1/$2"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

spl_hook_ping_inject_post() {
  local script ev
  script="$(_spl_hp_root)/$1.sh"
  if [[ "${HOOK_PING_SKIP_TOOL:-}" == 1 ]]; then
    ev='{"hook_event_name":"UserPromptSubmit"}'
  else
    ev='{"hook_event_name":"PostToolUse","tool_name":"run_shell_command"}'
  fi
  HOOK_PING_DIR="$2" bash "$script" <<<"$ev" >"$2/hook.out" 2>>"$2/hook.err" || true
  [[ -s "$2/token" ]]
}

spl_hook_ping_inject_agy() {
  local script dir
  script="$(_spl_hp_root)/agy.sh"
  dir="$1"
  if [[ "${HOOK_PING_SKIP_TOOL:-}" != 1 ]]; then
    HOOK_PING_DIR="$dir" bash "$script" PostToolUse <<<'{"stepIdx":1}' \
      >"$dir/post.out" 2>>"$dir/hook.err" || true
  fi
  HOOK_PING_DIR="$dir" bash "$script" PreInvocation \
    <<<'{"invocationNum":2,"initialNumSteps":1}' \
    >"$dir/hook.out" 2>>"$dir/hook.err" || true
  [[ -s "$dir/token" ]]
}

spl_hook_ping_shape() {
  local h="$1" tok="$2"
  case "$h" in
    grok|qwen)
      jq -e --arg t "$tok" \
        '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains($t))' \
        >/dev/null ;;
    agy)
      jq -e --arg t "$tok" '.injectSteps[0].ephemeralMessage | contains($t)' >/dev/null ;;
    *) return 2 ;;
  esac
}

spl_hook_ping_stub_trial() {
  local h="$1" i="$2" dir tok reply
  dir="$(spl_hook_ping_trial_dir "$h" "$i")"
  if [[ "$h" == agy ]]; then
    spl_hook_ping_inject_agy "$dir" || { echo "hook-ping $h $i fail no-injection"; return 1; }
  else
    spl_hook_ping_inject_post "$h" "$dir" || { echo "hook-ping $h $i fail no-injection"; return 1; }
  fi
  tok="$(cat "$dir/token")"
  spl_hook_ping_shape "$h" "$tok" <"$dir/hook.out" || { echo "hook-ping $h $i fail bad-shape"; return 1; }
  reply="$(HOOK_PING_HARNESS="$h" bash "$HOOK_PING_HARNESS_CMD" <"$dir/hook.out" 2>>"$dir/stub.err" || true)"
  if grep -qF -- "$tok" <<<"$reply"; then
    echo "hook-ping $h $i pass"
    return 0
  fi
  echo "hook-ping $h $i fail no-echo"
  return 1
}

spl_hook_ping_bin() {
  if [[ -n "${HOOK_PING_BIN:-}" ]]; then
    printf '%s' "$HOOK_PING_BIN"
    return 0
  fi
  command -v "$1"
}

spl_hook_ping_echoed() {
  local h="$1" tok="$2" raw="$3" text=""
  case "$h" in
    grok) text="$(jq -r '.text // empty' "$raw" 2>/dev/null || true)" ;;
    qwen) text="$(jq -r '[.[]? | select(.type == "result") | .result // empty] | last // empty' "$raw" 2>/dev/null || true)" ;;
    agy) text="$(jq -r 'if type == "object" then (.response // .text // .result // .message // empty) elif type == "array" then ([.[] | .response // .result // .text // empty] | map(select(length > 0)) | last // empty) else empty end' "$raw" 2>/dev/null || true)" ;;
    *) return 2 ;;
  esac
  [[ -n "$text" ]] && grep -qF -- "$tok" <<<"$text"
}

spl_hook_ping_live_trial() {
  local h="$1" i="$2" dir bin tok
  dir="$(spl_hook_ping_trial_dir "$h" "$i")"
  if ! bin="$(spl_hook_ping_bin "$h")"; then
    echo "hook-ping $h $i fail not-installed"
    return 1
  fi
  timeout "${HOOK_PING_LIVE_TIMEOUT:-180}" env HOOK_PING_DIR="$dir" HOOK_PING_BIN="$bin" \
    bash "$(_spl_hp_root)/live-one.sh" "$h" >"$dir/raw.out" 2>"$dir/cli.err" || true
  if [[ ! -s "$dir/token" ]]; then
    echo "hook-ping $h $i fail no-injection"
    return 1
  fi
  tok="$(cat "$dir/token")"
  if spl_hook_ping_echoed "$h" "$tok" "$dir/raw.out"; then
    echo "hook-ping $h $i pass"
    return 0
  fi
  echo "hook-ping $h $i fail no-echo"
  return 1
}

spl_hook_ping_trial() {
  if [[ -n "${HOOK_PING_HARNESS_CMD:-}" ]]; then
    spl_hook_ping_stub_trial "$1" "$2"
  else
    spl_hook_ping_live_trial "$1" "$2"
  fi
}

spl_hook_ping_one() {
  local h="$1" n="${N:-3}" i pass=0 fail=0
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "hook-ping $h fail bad-n"; return 2; }
  for ((i = 1; i <= n; i++)); do
    if spl_hook_ping_trial "$h" "$i"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
  echo "hook-ping $h n=$n pass=$pass fail=$fail"
  [[ "$fail" -eq 0 ]]
}

spl_hook_ping_run() {
  local h rc=0 list
  if [[ -z "${HOOK_PING_HARNESS_CMD:-}" && "${SPOOL_TEST:-}" == 1 ]]; then
    echo "hook-ping REFUSED: SPOOL_TEST=1 and no HOOK_PING_HARNESS_CMD"
    return 97
  fi
  list="$(spl_hook_ping_harnesses)" || return $?
  spl_hook_ping_prepare || return 1
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    spl_hook_ping_one "$h" || rc=$?
  done <<<"$list"
  return "$rc"
}

do_spl_hook_ping() {
  local rc=0
  spl_hook_ping_run || rc=$?
  spl_hook_ping_cleanup
  return "$rc"
}
