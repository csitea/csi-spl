#!/usr/bin/env bash
# test-agent-winch.sh — a CLI launched through the run-as hop hears a resize
# (ported from the frozen box engine, specs/048 SPL-1160).
#
# Every agent CLI starts as `spool_agent_exec "<cmd>"` inside a tmux pane. With
# plain `su - <agent> -c`, su setsid()s the command: it has no controlling tty,
# the SIGWINCH of a split goes to su's process group and su does not forward
# it, and the CLI keeps drawing at the old width. This suite starts a probe in
# the CLI's position on a PRIVATE tmux server, splits the pane, and requires
# the probe to get SIGWINCH with the new size.
#
#   run-as   each mode reachable here (su-dash, sudo-i; su as root)
#   pipe     off a terminal the hop stays byte-clean (no \r, no echoed stdin)
#
# It needs a second OS user the caller may `sudo su -` to: WINCH_AGENT_USER,
# else the owner of this checkout when that is not the caller. Without one
# every case SKIPS (a CI runner has none). WINCH_T_LIB points it at another
# resolver: the control run against the pre-fix one must go RED.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${WINCH_T_LIB:-$HERE/../lib/spool-env.inc.sh}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }
is()   { [ "$2" = "$3" ] && ok "$1" || nok "$1" "expected [$3], got [$2]"; }
done_() { echo "-- $(basename "$0"): ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"; [ "$FAIL" -eq 0 ]; exit $?; }

command -v tmux >/dev/null 2>&1 || { skip "no tmux"; done_; }
AGENT="${WINCH_AGENT_USER:-$(stat -c %U "$HERE")}"
if [ -z "$AGENT" ] || [ "$AGENT" = "$(id -un)" ] || ! getent passwd "$AGENT" >/dev/null; then
  skip "run-as: no distinct agent user here"; done_
fi

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; chmod 755 "$T"
mkdir "$T/log"; chmod 1777 "$T/log"
SRV="winch-$$"
trap 'tmux -L "$SRV" kill-server 2>/dev/null; rm -rf "$T"' EXIT
unset TMUX TMUX_PANE

# The probe stands where the CLI stands: it logs its size on start and on
# every SIGWINCH, reading the size from its own stdin, as a TUI does.
cat > "$T/probe.sh" <<'EOF'
f="$1"; trap 'echo "WINCH $(stty size 2>/dev/null)" >> "$f"' WINCH
echo "start $(stty size 2>/dev/null)" >> "$f"
while :; do sleep 0.1; done
EOF
chmod 644 "$T/probe.sh"

wait_for() {  # FILE PATTERN SECONDS
  local i
  for ((i = 0; i < $3 * 10; i++)); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

winch_case() {  # LABEL MODE
  local label="$1" mode="$2" log="$T/log/$2.log" w
  : > "$log"; chmod 666 "$log"
  tmux -L "$SRV" -f /dev/null new-session -d -s "$mode" -x 120 -y 40 \
    "env -i HOME=\"\$HOME\" PATH=\"\$PATH\" TERM=\"\$TERM\" SPOOL_AGENT_USER=$AGENT SPOOL_RUN_AS_AGENT=$mode \
     bash -c '. \"\$1\"; spool_agent_exec \"bash \$2 \$3\"' _ '$LIB' '$T/probe.sh' '$log'"
  if ! wait_for "$log" '^start' 15; then nok "$label: the probe started" "log: $(cat "$log")"; return; fi
  sleep 0.3
  tmux -L "$SRV" split-window -d -h -l 40 -t "$mode" "sleep 60"
  w="$(tmux -L "$SRV" display -p -t "$mode:0.0" '#{pane_height} #{pane_width}')"
  if wait_for "$log" '^WINCH' 5; then ok "$label: the CLI position got SIGWINCH on a split"
  else nok "$label: the CLI position got SIGWINCH on a split" "log: $(tr '\n' '|' < "$log")"; fi
  is "$label: it reads the new size ($w)" "$(sed -n 's/^WINCH //p' "$log" | tail -1)" "$w"
  tmux -L "$SRV" kill-session -t "$mode" 2>/dev/null
}

if [ "$(id -u)" -eq 0 ]; then
  winch_case "root: su" su-dash
elif sudo -n su - "$AGENT" -c true >/dev/null 2>&1; then
  winch_case "su-dash" su-dash
  if sudo -n -u "$AGENT" -i true >/dev/null 2>&1; then winch_case "sudo-i" sudo-i
  else skip "sudo-i: no ($AGENT) NOPASSWD rule here"; fi
else
  skip "run-as: no passwordless sudo to $AGENT here"
fi

if [ "$(id -u)" -eq 0 ] || sudo -n su - "$AGENT" -c true >/dev/null 2>&1; then
  # A login shell may print its own banner first (the agent user's profile),
  # so the check is the tail: exactly "in\nout\n", and no \r anywhere.
  raw="$(printf 'in\n' | env -i HOME="$HOME" PATH="$PATH" SPOOL_AGENT_USER="$AGENT" SPOOL_RUN_AS_AGENT=su-dash \
    bash -c '. "$1"; spool_agent_exec "cat; echo out"' _ "$LIB" 2>/dev/null | od -An -c | tr -s ' \n' ' ')"
  is "pipe: stdin passes once, then the command's own output" "${raw: -17}" " i n \n o u t \n "
  case "$raw" in *'\r'*) nok "pipe: no \\r added" "$raw" ;; *) ok "pipe: no \\r added" ;; esac
else
  skip "pipe: no passwordless sudo to $AGENT here"
fi
done_
