#!/usr/bin/env bash
# agent-models.inc.sh — the live list of models each agent CLI offers, read at
# call time (spec 184 row A1, contract 7.1.6; owner Q3 "liv"). Sourced, not
# executed.
#
#   spool_agent_models VENDOR
#       prints the models the installed CLI offers, one per line; the CLI
#       version on stderr as "cli=<version>". Exit 0 with a list, 4 when the
#       vendor has no list source or the read failed (the caller then skips
#       the live check), 2 for an unknown vendor. Never a paid call, never
#       writes the cnf or the agent's home: it reads files and --help only.
#   spool_agent_models_report VENDOR CLI_VERSION   (models on stdin)
#       PUT /v1/boxes/{box}/agent-models/{vendor} (contract 7.1.5), body
#       {"cli_version", "models": [...], "read_at"}. OFF unless SPOOL_HUB_URL,
#       SPOOL_BOX_ID, SPOOL_TENANT and SPOOL_AGENT_MODELS_HUB_TOKEN are all set:
#       7.1.5 names no box auth yet (row H1 names it; holder c-002, msg
#       f53d87b1), so the token is the stand-in. Exit 0 sent, 3 off (unset, or
#       the hub has no such route: 404 / 405), 1 the hub refused or did not
#       answer.
#
# Sources, measured on this box 2026-11-21 (no list command run):
#   claude  the aliases its --help names for --model, "(e.g. 'fable', 'opus',
#           or 'sonnet')" on 2.1.323; a full model name is not listable and
#           passes on syntax alone (G8)
#   grok    the CLI's own cache <agent home>/.grok/models_cache.json, the keys
#           of "models" (1.0.92); `grok models` is not run until row M0 proves
#           it makes no paid call
#   mistral the [[models]] name and alias of <agent home>/.vibe/config.toml
#           (vibe 2.26.0); [[mcp_servers]] names are not models
#   agy, qwen, codex  no source until row M0 measures them: exit 4
#
# Env: SPOOL_AGENT_HOME (default the home of SPOOL_AGENT_USER, else $HOME);
# CLAUDE_BIN GROK_BIN MISTRAL_BIN (default <agent home>/.local/bin/<cli> when
# it exists, else the bare name), as spool_resolve_bins in spool-env.inc.sh.

# A model as contract 7.1.2 allows it on a command line; anything else a CLI
# prints is dropped, never passed on.
SPOOL_AGENT_MODEL_RX='^[A-Za-z0-9._:/-]{1,80}$'

_agent_models_home() {
  if [ -n "${SPOOL_AGENT_HOME:-}" ]; then printf '%s' "$SPOOL_AGENT_HOME"; return 0; fi
  local h=""
  [ -n "${SPOOL_AGENT_USER:-}" ] && h="$(getent passwd "$SPOOL_AGENT_USER" 2>/dev/null | cut -d: -f6)"
  printf '%s' "${h:-$HOME}"
}

# _agent_models_bin VAR CLI -> the CLI's path: $VAR, else <home>/.local/bin/CLI
# when executable, else the bare name; exit 4 when it does not resolve.
_agent_models_bin() {
  local var="$1" cli="$2" home b
  home="$(_agent_models_home)"
  b="${!var:-}"
  if [ -z "$b" ]; then
    if [ -x "$home/.local/bin/$cli" ]; then b="$home/.local/bin/$cli"; else b="$cli"; fi
  fi
  command -v "$b" >/dev/null 2>&1 || return 4
  printf '%s' "$b"
}

# _agent_models_version BIN -> the first x.y.z its --version prints.
_agent_models_version() {
  "$1" --version 2>/dev/null </dev/null | awk 'match($0, /[0-9]+\.[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }'
}

# _agent_models_clean: stdin lines -> the syntax-valid ones, first seen first.
_agent_models_clean() {
  awk -v rx="$SPOOL_AGENT_MODEL_RX" '{ sub(/\r$/, "") } $0 ~ rx && !seen[$0]++'
}

_agent_models_claude() {
  local bin
  bin="$(_agent_models_bin CLAUDE_BIN claude)" || return 4
  "$bin" --help 2>/dev/null </dev/null | awk '
    /^ +--model[ ,]/ { on = 1; text = $0; next }
    on && /^ +-/ { on = 0 }
    on { text = text " " $0 }
    END {
      if (!match(text, /\(e\.g\.[^)]*\)/)) exit
      s = substr(text, RSTART, RLENGTH)
      while (match(s, /\047[^\047]+\047/)) { print substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) }
    }'
  echo "cli=$(_agent_models_version "$bin")" >&2
}

_agent_models_grok() {
  local bin cache
  bin="$(_agent_models_bin GROK_BIN grok)" || return 4
  cache="$(_agent_models_home)/.grok/models_cache.json"
  [ -r "$cache" ] || return 4
  jq -r '.models | if type == "object" then keys_unsorted[] else empty end' "$cache" 2>/dev/null || return 4
  echo "cli=$(_agent_models_version "$bin")" >&2
}

_agent_models_mistral() {
  local bin conf
  bin="$(_agent_models_bin MISTRAL_BIN vibe)" || return 4
  conf="$(_agent_models_home)/.vibe/config.toml"
  [ -r "$conf" ] || return 4
  python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    models = tomllib.load(f).get("models", [])
for m in models if isinstance(models, list) else []:
    for k in ("name", "alias"):
        if isinstance(m, dict) and isinstance(m.get(k), str):
            print(m[k])
' "$conf" 2>/dev/null || return 4
  echo "cli=$(_agent_models_version "$bin")" >&2
}

spool_agent_models() {
  local vendor="${1:-}" out
  case "$vendor" in
    claude | grok | mistral) ;;
    agy | qwen | codex) return 4 ;;
    *) echo "spool_agent_models: unknown vendor '$vendor'" >&2; return 2 ;;
  esac
  out="$("_agent_models_$vendor")" || return 4
  out="$(printf '%s\n' "$out" | _agent_models_clean)"
  [ -n "$out" ] || return 4
  printf '%s\n' "$out"
}

spool_agent_models_report() {
  local vendor="${1:-}" cli="${2:-}" body code hub="${SPOOL_HUB_URL:-}"
  [ -n "$hub" ] && [ -n "${SPOOL_BOX_ID:-}" ] && [ -n "${SPOOL_TENANT:-}" ] &&
    [ -n "${SPOOL_AGENT_MODELS_HUB_TOKEN:-}" ] || return 3
  case "$vendor" in claude | grok | mistral | agy | qwen | codex) ;; *) return 1 ;; esac
  [[ "$SPOOL_BOX_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || return 1
  body="$(_agent_models_clean | jq -Rn --arg cli "$cli" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{cli_version: $cli, models: [inputs], read_at: $at}')" || return 1
  # The token goes through fd 3, never on curl's argv (/proc/<pid>/cmdline is
  # world-readable), as set-mistral-key.func.sh does.
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${SPOOL_AGENT_MODELS_HUB_TIMEOUT:-10}" \
    -X PUT -H 'Content-Type: application/json' -H @/dev/fd/3 -H "X-Spool-Tenant: $SPOOL_TENANT" \
    --data-binary "$body" "${hub%/}/v1/boxes/$SPOOL_BOX_ID/agent-models/$vendor" \
    3<<<"Authorization: Bearer $SPOOL_AGENT_MODELS_HUB_TOKEN" 2>/dev/null)"
  case "$code" in
    2??) return 0 ;;
    404 | 405) return 3 ;;
    *) return 1 ;;
  esac
}
