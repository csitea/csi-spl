#!/usr/bin/env bash
# shellcheck disable=SC2034 # CM_* globals: the sourcing actions read them
# channel-move.inc.sh — spec 167 row B1: the channel move's manifest (derive +
# declare), its read-only plan, and the caller check of D1.
#
# The manifest is one box-local file per channel, never in git (it names
# customer paths): $SPOOL_ROOT/channel-move/<tenant>-<channel>.manifest, 0600,
# one line per item, "<kind> <path> [<extra>...]". Seats DECLARE data, config,
# binary, secret, marker and tests-not-run lines (do_spl_channel_manifest_add);
# the plan DERIVES seat, repo, uncommitted, scratch, transcript and spool lines
# from code (spec 167 4.2). An undeclared path is not found: a plan lists what
# the manifest holds and proves nothing absent.
#
# The caller check (spec 167 4.1, D1): the owner or the orchestrator seat only.
#   - agent: an agent CLI in the caller's process ancestry, an agent id in the
#     environ of a process of it, or a tmux pane in it registered to an agent.
#     Its id comes from the PANE (window name, else registry pane column),
#     never from an environment variable; it must be the fleet's orch lease
#     holder (<spool root>/dispatch/lease.orch, "<id>@<box> <epoch>") on this
#     box. One exception: MOVE_CMD=ack by the seat the journal of that MOVE_ID
#     names (a journal step "S6:<id>@<box>").
#   - owner: no agent, a tty on stdin, the box user's own login (not a sudo
#     from another user). Only a mistake-catcher (R5): a command that changes
#     something (DRY_RUN=0) also needs an owner-signed directive over its own
#     text, signed in a 5-minute window this action opens and shuts (C22, C24).
#   - anything else (no tty, cron, an unknown pane) is refused.
#
# What the check trusts, outside SPOOL_TEST=1 (c-715 review W1-W3): the live
# spool root /var/spool-hub (lease.orch, registry.tsv, the journals), the box
# tag from its box config (box.env SPOOL_BOX_TAG, never the environment), the
# box user as the owner of that root, the tmux socket of that user, the
# directive scripts next to this file, called with every DIRECTIVE_* knob,
# SPOOL_BOX_ENV and GNUPGHOME stripped (the pin then comes from the box
# config). The caller id comes from the registry row of its pane; a window
# name that names another id is refused (a lane can rename its window).
# The limits (N1): the owner process test reads SUDO_USER from the
# environment and is a mistake-catcher only (spec 167 R5); a caller that
# runs its own copy of this code, sets a BASH_ENV (it runs in the action's
# own shell before its first line, c-715 N7), or edits the registry, is not
# stopped by any shell check, the driver's own verify included: the barrier
# is the owner's passphrase and the verify on the OTHER box (the hub path).
# Outside SPOOL_TEST do_spl_channel_move refuses an exported function and
# runs the action in a fresh env -i process with PATH = CM_SAFE_PATH (c-715
# W4, W5). Under SPOOL_TEST=1 the spool root is $SPOOL_ROOT (the spool test
# guard refuses the live one) and the environment is trusted, for the tests.
# SPOOL_TEST=1 is itself an environment variable (c-715 N5): with it and a
# fake root every seam is honoured again, so a cm_cmd_* hook (rows B4, B5)
# must, under SPOOL_TEST=1, refuse any path, pane or ssh target outside
# $SPOOL_ROOT and its sandbox, and never drive a live seat.
# The registry is keyed on the pane id (%N), which tmux reuses after a server
# restart (c-715 N6, unverified): an old row can name a dead agent when the
# window carries no id. B4/B5 re-check the id is live before acting on it.
#
# Seams, honoured only under SPOOL_TEST=1: MOVE_CALLER_PROC (a fake /proc),
# MOVE_CALLER_PID (where the walk starts), MOVE_DIRECTIVE_DIR (the directive
# scripts), SPOOL_BOX_TAG, SPOOL_BOX_USER and SPOOL_TMUX_SOCKET from the
# environment. Always: MOVE_SSH (the ssh command prefix to the other box),
# MOVE_UPLINK_KBPS (skip the 1 MB probe).
# Guard: csi-spl-orc/src/bash/tests/channel-move-plan.tst.sh.

CM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=channel-rules.inc.sh
declare -F cr_map >/dev/null || . "$CM_LIB_DIR/channel-rules.inc.sh"
CM_KINDS_DECLARED='data config binary secret marker tests-not-run'
CM_AGENT_COMMS='claude grok agy antigravity vibe mistral qwen codex gemini'
CM_ID_RX='[a-z]-[0-9]{3}'

CM_LIVE_ROOT=/var/spool-hub

cm_in_test() { [ "${SPOOL_TEST:-}" = 1 ]; }

cm_dir() { printf '%s/channel-move' "${SPOOL_ROOT:-/var/spool-hub}"; }

# The spool root the caller check reads: the live one outside SPOOL_TEST.
cm_trust_root() {
  if cm_in_test; then printf '%s' "${SPOOL_ROOT:-$CM_LIVE_ROOT}"; else printf '%s' "$CM_LIVE_ROOT"; fi
}

# KEY's value in the trusted root's box config, parse-only.
cm_box_env_get() {  # KEY
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k="${k#export }"; k="${k// /}"
    [ "$k" = "$1" ] || continue
    v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf '%s' "$v"; return 0
  done 2>/dev/null <"$(cm_trust_root)/box.env"
  return 0
}

# The box user: the owner of the trusted spool root (SPOOL_BOX_USER in tests).
cm_box_user() {
  if cm_in_test; then printf '%s' "${SPOOL_BOX_USER:-}"; else stat -c %U "$(cm_trust_root)" 2>/dev/null; fi
}

# cm_parse_channel "<tenant>/<channel>": sets CM_TENANT, CM_CHANNEL; 2 + one
# line on stderr when it is not that shape.
cm_parse_channel() {
  local v="${1:-}"
  if [[ "$v" =~ ^(${CR_TENANT_RX})/(${CR_CHANNEL_RX})$ ]]; then
    CM_TENANT="${BASH_REMATCH[1]}"; CM_CHANNEL="${BASH_REMATCH[2]}"; return 0
  fi
  echo "channel-move: CHANNEL must be <tenant>/<channel>, got '$v'" >&2
  return 2
}

cm_manifest_path() { printf '%s/%s-%s.manifest' "$(cm_dir)" "$1" "$2"; }

cm_home_of() { [ -n "${1:-}" ] && getent passwd "$1" 2>/dev/null | cut -d: -f6; }

# cm_allowed_path PATH: 0 when PATH resolves under an allowed root (spec 167
# 4.2): /opt/<org>, /var/tmp, /tmp, $SPOOL_ROOT, the agent user's and the box
# user's home.
cm_allowed_path() {
  local p r h
  p="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  [[ "$p" =~ ^/opt/[^/]+/. ]] && return 0
  for r in /var/tmp /tmp "${SPOOL_ROOT:-/var/spool-hub}" \
           "$(cm_home_of "${SPOOL_AGENT_USER:-}")" "$(cm_home_of "${SPOOL_BOX_USER:-}")"; do
    [ -n "$r" ] && [ "$r" != / ] || continue
    h="$(realpath -m -- "$r")"
    [[ "$p" == "$h"/* ]] && return 0
  done
  return 1
}

# ---- the caller check (D1) -------------------------------------------------

cm_proc_root() {
  if [ "${SPOOL_TEST:-}" = 1 ] && [ -n "${MOVE_CALLER_PROC:-}" ]; then printf '%s' "$MOVE_CALLER_PROC"
  else printf /proc; fi
}

cm_start_pid() {
  if [ "${SPOOL_TEST:-}" = 1 ] && [ -n "${MOVE_CALLER_PID:-}" ]; then printf '%s' "$MOVE_CALLER_PID"
  else printf '%s' "$$"; fi
}

# The caller's pids, itself first, up to (not into) the tmux server or pid 1.
cm_chain() {  # ROOT PID
  local root="$1" pid="$2" n=0 comm
  while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
    comm="$(cat "$root/$pid/comm" 2>/dev/null)" || break
    case "$comm" in tmux*) break ;; esac
    echo "$pid"
    pid="$(awk '/^PPid:/ { print $2; exit }' "$root/$pid/status" 2>/dev/null)"
    n=$((n + 1))
  done
}

# "<pid> <how>" of the first agent sign in CHAIN: a CLI by its comm, or an
# agent id in a readable environ (presence only, never the identity).
cm_chain_agent() {  # ROOT CHAIN
  local root="$1" p comm
  for p in $2; do
    comm="$(cat "$root/$p/comm" 2>/dev/null)"
    case " $CM_AGENT_COMMS " in *" $comm "*) echo "$p cli:$comm"; return 0 ;; esac
    if tr '\0' '\n' 2>/dev/null <"$root/$p/environ" | grep -qE '^(SPOOL_AGENT_ID|MCP_BOT_AGENT_ID)=.+'; then
      echo "$p environ"; return 0
    fi
  done
  return 1
}

# "<pane pid>\t<pane id>\t<window name>" of every pane on this box's server.
cm_panes() {
  local u sock
  u="$(cm_box_user)"
  if cm_in_test; then sock="${SPOOL_TMUX_SOCKET:-}"; else sock="/tmp/tmux-$(id -u "$u" 2>/dev/null)/default"; fi
  local -a tm=(tmux ${sock:+-S "$sock"})
  [ -z "$u" ] || [ "$(id -un)" = "$u" ] || tm=(sudo -n -u "$u" "${tm[@]}")
  timeout 5 "${tm[@]}" list-panes -a -F '#{pane_pid}	#{pane_id}	#{window_name}' 2>/dev/null
}

# The agent id of the first pane in CHAIN: the newest registry row for its
# pane id. "?" when no row names the pane, or when its window name names
# another id (a lane can rename its window, c-715 W2); nothing when the chain
# holds no pane.
cm_chain_pane_id() {  # CHAIN
  local p ppid pid w id wid reg
  reg="$(cm_trust_root)/registry.tsv"
  local -A pane=() win=()
  while IFS=$'\t' read -r ppid pid w; do
    [ -n "$ppid" ] && { pane[$ppid]="$pid"; win[$ppid]="$w"; }
  done < <(cm_panes)
  for p in $1; do
    [ -n "${pane[$p]+x}" ] || continue
    id="$(awk -F'\t' -v q="${pane[$p]}" '$3 == q { i = $1 } END { print i }' "$reg" 2>/dev/null)"
    id="${id%%@*}"
    wid="$(spool_id_of_window "${win[$p]}" 2>/dev/null)"
    if [[ "$id" =~ ^${CM_ID_RX}$ ]] && { [ -z "$wid" ] || [ "$wid" = "$id" ]; }; then echo "$id"; return 0; fi
    echo "?"; return 0
  done
}

# This box's tag: the box config's SPOOL_BOX_TAG, never the environment
# outside SPOOL_TEST (c-715 W3).
cm_box() {
  if cm_in_test; then printf '%s' "${SPOOL_BOX_TAG:-}"; else cm_box_env_get SPOOL_BOX_TAG; fi
}

# 0 when ID@<this box> is the fleet's orch lease holder.
cm_is_orch() {  # ID
  local h=""
  read -r h _ <"$(cm_trust_root)/dispatch/lease.orch" 2>/dev/null || return 1
  [ -n "$1" ] && [ -n "$(cm_box)" ] && [ "$h" = "$1@$(cm_box)" ]
}

# 0 when the journal of MOVE_ID names ID as a new seat on this box.
cm_journal_names_seat() {  # MOVE_ID ID
  local j
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,63}$ ]] || return 1
  j="$(cm_trust_root)/channel-move/$1/journal.tsv"
  [ -r "$j" ] || return 1
  awk -F'\t' -v s="S6:$2@$(cm_box)" '$1 == s { f = 1 } END { exit !f }' "$j"
}

# 0 when the caller is the box user's own login on a tty.
cm_owner_process() {
  [ -t 0 ] || { CM_WHY="no tty on stdin (cron, a pipe or a detached process)"; return 1; }
  local u; u="$(cm_box_user)"
  [ -n "$u" ] || { CM_WHY="no box user known"; return 1; }
  [ "$(id -un)" = "$u" ] || { CM_WHY="not the box user's login ($(id -un))"; return 1; }
  [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "$u" ] ||
    { CM_WHY="a sudo from $SUDO_USER, not the box user's own login"; return 1; }
}

# cm_caller_check CMD: 0 = allowed, CM_CALLER set to "owner", "orch <id>" or
# "seat <id>". 3 = refused, one line on stderr naming why.
cm_caller_check() {  # CMD
  local cmd="$1" root chain agent="" id=""
  root="$(cm_proc_root)"; chain="$(cm_chain "$root" "$(cm_start_pid)")"
  agent="$(cm_chain_agent "$root" "$chain")"
  id="$(cm_chain_pane_id "$chain")"
  CM_CALLER="" CM_WHY=""
  if [ -n "$agent" ] || [ -n "$id" ]; then
    if [ "$cmd" = ack ] && [ -n "$id" ] && [ "$id" != "?" ] && [ "$id" = "${SEAT:-}" ] &&
       cm_journal_names_seat "${MOVE_ID:-}" "$id"; then CM_CALLER="seat $id"; return 0; fi
    if [ -n "$id" ] && [ "$id" != "?" ] && [ "$cmd" != ack ] && cm_is_orch "$id"; then CM_CALLER="orch $id"; return 0; fi
    echo "channel-move REFUSED: the caller is an agent (${agent:-pane}${id:+, pane id $id}), not the orch lease holder$([ "$cmd" = ack ] && echo ' and not the seat the journal of MOVE_ID names'); D1: the owner or the orchestrator seat only. Nothing was read." >&2
    return 3
  fi
  if [ "$cmd" = ack ]; then echo "channel-move REFUSED: an ack runs only in the new seat's own pane. Nothing was read." >&2; return 3; fi
  cm_owner_process || { echo "channel-move REFUSED: not the owner ($CM_WHY) and no agent; D1. Nothing was read." >&2; return 3; }
  CM_CALLER=owner
}

# ---- the owner's signed directive (C22, C24) -------------------------------

# The directive scripts: next to this file; MOVE_DIRECTIVE_DIR in tests only.
cm_dir_scripts() {
  if cm_in_test && [ -n "${MOVE_DIRECTIVE_DIR:-}" ]; then printf '%s' "$MOVE_DIRECTIVE_DIR"
  else printf '%s' "$CM_LIB_DIR/../../directive/scripts"; fi
}

# Run directive script NAME. Outside SPOOL_TEST it runs under `env -i` with
# an allow-list only (c-715 W1'): a fixed PATH, HOME from getent, USER and
# LOGNAME, LANG, TERM and GPG_TTY for the pinentry, SPOOL_ROOT the live root,
# DIRECTIVE_BOX this box's trusted tag. So no DIRECTIVE_* knob, BASH_ENV,
# PATH entry, LD_PRELOAD or exported function of the caller reaches it; the
# pin, keyring, ledger and window record come from the box config and the
# user's own home. bash and env by absolute path.
CM_SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cm_dir_run() {  # NAME ARGS...
  local f h u t=""; f="$(cm_dir_scripts)/$1"; shift
  if cm_in_test; then DIRECTIVE_BOX="$(cm_box)" bash "$f" "$@"; return; fi
  u="$(id -un)"; h="$(cm_home_of "$u")"
  [ -t 0 ] && t="$(/usr/bin/tty 2>/dev/null)"
  /usr/bin/env -i PATH="$CM_SAFE_PATH" HOME="${h:-/nonexistent}" USER="$u" LOGNAME="$u" \
    LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" ${t:+GPG_TTY="$t"} \
    SPOOL_ROOT="$(cm_trust_root)" DIRECTIVE_BOX="$(cm_box)" /bin/bash "$f" "$@"
}

# The text an owner command signs: command, channel, target, move id.
cm_directive_text() {  # CMD CHANNEL TO MOVE_ID
  printf 'channel-move %s CHANNEL=%s TO=%s MOVE_ID=%s' "$1" "$2" "$3" "$4"
}

# cm_owner_sign OUTDIR TEXT DRIVER [PEER]: envelopes OUTDIR/envelope.<box>.asc
# for the driver box and, when the other box acts through the hub, for PEER,
# all in one window. A window the owner had open is used and left open; else
# a 5-minute one is opened and shut before this returns. 3 = refused.
cm_owner_sign() {  # OUTDIR TEXT DRIVER [PEER]
  local out="$1" text="$2" opened=0 box rc=0
  if ! grep -q 'session OPEN' <<<"$(cm_dir_run directive-session.sh --status 2>/dev/null)"; then
    cm_dir_run directive-session.sh --minutes 5 >&2 || { echo "channel-move REFUSED: no signing window (directive-session.sh --minutes 5 failed)" >&2; return 3; }
    opened=1
  fi
  for box in "$3" ${4:+"$4"}; do
    ( umask 077; cm_dir_run directive-sign.sh --minutes 10 "$box" "$text" >"$out/envelope.$box.asc" ) || rc=3
  done
  [ "$opened" = 1 ] && cm_dir_run directive-session.sh --close >/dev/null 2>&1
  [ "$rc" = 0 ] || echo "channel-move REFUSED: the owner directive could not be signed" >&2
  return "$rc"
}

# cm_owner_verify ENVELOPE TEXT: 0 when it verifies on this box (its own `to:`
# check and nonce ledger) and its instruction is exactly TEXT. 3 = refused.
cm_owner_verify() {  # ENVELOPE TEXT
  local got rc
  got="$(cm_dir_run directive-verify.sh --show <"$1" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] || [ "$got" != "$2" ]; then
    echo "channel-move REFUSED: the owner directive did not verify on $(cm_box) (rc $rc): ${got//$'\n'/ }" >&2
    return 3
  fi
}

# cm_owner_directive CMD MOVE_ID PEER: sign + verify before any change. Sets
# CM_ENVELOPES (the dir) and CM_DIRECTIVE_NONCE. 3 = refused.
cm_owner_directive() {  # CMD MOVE_ID PEER
  local text out
  [ -n "$(cm_box)" ] || { echo "channel-move REFUSED: this box has no tag (box.env SPOOL_BOX_TAG)" >&2; return 3; }
  text="$(cm_directive_text "$1" "${CHANNEL:-}" "${TO:-}" "$2")"
  out="$(umask 077 && mktemp -d)" || return 3
  cm_owner_sign "$out" "$text" "$(cm_box)" "$3" || { rm -rf "$out"; return 3; }
  cm_owner_verify "$out/envelope.$(cm_box).asc" "$text" || { rm -rf "$out"; return 3; }
  CM_ENVELOPES="$out"
  CM_DIRECTIVE_NONCE="$(sed -n 's/^nonce: //p' "$out/envelope.$(cm_box).asc" | sed -n 1p)"
}

# ---- the manifest: declared + derived --------------------------------------

# Declared lines of the manifest, comments and blanks dropped.
cm_manifest_declared() {  # TENANT CHANNEL
  local m; m="$(cm_manifest_path "$1" "$2")"
  [ -r "$m" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$m"
}

# The channel's seats: column 6 of its channel-rules row, plus every live
# registry id whose brief names "Channel: <tenant> #<channel>".
cm_seats() {  # TENANT CHANNEL
  local root="${SPOOL_ROOT:-/var/spool-hub}" sole id ch
  sole="$(cr_sole_seat "$1" "$2" 2>/dev/null)"; sole="${sole%%@*}"
  {
    [[ "$sole" =~ ^${CM_ID_RX}$ ]] && echo "$sole"
    for id in $(awk -F'\t' '{ print $1 }' "$root/registry.tsv" 2>/dev/null | sort -u); do
      [[ "$id" =~ ^${CM_ID_RX}$ ]] && [ -d "$root/$id" ] || continue
      ch="$(cr_channel_of "$root/$id/lifetime/brief.md" "$root/$id/lifetime/prompt.txt" 2>/dev/null)" || continue
      [ "$ch" = "$1 $2" ] && echo "$id"
    done
  } | sort -u
}

cm_worktree_of() {  # ID
  awk -F'\t' -v i="$1" '$1 == i { w = $4 } END { print w }' "${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" 2>/dev/null
}

# Derived lines for one seat (spec 167 4.2). Claude's scratch and transcripts
# only: the other vendors' dirs are not derived yet (the plan says so).
cm_derive_seat() {  # ID
  local id="$1" root="${SPOOL_ROOT:-/var/spool-hub}" wt slug h r d
  echo "seat $id"
  wt="$(cm_worktree_of "$id")"
  if [ -n "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    r="$(git -C "$wt" remote 2>/dev/null | sed -n 1p)"
    echo "repo $wt ${r:--}"
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || echo "uncommitted $wt"
  fi
  [ -d "/var/tmp/$id" ] && echo "scratch /var/tmp/$id"
  if [ -n "$wt" ]; then
    slug="${wt//\//-}"
    for d in /tmp/claude-*/"$slug"; do [ -d "$d" ] && echo "scratch $d"; done
    h="$(cm_home_of "${SPOOL_AGENT_USER:-}")"
    [ -n "$h" ] && [ -d "$h/.claude/projects/$slug" ] && echo "transcript $h/.claude/projects/$slug"
  fi
  [ -d "$root/$id" ] && echo "spool $root/$id"
  return 0
}

# The whole manifest: derived lines first, then the declared ones.
cm_manifest() {  # TENANT CHANNEL
  local id
  for id in $(cm_seats "$1" "$2"); do cm_derive_seat "$id"; done
  cm_manifest_declared "$1" "$2"
}

# ---- sizes, secrets, the target --------------------------------------------

cm_bytes() { du -sb -- "$1" 2>/dev/null | awk '{ print $1 + 0 }'; }

# The base of a worktree's branch: its merge-base with the remote's default
# branch (the commit the target's clone most likely has).
cm_repo_base() {  # WORKTREE REMOTE
  local def c
  def="$(git -C "$1" symbolic-ref -q --short "refs/remotes/$2/HEAD" 2>/dev/null)"
  if [ -z "$def" ]; then
    for c in "$2/master" "$2/main"; do git -C "$1" rev-parse -q --verify "$c" >/dev/null 2>&1 && { def="$c"; break; }; done
  fi
  [ -n "$def" ] || return 1
  git -C "$1" merge-base HEAD "$def" 2>/dev/null
}

# Bytes the bundle of a worktree's HEAD carries on top of BASE.
cm_repo_bytes() {  # WORKTREE BASE
  git -C "$1" rev-list --objects --disk-usage HEAD ${2:+"^$2"} 2>/dev/null || echo 0
}

# 0 when the box's secret scan (spl_box_state_upload_scan) refuses PATH.
cm_is_secret() {  # PATH
  [ -e "$1" ] || return 1
  declare -F spl_box_state_upload_scan >/dev/null || return 1
  ( do_log() { :; }; spl_box_state_upload_scan "$1" ) >/dev/null 2>&1
  [ $? = 3 ]
}

cm_ssh() {  # TO ARGS...
  local to="$1"; shift
  # shellcheck disable=SC2086 # MOVE_SSH is a command prefix, split on purpose
  ${MOVE_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=5} "$to" "$@"
}

# The read-only checks run on the target: one "key value" line each.
cm_target_script() {  # TENANT SHA:PATH...
  local t="$1" sp; shift
  printf 'cd / || exit 1\n'
  printf 'r="${SPOOL_ROOT:-/var/spool-hub}"\n'
  printf 'awk -F"\\t" -v t=%q '\''$1 == t { f = 1 } END { print "desk " (f ? "yes" : "no") }'\'' "$r/channel-rules.tsv" 2>/dev/null || echo "desk no"\n' "$t"
  printf 'n="$(tmux list-windows -a -F "#{window_name}" 2>/dev/null | grep -cE "^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3})")" || true; echo "agents ${n:-unknown}"\n'
  for sp in "$@"; do
    printf 'if git -C %q cat-file -e %q 2>/dev/null; then echo "base %s yes"; else echo "base %s no"; fi\n' \
      "${sp#*:}" "${sp%%:*}^{commit}" "${sp%%:*}" "${sp%%:*}"
  done
}

# kB/s to the target: MOVE_UPLINK_KBPS, else a 1 MB probe written to
# /dev/null on the target, else the worked example's 75 (assumed).
cm_uplink() {  # TO REACHABLE
  local t0 t1 ms
  [ -n "${MOVE_UPLINK_KBPS:-}" ] && { echo "$MOVE_UPLINK_KBPS given"; return 0; }
  if [ "$2" = yes ]; then
    t0="$(date +%s%N)"
    if head -c 1048576 /dev/zero | cm_ssh "$1" 'cat >/dev/null' 2>/dev/null; then
      t1="$(date +%s%N)"; ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -gt 0 ] || ms=1
      echo "$(( 1048576 / ms )) measured"; return 0
    fi
  fi
  echo "75 assumed"
}

cm_eta() {  # BYTES KBPS
  local b="${1:-0}" k="${2:-75}"
  [ "$k" -gt 0 ] 2>/dev/null || k=75
  printf '%ss' "$(( (b + k * 1000 - 1) / (k * 1000) ))"
}
