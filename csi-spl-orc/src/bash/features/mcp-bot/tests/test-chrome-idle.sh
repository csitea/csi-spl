#!/usr/bin/env bash
# The idle timeout of mcp-start-chrome.sh (section 8), with no real browser:
# a fake `npx` stands in for the MCP server (records the bytes it is sent)
# and sleeping processes carrying --user-data-dir stand in for Chrome.
#  - client bytes reach the server unchanged, including a last line with no
#    newline
#  - requests keep the browser alive; after IDLE_SEC without one the MAIN
#    browser of THIS profile is closed, and nothing else: not a --type= child
#    of it, not another profile's browser
#  - stdin EOF and SIGTERM both end the wrapper with no relay, watchdog or
#    stamp left behind
#  - MCP_BOT_CHROME_IDLE_SEC=0 starts no watchdog and closes nothing
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
W="$T_SCRIPTS/mcp-start-chrome.sh"
t_sandbox

mkdir -p "$T_TMP/bin"
cat > "$T_TMP/bin/npx" <<'NPX'
#!/usr/bin/env bash
exec cat > "$FAKE_SERVER_IN"
NPX
chmod +x "$T_TMP/bin/npx"
export PATH="$T_TMP/bin:$PATH"

# alive and not a zombie (the fakes are our children until reaped)
up() {
  local s
  s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$s" in Z*) return 1 ;; esac
}
# children must not inherit fd 7: a writer they hold keeps stdin from ever EOF-ing
fake() { python3 -c 'import time; time.sleep(300)' "$@" 7>&- & T_PIDS="${T_PIDS:-} $!"; }
# exact cmdline: an unanchored match also counts any caller whose command
# line merely mentions the script path (e.g. a `bash -c "... $W ..."`)
wrappers() { pgrep -fx -- "bash $W" | wc -l; }
relays() { pgrep -f -- "$MCP_BOT_HOME/run/chrome-activity-" | wc -l; }
wait_gone() {  # PID SECS
  local i
  for i in $(seq 1 "$(( $2 * 10 ))"); do up "$1" || return 0; sleep 0.1; done
  return 1
}
start() {  # ID — runs the wrapper with stdin on a fifo held open by fd 7
  rm -f "$T_TMP/in"; mkfifo "$T_TMP/in"
  exec 7<>"$T_TMP/in"
  export FAKE_SERVER_IN="$T_TMP/server-in-$1"
  MCP_BOT_AGENT_ID="$1" bash "$W" <"$T_TMP/in" >"$T_TMP/out-$1" 2>"$T_TMP/err-$1" 7>&- &
  WPID=$!; T_PIDS="${T_PIDS:-} $WPID"
  sleep 1
}

# ── 1. activity, idle close, scope of the kill, EOF exit ────────────────────
export MCP_BOT_CHROME_IDLE_SEC=8 MCP_BOT_CHROME_IDLE_POLL_SEC=1
start t1
PROF="$MCP_BOT_HOME/cr-profile-t1"
fake "--user-data-dir=$PROF";                  MAIN=$!
fake --type=renderer "--user-data-dir=$PROF";  CHILD=$!
fake "--user-data-dir=$PROF-other";            OTHER=$!
: > "$T_TMP/sent"
for i in $(seq 1 12); do
  printf '{"id":%d}\n' "$i" | tee -a "$T_TMP/sent" >&7
  sleep 1
done
check "requests every 1s keep the browser up past IDLE_SEC=8" up "$MAIN"
eq "watchdog runs beside the wrapper" 2 "$(wrappers)"
sleep 11
check "idle > 8s closes the main browser" wait_gone "$MAIN" 2
check "its --type= child is not targeted" up "$CHILD"
check "another profile's browser is untouched" up "$OTHER"
has "the close is logged with its pid" "closing browser pid $MAIN " "$(cat "$T_TMP/err-t1")"
eq "exactly one close" 1 "$(grep -c 'closing browser pid' "$T_TMP/err-t1")"
eq "nothing written to the MCP stdout channel" "" "$(cat "$T_TMP/out-t1")"
printf 'tail-no-newline' | tee -a "$T_TMP/sent" >&7
exec 7>&-
check "stdin EOF ends the wrapper" wait_gone "$WPID" 10
check "server got the client bytes unchanged" cmp -s "$T_TMP/sent" "$FAKE_SERVER_IN"
eq "no relay left" 0 "$(relays)"
eq "no watchdog left" 0 "$(wrappers)"
eq "no stamp left" "" "$(cd "$MCP_BOT_HOME/run" && compgen -G 'chrome-activity-*' || true)"

# ── 2. SIGTERM while the client still holds stdin open ──────────────────────
export MCP_BOT_CHROME_IDLE_SEC=600
start t2
kill -TERM "$WPID"
check "SIGTERM ends the wrapper" wait_gone "$WPID" 10
sleep 0.5
eq "no relay left after SIGTERM" 0 "$(relays)"
eq "no watchdog left after SIGTERM" 0 "$(wrappers)"
exec 7>&-

# ── 3. IDLE_SEC=0 disables the watchdog ─────────────────────────────────────
export MCP_BOT_CHROME_IDLE_SEC=0
start t3
fake "--user-data-dir=$MCP_BOT_HOME/cr-profile-t3"; MAIN3=$!
eq "no watchdog process" 1 "$(wrappers)"
sleep 3
check "browser stays up with the timeout off" up "$MAIN3"
exec 7>&-
check "stdin EOF ends the wrapper" wait_gone "$WPID" 10

t_done
