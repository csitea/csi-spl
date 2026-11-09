#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the kill-target matcher
# (features/spawn-agents/lib/kill-target-guard.inc.sh), SPL-2583:
#   1. refused: rc 2, one "kill-guard: refused:" line - the 2026-10-18 sat
#      command (`pids=$(ps ... | awk ...); sudo kill $pids`), kill 0 / 1 /
#      a negative pid, a literal pid of tmux, cron, systemd, sshd or another
#      agent's claude, $( ) / backtick / xargs targets, killall, pkill -f,
#      pkill of a protected name, and the same inside bash -c / sudo / eval
#   2. allowed: rc 0, nothing on stderr - one own child pid (a descendant of
#      the caller agent), $!, %1, kill -l, pkill -x <own tool>, commands that
#      only mention kill, a pid with no process
#   3. the hook path: force-push-guard-hook.sh refuses the sat command for
#      claude (exit 2) and agy (deny JSON, exit 0) and lets an own child
#      through; RED: the hook on origin/master before SPL-2583 lets it through
#   3b. the mistral vibe pre_tool hook denies it; 3c. spool-install y13 and
#      y12 copy the matcher next to the hooks they install
#   4. the direct CLI form (--check) answers the same, and a bad call is 64
#   5. fail closed: with no python3 on PATH a kill command is refused
# RED CONTROL: a matcher that allows everything fails every case in 1.
# The cases are TEXT only: nothing here is ever run as a command. `ps` is a
# stub on PATH printing a fixed process table; KILL_GUARD_SELF_PID names the
# caller agent in it.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC1091  # the cases are literal commands, never expanded
set -uo pipefail
SA="$(cd "$(dirname "$0")/../features/spawn-agents" && pwd)"
G="$SA/lib/kill-target-guard.inc.sh"
HOOK="$SA/scripts/force-push-guard-hook.sh"
# shellcheck source=../features/spawn-agents/lib/kill-target-guard.inc.sh
. "$G"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
# The stub process table: pid ppid args. 3000 is the caller agent, 3100 its
# shell, 3200 its child; 2000 is another seat's claude.
cat >"$T/ps.txt" <<'EOF_PS'
      1       0 /usr/lib/systemd/systemd --system --deserialize=71
   1000       1 tmux -u -S /tmp/tmux-2000/default new-session -d -s main
   1100       1 /usr/sbin/cron -f
   1200       1 /usr/lib/systemd/systemd --user
   1300       1 sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
   2000    1000 /opt/agent/bin/claude --name c-002@box --dangerously-skip-permissions
   2100    1000 grok --dangerously-skip-permissions
   2200    1000 python3 /opt/agent/bin/vibe --auto-approve
   3000    1000 /opt/agent/bin/claude --name c-454@box --dangerously-skip-permissions
   3100    3000 /bin/bash -c sleep 600
   3200    3100 sleep 600
   3300    3000 node serve.mjs --port 4321
   2500    1000 -bash
   2600    2500 /opt/agent/bin/claude --name c-110@box --dangerously-skip-permissions
   4000    1000 -bash
   4100    4000 sleep 99
EOF_PS
printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/ps.txt" >"$T/bin/ps"
chmod +x "$T/bin/ps"
# The stub tmux answers display-message like the real one: a bad target is
# rc 0 with empty output. %2 / c-002 another claude, %5 a shell over another
# claude, %3 the caller's own pane, %4 a bare shell. sudo only runs its command.
cat >"$T/bin/tmux" <<'EOF_TMUX'
#!/usr/bin/env bash
t=default
while [ $# -gt 0 ]; do [ "$1" = -t ] && t="$2"; shift; done
case "$t" in
  %2|c-002) echo 2000 ;;
  %5) echo 2500 ;;
  %3|default) echo 3000 ;;
  %4) echo 4000 ;;
esac
exit 0
EOF_TMUX
cat >"$T/bin/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
EOF_SUDO
chmod +x "$T/bin/tmux" "$T/bin/sudo"
export PATH="$T/bin:$PATH" KILL_GUARD_SELF_PID=3000

refuse() {  # <name> <command>
  local err rc
  err="$(kill_target_guard_check "$2" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [[ "$err" == "kill-guard: refused: "* ]]
  then pass "refused: $1"; else fail "should refuse (rc=$rc err=$err): $1"; fi
}
allow() {  # <name> <command>
  local err rc
  err="$(kill_target_guard_check "$2" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$err" ]; then pass "allowed: $1"; else fail "should allow (rc=$rc err=$err): $1"; fi
}

# the exact command of 2026-10-18 11:57:04Z on sat (c-454 transcript)
SAT='pids=$(ps -eo pid=,ppid= | awk -v r=3699287 '"'"'BEGIN{a[r]=1} {p[$1]=$2} END{ch=1; while(ch){ch=0; for(k in p) if(a[p[k]] && !a[k]){a[k]=1; ch=1}} for(k in a) print k}'"'"'); sudo kill $pids'

# 1. refused
run_refusals() {
  refuse "the 2026-10-18 sat command" "$SAT"
  refuse "the list it expanded to: sudo kill 0 1 1000 1100" 'sudo kill 0 1 1000 1100'
  refuse "kill 1" 'kill 1'
  refuse "kill -9 -1 (every process)" 'kill -9 -1'
  refuse "kill -- -3100 (a process group)" 'kill -- -3100'
  refuse "kill -s KILL -3100" 'kill -s KILL -3100'
  refuse "the tmux server" 'kill 1000'
  refuse "cron" 'sudo kill -9 1100'
  refuse "the user systemd" 'kill 1200'
  refuse "sshd" 'sudo kill 1300'
  refuse "another agent's claude" 'kill 2000'
  refuse "another agent's grok" 'kill -TERM 2100'
  refuse "another agent's vibe" 'kill 2200'
  refuse "an own child next to cron" 'kill 3200 1100'
  refuse "a \$( ) target" 'kill $(pgrep -x sleep)'
  refuse "a backtick target" 'kill `cat /tmp/x.pid`'
  refuse "a variable target" 'kill "$PID"'
  refuse "xargs kill" 'pgrep sleep | xargs -r kill -9'
  refuse "killall" 'killall sleep'
  refuse "sudo killall" 'sudo killall -9 node'
  refuse "pkill -f" 'pkill -f "git push"'
  refuse "pkill --full" 'pkill --full serve.mjs'
  refuse "pkill claude" 'pkill claude'
  refuse "pkill tmux" 'sudo pkill -x tmux'
  refuse "pkill . (matches everything)" 'pkill .'
  refuse "inside bash -c" 'sudo -u owner bash -c "kill -9 1000"'
  refuse "inside eval" 'eval kill 1'
  refuse "after &&" 'cd /tmp && timeout 5 kill 1100'
  refuse "a heredoc read by bash" 'bash <<EOF_K
kill 1000
EOF_K'
  refuse "send-keys /exit into another agent" "tmux send-keys -t %2 '/exit' Enter"
  refuse "send-keys -l /exit, the alias send" 'tmux send -t %2 -l /exit'
  refuse "send-keys -t glued to the target" 'tmux send-keys -t%2 /exit Enter'
  refuse "send-keys by window name" 'tmux send-keys -t c-002 /exit Enter'
  refuse "send-keys /exit-clean with an argument" "tmux send-keys -t %2 '/exit-clean no-close' Enter"
  refuse "send-keys /kill-your-self" 'tmux send-keys -t %2 /kill-your-self Enter'
  refuse "/exit typed key by key" 'tmux send-keys -t %2 / e x i t Enter'
  refuse "a shell pane over another agent" 'tmux send-keys -t %5 /exit Enter'
  refuse "send-keys with the socket, through sudo" 'sudo -u owner tmux -S /tmp/s send-keys -t %2 /exit Enter'
  refuse "send-keys inside bash -c under sudo" "sudo -u owner bash -c 'tmux -S /tmp/s send-keys -t %2 /exit Enter'"
  refuse "the second command of a tmux chain" 'tmux send-keys -t %4 C-u \; send-keys -t %2 /exit Enter'
  refuse "send-keys /exit to a computed pane" 'tmux send-keys -t "$PANE" /exit Enter'
  refuse "send-keys /exit to a \$( ) pane" 'tmux send-keys -t $(cat /tmp/p) /exit Enter'
  refuse "send-keys /exit to a pane tmux cannot find" 'tmux send-keys -t %99 /exit Enter'
  refuse "send-keys /exit on another box" "ssh box2 'tmux send-keys -t %2 /exit Enter'"
  refuse "send-keys /exit-clean on another box" "ssh box2 'tmux send-keys -t %4 /exit-clean Enter'"
  refuse "send-keys of a quoted /exit on another box" "ssh box2 'tmux send-keys -t %4 \"/exit\" Enter'"
  refuse "a \$( ) pane inside bash -c double quotes" 'bash -c "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "a \$( ) pane inside sudo bash -c double quotes" 'sudo -u owner bash -c "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "a \$( ) pane inside eval double quotes" 'eval "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "a \$( ) pane after a message that quotes one" 'spool-send.sh --body "tmux send-keys -t $(cat p) /exit"; tmux send-keys -t $(cat /tmp/p) /exit Enter'
  refuse "an apostrophe in double quotes before a live \$( ) pane" "echo \"don't\"; tmux send-keys -t \$(cat p) /exit Enter"
  refuse "a message with an apostrophe before a live \$( ) pane" "spool-send.sh --body \"it's ok\" && tmux send-keys -t \$(cat p) /exit Enter"
  refuse "a \$( ) pane inside bash -lc double quotes" 'bash -lc "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "a \$( ) pane inside env -S double quotes" 'env -S "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "send-keys /exit-clean; on another box" "ssh box2 'tmux send-keys -t %4 /exit-clean; true'"
  refuse "send-keys /exit; on another box" "ssh box2 'tmux send-keys -t %4 /exit; true'"
  refuse "a \$( ) pane inside sudo su -c double quotes" 'sudo su -c "tmux send-keys -t $(cat /tmp/p) /exit Enter"'
  refuse "a \$( ) pane inside sh -c single quotes" "sh -c 'tmux send-keys -t \$(cat /tmp/p) /exit Enter'"
  refuse "a \$( ) pane inside a double-quoted \$( )" 'echo "$(tmux send-keys -t $(cat /tmp/p) /exit Enter)"'
}
run_refusals

# 2. allowed
allow "one own child pid" 'kill 3200'
allow "own child, SIGKILL, through sudo" 'sudo kill -9 3200'
allow "two own children" 'kill 3100 3300'
allow "the last background job" 'sleep 100 & kill $!'
allow "a job spec" 'kill %1'
allow "kill -l" 'kill -l'
allow "a pid with no process" 'kill 99999'
allow "pkill -x of an own tool name" 'pkill -x sleep'
allow "a commit message that names kill" 'git commit -m "fix: kill guard refuses kill 1"'
allow "grep for kill" 'grep -rn "kill 0" src/'
allow "a heredoc body is data" 'cat > note.md <<EOF_N
sudo kill $pids
EOF_N'
allow "no kill at all" 'echo hi'
allow "send-keys /exit into the own pane" 'tmux send-keys -t %3 /exit Enter'
allow "send-keys /exit into \$TMUX_PANE" 'tmux send-keys -t "$TMUX_PANE" /exit Enter'
allow "send-keys /exit with no target: the own pane" 'tmux send-keys /exit Enter'
allow "send-keys /exit into a bare shell" 'tmux send-keys -t %4 /exit Enter'
allow "send-keys of other text into another agent" 'tmux send-keys -t %2 "hello" Enter'
allow "send-keys Enter alone into another agent" 'tmux send-keys -t %2 Enter'
allow "send-keys -X, a copy-mode command" 'tmux send-keys -t %2 -X cancel'
allow "a message that quotes the send-keys" 'spool-send.sh --body "tmux send-keys -t %2 /exit Enter"'
allow "a path that holds /exit" 'tmux send-keys -t %2 /exits/of/town Enter'
allow "a message that quotes a \$( ) pane" 'spool-send.sh --body "never tmux send-keys -t $(cat p) /exit Enter"'
allow "a single-quoted message with a \$( ) pane" "spool-send.sh --body 'never tmux send-keys -t \$(cat p) /exit Enter'"
allow "bash spool-send.sh with a message quoting a \$( ) pane" 'bash /h/scripts/spool-send.sh --from c-1 --to c-2 --kind result --body "never tmux send-keys -t $(cat p) /exit Enter"'
allow "bash spool-send.sh with a single-quoted message" "bash /h/scripts/spool-send.sh --from c-1 --to c-2 --kind result --body 'never tmux send-keys -t \$(cat p) /exit Enter'"
allow "env spool-send.sh with a message quoting a \$( ) pane" 'sudo -u owner env A=1 /h/spool-send.sh --body "never tmux send-keys -t $(cat p) /exit Enter"'
allow "a script argument quoting a \$( ) pane" 'bash scripts/x.sh "tmux send-keys -t $(cat p) /exit"'
allow "git log --grep quoting a \$( ) pane" 'git log --grep "tmux send-keys -t $(cat p) /exit"'
allow "grep -F quoting a \$( ) pane" "grep -F 'tmux send-keys -t \$(cat p) /exit' /tmp/a"

# 3. through the shared hook (claude / agy contracts)
hook() {  # <hook> <harness> <command> -> "rc|stdout"
  local p out rc
  p="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"toolCall":{"name":"run_command","args":{"CommandLine":sys.argv[1]}}}))' "$3")"
  out="$(printf '%s' "$p" | bash "$1" "$2" 2>/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}
r="$(hook "$HOOK" claude "$SAT")"
if [ "${r%%|*}" = 2 ] && [[ "$r" == *kill-guard* ]]; then pass "hook claude: the sat command exit 2"; else fail "hook claude: $r"; fi
r="$(hook "$HOOK" agy "$SAT")"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*kill-guard* ]]; then pass "hook agy: the sat command deny JSON"; else fail "hook agy: $r"; fi
r="$(hook "$HOOK" claude 'kill 3200')"
if [ "$r" = "0|" ]; then pass "hook claude: an own child passes"; else fail "hook claude own child: $r"; fi
r="$(hook "$HOOK" agy 'kill 3200')"
if [ "$r" = '0|{"decision":"allow"}' ]; then pass "hook agy: an own child allow"; else fail "hook agy own child: $r"; fi
r="$(hook "$HOOK" claude "tmux send-keys -t %2 '/exit' Enter")"
if [ "${r%%|*}" = 2 ] && [[ "$r" == *kill-guard* ]]; then pass "hook claude: /exit into another agent's pane exit 2"; else fail "hook claude send-keys: $r"; fi
r="$(hook "$HOOK" agy "tmux send-keys -t %2 '/exit' Enter")"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*kill-guard* ]]; then pass "hook agy: /exit into another agent's pane deny JSON"; else fail "hook agy send-keys: $r"; fi
r="$(hook "$HOOK" claude 'tmux send-keys -t %3 /exit Enter')"
if [ "$r" = "0|" ]; then pass "hook claude: /exit into the own pane passes"; else fail "hook claude own pane: $r"; fi
# The sanctioned paths type /exit inside their own scripts, which the hook
# does not read: it sees only the command that starts them.
for sanctioned in \
  'cd csi-spl-orc && ./run -a do_spl_dispatch_rotate' \
  'cd csi-spl-orc && ./run -a do_spl_lane_rotate' \
  'cd csi-spl-orc && ./run -a do_spl_orch_rotate' \
  'cd csi-spl-orc && ./run -a do_spl_peer_restart' \
  'bash tmux-close-window.sh c-110 --defer'; do
  r="$(hook "$HOOK" claude "$sanctioned")"
  if [ "$r" = "0|" ]; then pass "hook claude: sanctioned: $sanctioned"; else fail "hook claude sanctioned ($sanctioned): $r"; fi
done
grep -qF 'spl_rotate_tmux send-keys -t "$pane" -l "$cmd"' "$SA/../../run/spl-rotate-lib.func.sh" &&
  grep -qF "send-keys -t \"\$1\" -l '/exit'" "$SA/scripts/tmux-close-window.sh"
if [ $? = 0 ]; then pass "the rotate lib and close-window still type /exit in their own scripts"
else fail "a sanctioned path no longer types /exit in its script: re-check where the guard sits"; fi
# RED: the hook as it was before SPL-2583 (3bec8b115, kept as a fixture:
# CI checks out shallow, so git history is not there) lets the sat command
# through.
old="$T/old-hook"
mkdir -p "$old"
cp "$SA/lib/force-push-guard.inc.sh" "$SA/lib/heredoc-collision-guard.inc.sh" "$old/"
OLD_HOOK="$(dirname "${BASH_SOURCE[0]}")/fixtures/kill-target-guard/force-push-guard-hook.pre-spl-2583.sh"
if cp "$OLD_HOOK" "$old/force-push-guard-hook.sh" 2>/dev/null; then
  r="$(FORCE_PUSH_GUARD_LIB="$old/force-push-guard.inc.sh" hook "$old/force-push-guard-hook.sh" claude "$SAT")"
  if [ "$r" = "0|" ]; then pass "red: the pre-SPL-2583 hook let the sat command through"
  else fail "red: the pre-SPL-2583 hook answered $r"; fi
else
  fail "red: fixture $OLD_HOOK missing"
fi

# 3b. mistral: the vibe pre_tool hook (vibe-push-guard.py) denies it too
VIBE="$SA/../spool-install/assets/vibe-push-guard/vibe-push-guard.py"
vibe() {  # <command> -> "rc|stdout"
  local out rc
  out="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"pre_tool","tool_name":"bash","tool_input":{"command":sys.argv[1]}}))' "$1" |
    SPOOL_PUSH_GUARD_MATCHER="$SA/lib/force-push-guard.inc.sh" \
    SPOOL_HEREDOC_GUARD_MATCHER="$SA/lib/heredoc-collision-guard.inc.sh" \
    SPOOL_KILL_GUARD_MATCHER="$G" python3 "$VIBE" 2>/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}
r="$(vibe "$SAT")"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*kill-guard* ]]; then pass "vibe hook: the sat command denied"; else fail "vibe hook: $r"; fi
r="$(vibe 'kill 3200')"
if [ "$r" = "0|" ]; then pass "vibe hook: an own child passes"; else fail "vibe hook own child: $r"; fi
r="$(vibe 'tmux send-keys -t %2 /exit Enter')"
if [ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*kill-guard* ]]; then pass "vibe hook: /exit into another agent's pane denied"; else fail "vibe hook send-keys: $r"; fi

# 3c. spool-install y13 and y12 copy the matcher next to the hooks
y13d="$T/y13"
mkdir -p "$y13d/home/.claude"
bash -c '. "$1" && spool_install_force_push_guard "$2/home" "$2" 0 1' _ \
  "$SA/../spool-install/steps/y13-force-push-guard.sh" "$y13d" >/dev/null 2>&1
if cmp -s "$G" "$y13d/force-push-guard/kill-target-guard.inc.sh"; then
  r="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$SAT" |
    bash "$y13d/force-push-guard/force-push-guard-hook.sh" claude >/dev/null 2>&1; echo $?)"
  if [ "$r" = 2 ]; then pass "y13: the installed hook copy refuses the sat command"; else fail "y13 installed hook rc=$r"; fi
else fail "y13 did not copy kill-target-guard.inc.sh"; fi
mkdir -p "$T/vibe"
bash -c '. "$1" && spool_install_vibe_push_guard "$2" 0' _ \
  "$SA/../spool-install/steps/y12-vibe-push-guard.sh" "$T/vibe" >/dev/null 2>&1
if cmp -s "$G" "$T/vibe/spool-push-guard/kill-target-guard.inc.sh"; then pass "y12: copies the matcher next to the vibe hook"
else fail "y12 did not copy kill-target-guard.inc.sh"; fi

# 4. the CLI form
bash "$G" --check "$SAT" 2>/dev/null; rc=$?
if [ "$rc" = 2 ]; then pass "--check refuses the sat command"; else fail "--check rc=$rc"; fi
bash "$G" --check 'kill 3200' 2>/dev/null; rc=$?
if [ "$rc" = 0 ]; then pass "--check allows an own child"; else fail "--check own child rc=$rc"; fi
bash "$G" 2>/dev/null; rc=$?
if [ "$rc" = 64 ]; then pass "a bad call is 64"; else fail "bad call rc=$rc"; fi

# 5. fail closed
nopy="$T/nopy"
mkdir -p "$nopy"
ln -s "$(command -v bash)" "$nopy/bash"
PATH="$nopy" bash "$G" --check 'kill 3200' 2>/dev/null; rc=$?
if [ "$rc" = 2 ]; then pass "no python3: refused (fail closed)"; else fail "no python3 rc=$rc"; fi

# RED CONTROL: with the matcher stubbed to allow, every refusal case fails
kill_target_guard_check() { return 0; }
real_fails="$fails" real_n="$n"
run_refusals >/dev/null
red=$((fails - real_fails)) cases=$((n - real_n))
fails="$real_fails" n="$real_n"
if [ "$cases" -gt 0 ] && [ "$red" = "$cases" ]; then pass "red control: an allow-all matcher fails $red/$cases refusal cases"
else fail "red control: an allow-all matcher failed only $red/$cases"; fi

echo "kill-target-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
