#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_set_mistral_key (spec 110 2.3, seat-4 change 1), hermetic: a
#          temp agent home, a fake canary key, a real pty for the prompt.
#   1. the terminal path: .vibe/.env 600, dir 700, owner, other lines kept,
#      an old MISTRAL_API_KEY line replaced, the masked check printed
#   2. MISTRAL_KEY_FILE (MISTRAL_API_KEY=<key> and a bare key) and
#      MISTRAL_KEY_STDIN=1
#   3. TO_BOX: the key goes over ssh stdin to the box's agent user; a box
#      answering to another tag is refused before the key is sent
#   4. refusals: a fleet tmux window, a non-tty stdin, an empty key, a key
#      with a space - nothing written
#   5. the canary key is in no output, no stub argv/env and no ps sample
#   6. CONTROL: a planted echo of the key IS caught by the same leak check
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

ME="$(id -un)"
KEY="canaryK3y${RANDOM}${RANDOM}x${RANDOM}Z"
OLD="oldK3y${RANDOM}${RANDOM}${RANDOM}"
H="$T/agent-home"
mkdir -p "$H" "$T/spool" "$T/remote" "$T/stub/remote-bin"
: >"$T/calls.log"

# stubs: argv AND environment go to the log, so a key in either is caught
for b in curl sudo tmux; do
  printf '#!/usr/bin/env bash\n{ echo "%s $*"; env; } >>"$STUB_LOG"\n%s\n' "$b" \
    "$([[ $b == tmux ]] && echo 'echo "${FAKE_TMUX_WINDOW:-}"')" >"$T/stub/$b"
done
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
{ echo "ssh $*"; env; } >>"$STUB_LOG"
while [[ "$1" == -o ]]; do shift 2; done
dest="$1" cmd="$2"
[[ "$cmd" == 'cat /etc/csi-spl-satellite.env' ]] && { cat "$FAKE_BOX_ENV"; exit 0; }
PATH="$FAKE_STUB_DIR/remote-bin:$PATH" eval "$cmd"
EOF
cat >"$T/stub/remote-bin/sudo" <<'EOF'
#!/usr/bin/env bash
{ echo "remote-sudo $*"; env; } >>"$STUB_LOG"
while [[ "$1" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
HOME="$FAKE_REMOTE_HOME" exec "$@"
EOF
chmod +x "$T/stub/"* "$T/stub/remote-bin/sudo"
printf 'AGENT_USER=%s\nBOX_TAG=sat\n' "$ME" >"$T/box.env"

# in_orc with the hermetic agent: this user, the temp home, no tmux
smk() {
  env -u TMUX SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" MISTRAL_KEY_AGENT_HOME="$H" \
    FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_REMOTE_HOME="$T/remote" \
    SNIPPET="${SNIPPET:-do_set_mistral_key}" "$@"
}
export -f in_orc
export PROJ_ROOT APP_ROOT T
# on_pty <key> [VAR=value]...: the action on a real pty; the key is typed at
# the prompt (python reads it from its stdin, never argv or env)
on_pty() {
  local k="$1"; shift
  printf '%s\n' "$k" | smk "$@" python3 -c '
import os, pty, select, sys, time
key = sys.stdin.readline().rstrip("\n")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", "in_orc"])
buf, sent, end = b"", False, time.time() + 30
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        buf += d
    if not sent and b"not echoed" in buf:
        time.sleep(0.3); os.write(fd, (key + "\n").encode()); sent = True
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(buf)
sys.exit(os.waitstatus_to_exitcode(st))' >"$T/o" 2>&1
}
# ps sampler: every process line while the actions run
( while :; do ps -eo args= 2>/dev/null; sleep 0.05; done >>"$T/ps.log" ) & PS_PID=$!
no_leak() { ! grep -qF "$1" "$T/o" "$T/calls.log" "$T/ps.log"; }
envf="$H/.vibe/.env"
facts() { printf '%s %s %s' "$(stat -c %a "$envf")" "$(stat -c %a "$H/.vibe")" "$(stat -c %U "$envf")"; }

# --- 1. terminal path ------------------------------------------------------------------------
mkdir -p "$H/.vibe"; printf 'OTHER=keep-me\nMISTRAL_API_KEY=%s\n# a comment\n' "$OLD" >"$envf"; chmod 644 "$envf"
on_pty "$KEY"; rc=$?
if [[ $rc -eq 0 ]] && [[ "$(facts)" == "600 700 $ME" ]] && grep -qx "MISTRAL_API_KEY=$KEY" "$envf" &&
   grep -qx 'OTHER=keep-me' "$envf" && grep -qx '# a comment' "$envf" && ! grep -qF "$OLD" "$envf" &&
   [[ "$(grep -c '^MISTRAL_API_KEY=' "$envf")" == 1 ]] && grep -q "key read: length=${#KEY} last4=${KEY: -4}" "$T/o"; then
  pass "1: terminal key -> .vibe/.env 600 in 700, owner $ME, other lines kept, old key replaced, masked check"
else fail "1: terminal path (rc=$rc facts=$(facts)): $(tr -d '\r' <"$T/o" | tail -n3)"; fi
compgen -G "$H/.vibe/.env.*" >/dev/null && fail "1: a temp file was left behind" || pass "1: no temp file left"

# --- 2. file and stdin -------------------------------------------------------------------------
K2="fileK3y${RANDOM}${RANDOM}${RANDOM}"; printf 'MISTRAL_API_KEY=%s\n' "$K2" >"$T/crs"; chmod 600 "$T/crs"
smk MISTRAL_KEY_FILE="$T/crs" bash -c in_orc </dev/null >"$T/o" 2>&1 && grep -qx "MISTRAL_API_KEY=$K2" "$envf" &&
  grep -qx 'OTHER=keep-me' "$envf" && ! grep -q WARN "$T/o" && pass "2: MISTRAL_KEY_FILE (MISTRAL_API_KEY= form)" ||
  fail "2: MISTRAL_KEY_FILE: $(tail -n2 "$T/o")"
no_leak "$K2" && pass "2: file key in no output, argv, env or ps" || fail "2: file key leaked"
K3="bareK3y${RANDOM}${RANDOM}${RANDOM}"; printf '%s\r\n' "$K3" >"$T/crs2"; chmod 644 "$T/crs2"
smk MISTRAL_KEY_FILE="$T/crs2" bash -c in_orc </dev/null >"$T/o" 2>&1 && grep -qx "MISTRAL_API_KEY=$K3" "$envf" &&
  grep -q 'WARN .*readable beyond its owner' "$T/o" && pass "2: bare-key file (CRLF) + WARN on mode 644" ||
  fail "2: bare-key file: $(tail -n2 "$T/o")"
printf 'MISTRAL_API_KEY=%s\n' "$KEY" | smk MISTRAL_KEY_STDIN=1 bash -c in_orc >"$T/o" 2>&1 &&
  grep -qx "MISTRAL_API_KEY=$KEY" "$envf" && pass "2: MISTRAL_KEY_STDIN=1" || fail "2: stdin: $(tail -n2 "$T/o")"

# --- 3. TO_BOX over ssh stdin -------------------------------------------------------------------
printf 'MISTRAL_API_KEY=%s\n' "$KEY" >"$T/crs"
smk MISTRAL_KEY_FILE="$T/crs" TO_BOX=sat bash -c in_orc </dev/null >"$T/o" 2>&1; rc=$?
r="$T/remote/.vibe/.env"
[[ $rc -eq 0 && "$(stat -c %a "$r" 2>/dev/null)" == 600 ]] && grep -qx "MISTRAL_API_KEY=$KEY" "$r" &&
  grep -q '^remote-sudo -n -u '"$ME"' -H bash -c' "$T/calls.log" && pass "3: TO_BOX=sat: written as the box's agent user over ssh" ||
  fail "3: TO_BOX (rc=$rc): $(tail -n2 "$T/o")"
rm -rf "$T/remote/.vibe"; printf 'AGENT_USER=%s\nBOX_TAG=other\n' "$ME" >"$T/box2.env"
smk MISTRAL_KEY_FILE="$T/crs" TO_BOX=sat FAKE_BOX_ENV="$T/box2.env" bash -c in_orc </dev/null >"$T/o" 2>&1
[[ $? -ne 0 && ! -e "$T/remote/.vibe" ]] && grep -q 'answers-as-other' "$T/o" &&
  pass "3: a box answering as another tag is refused, nothing written" || fail "3: wrong tag: $(tail -n2 "$T/o")"

# --- 4. refusals ---------------------------------------------------------------------------------
before="$(sha256sum <"$envf")"
smk TMUX="$T/fake-tmux,1,0" FAKE_TMUX_WINDOW='sat: c-123 some lane' python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0: os.execvp("bash", ["bash", "-c", "in_orc"])
buf = b""
while True:
    try: d = os.read(fd, 4096)
    except OSError: break
    if not d: break
    buf += d
_, st = os.waitpid(pid, 0); sys.stdout.buffer.write(buf); sys.exit(os.waitstatus_to_exitcode(st))' >"$T/o" 2>&1
[[ $? -ne 0 ]] && grep -q 'fleet agent tmux window' "$T/o" && pass "4: refused in a fleet tmux window" || fail "4: fleet pane: $(tail -n2 "$T/o")"
printf '%s\n' "$KEY" | smk bash -c in_orc >"$T/o" 2>&1
[[ $? -ne 0 ]] && grep -q 'stdin is not a terminal' "$T/o" && pass "4: refused with a non-tty stdin" || fail "4: non-tty: $(tail -n2 "$T/o")"
on_pty ""
[[ $? -ne 0 ]] && grep -q 'empty key' "$T/o" && pass "4: refused an empty key" || fail "4: empty key: $(tr -d '\r' <"$T/o" | tail -n2)"
on_pty "abc def ghi jkl mno pqr"
[[ $? -ne 0 ]] && grep -q 'not 16..256' "$T/o" && pass "4: refused a key with spaces" || fail "4: bad key: $(tr -d '\r' <"$T/o" | tail -n2)"
[[ "$(sha256sum <"$envf")" == "$before" ]] && pass "4: no refusal touched .vibe/.env" || fail "4: a refusal changed .vibe/.env"

# --- 5. leak check over every run above ---------------------------------------------------------
on_pty "$KEY" >/dev/null
no_leak "$KEY" && pass "5: the canary key is in no output, stub argv/env or ps sample" ||
  fail "5: the canary key leaked: $(grep -lF "$KEY" "$T/o" "$T/calls.log" "$T/ps.log" | xargs -n1 basename | paste -sd' ')"

# --- 6. CONTROL: a planted echo is caught ---------------------------------------------------------
on_pty "$KEY" SNIPPET='eval "$(declare -f spl_smk_main | sed "s/do_log \"INFO key read: \$mask\"/echo \"\$key\"; &/")"; do_set_mistral_key'
no_leak "$KEY" && fail "6: CONTROL: the planted echo was NOT caught" || pass "6: CONTROL: the leak check catches a planted echo"

kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null
echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
