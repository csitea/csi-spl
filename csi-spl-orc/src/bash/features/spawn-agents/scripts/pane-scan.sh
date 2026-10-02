#!/usr/bin/env bash
# pane-scan.sh — census of what every spawned agent pane holds in its PROMPT.
#
# Answers two questions the inbox protocol depends on:
#
#   RESIDUE  the input box holds un-submitted POKE text. Non-zero means the
#            doorbell (spool-send.sh, or the older inbox sender) typed a poke that the TUI never
#            submitted, so an agent was told nothing while the sender was told
#            "OK: poked". This is the number that must stay 0.
#   TYPED    the input box holds other unsent text — a human sentence, a slash
#            command that never went in. Those panes are NOT pokeable:
#            send-keys appends, so a poke would destroy that text and submit
#            the two mashed together. spool-send.sh refuses them (exit 6).
#
# READ THE LAST PROMPT GLYPH, NOT THE FIRST.
#
# Claude and grok re-render every SUBMITTED turn with the same U+276F glyph, so
# the first match on a captured pane is scrollback while the live input box is
# the last one, just above the footer. A scan built on `grep -m1 '❯'` reported
# seven panes "holding un-submitted poke text" on 2026-08-28; all seven of
# those messages had in fact been read and moved to the agents' archive/ dirs.
# That wrong number was confident enough to be routed as work. This script
# exists so the claim can be re-checked in one command instead of by eye.
#
# agy's input box is ASCII `>` on its own line. Prefer U+276F when present so a
# `>` in the same buffer cannot steal the line; accept ASCII `>` ONLY for
# AGY-* ids (a `>` in claude/grok scrollback — markdown quotes, redirects —
# must not become a prompt).
#
# Dim placeholder hints are not typed text: Claude Code renders its own
# "Press up to edit queued messages" in SGR 2 while text a user typed is
# plain, so the capture is -e and only what lies outside a dim run counts.
#
# Ported from the frozen box engine (specs/048, SPL-1160). A poke is either
# harness's doorbell: the spool's ": 'SPOOL <ID>: ..." line or the older
# markdown inbox's "INBOX <ID>: read and act on ..." line.
#
# Usage: pane-scan.sh            # census, exit 1 if any RESIDUE is found
# env:   SPOOL_TMUX_SOCKET       the tmux server (default: lib/spool-env.inc.sh's,
#                                /tmp/tmux-<uid of the box user>/default)
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_here/../lib/agent-state.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve
TMUX_SOCKET="$SPOOL_TMUX_SOCKET"
SOCK_OWNER="$(stat -c %U "$TMUX_SOCKET" 2>/dev/null || true)"
# The socket's DIRECTORY is mode 700 (/tmp/tmux-<uid>/), so a caller who is not
# the socket owner cannot stat the socket FILE at all and the line above yields
# "". Falling through with SOCK_OWNER empty skips the sudo hop, and every tmux
# call then fails with its stderr discarded -- a confident wrong answer (an
# empty census). The directory itself is statable from anywhere in /tmp.
if [ -z "$SOCK_OWNER" ]; then
  SOCK_UID="$(stat -c %u "$(dirname "$TMUX_SOCKET")" 2>/dev/null || true)"
  [ -n "$SOCK_UID" ] && SOCK_OWNER="$(getent passwd "$SOCK_UID" | cut -d: -f1)"
fi
if [ -n "$SOCK_OWNER" ] && [ "$SOCK_OWNER" != "$(id -un)" ]; then
  # -u: LC_ALL=C would turn every non-ASCII -F field and TAB into "_".
  TM=(sudo -n -u "$SOCK_OWNER" tmux -u -S "$TMUX_SOCKET")
else
  TM=(tmux -u -S "$TMUX_SOCKET")
fi

# Last prompt line of a capture, WITH styling. Prefers U+276F when present so
# a `>` in the same buffer cannot steal the line. For AGY-* only, falls back
# to the last line whose de-styled, de-bordered form starts with ASCII `>`.
prompt_line_from_capture() {
  local last
  last="$(printf '%s\n' "$1" | grep '❯' | tail -1 || true)"
  if [ -n "$last" ]; then
    printf '%s\n' "$last"
    return 0
  fi
  case "$2" in
    AGY-*|QWN-*)
      printf '%s\n' "$1" | awk '
        {
          orig = $0
          plain = $0
          gsub(/\033\[[0-9;]*m/, "", plain)
          gsub(/│/, "", plain)
          gsub(/┃/, "", plain)
          if (plain ~ /^[ \t]*>/) last = orig
        }
        END { if (last != "") print last }
      '
      ;;
  esac
}
# What a human or agent has actually TYPED there (empty = a clear prompt).
# Drop dim runs first (claude's placeholder hint), then the prompt glyph.
# For agy the glyph is ASCII `>`: strip exactly one leading `>`, and only
# when U+276F is absent, so a claude/grok prompt holding a typed `>` is
# still seen as typed text.
rest_of() {
  local filtered stripped
  filtered="$(printf '%s' "$1" \
    | awk '{ s = $0; out = ""; dim = 0
             while (match(s, /\033\[[0-9;]*m/)) {
               if (!dim) out = out substr(s, 1, RSTART - 1)
               code = substr(s, RSTART, RLENGTH)
               if (code == "\033[2m") dim = 1
               else if (code == "\033[0m" || code == "\033[22m") dim = 0
               s = substr(s, RSTART + RLENGTH) }
             if (!dim) out = out s
             print out }')"
  stripped="$(printf '%s' "$filtered" | sed 's/❯//g; s/│//g; s/┃//g; s/\xc2\xa0//g')"
  case "$filtered" in
    *❯*) ;;
    *) stripped="$(printf '%s' "$stripped" | sed 's/^[[:space:]]*>//')" ;;
  esac
  printf '%s' "$stripped" | tr -d '[:space:]'
}
plain_of() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g; s/^ *//; s/ *$//' | cut -c1-72; }

if ! "${TM[@]}" list-panes -a -F '#{pane_id}' >/dev/null 2>&1; then
  echo "ERROR: the tmux server at ${TMUX_SOCKET} does not answer as $(id -un)." >&2
  echo "       An unreachable server returns an EMPTY pane list, so this scan would" >&2
  echo "       report a clean fleet it never actually looked at. Refusing to." >&2
  echo "       Retry as: sudo -u ${SOCK_OWNER:-<owner>} bash $0" >&2
  exit 2
fi

# The box tag ("<tag>: CLE-07 wip") is DISPLAY only: an_strip
# (lib/agent-state.inc.sh) removes it before the id is read.
nres=0; ntyped=0; nclear=0
while IFS='|' read -r wn p; do
  id="$(an_strip "$wn")"; id="${id%% *}"
  cap="$("${TM[@]}" capture-pane -e -p -t "$p" 2>/dev/null || true)"
  line="$(prompt_line_from_capture "$cap" "$id")"
  r="$(rest_of "$line")"
  if [ -z "$r" ]; then
    nclear=$((nclear + 1)); printf '  clear   %-9s %s\n' "$id" "$p"
  else
    case "$r" in
      *INBOX*|*readandacton*|*SPOOL*) nres=$((nres + 1));   printf 'RESIDUE   %-9s %s  %s\n' "$id" "$p" "$(plain_of "$line")" ;;
      *)                      ntyped=$((ntyped + 1)); printf 'TYPED     %-9s %s  %s\n' "$id" "$p" "$(plain_of "$line")" ;;
    esac
  fi
done < <("${TM[@]}" list-panes -a -F '#{window_name}|#{pane_id}' 2>/dev/null \
           | grep -E "^([A-Za-z0-9][A-Za-z0-9._-]*: )?${SPOOL_AGENT_ID_RX}")

echo
echo "RESIDUE (poke text stuck in a prompt) : $nres   <- must be 0"
echo "TYPED   (other unsent text, unpokeable): $ntyped"
echo "clear   (pokeable)                    : $nclear"
echo
echo "A TYPED pane is cleared WITHOUT submitting by:"
echo "  tmux -S ${TMUX_SOCKET} send-keys -t <pane> C-u"
echo "Never clear one holding text you did not put there — read it first."
[ "$nres" -eq 0 ]
