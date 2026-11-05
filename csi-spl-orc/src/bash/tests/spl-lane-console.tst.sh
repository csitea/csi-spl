#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a lane's live console on the box side (spec 153 section 3.20,
# SPL-4810): features/spawn-agents/lib/lane_console.py, run by the box file follower
# (file-stream-follow.py) on each tick. A PRIVATE tmux server on a socket in
# a mktemp dir and a stub hub: no live tmux, spool root or hub is touched,
# and every token and key below is made up at run time.
#   L1 a watched window: its screen plus 200 lines of scrollback is pushed,
#      a token planted on scrollback line 150 and a 4-line PEM key arrive
#      masked, the lines around them unchanged (dispatch holder's condition
#      on plan 7e928b34), but line 151: a complete token at a line end is
#      masked with the next line, as a wrap is (ruling c-002 e58ee764)
#   L2 nobody watches: no capture (not one tmux call) and no push
#   L3 a window named with a box tag ("<tag>: c-902 title") is found
#   L4 an unchanged screen is not re-sent before keep_s
#   L5 a token the agent's TUI hard-wrapped with real newlines (capture-pane
#      -J joins only tmux's own wraps): split at col 14 into 2 lines, and
#      at 12 cols into 4, each arrives masked, the lines around them kept
#      (R7 c-365 W2)
#   L6 a line longer than line_bytes is masked before it is cut, so a token
#      across the cut does not leave as an unmasked prefix (R7 c-365 N1)
#   L7 a token hard-wrapped inside a TUI box ("│ … │" on each line) is
#      masked: the border glyphs do not break the join (R7 c-164 W)
#   L8 a value-class secret ("password: <value>", KEY="<value>") the TUI
#      hard-wrapped arrives masked, its tail line too: the join reads the
#      raw lines, not the masked ones (R7 c-164 r3 W1)
#   L9 a token hard-wrapped inside a nested TUI box ("│ │ … │ │") is
#      masked: every border layer is dropped (R7 c-164 r3 N1)
#  L10 long tokens the TUI cut at col 80 (github_pat_, sk-ant-api03, a
#      Bearer JWT) and tokens at column 0 (cut at 40..80) arrive masked,
#      their tail lines too: a head line whose own mask runs to the line
#      end is a wrap even when it matches alone; a complete token inside
#      a line keeps the words after it (R7 c-164 r4)
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
WRAP2="gh""p_$(rnd 36)" WRAP4="gh""p_$(rnd 36)" LONG="gh""p_$(rnd 36)" BOXED="gh""p_$(rnd 36)"
PW1="$(rnd 68)" PW2="$(rnd 68)" NESTED="gh""p_$(rnd 36)"
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
# hard-wrapped tokens: WRAP2 cut at col 14, the rest indented as a TUI
# does; WRAP4 folded at 12 columns into 4 lines
python3 - "$T/wrap.txt" "$WRAP2" "$WRAP4" <<'EOF'
import sys
out, w2, w4 = sys.argv[1:]
a = "cut " + w2
b = "wrap " + w4
lines = ["before-wrap", a[:14], "  " + a[14:], "between-wrap"]
lines += [b[i : i + 12] for i in range(0, len(b), 12)] + ["after-wrap"]
open(out, "w").write("\n".join(lines) + "\n")
EOF
tmux -S "$SOCK" new-window -d -t lc -n "c-903 wrapped" "cat '$T/wrap.txt'; sleep 600"
# a 3000-byte line with a token across byte 2048 (the follower's line cut)
python3 -c 'import sys; print("x" * 2034 + sys.argv[1] + " tail-of-long-line")' "$LONG" >"$T/long.txt"
tmux -S "$SOCK" new-window -d -t lc -n "c-904 long" "cat '$T/long.txt'; sleep 600"
# a token cut after 16 characters inside a bordered TUI box
python3 - "$T/boxed.txt" "$BOXED" <<'EOF'
import sys
out, w = sys.argv[1:]
lines = ["before-box", f"│ cut {w[:16]} │", f"│ {w[16:]}            │", "-- after-box"]
open(out, "w").write("\n".join(lines) + "\n")
EOF
tmux -S "$SOCK" new-window -d -t lc -n "c-905 boxed" "cat '$T/boxed.txt'; sleep 600"
# value-class secrets hard-wrapped: an env line at col 80, a key: value at col 40
python3 - "$T/pw.txt" "$PW1" "$PW2" <<'EOF'
import sys
out, p1, p2 = sys.argv[1:]
a = f'  export MY_SERVICE_PASSWORD="{p1}"'
b = f"  db password: {p2}"
lines = ["before-pw", a[:80], a[80:], "between-pw", b[:40], b[40:], "after-pw"]
open(out, "w").write("\n".join(lines) + "\n")
EOF
tmux -S "$SOCK" new-window -d -t lc -n "c-906 password" "cat '$T/pw.txt'; sleep 600"
# a token cut after 16 characters inside a box nested in a box
python3 - "$T/nested.txt" "$NESTED" <<'EOF'
import sys
out, w = sys.argv[1:]
lines = ["before-nest", f"│ │ cut {w[:16]} │ │", f"│ │ {w[16:]} │ │", "-- after-nest"]
open(out, "w").write("\n".join(lines) + "\n")
EOF
# long tokens hard-wrapped (R7 c-164 r4 plants), WRAP_SPAN gap lines
# apart; <case>.pieces: 8 characters from the head, middle and tail of each
python3 - "$T/pat.txt" "$T/pat.pieces" <<'EOF'
import secrets, string, sys
out, pieces = sys.argv[1:]
rnd = lambda n: "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))
pat = lambda: "github" + "_pat_" + rnd(22) + "_" + rnd(59)
sk = lambda: "sk" + "-ant-api03-" + rnd(93) + "-AA"
jwt = "ey" + "J" + rnd(33) + ".ey" + "J" + rnd(60) + "." + rnd(43)
cases = [  # (text, its secret, wrap column)
    (f"  token: {(p := pat())}", p, 80),
    (f"ANTHROPIC_API_KEY={(k := sk())}", k, 80),
    (f'  -H "Authorization: Bearer {jwt}"', jwt, 80),
    *[((p := pat()), p, w) for w in (50, 60, 80)],
    ((k := sk()), k, 40),
]
keep = ["gh" + "p_" + rnd(36), "gh" + "p_" + rnd(36)]
lines, bits = ["before-pat"], []
for n, (text, sec, w) in enumerate(cases):
    lines += [text[i : i + w] for i in range(0, len(text), w)]
    lines += [f"-- gap {n} {g}" for g in range(4)]
    bits += [sec[12:20], sec[len(sec) // 2 : len(sec) // 2 + 8], sec[-9:-1]]
lines += [f"keep GH_TOKEN={keep[0]} kept-word", f"{keep[1]} tail", "-- after-pat"]
bits += [keep[0][4:12], keep[1][4:12]]
open(out, "w").write("\n".join(lines) + "\n")
open(pieces, "w").write("\n".join(bits) + "\n")
EOF
tmux -S "$SOCK" new-window -d -t lc -n "c-908 pat" "cat '$T/pat.txt'; sleep 600"
tmux -S "$SOCK" new-window -d -t lc -n "c-907 nested" "cat '$T/nested.txt'; sleep 600"
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
  # a complete token at a line end is masked with the line after it, as
  # a wrap would be: more, never less (R7 c-164 r4, ruling c-002 e58ee764)
  jq -e '.screen | contains("line 149\n<redacted:wrapped-secret>\n<redacted:wrapped-secret>\nline 152") and contains("line 220")
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

l5() {
  local d="$T/l5-$RANDOM" s p
  run "$1" "$d" '["c-903"]'
  s="$(screens "$d" c-903 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L5: no console push: $(cat "$d/out")"; return 1; }
  # 8 characters from the start, middle and end of each token's body
  for p in "${WRAP2:4:8}" "${WRAP2:28:8}" "${WRAP4:4:8}" "${WRAP4:20:8}" "${WRAP4:32:8}"; do
    if grep -qF -- "$p" "$d/pushed"; then echo "  L5: a piece of a wrapped token left the box: $p"; return 1; fi
  done
  # the join drops the newline, so a word that follows a token on the next
  # line ("between-wrap") may be masked with it: more, never less
  jq -e '(.screen | startswith("before-wrap\n<redacted:wrapped-secret>\n<redacted:wrapped-secret>\n")
    and endswith("<redacted:wrapped-secret>\nafter-wrap")) and (.redactions["wrapped-secret"] // 0) >= 6' <<<"$s" >/dev/null ||
    { echo "  L5: screen: $(jq -c '{screen, redactions}' <<<"$s")"; return 1; }
}

l6() {
  local d="$T/l6-$RANDOM" s
  run "$1" "$d" '["c-904"]'
  s="$(screens "$d" c-904 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L6: no console push: $(cat "$d/out")"; return 1; }
  if grep -qF -- "${LONG:0:12}" "$d/pushed"; then echo "  L6: a prefix of the token across the cut left the box"; return 1; fi
  jq -e '.screen | contains("<redacted")' <<<"$s" >/dev/null || { echo "  L6: no marker: $(jq -r .screen <<<"$s" | tail -c 200)"; return 1; }
}

l7() {
  local d="$T/l7-$RANDOM" s p
  run "$1" "$d" '["c-905"]'
  s="$(screens "$d" c-905 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L7: no console push: $(cat "$d/out")"; return 1; }
  for p in "${BOXED:4:8}" "${BOXED:20:8}" "${BOXED:32:8}"; do
    if grep -qF -- "$p" "$d/pushed"; then echo "  L7: a piece of a boxed token left the box: $p"; return 1; fi
  done
  jq -e '(.screen | startswith("before-box\n<redacted:wrapped-secret>\n<redacted:wrapped-secret>\n-- after-box"))
    and (.redactions["wrapped-secret"] // 0) >= 2' <<<"$s" >/dev/null ||
    { echo "  L7: screen: $(jq -c '{screen, redactions}' <<<"$s")"; return 1; }
}

l8() {
  local d="$T/l8-$RANDOM" s p
  run "$1" "$d" '["c-906"]'
  s="$(screens "$d" c-906 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L8: no console push: $(cat "$d/out")"; return 1; }
  # 8 characters from the head, the middle and the tail of each value
  for p in "${PW1:2:8}" "${PW1:40:8}" "${PW1:58:8}" "${PW2:2:8}" "${PW2:30:8}" "${PW2:58:8}"; do
    if grep -qF -- "$p" "$d/pushed"; then echo "  L8: a piece of a wrapped value left the box: $p"; return 1; fi
  done
  # a value ends at a space, and the join drops the newline, so the word
  # that starts the next line ("between-pw", "after-pw") may be masked
  # with it: more, never less (as in L5)
  jq -e '(.screen | startswith("before-pw\n<redacted:wrapped-secret>\n<redacted:wrapped-secret>\n"))
    and (.redactions["wrapped-secret"] // 0) >= 4' <<<"$s" >/dev/null ||
    { echo "  L8: screen: $(jq -c '{screen, redactions}' <<<"$s")"; return 1; }
}

l9() {
  local d="$T/l9-$RANDOM" s p
  run "$1" "$d" '["c-907"]'
  s="$(screens "$d" c-907 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L9: no console push: $(cat "$d/out")"; return 1; }
  for p in "${NESTED:4:8}" "${NESTED:20:8}" "${NESTED:32:8}"; do
    if grep -qF -- "$p" "$d/pushed"; then echo "  L9: a piece of a nested-box token left the box: $p"; return 1; fi
  done
  jq -e '.screen | startswith("before-nest\n<redacted:wrapped-secret>\n<redacted:wrapped-secret>\n-- after-nest")' <<<"$s" >/dev/null ||
    { echo "  L9: screen: $(jq -c '{screen, redactions}' <<<"$s")"; return 1; }
}

l10() {
  local d="$T/l10-$RANDOM" s p
  run "$1" "$d" '["c-908"]'
  s="$(screens "$d" c-908 | tail -n 1)"
  [[ -n "$s" ]] || { echo "  L10: no console push: $(cat "$d/out")"; return 1; }
  while read -r p; do
    if grep -qF -- "$p" "$d/pushed"; then echo "  L10: a piece of a wrapped long token left the box: $p"; return 1; fi
  done <"$T/pat.pieces"
  # a gap line after a token may be masked with it (more, never less):
  # the last gap line of each case stays
  jq -e '(.screen | contains("-- gap 0 3") and contains("-- gap 6 3") and contains("-- after-pat"))
    and (.screen | contains("keep GH_TOKEN=<redacted:github-token> kept-word"))' <<<"$s" >/dev/null ||
    { echo "  L10: screen: $(jq -c '{screen, redactions}' <<<"$s")"; return 1; }
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
  no-mask 'self.mask(st, ln)' '[(ln, False, {})]:' \
  screen-only '"-S", f"-{self.scroll}", ' '' \
  pem-joined 'and PEM_MASK not in text' 'and True'
check L2 "nobody watches: no tmux call, no push" l2 \
  always-capture 'if not self.agents:' 'if not self.agents and False:'
check L3 "a window named with a box tag is found" l3 \
  no-tag 'WINDOW_RE = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9._-]*: )?(\S+)")' 'WINDOW_RE = re.compile(r"^(\S+)")'
check L4 "an unchanged screen is not re-sent before keep_s" l4 \
  always-send 'if last and last[0] == sha and now - last[1] < self.keep_s:' 'if False:'
check L5 "a token hard-wrapped by the TUI (2 lines at col 14, 4 lines at 12 cols) is masked" l5 \
  no-wrap 'for i in self.wrapped(src):' 'for i in []:' \
  pairs-only 'run = parts[i : i + WRAP_SPAN]' 'run = parts[i : i + 2]'
check L6 "a long line is masked before it is cut" l6 \
  cut-first 'ln = ln.rstrip()' 'ln = self.cut(ln.rstrip())'
check L7 "a token hard-wrapped inside a bordered TUI box is masked" l7 \
  no-border 'parts = [unbox(x) for x in lines]  # ctl:console-border' 'parts = [x.strip() for x in lines]'
check L8 "a value-class secret hard-wrapped across two lines is masked, its tail too" l8 \
  masked-join 'src.append(ln if raw else text)  # ctl:console-raw' 'src.append(text)' \
  count-only 'and not crosses:  # ctl:console-wrap' ':  # ctl:console-wrap'
check L9 "a token hard-wrapped inside a nested TUI box is masked" l9 \
  one-layer 'while prev != text:  # ctl:console-unbox' 'for _ in [0]:'
check L10 "a long token wrapped at col 80, and one at col 0, is masked, its tail too" l10 \
  no-end 'self.at_end(run[0]) or ' '' \
  no-whole ' or not self.whole(run[0])' ' or True' \
  lo-falsy 'span(ln, text)[0] is not None' 'span(ln, text)[0]'

[[ "$fails" == 0 ]] && echo "OK spl-lane-console: all passed" || echo "FAIL spl-lane-console: $fails failed"
((fails == 0))
