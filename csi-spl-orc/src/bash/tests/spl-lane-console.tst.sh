#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a lane's live console on the box side (spec 153 section 3.18,
# SPL-4810): features/spawn-agents/lib/lane_console.py, run by the box file follower
# (file-stream-follow.py) on each tick. A PRIVATE tmux server on a socket in
# a mktemp dir and a stub hub: no live tmux, spool root or hub is touched,
# and every token and key below is made up at run time.
#   L1 a watched window: its screen plus 200 lines of scrollback is pushed,
#      a token planted on scrollback line 150 and a 4-line PEM key arrive
#      masked, the lines around them unchanged (dispatch holder's condition
#      on plan 7e928b34)
#   L2 nobody watches: no capture (not one tmux call) and no push
#   L3 a window named with a box tag ("<tag>: c-902 title") is found
#   L4 an unchanged screen is not re-sent before keep_s
# Each runs green on the module and red on a copy with one planted defect.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq and python3 are required"; exit 1; }
if ! command -v tmux >/dev/null; then
  echo "SKIP spl-lane-console: no tmux on this box"
  exit 0
fi

SCRIPTS="$PROJ_ROOT/src/bash/scripts"
LIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib"
SOCK="$T/tmux.sock"
trap 'tmux -S "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$T"' EXIT
B="-----BEGIN" E="-----END" PK="PRIV""ATE KEY"
rnd() { python3 -c 'import secrets, string, sys; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(int(sys.argv[1]))))' "$1"; }
b64() { python3 -c 'import base64, secrets; print(base64.b64encode(secrets.token_bytes(48)).decode()[:64])'; }
TOKEN="gh""p_$(rnd 36)"
KEYLINES=("$(b64)" "$(b64)")

# The screen: 220 lines, the token on line 150, a PEM key on lines 160-163.
python3 - "$T/screen.txt" "$TOKEN" "$B $PK-----" "${KEYLINES[0]}" "${KEYLINES[1]}" "$E $PK-----" <<'EOF'
import sys
out, token, begin, k1, k2, end = sys.argv[1:]
lines = [f"line {i}" for i in range(1, 221)]
lines[149] = f"line 150 export GH_TOKEN={token}"
lines[159:163] = [begin, k1, k2, end]
open(out, "w").write("\n".join(lines) + "\n")
EOF
# two windows on the private server; a tall pane, so 220 lines need scrollback
tmux -S "$SOCK" -f /dev/null new-session -d -s lc -x 200 -y 40 -n "c-901 console test" "cat '$T/screen.txt'; sleep 600"
tmux -S "$SOCK" new-window -d -t lc -n "box1: c-902 tagged" "echo tagged-window-text; sleep 600"
sleep 1

# tmux wrapper: logs every call, then runs the private server's tmux
cat >"$T/tmuxw" <<EOF
#!/bin/sh
echo "\$*" >>"$T/tmux.calls"
exec tmux -S "$SOCK" "\$@"
EOF
chmod +x "$T/tmuxw"

# stub hub: answers a demands pull from <case>/demands.json, logs every frame
cat >"$T/push" <<'EOF'
#!/bin/sh
f="$(cat)"
printf '%s\n' "$f" >>"$PUSH_LOG"
case "$f" in
*'"file_streams_console_demands"'*) printf '{"type":"ack","lane_op":"x","agents":%s}\n' "$(cat "$DEMANDS")" ;;
*) echo '{"type":"ack","lane_op":"x","inserted":1}' ;;
esac
EOF
chmod +x "$T/push"

# variant <name> <old> <new>: the follower beside a lib dir whose
# lane_console.py carries one planted defect (spool_redact is the real one).
variant() {
  local d="$T/v/$1" f
  mkdir -p "$d/src/bash/scripts" "$d/src/bash/features/spawn-agents/lib"
  cp "$SCRIPTS/file-stream-follow.py" "$d/src/bash/scripts/"
  for f in "$LIB"/*.py; do ln -sfn "$f" "$d/src/bash/features/spawn-agents/lib/"; done
  rm -f "$d/src/bash/features/spawn-agents/lib/lane_console.py"
  python3 - "$LIB/lane_console.py" "$d/src/bash/features/spawn-agents/lib/lane_console.py" "$2" "$3" <<'EOF' || return 1
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(f"the defect text is in lane_console.py {s.count(old)} times, not once: {old!r}")
open(dst, "w").write(s.replace(old, new))
EOF
  echo "$d/src/bash/scripts/file-stream-follow.py"
}

# run <py> <case> <demands json> [ticks] [VAR=v]...: the follower with no
# file stream, a pull every tick.
run() {
  local py="$1" d="$2" dem="$3" n="${4:-1}"
  shift 4 2>/dev/null || shift $#
  mkdir -p "$d/home" "$d/spool"
  echo "$dem" >"$d/demands.json"
  env HOME="$d/home" SPOOL_ROOT="$d/spool" FILE_STREAMS_STATE_DIR="$d/state" FILE_STREAMS_PUSH_CMD="$T/push" \
    PUSH_LOG="$d/pushed" DEMANDS="$d/demands.json" FILE_STREAMS_ALLOW='[]' FILE_STREAMS_TICK_S=0.2 \
    FILE_STREAMS_CONSOLE_TMUX="$(jq -n -c --arg w "$T/tmuxw" '[$w]')" FILE_STREAMS_CONSOLE_S=0 "$@" \
    timeout 30 python3 "$py" --ticks "$n" >>"$d/out" 2>&1
}
screens() { jq -c --arg a "$2" 'select(.lane_op == "file_streams_console_push" and .agent_id == $a)' "$1/pushed" 2>/dev/null; }

l1() {
  local d="$T/l1-$RANDOM" s
  : >"$T/tmux.calls"
  run "$1" "$d" '["c-901"]'
  s="$(screens "$d" c-901 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L1: no console push: $(cat "$d/out")"; return 1; }
  if grep -qF -- "$TOKEN" "$d/pushed" || grep -qF -- "${KEYLINES[0]}" "$d/pushed" || grep -qF -- "${KEYLINES[1]}" "$d/pushed"; then
    echo "  L1: a secret left the box"; return 1
  fi
  jq -e '.screen | contains("line 150 export GH_TOKEN=<redacted") and contains("line 149\nline 150") and contains("line 220")
    and contains("line 30\n") and contains("<redacted:private-key>") and contains("line 164")' <<<"$s" >/dev/null ||
    { echo "  L1: screen: $(jq -r .screen <<<"$s" | sed -n '145,170p')"; return 1; }
  jq -e '([.redactions | to_entries[] | select(.key != "private-key") | .value] | add // 0) >= 1 and .redactions["private-key"] >= 1 and .lines_n >= 200' <<<"$s" >/dev/null ||
    { echo "  L1: counts $(jq -c '{redactions, lines_n}' <<<"$s")"; return 1; }
}

l2() {
  local d="$T/l2-$RANDOM"
  : >"$T/tmux.calls"
  run "$1" "$d" '[]' 2
  [[ ! -s "$T/tmux.calls" ]] || { echo "  L2: tmux was called: $(cat "$T/tmux.calls")"; return 1; }
  ! grep -q file_streams_console_push "$d/pushed" || { echo "  L2: a push nobody asked for"; return 1; }
  grep -q file_streams_console_demands "$d/pushed" || { echo "  L2: no demands pull"; return 1; }
}

l3() {
  local d="$T/l3-$RANDOM"
  run "$1" "$d" '["c-902"]'
  screens "$d" c-902 | jq -e '.screen | contains("tagged-window-text")' >/dev/null ||
    { echo "  L3: no screen of the tagged window: $(cat "$d/pushed")"; return 1; }
}

l4() {
  local d="$T/l4-$RANDOM" n
  run "$1" "$d" '["c-902"]' 3 FILE_STREAMS_CONSOLE_KEEP_S=600
  n="$(screens "$d" c-902 | wc -l)"
  [[ "$n" == 1 ]] || { echo "  L4: $n pushes of an unchanged screen, want 1"; return 1; }
}

# check <id> <what> <fn> [<control> <old> <new>]...: green on the module,
# red on each planted defect.
check() {
  local id="$1" what="$2" fn="$3" v
  shift 3
  if "$fn" "$SCRIPTS/file-stream-follow.py"; then pass "$id $what"; else fail "$id $what"; fi
  while (($# >= 3)); do
    if ! v="$(variant "$id-$1" "$2" "$3")"; then
      fail "$id control $1: its defect could not be planted"
    elif "$fn" "$v" >/dev/null 2>&1; then
      fail "$id control $1: still green on the planted defect"
    else
      pass "$id control $1: red on the planted defect"
    fi
    shift 3
  done
}

check L1 "a watched window: screen + 200 lines of scrollback, line 150's token and a PEM key masked" l1 \
  no-mask 'self.mask(st, ln):  # ctl:console-mask' '[(ln, False, {})]:' \
  screen-only '"-S", f"-{self.scroll}", ' ''
check L2 "nobody watches: no tmux call, no push" l2 \
  always-capture 'if not self.agents:' 'if not self.agents and False:'
check L3 "a window named with a box tag is found" l3 \
  no-tag 'WINDOW_RE = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9._-]*: )?(\S+)")' 'WINDOW_RE = re.compile(r"^(\S+)")'
check L4 "an unchanged screen is not re-sent before keep_s" l4 \
  always-send 'if last and last[0] == sha and now - last[1] < self.keep_s:' 'if False:'

[[ "$fails" == 0 ]] && echo "OK spl-lane-console: all passed" || echo "FAIL spl-lane-console: $fails failed"
((fails == 0))
