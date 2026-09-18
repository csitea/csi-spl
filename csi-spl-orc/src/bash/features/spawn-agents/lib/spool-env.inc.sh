#!/usr/bin/env bash
# spool-env.inc.sh — the ONE resolver behind every spawn-agents script.
#
# Forked from the box engine's resolver and cut down to what the spool needs.
# Every value comes from the environment first; the defaults are derived from
# the running system (users, the tmux socket's owner), never baked in. Nothing
# here names a user, a host or a box.
#
#   SPOOL_ROOT          message root (spec 002, local-folder-layout.md)
#                                                   default /var/spool-hub
#   SPOOL_BOX_USER      OS user that owns the tmux server the windows go into
#                       default: the owner of $SPOOL_ROOT (the box user owns
#                       the spool root), else the current user
#   SPOOL_AGENT_USER    OS user the agent CLIs run as
#                                                   default $SPOOL_BOX_USER (no hop)
#   SPOOL_RUN_AS_AGENT  su-dash | sudo-i            how to hop to the agent user
#   SPOOL_TMUX_SOCKET   the box user's tmux socket  default /tmp/tmux-<uid>/default
#   SPOOL_TMUX_SIZE     WxH for a window nobody is looking at   default 200x50
#   SPOOL_BOX_TAG       display tag on window names ("<tag>: CLE-07") default none
#   SPOOL_ORCHESTRATOR_ID  who spawned agents report to   default CLE-00
#   SPOOL_BIN           the spool binary            default: this repo's build
#                       output, else `spool` on PATH
#   CLAUDE_BIN GROK_BIN AGY_BIN   default <agent home>/.local/bin/<cli> when it
#                       exists, else the bare name
#
# Agent ids follow SPEC-spool-identity-routing.md §2: ^[A-Z]{2,4}-[0-9]+$,
# unique per box, and BOX is never an agent prefix.

SPOOL_ID_RE='^[A-Z]{2,4}-[0-9]+$'

# The kinds this feature can launch, and the id prefix each one owns.
spool_prefix_of_kind() {  # KIND -> PREFIX
  case "${1:-}" in
    claude) printf 'CLE' ;;
    grok)   printf 'GRK' ;;
    agy)    printf 'AGY' ;;
    *) return 1 ;;
  esac
}

# 0 when ID is a valid spool agent id (identity-routing §2), else 1 with the
# reason on stderr.
spool_valid_id() {  # ID
  local id="${1:-}"
  if ! [[ "$id" =~ $SPOOL_ID_RE ]]; then
    echo "spool-env: '${id}' is not a spool agent id (want ${SPOOL_ID_RE})" >&2
    return 1
  fi
  if [ "${id%%-*}" = BOX ]; then
    echo "spool-env: '${id}' uses the forbidden prefix BOX (identity-routing §2)" >&2
    return 1
  fi
  return 0
}

_spool_home_of() {  # USER
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

_spool_feature_dir() {
  cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd
}

spool_env_resolve() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  # Not $SUDO_USER: under `sudo -u <box user>` that names the CALLER, and an
  # agent calling spool-send.sh as itself would ring its own (empty) tmux.
  if [ -z "${SPOOL_BOX_USER:-}" ]; then
    SPOOL_BOX_USER="$(stat -c %U "$SPOOL_ROOT" 2>/dev/null || true)"
    case "$SPOOL_BOX_USER" in ''|root|UNKNOWN) SPOOL_BOX_USER="$(id -un)" ;; esac
  fi
  SPOOL_AGENT_USER="${SPOOL_AGENT_USER:-$SPOOL_BOX_USER}"
  SPOOL_RUN_AS_AGENT="${SPOOL_RUN_AS_AGENT:-su-dash}"
  if [ -z "${SPOOL_TMUX_SOCKET:-}" ]; then
    SPOOL_TMUX_SOCKET="/tmp/tmux-$(id -u "$SPOOL_BOX_USER" 2>/dev/null || id -u)/default"
  fi
  SPOOL_TMUX_SIZE="${SPOOL_TMUX_SIZE:-200x50}"
  SPOOL_BOX_TAG="${SPOOL_BOX_TAG:-}"
  SPOOL_ORCHESTRATOR_ID="${SPOOL_ORCHESTRATOR_ID:-CLE-00}"
  SPOOL_AGENT_HOME="$(_spool_home_of "$SPOOL_AGENT_USER")"

  SPOOL_FEATURE_DIR="$(_spool_feature_dir)"
  if [ -z "${SPOOL_BIN:-}" ]; then
    # <repo>/csi-spl-orc/src/bash/features/spawn-agents -> <repo>
    local repo built
    repo="$(cd "$SPOOL_FEATURE_DIR/../../../../.." && pwd)"
    built="$repo/csi-spl-api/src/go/spool-hub-api/bin/spool"
    if [ -x "$built" ]; then SPOOL_BIN="$built"
    else SPOOL_BIN="$(command -v spool 2>/dev/null || printf 'spool')"
    fi
  fi

  local cli var
  for cli in claude grok agy; do
    var="$(printf '%s' "$cli" | tr '[:lower:]' '[:upper:]')_BIN"
    if [ -z "${!var:-}" ]; then
      if [ -n "$SPOOL_AGENT_HOME" ] && [ -x "$SPOOL_AGENT_HOME/.local/bin/$cli" ]; then
        printf -v "$var" '%s' "$SPOOL_AGENT_HOME/.local/bin/$cli"
      else
        printf -v "$var" '%s' "$cli"
      fi
    fi
  done
  export SPOOL_ROOT
}

# The tmux command, hopping to the socket owner when this is someone else.
# -u: without a UTF-8 locale (cron, a sudo hop with no LANG) tmux prints TAB
# and non-ASCII in -F output as "_".
spool_tmux_argv() {
  SPOOL_TM=(tmux -u -S "$SPOOL_TMUX_SOCKET")
  [ "$(id -un)" = "$SPOOL_BOX_USER" ] || SPOOL_TM=(sudo -u "$SPOOL_BOX_USER" tmux -u -S "$SPOOL_TMUX_SOCKET")
}

# The widest attached client, else SPOOL_TMUX_SIZE: a window created with no
# client attached otherwise gets tmux's 80x24 and the CLI wraps there for good.
spool_tmux_default_size() {
  local w h bw=0 best="" dflt="$SPOOL_TMUX_SIZE"
  [[ "$dflt" =~ ^[0-9]+x[0-9]+$ ]] || dflt=200x50
  spool_tmux_argv
  while IFS=x read -r w h; do
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || continue
    if [ "$w" -gt "$bw" ]; then bw="$w"; best="${w}x${h}"; fi
  done < <("${SPOOL_TM[@]}" list-clients -F '#{client_width}x#{client_height}' 2>/dev/null)
  printf '%s' "${best:-$dflt}"
}

# ── Running a command as the agent user ─────────────────────────────────────
#   su-dash   sudo su - <agent>        needs sudo to root
#   sudo-i    sudo -u <agent> -i bash  needs only `(<agent>) NOPASSWD`
#   same user, or already root: no sudo
spool_agent_argv() {
  case "$SPOOL_RUN_AS_AGENT" in
    su-dash|sudo-i) ;;
    *) echo "spool-env: unknown SPOOL_RUN_AS_AGENT '${SPOOL_RUN_AS_AGENT}' (want su-dash or sudo-i)" >&2; return 2 ;;
  esac
  if [ "$(id -un)" = "$SPOOL_AGENT_USER" ]; then SPOOL_AGENT_ARGV=(bash -l); return 0; fi
  if [ "$(id -u)" = 0 ]; then SPOOL_AGENT_ARGV=(su - "$SPOOL_AGENT_USER"); return 0; fi
  case "$SPOOL_RUN_AS_AGENT" in
    su-dash) SPOOL_AGENT_ARGV=(sudo su - "$SPOOL_AGENT_USER") ;;
    sudo-i)  SPOOL_AGENT_ARGV=(sudo -u "$SPOOL_AGENT_USER" -i bash) ;;
  esac
}

# Run one command string as the agent user, in its login environment. `sudo
# -i` re-parses its arguments and would expand a literal `$` twice, so that
# form ships the command base64-encoded.
spool_agent_exec() {  # "<command string>"
  spool_agent_argv || return $?
  if [ "${SPOOL_AGENT_ARGV[0]}" = sudo ] && [ "${SPOOL_AGENT_ARGV[3]:-}" = -i ]; then
    local b64
    b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
    "${SPOOL_AGENT_ARGV[@]}" -c "eval \"\`printf %s $b64 | base64 -d\`\""
  else
    "${SPOOL_AGENT_ARGV[@]}" -c "$1"
  fi
}

spool_agent_cmd_text() { spool_agent_argv >/dev/null 2>&1 || return 0; printf '%s' "${SPOOL_AGENT_ARGV[*]}"; }

# STRING escaped for a double-quoted argument that a shell parses again: only
# \ " $ and ` are live inside double quotes. Stored in VAR so trailing
# newlines survive.
spool_dq_escape() {  # VAR STRING
  local _dq="$2"
  _dq="${_dq//\\/\\\\}"
  _dq="${_dq//\"/\\\"}"
  _dq="${_dq//\$/\\\$}"
  _dq="${_dq//\`/\\\`}"
  printf -v "$1" '%s' "$_dq"
}

# The display name of an id: "<tag>: <id>" when SPOOL_BOX_TAG is set.
spool_decorate() {  # ID
  if [ -n "$SPOOL_BOX_TAG" ]; then printf '%s: %s' "$SPOOL_BOX_TAG" "$1"; else printf '%s' "$1"; fi
}

# The agent id a window name carries, or nothing. Accepts an optional
# "<tag>: " in front and anything after the id ("CLE-07 > wip").
spool_id_of_window() {  # WINDOW_NAME
  local n="${1:-}"
  n="$(printf '%s' "$n" | sed -E 's/^[A-Za-z0-9][A-Za-z0-9._-]*: //')"
  n="${n%% *}"
  [[ "$n" =~ $SPOOL_ID_RE ]] && printf '%s' "$n"
  return 0
}

# The live pane of an agent: registry rows newest-first whose pane still
# exists AND whose window still carries the id, else the first live window
# named for the id. Prints the pane id (%NN) or nothing.
spool_pane_of() {  # ID
  local id="$1" reg="$SPOOL_ROOT/registry.tsv" pane live p w
  spool_tmux_argv
  live="$("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id}	#{window_name}' 2>/dev/null || true)"
  [ -n "$live" ] || return 0
  if [ -r "$reg" ]; then
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      while IFS=$'\t' read -r p w; do
        if [ "$p" = "$pane" ] && [ "$(spool_id_of_window "$w")" = "$id" ]; then
          printf '%s' "$pane"; return 0
        fi
      done <<<"$live"
    done < <(awk -F'\t' -v id="$id" '$1 == id { print $3 }' "$reg" | tac)
  fi
  while IFS=$'\t' read -r p w; do
    if [ "$(spool_id_of_window "$w")" = "$id" ]; then printf '%s' "$p"; return 0; fi
  done <<<"$live"
}
