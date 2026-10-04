#!/usr/bin/env bash
# live-terminal-proof.sh - specs/028-spool-terminal-delivery SC-001..SC-003,
# against the box user's REAL tmux server.
#
# NOT part of run-all-tests.sh: it needs a live box tmux server, and (for case
# 2) two boxes already pinned against a hub by do_spl_m3_e2e. Run it by hand:
#
#   bash csi-spl-orc/src/bash/features/spawn-agents/tests/live-terminal-proof.sh
#
# The m3 e2e proves the four message kinds against the REAL dev hub, but on a
# PRIVATE tmux server. This proves the other half: the box user's REAL tmux
# server - the one every agent on this box actually lives in - with a throwaway
# agent id and a real interactive shell in the pane.
#
# It reuses the boxes the e2e already pinned (box-e2e-a / box-e2e-b under the
# e2e state dir), so the message really crosses the dev hub; only the recipient
# id and the pane are this script's own.
#
# Writes every capture to $OUT. Never touches a live lane's window.
set -uo pipefail

# Nothing below names a user, a box or a host: the repo comes from this file's
# own location, the socket from the running uid (the rule in
# lib/spool-env.inc.sh), and the hub from whatever the e2e last talked to.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FEAT="$(cd "$HERE/.." && pwd)"
REPO="${REPO:-$(cd "$FEAT/../../../../.." && pwd)}"
# NOT basename "$REPO": in a git worktree the checkout dir is named after the
# BRANCH, so that read "CLE-3428" here. The <org-app>-orc dir above this
# feature is the stable name.
ORG_APP="$(basename "$(cd "$FEAT/../../../.." && pwd)")"; ORG_APP="${ORG_APP%-orc}"
OUT="${OUT:-/var/tmp/${ORG_APP}-terminal-proof}"
SOCK="${SOCK:-/tmp/tmux-$(id -u)/default}"
E2E="${E2E:-$HOME/.local/share/$ORG_APP/cloud/dev/m3-e2e/t1}"
SPOOL="${SPOOL:-$REPO/${ORG_APP}-api/src/go/spool-hub-api/bin/spool}"
NOTIFY="$FEAT/scripts/spool-notify.sh"
# The hub the pinned boxes belong to: whatever do_spl_m3_e2e last used. No
# default host is baked in (doc-hub distribution rule 3).
HUB_URL="${HUB_URL:-$(sed -n 's/.*"hub": *"\([^"]*\)".*/\1/p' "$E2E/results.json" 2>/dev/null | sed -n 1p)}"
TENANT="${TENANT:-t1}"
AGENT="${AGENT:-TRM-1}"       # throwaway; not a live lane, and not CLE/GRK/AGY
OTHER="${OTHER:-TRM-2}"       # the isolation control
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUT" || exit 1
say() { printf '%s\n' "$*" | tee -a "$OUT/real-tmux-proof.log"; }
tm()  { tmux -u -S "$SOCK" "$@"; }
cap() { tm capture-pane -p -t "$1" 2>/dev/null; }
# capture-pane hard-wraps at the pane width, so a raw substring test can miss
# text that is plainly on the screen - which is how this script first reported a
# FALSE PASS on the busy-pane control. Compare on one whitespace-collapsed line.
flat() { tr -d '[:space:]'; }
has_txt() {  # HAYSTACK NEEDLE
  local h n
  h="$(printf '%s' "$1" | flat)"; n="$(printf '%s' "$2" | flat)"
  [ "${h#*"$n"}" != "$h" ]
}

say "=== CLE-3428 live proof on the REAL box tmux server, $STAMP ==="
say "socket $SOCK  agent $AGENT  control $OTHER  notifier $NOTIFY"
say "spool  $($SPOOL version 2>/dev/null || echo '?')  hub ${HUB_URL:-<none>}"

# ── windows: two throwaway panes running a real interactive shell ───────────
cleanup() {
  for w in "$AGENT" "$OTHER"; do tm kill-window -t "$w" 2>/dev/null; done
}
trap cleanup EXIT
cleanup
PANE_A="$(tm new-window -d -n "$AGENT" -P -F '#{pane_id}' 'bash --norc -i')" || exit 1
PANE_B="$(tm new-window -d -n "$OTHER" -P -F '#{pane_id}' 'bash --norc -i')" || exit 1
say "panes: $AGENT=$PANE_A  $OTHER=$PANE_B"
sleep 1
# Give each pane a foreground job, so its tty carries something that is not a
# shell. That is the shape of a live agent window (the launcher hops through
# sudo/su into the CLI, which runs on its own pty); a pane whose tty runs ONLY
# shells is an agent that has exited, and the notifier skips it on purpose
# (contracts/poke-line.md section 4). Proving the rule, not working around it:
# step 5 below asserts the skip on a deliberately bare pane.
for p in "$PANE_A" "$PANE_B"; do tm send-keys -t "$p" -l 'sleep 3600'; tm send-keys -t "$p" Enter; done
sleep 1
say "pane ttys now run: $(ps -t "$(tm display-message -p -t "$PANE_A" '#{pane_tty}' | sed 's|/dev/||')" -o comm= | sort -u | tr '\n' ' ')"

# ── 1. a same-box send: the `spool send` verb (= the spool_send MCP tool) ───
# Its own SPOOL_ROOT, so nothing is written into the box's shared /var/spool-hub.
ROOT="$OUT/rt/spool"
rm -rf "$OUT/rt"; mkdir -p "$ROOT/$AGENT/inbox" "$ROOT/$OTHER/inbox" || exit 1
printf '%s\tclaude\t%s\t%s\t%s\n' "$AGENT" "$PANE_A" "$OUT" "$STAMP" >>"$ROOT/registry.tsv"
printf '%s\tclaude\t%s\t%s\t%s\n' "$OTHER" "$PANE_B" "$OUT" "$STAMP" >>"$ROOT/registry.tsv"

B1="local send, the CLI verb and the MCP tool share it $STAMP"
t0=$(date +%s.%N)
SPOOL_ROOT="$ROOT" SPOOL_TMUX_SOCKET="$SOCK" SPOOL_NOTIFY_CMD="$NOTIFY" \
  "$SPOOL" send --from "$OTHER" --to "$AGENT" --kind task --body "$B1" >>"$OUT/real-tmux-proof.log" 2>&1
rc1=$?
t1=$(date +%s.%N)
sleep 1
cap "$PANE_A" >"$OUT/pane-$AGENT-after-local-send.txt"
case "$(cat "$OUT/pane-$AGENT-after-local-send.txt")" in
  *"$B1"*) say "PASS 1 local send: the BODY is visible in $AGENT's real pane (send rc=$rc1, $(echo "$t1 - $t0" | bc)s)" ;;
  *)       say "FAIL 1 local send: the body is NOT in $AGENT's pane" ;;
esac

# ── 2. across the dev hub: box-e2e-a -> this box's agent ───────────────────
# The e2e pinned both boxes with the tenant root key; box-e2e-b's own hub-sync
# is what writes the inbox here, so it is what has to ring the pane.
if [ -d "$E2E/box-e2e-b/spool" ] && [ -n "$HUB_URL" ]; then
  BB="$E2E/box-e2e-b"
  mkdir -p "$BB/spool/$AGENT/inbox" || exit 1
  # point box-e2e-b's registry at the REAL pane for this throwaway id
  grep -v "^$AGENT	" "$BB/spool/registry.tsv" 2>/dev/null >"$BB/spool/registry.tsv.new"
  printf '%s\tclaude\t%s\t%s\t%s\n' "$AGENT" "$PANE_A" "$OUT" "$STAMP" >>"$BB/spool/registry.tsv.new"
  mv "$BB/spool/registry.tsv.new" "$BB/spool/registry.tsv"

  boxenv() {  # BOXDIR BOXID VERB...
    local d="$1" b="$2"; shift 2
    env SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$b" \
        SPOOL_HUB_URL="$HUB_URL" SPOOL_TENANT="$TENANT" \
        SPOOL_TMUX_SOCKET="$SOCK" SPOOL_NOTIFY_CMD="$NOTIFY" \
        SPOOL_BOX_USER="$(id -un)" SPOOL_AGENT_USER="$(id -un)" SPOOL_BOX_TAG="" "$SPOOL" "$@"
  }
  B2="across the dev hub, box to box $STAMP"
  t0=$(date +%s.%N)
  boxenv "$E2E/box-e2e-a" box-e2e-a send --from EZA-1 --to "$AGENT" --to-box box-e2e-b \
    --kind task --body "$B2" >>"$OUT/real-tmux-proof.log" 2>&1
  rc2=$?
  boxenv "$BB" box-e2e-b hub-sync >>"$OUT/real-tmux-proof.log" 2>&1
  rc3=$?
  t1=$(date +%s.%N)
  sleep 1
  cap "$PANE_A" >"$OUT/pane-$AGENT-after-hub-send.txt"
  case "$(cat "$OUT/pane-$AGENT-after-hub-send.txt")" in
    *"$B2"*) say "PASS 2 cross-box over the dev hub: the BODY is visible in $AGENT's real pane (send rc=$rc2 sync rc=$rc3, $(echo "$t1 - $t0" | bc)s)" ;;
    *)       say "FAIL 2 cross-box over the dev hub: the body is NOT in $AGENT's pane (send rc=$rc2 sync rc=$rc3)" ;;
  esac
else
  say "SKIP 2 cross-box: no pinned box at $E2E/box-e2e-b, or no hub in its results.json (run do_spl_m3_e2e on dev first)"
fi

# ── 3. CONTROL: the other agent's pane saw none of it ──────────────────────
cap "$PANE_B" >"$OUT/pane-$OTHER-control.txt"
ctl="$(cat "$OUT/pane-$OTHER-control.txt")"
if ! has_txt "$ctl" "$B1" && ! has_txt "$ctl" "${B2:-@@none@@}"; then
  say "PASS 3 CONTROL: $OTHER's pane shows neither message"
else
  say "FAIL 3 CONTROL: a message for $AGENT leaked into $OTHER's pane"
fi

# ── 4. CONTROL: an AGENT pane holding a half-typed line is never clobbered ──
# The detector reads the TUI's own input line, so the pane must have one. This
# is the shape every claude / grok / agy window on this box actually has.
printf '#!/bin/sh\nprintf "\\n\342\235\257 half typed and never sent"\nsleep 3600\n' >"$OUT/tui-pane.sh"
chmod +x "$OUT/tui-pane.sh"
PANE_D="$(tm new-window -d -n "TRM-4" -P -F '#{pane_id}' "$OUT/tui-pane.sh")"
mkdir -p "$ROOT/TRM-4/inbox"
printf '%s\tclaude\t%s\t%s\t%s\n' TRM-4 "$PANE_D" "$OUT" "$STAMP" >>"$ROOT/registry.tsv"
sleep 1
if has_txt "$(cap "$PANE_D")" "half typed and never sent" && cap "$PANE_D" | grep -F "$(printf '\342\235\257')" >/dev/null; then
  say "     (TRM-4 pane really carries the TUI prompt glyph and the unsent text)"
else
  say "FAIL 4 setup: TRM-4 pane does not show a prompt glyph + unsent text; the control would be vacuous"
  say "     pane reads: $(cap "$PANE_D" | sed -n 1,3p | tr '\n' '|')"
fi
B4="this must NOT be typed over a half-typed line $STAMP"
out4="$(SPOOL_ROOT="$ROOT" SPOOL_TMUX_SOCKET="$SOCK" SPOOL_NOTIFY_CMD="$NOTIFY" \
  "$SPOOL" send --from "$AGENT" --to TRM-4 --kind note --body "$B4" 2>&1)"
rc4=$?
sleep 1
cap "$PANE_D" >"$OUT/pane-TRM-4-busy.txt"
busy="$(cat "$OUT/pane-TRM-4-busy.txt")"
inbox_n="$(ls "$ROOT/TRM-4/inbox" 2>/dev/null | wc -l)"
if ! has_txt "$busy" "$B4" && has_txt "$busy" "half typed and never sent" && [ "$inbox_n" -ge 1 ]; then
  say "PASS 4 CONTROL: an agent pane mid-sentence is left alone, and the message IS delivered ($inbox_n file(s), send rc=$rc4)"
else
  say "FAIL 4 CONTROL: busy agent pane clobbered, or not delivered (inbox=$inbox_n rc=$rc4) $out4"
fi

# ── 4b. the BOUND of that rule, measured, not assumed ──────────────────────
# The detector reads a TUI input line. A pane at a bare SHELL prompt has none,
# so type-ahead there is NOT protected. It is not an exposure - a pane whose
# tty runs only shells is skipped as an exited agent (case 5) - but the
# contract must say so rather than imply a guarantee that was never measured.
tm send-keys -t "$PANE_B" -l 'echo shell type-ahead is not protected'
sleep 0.5
B4B="a shell prompt has no input line to detect $STAMP"
SPOOL_ROOT="$ROOT" SPOOL_TMUX_SOCKET="$SOCK" SPOOL_NOTIFY_CMD="$NOTIFY" \
  "$SPOOL" send --from "$AGENT" --to "$OTHER" --kind note --body "$B4B" >>"$OUT/real-tmux-proof.log" 2>&1
sleep 1
cap "$PANE_B" >"$OUT/pane-$OTHER-shell-typeahead.txt"
if has_txt "$(cat "$OUT/pane-$OTHER-shell-typeahead.txt")" "$B4B"; then
  say "BOUND 4b a bare SHELL prompt has no input line: type-ahead there is NOT detected (poked anyway) - recorded in contracts/poke-line.md section 4"
else
  say "NOTE 4b a shell prompt was also protected (better than the contract claims)"
fi
tm send-keys -t "$PANE_B" C-u 2>/dev/null
tm kill-window -t TRM-4 2>/dev/null

# ── 5. the rule behind case 1: a pane whose tty runs ONLY shells is skipped ──
PANE_C="$(tm new-window -d -n "TRM-3" -P -F '#{pane_id}' 'bash --norc -i')"
mkdir -p "$ROOT/TRM-3/inbox"
printf '%s\tclaude\t%s\t%s\t%s\n' TRM-3 "$PANE_C" "$OUT" "$STAMP" >>"$ROOT/registry.tsv"
sleep 1
out5="$(SPOOL_ROOT="$ROOT" SPOOL_TMUX_SOCKET="$SOCK" \
  bash "$NOTIFY" --to TRM-3 --from "$AGENT" --kind note --body "into a bare shell $STAMP" 2>&1)"
rc5=$?
tm kill-window -t TRM-3 2>/dev/null
if [ "$rc5" = 7 ] && [ "${out5#*only shells}" != "$out5" ]; then
  say "PASS 5 a pane running only a shell is an exited agent: exit 7, not poked ($out5)"
else
  say "FAIL 5 bare-shell pane: want exit 7 'runs only shells', got rc=$rc5 ($out5)"
fi

say "=== captures in $OUT ==="
ls -l "$OUT"/pane-*.txt | tee -a "$OUT/real-tmux-proof.log"
