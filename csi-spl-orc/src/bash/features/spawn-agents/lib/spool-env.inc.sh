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
#                       default: the box config (below), else $SPOOL_BOX_USER (no hop)
#   SPOOL_RUN_AS_AGENT  su-dash | sudo-i            how to hop to the agent user
#   SPOOL_TMUX_SOCKET   the box user's tmux socket  default /tmp/tmux-<uid>/default
#   SPOOL_TMUX_SIZE     WxH for a window nobody is looking at   default 200x50
#   SPOOL_BOX_TAG       display tag on window names ("<tag>: CLE-07") default none
#   SPOOL_ORCHESTRATOR_ID  who spawned agents report to   default c-001
#   SPOOL_BIN           the spool binary            default: this repo's build
#                       output, else `spool` on PATH. The seed names the
#                       agent user's one instead: spool_agent_spool_bin
#   SPOOL_NOTIFY_CMD    the terminal leg (specs/028): the command the spool
#                       binary runs after a message lands in a local agent's
#                       inbox, so the agent's pane SHOWS it. Default: this
#                       feature's scripts/spool-notify.sh. `off` disables it.
#                       Resolved here, EXPORTED by spool-harness.sh
#   CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN   default <agent home>/.local/bin/<cli> when it
#                       exists, else the bare name
#   MISTRAL_BIN         the same, for the binary vibe (spec 110)
#
# The box config, $SPOOL_BOX_ENV (default $SPOOL_ROOT/box.env), is where a box
# says once what every spawn on it should default to, so a bare
# `spawn-window.sh claude auto ...` needs no env (CLE-77907: the owner's rule is
# that agents run as a dedicated agent user, not as the box user). Plain
# KEY=VALUE lines, never sourced; only the keys in SPOOL_BOX_ENV_KEYS are read,
# and the environment always wins over the file. Write it with
# scripts/box-config.sh.
#
# Agent ids follow specs/061 §2: c-004 (^[acgmq]-[0-9]{3}$, m = mistral since
# spec 110), and until
# SPOOL_LEGACY_ID_UNTIL the legacy CLE-07 form too. Unique per box, and BOX is
# never an agent prefix. The helpers below are the ONE place that grammar lives.

# 0 when the tree's build output is OLDER than the last commit to the sources
# it is built from: it may not speak today's protocol. Measured 2026-10-02:
# the box user's checkout held a 2026-09-18 bin/spool (0.1.0-dev) that refused
# kind blocker, and every spool-send.sh run from that tree failed with it.
# Not a git checkout = not judged.
_spool_bin_stale() {  # REPO BUILT
  local api=csi-spl-api/src/go/spool-hub-api src built
  src="$(git -C "$1" log -1 --format=%ct -- "$api/cmd" "$api/internal" "$api/go.mod" 2>/dev/null)"
  [ -n "$src" ] || return 1
  built="$(stat -c %Y "$2" 2>/dev/null)" || return 1
  if [ "$built" -lt "$src" ]; then
    echo "spool-env: WARN $2 is older than its sources (built $(date -u -d "@$built" +%FT%TZ), last source commit $(date -u -d "@$src" +%FT%TZ)); not using it. Rebuild: bash $1/csi-spl-api/src/bash/build.sh $2" >&2
    return 0
  fi
  return 1
}

# The spool on PATH, else the box user's ~/.local/bin/spool (not on a
# non-login PATH), else the stale build with a loud warning, else bare spool.
_spool_bin_fallback() {  # BUILT
  local b
  b="$(command -v spool 2>/dev/null)"
  [ -z "$b" ] && [ -x "$HOME/.local/bin/spool" ] && b="$HOME/.local/bin/spool"
  if [ -z "$b" ] && [ -x "$1" ]; then
    echo "spool-env: WARN no other spool found; using the stale $1 anyway" >&2
    b="$1"
  fi
  printf '%s' "${b:-spool}"
}

# This file's own directory: its sibling libs (agent-identity.inc.sh) load from it.
_SPOOL_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# specs/061 §0: the instant the legacy agent ids (CLE-/AGY-/GRK-/QWN-) stop
# being accepted on a write path (owner, 2026-10-02 ~06:52Z: moved one day, to
# 2026-10-03). A copy of the Go agentid.LegacyUntil, the source;
# tests/test-agent-id.sh fails when the two differ (FR-005).
SPOOL_LEGACY_ID_UNTIL='2026-10-03T20:59:59Z'
# Unanchored ERE fragments, for parsing window names and pane text. Readers
# take both forms whatever the clock: history keeps legacy ids for good
# (FR-006). SPOOL_AGENT_ID_RX and SPOOL_PARTICIPANT_RX each open exactly ONE
# capture group (the id), so BASH_REMATCH / sed \N indices stay countable.
SPOOL_AGENT_ID_NEW_RX='[acgmq]-[0-9]{3}'
# shellcheck disable=SC2034  # read by the scripts that source this file
SPOOL_AGENT_ID_RX="(${SPOOL_AGENT_ID_NEW_RX}|CLE-[0-9]+|GRK-[0-9]+|AGY-[0-9]+|QWN-[0-9]+)"
# The legacy half is the pre-061 participant grammar, so HUM-17 and test ids
# (ORC-1) still parse.
SPOOL_PARTICIPANT_RX="(${SPOOL_AGENT_ID_NEW_RX}|[A-Z]{2,4}-[0-9]+)"
SPOOL_ID_RE="^${SPOOL_PARTICIPANT_RX}\$"

# The clock the legacy cutoff reads (FR-004), as ISO-8601 UTC. SPOOL_NOW pins
# it (tests set it, so CI never turns red at the cutoff on its own); it takes
# 2026-10-02T12:00:00Z or epoch seconds. Fork-free.
spl_now_var() {  # VAR
  local _n="${SPOOL_NOW:-}"
  if [ -z "$_n" ]; then
    TZ=UTC printf -v _n '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  elif [[ "$_n" =~ ^[0-9]+$ ]]; then
    TZ=UTC printf -v _n '%(%Y-%m-%dT%H:%M:%SZ)T' "$_n"
  fi
  printf -v "$1" '%s' "$_n"
}

# 0 while the legacy form is still accepted on a write path (now <= cutoff).
spl_legacy_id_ok() {
  local _now
  spl_now_var _now
  ! [[ "$_now" > "$SPOOL_LEGACY_ID_UNTIL" ]]
}

# 0 when ID has the legacy shape (CLE-07, HUM-17, ORC-1), else 1.
spl_is_legacy_id() {  # ID
  [[ "${1:-}" =~ ^[A-Z]{2,4}-[0-9]+$ ]]
}

# The new id a legacy id was renamed to (specs/061 §5: the alias table
# $SPOOL_ROOT/agent-id-aliases.tsv, old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc,
# keyed (old, box) as the Go cmd/spool reader). ID@<box> picks that box's row;
# a bare ID resolves only when exactly one row names it. Else ID itself.
spl_agent_id_resolve() {  # ID[@BOX]
  local id="${1:-}" box="" old new _k b _r hit="" n=0 f="${SPOOL_ROOT:-/var/spool-hub}/agent-id-aliases.tsv"
  case "$id" in *@*) box="${id#*@}"; id="${id%%@*}" ;; esac
  if spl_is_legacy_id "$id" && [ -r "$f" ]; then
    while IFS=$'\t' read -r old new _k b _r; do
      [ "$old" = "$id" ] && [[ "$new" =~ ^${SPOOL_AGENT_ID_NEW_RX}$ ]] || continue
      [ -z "$box" ] || [ "$b" = "$box" ] || continue
      hit="$new"; n=$((n + 1))
    done < "$f"
    [ "$n" = 1 ] && { printf '%s' "$hit"; return 0; }
  fi
  printf '%s' "$id"
}

# 0 when agent id ID may be used on a write path, else 1 with the FR-003
# reason on stderr: the new form always, the legacy form until the cutoff.
_spl_id_write_ok() {  # ID
  spl_is_legacy_id "$1" || return 0
  spl_legacy_id_ok && return 0
  local to
  to="$(spl_agent_id_resolve "$1")"
  [ "$to" = "$1" ] && to="c-0NN"
  echo "spool-env: $1 is retired as an id; use ${to} (legacy ids ended ${SPOOL_LEGACY_ID_UNTIL}, specs/061)" >&2
  return 1
}

# 0 when ID is an agent id: c-004, or (until the cutoff) a legacy agent id.
# HUM-/GST-/BOX- are participants, never agents.
spl_is_agent_id() {  # ID
  local id="${1:-}"
  [[ "$id" =~ ^${SPOOL_AGENT_ID_NEW_RX}$ ]] && { [ "${id#?-}" != 000 ]; return; }
  spl_is_legacy_id "$id" || return 1
  case "${id%%-*}" in HUM|GST|BOX) return 1 ;; esac
  _spl_id_write_ok "$id"
}

# 0 when ID is any participant: an agent id (as spl_is_agent_id), or
# HUM-/GST-/BOX-NN, which 061 leaves unchanged.
spl_is_participant_id() {  # ID
  local id="${1:-}"
  [[ "$id" =~ $SPOOL_ID_RE ]] || return 1
  case "${id%%-*}" in HUM|GST|BOX) return 0 ;; esac
  _spl_id_write_ok "$id"
}

# The kind an agent id belongs to, by its letter (new) or prefix (legacy).
spl_kind_of_agent_id() {  # ID -> KIND
  case "${1:-}" in
    c-*|CLE-*) printf 'claude' ;;
    g-*|GRK-*) printf 'grok' ;;
    a-*|AGY-*) printf 'agy' ;;
    q-*|QWN-*) printf 'qwen' ;;
    m-*)       printf 'mistral' ;;
    *) return 1 ;;
  esac
}

# The kinds this feature can launch, and the legacy id prefix each one owns.
# mistral has none (spec 110 3.1: no MST- is ever minted): nothing, rc 1.
spool_prefix_of_kind() {  # KIND -> PREFIX
  case "${1:-}" in
    claude) printf 'CLE' ;;
    grok)   printf 'GRK' ;;
    agy)    printf 'AGY' ;;
    qwen)   printf 'QWN' ;;
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
  spl_is_participant_id "$id"
}

# SPOOL_FLEET_ENV / SPOOL_FLEET_TENANT (specs/058 N1): the hub env + tenant
# whose desk relays a send to an agent on another machine of the fleet.
# SPOOL_DIR_LAYOUT=qualified (specs/058 6): new mailboxes are <ID>@<box>.
# SPOOL_BOX_TAG: the <ID>@<tag> display tag. A cron job and an @reboot restore
# read no profile, so the tag lives here too, or they name windows bare.
SPOOL_BOX_ENV_KEYS="SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN MISTRAL_BIN SPOOL_AGENT_ID_RANGE SPOOL_DESK_BOX SPOOL_FLEET_ENV SPOOL_FLEET_TENANT SPOOL_DIR_LAYOUT SPOOL_BOX_TAG"

# Fill each unset SPOOL_BOX_ENV_KEYS variable from the box config.
_spool_box_env_load() {
  local f="${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}" k v
  [ -r "$f" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case " $SPOOL_BOX_ENV_KEYS " in *" $k "*) ;; *) continue ;; esac
    [ -n "${!k:-}" ] && continue
    v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf -v "$k" '%s' "$v"
  done <"$f"
}

_spool_home_of() {  # USER
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

_spool_feature_dir() {
  cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd
}

# The test guard (CLE-77923). A test harness sets SPOOL_TEST=1; under it the
# LIVE spool root is refused outright and every leg that leaves the sandbox is
# off by default: no tmux poke unless the test names its own socket, no hub
# relay unless it names SPOOL_FLEET_RELAY_CMD. responder-run.tst.sh isolated
# SPL_STATE_DIR but not the spool root, and every pre-push run filed its
# fixtures (t-aaa, t-bbb, t-ddd) into the orchestrator's real inbox and rang
# its real pane. SPOOL_LIVE_ROOT exists for the guard's own test, which cannot
# aim at the real root to prove the refusal. A refusal is also appended to
# SPOOL_TEST_GUARD_LOG: callers often send 2>/dev/null, and a refusal nobody
# sees cannot fail a sweep.
spool_test_guard() {
  [ "${SPOOL_TEST:-}" = 1 ] || return 0
  local live="${SPOOL_LIVE_ROOT:-/var/spool-hub}" rr lr
  rr="$(readlink -m -- "${SPOOL_ROOT:-$live}")"; lr="$(readlink -m -- "$live")"
  if [ "$rr" = "$lr" ]; then
    local msg="spool-env: REFUSED: SPOOL_TEST=1 and SPOOL_ROOT is the live root (${lr}); a test must give its own SPOOL_ROOT"
    echo "$msg" >&2
    [ -n "${SPOOL_TEST_GUARD_LOG:-}" ] && printf '%s (%s)\n' "$msg" "${0##*/}" >>"$SPOOL_TEST_GUARD_LOG"
    return 96
  fi
  SPOOL_TMUX_SOCKET="${SPOOL_TMUX_SOCKET:-$rr/.spool-test-no-tmux.sock}"
  [ -n "${SPOOL_FLEET_RELAY_CMD:-}" ] || SPOOL_FLEET_RELAY=0
  export SPOOL_TMUX_SOCKET SPOOL_FLEET_RELAY
  return 0
}

spool_env_resolve() {
  # exit, not return: callers source this and run unchecked, so a refusal that
  # returned would fall through to the send it exists to stop.
  spool_test_guard || exit 96
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  _spool_box_env_load
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
  SPOOL_ORCHESTRATOR_ID="${SPOOL_ORCHESTRATOR_ID:-c-001}"
  SPOOL_FEATURE_DIR="$(_spool_feature_dir)"
  if [ -z "${SPOOL_BIN:-}" ]; then
    # <repo>/csi-spl-orc/src/bash/features/spawn-agents -> <repo>
    local repo built
    repo="$(cd "$SPOOL_FEATURE_DIR/../../../../.." && pwd)"
    built="$repo/csi-spl-api/src/go/spool-hub-api/bin/spool"
    if [ -x "$built" ] && ! _spool_bin_stale "$repo" "$built"; then SPOOL_BIN="$built"
    else SPOOL_BIN="$(_spool_bin_fallback "$built")"
    fi
  fi

  # specs/028 FR-005: the box's own renderer, unless the operator names another
  # one or turns the terminal leg off. Not exported here - spool-harness.sh
  # decides which processes get it (the agent session and its hub-run sidecar).
  if [ -z "${SPOOL_NOTIFY_CMD:-}" ] && [ -x "$SPOOL_FEATURE_DIR/scripts/spool-notify.sh" ]; then
    SPOOL_NOTIFY_CMD="$SPOOL_FEATURE_DIR/scripts/spool-notify.sh"
  fi
  SPOOL_NOTIFY_CMD="${SPOOL_NOTIFY_CMD:-}"

  # The CLI paths cost a getent (SPOOL_AGENT_HOME) and, when no build output
  # exists, a `command -v` - and the notifier, the one caller on a latency
  # budget, never launches a CLI. It asks for them to be skipped (CLE-3435).
  # Opt-OUT, not opt-in: a caller that forgets gets the full resolve, which is
  # the safe direction.
  [ "${SPOOL_ENV_NO_BINS:-}" = 1 ] && { export SPOOL_ROOT; return 0; }

  SPOOL_AGENT_HOME="$(_spool_home_of "$SPOOL_AGENT_USER")"
  local cli var
  # mistral's binary is vibe (spec 110 2.1); the variable keeps the kind's name.
  for cli in claude grok agy qwen vibe; do
    var="$(printf '%s' "$cli" | tr '[:lower:]' '[:upper:]')_BIN"
    [ "$cli" = vibe ] && var=MISTRAL_BIN
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

# The spool binary the AGENT USER can run, for the seed it reads (c-908 msg
# 22a471ef). SPOOL_BIN is the spawner's: under its home (.local 0700) it is
# rc 126 for an agent user that differs. Resolved AS the agent user, because
# its PATH is what runs the seed's recv line; no answer (no sudo, no such
# user) keeps SPOOL_BIN unless it sits in the spawner's home, then bare
# `spool`. Guard: tests/test-seed-spool-bin.sh.
spool_agent_spool_bin() {
  local me b h
  me="$(id -un)"
  if [ "${SPOOL_AGENT_USER:-$me}" = "$me" ]; then printf '%s' "$SPOOL_BIN"; return 0; fi
  b="$(sudo -n -u "$SPOOL_AGENT_USER" bash -lc 'command -v spool' </dev/null 2>/dev/null | tail -n 1)"
  case "$b" in /*) printf '%s' "$b"; return 0 ;; esac
  for h in "$HOME" "$(_spool_home_of "$me")"; do
    case "$SPOOL_BIN" in "${h:-/nonexistent}"/*) printf 'spool'; return 0 ;; esac
  done
  printf '%s' "$SPOOL_BIN"
}

# ── Running a command as the agent user ─────────────────────────────────────
#   su-dash   sudo su --pty - <agent>  needs sudo to root
#   sudo-i    sudo -u <agent> -i bash  needs only `(<agent>) NOPASSWD`
#   same user: no hop; already root: su --pty - <agent>
#
# --pty, on a terminal only (ported from the frozen box engine, specs/048).
# `su -c` setsid()s its child, so a CLI started by plain `su - <agent> -c` has
# no controlling tty: a tmux split or resize never reaches it as SIGWINCH and it
# keeps drawing at the old width (the notice strip split into a live agent's
# window garbles every line). Off a terminal --pty is harmful: su turns every
# \n into \r\n and echoes piped stdin, so captured output is mangled.
# SPOOL_AGENT_PTY=1|0 overrides the terminal test (default auto); --tty builds
# the terminal form whatever fd 0/1 are (for the "resume with" hints).
# `sudo -u <agent> -i` needs no flag: sudo's own pty makes the CLI its
# foreground job.
spool_agent_argv() {  # [--tty]
  local pty=()
  case "${1:-}:${SPOOL_AGENT_PTY:-auto}" in
    --tty:*|*:1) pty=(--pty) ;;
    *:0) ;;
    *) if [ -t 0 ] && [ -t 1 ]; then pty=(--pty); fi ;;
  esac
  case "$SPOOL_RUN_AS_AGENT" in
    su-dash|sudo-i) ;;
    *) echo "spool-env: unknown SPOOL_RUN_AS_AGENT '${SPOOL_RUN_AS_AGENT}' (want su-dash or sudo-i)" >&2; return 2 ;;
  esac
  if [ "$(id -un)" = "$SPOOL_AGENT_USER" ]; then SPOOL_AGENT_ARGV=(bash -l); return 0; fi
  if [ "$(id -u)" = 0 ]; then SPOOL_AGENT_ARGV=(su "${pty[@]}" - "$SPOOL_AGENT_USER"); return 0; fi
  case "$SPOOL_RUN_AS_AGENT" in
    su-dash) SPOOL_AGENT_ARGV=(sudo su "${pty[@]}" - "$SPOOL_AGENT_USER") ;;
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

spool_agent_cmd_text() { spool_agent_argv --tty >/dev/null 2>&1 || return 0; printf '%s' "${SPOOL_AGENT_ARGV[*]}"; }

# The permission / autonomy flags of each harness: the ONE place they live
# (060 FR-061, 102 spec 9.2). Spawn, restore, chain, rotation and the lane
# restart take them from here; no launcher writes its own. claude and agy:
# --dangerously-skip-permissions (bypass, the fleet's only mode); grok: that
# name plus the explicit mode, so a spawn does not depend on its config.toml
# (measured grok 1.0.41: the pair parses); qwen: --yolo; mistral (vibe):
# --auto-approve (spec 110 3.3).
spool_claude_perm_flags() {  # [KIND]   default claude
  case "${1:-claude}" in
    claude|agy) printf '%s' '--dangerously-skip-permissions' ;;
    grok)       printf '%s' '--dangerously-skip-permissions --permission-mode bypassPermissions' ;;
    qwen)       printf '%s' '--yolo' ;;
    mistral)    printf '%s' '--auto-approve' ;;
    *) echo "spool-env: no permission flags for harness '${1}'" >&2; return 2 ;;
  esac
}

# Self-update is off for every agent CLI (102 spec 9.1): the controlled update
# (do_spl_cli_update) is the only path to a new version. Exported here, so
# spool-harness.sh (which sources this file as the agent user, right before it
# exec-s the CLI) hands it to every launch; SPOOL_CLI_ENV is the same pair for
# the launch lines that cross the user hop, where an export does not survive.
export DISABLE_AUTOUPDATER=1
# shellcheck disable=SC2034  # read by the launchers that source this file
SPOOL_CLI_ENV="DISABLE_AUTOUPDATER='1'"

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

# The ONE name of an agent (spec 061, owner 07af027a): "<id>@<tag>", e.g.
# c-036@<tag>. It is the `claude --name`, the FIRST token of the tmux window
# (a title may follow after a space), and what every spawn, restore, rotation
# and rename writes. The tag is SPOOL_BOX_TAG, else the box config (box.env),
# so a cron or @reboot launcher that read no profile names alike; no tag
# anywhere = the bare id. The old "<tag>: <id>" shape (SPOOL_NAME_STYLE=colon)
# is gone: parsers still read it, nothing writes it.
# tests/test-agent-name-shape.sh fails when a launcher writes another shape.
spool_decorate() {  # ID
  local t="${SPOOL_BOX_TAG:-}"
  [ -n "$t" ] || t="$(SPOOL_BOX_TAG=''; _spool_box_env_load; printf '%s' "$SPOOL_BOX_TAG")"
  if [ -z "$t" ]; then printf '%s' "$1"; else printf '%s@%s' "$1" "$t"; fi
}

# The agent id a window name carries, or nothing. Accepts an optional
# "<tag>: " in front and anything after the id ("CLE-07 > wip").
#
# Fork-free on purpose (CLE-3435). spool_pane_of calls this once per live pane
# on the terminal-delivery hot path, and the `sed` it used to run cost ~3.5 ms
# a pane: 52 ms of the notifier's budget across the 15 panes live on the box
# when it was measured, and that grows with the fleet. Parameter expansion
# reads the same grammar: the stripped prefix is anchored and its character
# class excludes both ':' and ' ', so it can only ever be the text before the
# FIRST ": " - which is exactly ${n%%: *}.
spool_id_of_window_var() {  # VAR WINDOW_NAME
  local n="${2:-}" pre
  case "$n" in
    *": "*) pre="${n%%: *}"
            [[ "$pre" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && n="${n#*: }" ;;
  esac
  n="${n%% *}"
  n="${n%%@*}"   # "CLE-07@sat": the box is display (specs/058)
  [[ "$n" =~ $SPOOL_ID_RE ]] || n=""
  printf -v "$1" '%s' "$n"
}

# The printing wrapper, for callers that read it once. On the hot path use the
# _var form: `$(spool_id_of_window ...)` forks a subshell per call, which is
# the very cost the parameter expansion above exists to remove.
spool_id_of_window() {  # WINDOW_NAME
  local _idw
  spool_id_of_window_var _idw "${1:-}"
  printf '%s' "$_idw"
  return 0
}

# The live pane of an agent: registry rows newest-first whose pane still
# exists AND whose window still carries the id, else the first live window
# named for the id. Puts the pane id (%NN), or '', in VAR, and that pane's tty
# in SPOOL_PANE_TTY and its foreground command in SPOOL_PANE_CMD.
#
# One tmux round trip and one id parse per live pane (CLE-3435). It used to
# re-scan the whole pane list - id-parsing every row again - once per registry
# row of the id, so it paid R x P parses where P is enough; with a `sed` per
# parse that was 110 ms of a 190 ms notifier.
#
# The _var form exists because the caller on the hot path is the notifier, and
# `pane="$(spool_pane_of "$to")"` is a subshell: it forks, and it drops
# SPOOL_PANE_TTY on the floor, so the poke then paid a `display-message` round
# trip to re-learn a tty this function already had.
spool_pane_of_var() {  # VAR ID
  local __pv="$1" id="$2" reg="$SPOOL_ROOT/registry.tsv" p tty cmd w rid i
  local -a order=() regrows=()
  local -A pid=() ptty=() pcmd=()
  SPOOL_PANE_TTY=""; SPOOL_PANE_CMD=""
  printf -v "$__pv" '%s' ""
  spool_tmux_argv
  while IFS=$'\t' read -r p tty cmd w; do
    [ -n "$p" ] || continue
    order+=("$p")
    spool_id_of_window_var rid "$w"
    pid["$p"]="$rid"
    ptty["$p"]="$tty"
    pcmd["$p"]="$cmd"
  done < <("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id}	#{pane_tty}	#{pane_current_command}	#{window_name}' 2>/dev/null || true)
  [ "${#order[@]}" -gt 0 ] || return 0

  # The identity map first (SPEC-agent-identity-map.md): the pane of the
  # process that carries SPOOL_AGENT_ID=<id>, proven live (pid, start time,
  # env) and present on the server. A window NAME cannot mislead it - after a
  # restart or a sort, names and registry rows were what pointed pokes at the
  # wrong agent. No record, or not provably alive: the old lookup below.
  if [ -r "$SPOOL_ROOT/agents/$id.json" ]; then
    type ai_pane_of >/dev/null 2>&1 || . "$_SPOOL_ENV_LIB_DIR/agent-identity.inc.sh" 2>/dev/null
    if p="$(ai_pane_of "$id" "$(printf '%s\n' "${order[@]}")" 2>/dev/null)" && [ -n "$p" ]; then
      SPOOL_PANE_TTY="${ptty[$p]:-}"; SPOOL_PANE_CMD="${pcmd[$p]:-}"
      printf -v "$__pv" '%s' "$p"; return 0
    fi
  fi

  # The registry appends, so its rows for an id are oldest-first: walk back.
  if [ -r "$reg" ]; then
    while IFS=$'\t' read -r rid _ p _; do
      [ "$rid" = "$id" ] && regrows+=("$p")
    done < "$reg"
    for (( i=${#regrows[@]}-1; i>=0; i-- )); do
      p="${regrows[$i]}"
      if [ -n "$p" ] && [ "${pid[$p]:-}" = "$id" ]; then
        SPOOL_PANE_TTY="${ptty[$p]}"; SPOOL_PANE_CMD="${pcmd[$p]}"
        printf -v "$__pv" '%s' "$p"; return 0
      fi
    done
  fi
  for p in "${order[@]}"; do
    if [ "${pid[$p]}" = "$id" ]; then
      SPOOL_PANE_TTY="${ptty[$p]}"; SPOOL_PANE_CMD="${pcmd[$p]}"
      printf -v "$__pv" '%s' "$p"; return 0
    fi
  done
}

# The printing wrapper, for callers that only want the pane id. A command
# substitution round it cannot carry SPOOL_PANE_TTY back out.
spool_pane_of() {  # ID
  local _pane
  spool_pane_of_var _pane "$1"
  printf '%s' "$_pane"
  return 0
}

# Bare agent id, or "". Drops a "<tag>: " prefix and an "@<box>" suffix the
# way spool_id_of_window does, then keeps a new id (c-004) or a legacy one
# (CLE-07). spl_is_agent_id is the wrong test here: past the legacy cutoff it
# rejects a live CLE- lane, and this question is "who is calling", not "may
# this id be written".
_spool_bare_agent_id() {  # TEXT
  local n="${1:-}"
  n="${n##*: }"
  n="${n%%@*}"
  n="${n%% *}"
  [[ "$n" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || n=""
  printf '%s' "$n"
}

# SPOOL_AGENT_ID, else MCP_BOT_AGENT_ID, from PID's environ. The harness
# exports both (spawn-core.inc.sh LAUNCH, spool-harness.sh, spool-agent.sh).
# spool_proc_environ reads another user's environ (proc-owner.inc.sh).
_spool_pid_agent_id() {  # PID
  local kv spool="" mcp=""
  [ -n "${1:-}" ] || return 0
  # shellcheck source=proc-owner.inc.sh
  declare -F spool_proc_environ >/dev/null 2>&1 || . "${_SPOOL_ENV_LIB_DIR}/proc-owner.inc.sh"
  while IFS= read -r -d '' kv; do
    case "$kv" in
      SPOOL_AGENT_ID=*) spool="$(_spool_bare_agent_id "${kv#*=}")" ;;
      MCP_BOT_AGENT_ID=*) mcp="$(_spool_bare_agent_id "${kv#*=}")" ;;
    esac
  done < <(spool_proc_environ /proc "$1" 2>/dev/null || true)
  printf '%s' "${spool:-$mcp}"
}

# The spool id of the session calling a spawn, or "" when this is a shell
# with no agent id (a human, or a cron tick).
#
#   1. SPOOL_AGENT_ID, else MCP_BOT_AGENT_ID. riname.sh and agent-send.sh
#      read those two first; the harness put them in the session's environ.
#   2. The id in the window name of $TMUX_PANE (riname.sh,
#      kill-your-self-report.sh), via spool_id_of_window.
#   3. The registry.tsv row whose pane column (field 3) equals $TMUX_PANE.
#      Newest row wins; the file is append-only. agent-top.sh registry_row
#      matches the same column.
#   4. The closest ancestor that still carries the id. `sudo -u` strips
#      SPOOL_AGENT_ID and TMUX_PANE from the child (tmux-close-window.sh);
#      the agent process the harness started still has them. Skipped when
#      SPAWN_TEST_SANDBOX=1, so a suite running inside a lane is not that lane.
#   5. SPAWN_REQUESTER, only when nothing above named an id. spawn-remote.sh
#      --serve sets it from the verified request `from` (the cron tick that
#      runs spawn-window on the target machine has no agent id of its own).
spool_spawn_requester() {
  local id="" w raw pid hops
  id="$(_spool_bare_agent_id "${SPOOL_AGENT_ID:-}")"
  [ -n "$id" ] || id="$(_spool_bare_agent_id "${MCP_BOT_AGENT_ID:-}")"
  if [ -z "$id" ] && [ -n "${TMUX_PANE:-}" ]; then
    spool_tmux_argv
    w="$("${SPOOL_TM[@]}" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || true)"
    id="$(spool_id_of_window "$w")"
    if [ -z "$id" ] && [ -r "${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" ]; then
      raw="$(awk -F'\t' -v p="$TMUX_PANE" '$3 == p { id = $1 } END { print id }' "${SPOOL_ROOT}/registry.tsv")"
      id="$(_spool_bare_agent_id "$raw")"
    fi
  fi
  if [ -z "$id" ] && [ "${SPAWN_TEST_SANDBOX:-0}" != 1 ]; then
    pid="${PPID:-}"
    hops=0
    while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$hops" -lt 16 ]; do
      id="$(_spool_pid_agent_id "$pid")"
      [ -n "$id" ] && break
      pid="$(awk '/^PPid:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || true)"
      hops=$((hops + 1))
    done
  fi
  if [ -z "$id" ]; then
    raw="${SPAWN_REQUESTER:-}"
    if [ "$raw" = "-" ]; then id="-"
    else id="$(_spool_bare_agent_id "$raw")"; fi
  fi
  printf '%s' "$id"
}

# 0 for a role seat. These three ids, on any box; the "@<box>" is already
# stripped. A lease.conf id that is not one of them is still a lane.
spool_spawn_is_seat() {  # ID
  case "$1" in c-001|c-002|c-003) return 0 ;; *) return 1 ;; esac
}

# Allow a seat or a shell with no agent id. A lane is exit 9 and one line on
# stderr naming it. SPAWN_ALLOW_LANE=1 with a non-empty SPAWN_ALLOW_REASON
# allows the lane and appends one line to $SPOOL_ROOT/spawn-allow.log.
# Prints the requester token ("-" when there is no agent id).
spool_spawn_gate() {
  local req reason root
  req="$(spool_spawn_requester)"
  [ -n "$req" ] || req="-"
  if [ "$req" = "-" ] || spool_spawn_is_seat "$req"; then
    printf '%s' "$req"
    return 0
  fi
  reason="$(printf '%s' "${SPAWN_ALLOW_REASON:-}" | tr '\t\n\r' ' ' | sed 's/^ *//; s/ *$//' | cut -c1-200)"
  if [ "${SPAWN_ALLOW_LANE:-}" = 1 ] && [ -n "$reason" ]; then
    echo "spawn: ALLOW requester ${req} (SPAWN_ALLOW_LANE=1): ${reason}" >&2
    root="${SPOOL_ROOT:-/var/spool-hub}"
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$req" "$reason" >>"$root/spawn-allow.log" 2>/dev/null || true
    chmod 0664 "$root/spawn-allow.log" 2>/dev/null || true
    printf '%s' "$req"
    return 0
  fi
  if [ "${SPAWN_ALLOW_LANE:-}" = 1 ]; then
    echo "spawn: refused: requester ${req} is a lane; SPAWN_ALLOW_LANE=1 needs a reason in SPAWN_ALLOW_REASON" >&2
  else
    echo "spawn: refused: requester ${req} is a lane; only c-001, c-002 and c-003, or a shell with no agent id, may spawn" >&2
  fi
  return 9
}
