#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_box_copy_gcp_key (t1 8451d159) copies ONE key, offline here: ssh
#          is a stub that plays the target box (its /etc/csi-spl-satellite.env
#          and a sudo to the agent user in a temp home).
#   1. refusals: a path, ../, a glob, another prefix, a bad box, FORCE=2,
#      DRY_RUN=2 - before any ssh call
#   2. DRY_RUN is the default: no ssh call
#   3. DRY_RUN=0: dir 700, file 600, bytes equal, the verify line
#   4. a second run: "already there"
#   5. a different key on the target is kept; FORCE=1 replaces it
#   6. a box answering to another BOX_TAG is refused before a byte is sent
#   7. no key bytes, no full client_email and no sha in any output or argv
#   8. CONTROL: an ssh call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

ME="$(id -un)"
SECRET="FAKE-PRIVATE-KEY-$RANDOM$RANDOM"
mkdir -p "$T/src" "$T/remote" "$T/stub"
printf '{"type":"service_account","client_email":"bkp-reader@csi-spl-bkp.iam.gserviceaccount.com","private_key":"%s"}\n' "$SECRET" \
  >"$T/src/key-csi-spl-bkp.json"
SRC_SHA="$(sha256sum <"$T/src/key-csi-spl-bkp.json" | cut -d' ' -f1)"
printf 'OWNER_USER=%s\nAGENT_USER=%s\nBOX_TAG=sat\n' "$ME" "$ME" >"$T/box.env"

# ssh <-o x> <dest> <command>: logs dest + command (never stdin), then plays
# the box: the env file, or the command with sudo stubbed to the temp home
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -o ]]; do shift 2; done
dest="$1" cmd="$2"
printf 'ssh %s %s\n' "$dest" "$cmd" >>"$STUB_LOG"
[[ "$cmd" == 'cat /etc/csi-spl-satellite.env' ]] && { cat "$FAKE_BOX_ENV"; exit 0; }
PATH="$FAKE_STUB_DIR/remote-bin:$PATH" eval "$cmd"
EOF
mkdir -p "$T/stub/remote-bin"
cat >"$T/stub/remote-bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
HOME="$FAKE_REMOTE_HOME" exec "$@"
EOF
chmod +x "$T/stub/ssh" "$T/stub/remote-bin/sudo"

run_copy() {
  SNIPPET=do_box_copy_gcp_key in_orc GCP_KEY_DIR="$T/src" FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" \
    FAKE_REMOTE_HOME="$T/remote" "$@" >"$T/o" 2>&1
}
no_leak() {
  ! grep -qF "$SECRET" "$T/o" "$T/calls.log" && ! grep -qF "bkp-reader@" "$T/o" && ! grep -qF "$SRC_SHA" "$T/o"
}

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "KEY_NAME=" "KEY_NAME=../key-csi-spl-bkp.json" "KEY_NAME=x/key-csi-spl-bkp.json" "KEY_NAME=key-csi-spl-*.json" \
  "KEY_NAME=key-csi-rel-dev.json" "KEY_NAME=key-csi-spl-bkp.json.bak" "KEY_NAME=key-csi-spl-BKP.json" \
  "TO_BOX=" "TO_BOX=SAT" "TO_BOX=box-wui" "TO_BOX=sat;id" "FORCE=2" "DRY_RUN=2"; do
  if run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0 "$bad"; then fail "accepts $bad"; else pass "refuses $bad"; fi
done
[[ ! -s "$T/calls.log" ]] && pass "refusals make no ssh call" || fail "refusals called: $(cat "$T/calls.log")"
run_copy KEY_NAME=key-csi-spl-none.json TO_BOX=sat DRY_RUN=0 && fail "a missing source key passes" || pass "refuses a missing source key"

# --- 2. DRY_RUN default --------------------------------------------------------------------
: >"$T/calls.log"
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was copied" "$T/o" && [[ ! -s "$T/calls.log" ]] && [[ ! -e "$T/remote/.gcp" ]] &&
  pass "dry run by default: no ssh call, nothing on the target" || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$(cat "$T/o")"
grep -q "@csi-spl-bkp.iam.gserviceaccount.com" "$T/o" && no_leak && pass "dry run names the domain only" || fail "dry run text: $(cat "$T/o")"

# --- 3. the copy: modes, bytes, verify line --------------------------------------------------
mkdir -p "$T/remote/.gcp/.csi"; chmod 755 "$T/remote/.gcp" "$T/remote/.gcp/.csi"
: >"$T/calls.log"
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0; rc=$?
f="$T/remote/.gcp/.csi/key-csi-spl-bkp.json"
[[ $rc -eq 0 ]] && cmp -s "$f" "$T/src/key-csi-spl-bkp.json" && pass "copied: bytes equal" || fail "copy: rc=$rc out=$(cat "$T/o")"
[[ "$(stat -c %a "$f" 2>/dev/null)" == 600 && "$(stat -c %a "$T/remote/.gcp/.csi")" == 700 && "$(stat -c %a "$T/remote/.gcp")" == 700 ]] &&
  pass "file 600, dirs 700" || fail "modes: file=$(stat -c %a "$f" 2>/dev/null) dir=$(stat -c %a "$T/remote/.gcp/.csi")"
grep -qE "^verify box=sat path=$f mode=600 dir_mode=700 owner=$ME client_email=@csi-spl-bkp.iam.gserviceaccount.com sha256_equal=yes$" "$T/o" &&
  pass "verify line: path, mode, owner, domain, sha256 equal" || fail "verify line: $(cat "$T/o")"
no_leak && pass "copy: no key bytes, email or sha in output or ssh argv" || fail "copy leaked: $(cat "$T/o")"

# --- 4. already there ----------------------------------------------------------------------
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "already there" "$T/o" && grep -q "sha256_equal=yes" "$T/o" && pass "identical key: already there" \
  || fail "already there: rc=$rc $(cat "$T/o")"

# --- 5. no overwrite; FORCE=1 replaces ---------------------------------------------------------
echo '{"client_email":"other@x.example"}' >"$f"
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0 && fail "overwrote a different key without FORCE" || {
  grep -q '"other@x.example"' "$f" && grep -q "exists and differs" "$T/o" && pass "different key kept without FORCE" \
    || fail "no-overwrite: $(cat "$T/o")"; }
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=sat DRY_RUN=0 FORCE=1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$f" "$T/src/key-csi-spl-bkp.json" && [[ "$(stat -c %a "$f")" == 600 ]] && pass "FORCE=1 replaces it, mode 600" \
  || fail "force: rc=$rc $(cat "$T/o")"

# --- 6. a box with another tag -------------------------------------------------------------------
rm -rf "$T/remote/.gcp"
: >"$T/calls.log"
run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=pc DRY_RUN=0 && fail "copied to a box answering as sat for TO_BOX=pc" || {
  [[ ! -e "$T/remote/.gcp" && "$(grep -c . "$T/calls.log")" == 1 ]] && grep -q "answers as box 'sat', not 'pc'" "$T/o" &&
    pass "wrong BOX_TAG: refused before a byte is sent" || fail "wrong tag: calls=$(cat "$T/calls.log") $(cat "$T/o")"; }
BOX_SSH_PC=pc-host run_copy KEY_NAME=key-csi-spl-bkp.json TO_BOX=pc DRY_RUN=0
grep -q "^ssh pc-host " "$T/calls.log" && pass "BOX_SSH_<BOX> names the ssh destination" || fail "BOX_SSH_PC: $(cat "$T/calls.log")"

# --- 8. CONTROL ------------------------------------------------------------------------------------
: >"$T/calls.log"
SNIPPET='ssh -o BatchMode=yes satellite true' in_orc FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_REMOTE_HOME="$T/remote" >/dev/null 2>&1
grep -q "^ssh satellite true" "$T/calls.log" && pass "CONTROL: an ssh call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all box-copy-gcp-key.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
