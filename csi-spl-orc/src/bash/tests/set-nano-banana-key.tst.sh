#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_set_nano_banana_key (spec 111 T011, test 9-p), hermetic: a temp
#          agent home, a temp box-user home, fake canary keys.
#   1. the default file ($HOME/.gemini/.csi/api_key): .nano-banana/crs is ONE
#      line GEMINI_API_KEY=<key>, 600 in 700, owner, an old crs replaced
#      whole, the masked check printed, no temp file left
#   2. NANO_BANANA_KEY_FILE: a bare key (CRLF, mode 644 -> WARN) and a quoted
#      GOOGLE_API_KEY= line
#   3. TO_BOX: the key goes over ssh stdin to the box's agent user; a box
#      answering to another tag is refused before the key is sent
#   4. refusals: a missing file, an empty file, a key with a space, a crs
#      that is a symlink - nothing written
#   5. the canary key is in no output (the log), stub argv/env or ps sample
#   6. CONTROL: a planted echo of the key in the output, in argv and in an
#      exported env var IS caught by the same leak check
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME="$(id -un)"
KEY="canaryNb${RANDOM}${RANDOM}x${RANDOM}Z"
OLD="oldNbK3y${RANDOM}${RANDOM}${RANDOM}"
H="$T/agent-home" U="$T/user-home"
mkdir -p "$H" "$U/.gemini/.csi" "$T/spool" "$T/remote" "$T/stub/remote-bin"
: >"$T/calls.log"

# stubs: argv AND environment go to the log, so a key in either is caught
for b in curl sudo tmux; do
  printf '#!/usr/bin/env bash\n{ echo "%s $*"; env; } >>"$STUB_LOG"\n' "$b" >"$T/stub/$b"
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

# snb [VAR=value]...: in_orc with the hermetic agent (this user, the temp
# home) and the temp box-user home; stdin is never a terminal
snb() {
  env -u TMUX -u NANO_BANANA_KEY_FILE HOME="$U" SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
    NANO_BANANA_KEY_AGENT_HOME="$H" FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" \
    FAKE_REMOTE_HOME="$T/remote" SNIPPET="${SNIPPET:-do_set_nano_banana_key}" "$@" \
    bash -c in_orc </dev/null >"$T/o" 2>&1
}
export -f in_orc
export PROJ_ROOT APP_ROOT T
# ps sampler: every process line while the actions run
( while :; do ps -eo args= 2>/dev/null; sleep 0.05; done >>"$T/ps.log" ) & PS_PID=$!
no_leak() { ! grep -qF "$1" "$T/o" "$T/calls.log" "$T/ps.log"; }
crs="$H/.nano-banana/crs" src="$U/.gemini/.csi/api_key"
facts() { printf '%s %s %s %s' "$(stat -c %a "$crs")" "$(stat -c %a "$H/.nano-banana")" "$(stat -c %U "$crs")" "$(wc -l <"$crs")"; }

# --- 1. default file -----------------------------------------------------------------------------
mkdir -p "$H/.nano-banana"; chmod 755 "$H/.nano-banana"
printf 'OTHER=gone\nGEMINI_API_KEY=%s\n# a comment\n' "$OLD" >"$crs"; chmod 644 "$crs"
printf 'GEMINI_API_KEY=%s\n' "$KEY" >"$src"; chmod 600 "$src"
snb; rc=$?
if [[ $rc -eq 0 ]] && [[ "$(facts)" == "600 700 $ME 1" ]] && [[ "$(cat "$crs")" == "GEMINI_API_KEY=$KEY" ]] &&
   grep -q "key read: length=${#KEY} last4=${KEY: -4}" "$T/o" && grep -q '^OK GEMINI_API_KEY is in' "$T/o" &&
   ! grep -q WARN "$T/o"; then
  pass "1: default file -> crs ONE line, 600 in 700, owner $ME, old crs replaced whole, masked check"
else fail "1: default file (rc=$rc facts=$(facts)): $(tail -n3 "$T/o")"; fi
compgen -G "$H/.nano-banana/.crs.*" >/dev/null && fail "1: a temp file was left behind" || pass "1: no temp file left"

# --- 2. NANO_BANANA_KEY_FILE forms ---------------------------------------------------------------
K2="bareNbK3y${RANDOM}${RANDOM}${RANDOM}"; printf '%s\r\n' "$K2" >"$T/k2"; chmod 644 "$T/k2"
snb NANO_BANANA_KEY_FILE="$T/k2" && [[ "$(cat "$crs")" == "GEMINI_API_KEY=$K2" ]] &&
  grep -q 'WARN .*readable beyond its owner' "$T/o" && pass "2: bare-key file (CRLF) + WARN on mode 644" ||
  fail "2: bare-key file: $(tail -n2 "$T/o")"
no_leak "$K2" && pass "2: file key in no output, argv, env or ps" || fail "2: file key leaked"
K3="googNbK3y${RANDOM}${RANDOM}${RANDOM}"; printf '# x\nexport GOOGLE_API_KEY="%s"\n' "$K3" >"$T/k3"; chmod 600 "$T/k3"
snb NANO_BANANA_KEY_FILE="$T/k3" && [[ "$(cat "$crs")" == "GEMINI_API_KEY=$K3" ]] &&
  pass "2: a quoted GOOGLE_API_KEY= line is read" || fail "2: GOOGLE_API_KEY form: $(tail -n2 "$T/o")"

# --- 3. TO_BOX over ssh stdin ---------------------------------------------------------------------
snb TO_BOX=sat; rc=$?
r="$T/remote/.nano-banana/crs"
[[ $rc -eq 0 && "$(stat -c %a "$r" 2>/dev/null)" == 600 && "$(stat -c %a "$T/remote/.nano-banana")" == 700 ]] &&
  [[ "$(cat "$r")" == "GEMINI_API_KEY=$KEY" ]] && grep -q '^remote-sudo -n -u '"$ME"' -H bash -c' "$T/calls.log" &&
  pass "3: TO_BOX=sat: written as the box's agent user over ssh stdin" || fail "3: TO_BOX (rc=$rc): $(tail -n2 "$T/o")"
rm -rf "$T/remote/.nano-banana"; printf 'AGENT_USER=%s\nBOX_TAG=other\n' "$ME" >"$T/box2.env"
snb TO_BOX=sat FAKE_BOX_ENV="$T/box2.env"
[[ $? -ne 0 && ! -e "$T/remote/.nano-banana" ]] && grep -q 'answers-as-other' "$T/o" &&
  pass "3: a box answering as another tag is refused, nothing written" || fail "3: wrong tag: $(tail -n2 "$T/o")"

# --- 4. refusals ------------------------------------------------------------------------------------
before="$(sha256sum <"$crs")"
snb NANO_BANANA_KEY_FILE="$T/nope"
[[ $? -ne 0 ]] && grep -q 'no readable file' "$T/o" && pass "4: refused a missing key file" || fail "4: missing file: $(tail -n2 "$T/o")"
: >"$T/empty"; chmod 600 "$T/empty"
snb NANO_BANANA_KEY_FILE="$T/empty"
[[ $? -ne 0 ]] && grep -q 'empty key' "$T/o" && pass "4: refused an empty key" || fail "4: empty key: $(tail -n2 "$T/o")"
printf 'GEMINI_API_KEY=abc def ghi jkl mno pqr\n' >"$T/bad"; chmod 600 "$T/bad"
snb NANO_BANANA_KEY_FILE="$T/bad"
[[ $? -ne 0 ]] && grep -q 'not 16..256' "$T/o" && pass "4: refused a key with spaces" || fail "4: bad key: $(tail -n2 "$T/o")"
[[ "$(sha256sum <"$crs")" == "$before" ]] && pass "4: no refusal touched the crs" || fail "4: a refusal changed the crs"
mv "$crs" "$T/real-crs"; ln -s "$T/real-crs" "$crs"
snb
[[ $? -ne 0 ]] && grep -q 'target-is-symlink' "$T/o" && [[ "$(sha256sum <"$T/real-crs")" == "$before" ]] &&
  pass "4: refused a crs that is a symlink, its target untouched" || fail "4: symlink: $(tail -n2 "$T/o")"
rm -f "$crs"; mv "$T/real-crs" "$crs"

# --- 5. leak check over every run above -------------------------------------------------------------
snb
no_leak "$KEY" && pass "5: the canary key is in no output (the log), stub argv/env or ps sample" ||
  fail "5: the canary key leaked: $(grep -lF "$KEY" "$T/o" "$T/calls.log" "$T/ps.log" | xargs -n1 basename | paste -sd' ')"

# --- 6. CONTROLS: a planted echo is caught ----------------------------------------------------------
# plant <statement>: run the action with <statement> injected before the masked log line
plant() {
  local p="$1" s
  s='eval "$(declare -f spl_snb_main | sed "s|do_log \"INFO key read: \$mask\"|'"$p"'; &|")"; do_set_nano_banana_key'
  : >"$T/calls.log"; : >"$T/ps.log"
  snb SNIPPET="$s"
  no_leak "$KEY" && fail "6: CONTROL $2: the planted echo was NOT caught" || pass "6: CONTROL $2: the leak check catches it"
}
plant 'echo \"\$key\"' "output/log"
plant 'curl -s \"\$key\"' "argv"
plant 'K=\"\$key\" curl -s' "env"

kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null
echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
