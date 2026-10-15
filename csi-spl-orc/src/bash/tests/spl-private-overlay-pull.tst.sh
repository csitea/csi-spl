#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_private_overlay_pull (SPL-1919) pulls the SPL-1874 private
#          overlay of both box users from the satellite, offline here: ssh is
#          a stub that plays the source box (its /etc/csi-spl-satellite.env and
#          a sudo to each user's temp home), the local sudo, getent, chown and
#          stat are stubs over temp homes. The overlay is placeholder text.
#   1. refusals: a bad FROM_BOX, DRY_RUN=2 - before any ssh call
#   2. DRY_RUN is the default: reads the source shas, writes nothing
#   3. DRY_RUN=0: both users, bytes equal, mode 600, owner, verify lines
#   4. a second run: "already-there"; a changed source: "replaced"; a
#      shared ~/.gcp (symlink) is pulled once, owned by the owner
#   5. a source missing or empty for one user fails fast: nothing written
#   6. a box answering to another BOX_TAG is refused; an unknown local user too
#   7. the overlay content never reaches any output or argv
#   8. CONTROL: an ssh call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

MARK="PLACEHOLDER-OVERLAY-$RANDOM$RANDOM"
mkdir -p "$T/remote/ownr/.gcp/.csi" "$T/remote/agnt/.gcp/.csi" "$T/local/ownr" "$T/local/agnt" "$T/stub/remote-bin" "$T/stub/local-bin" "$T/owners"
put_src() { printf 'workspaces:\n  ws-hidden-01: %s-%s\n' "$MARK" "$2" >"$T/remote/$1/.gcp/.csi/csi-spl-private.yaml"; }
put_src ownr a; put_src agnt b
printf 'OWNER_USER=ownr\nAGENT_USER=agnt\nBOX_TAG=sat\n' >"$T/box.env"

# ssh <-o x> <dest> <command>: logs dest + command (never stdin), then plays
# the box: the env file, or the command with sudo -u <user> -> that temp home
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -o ]]; do shift 2; done
dest="$1" cmd="$2"
printf 'ssh %s %s\n' "$dest" "$cmd" >>"$STUB_LOG"
[[ "$cmd" == 'cat /etc/csi-spl-satellite.env' ]] && { cat "$FAKE_BOX_ENV"; exit 0; }
PATH="$FAKE_STUB_DIR/remote-bin:$PATH" eval "$cmd"
EOF
cat >"$T/stub/remote-bin/sudo" <<'EOF'
#!/usr/bin/env bash
u=root
while [[ "$1" == -* ]]; do case "$1" in -u) u="$2"; shift 2 ;; *) shift ;; esac; done
HOME="$FAKE_REMOTE_ROOT/$u" exec "$@"
EOF
# the local root: sudo runs the step with chown recorded and stat %U read back
cat >"$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" | head -c 200 >>"$STUB_LOG"; echo >>"$STUB_LOG"
while [[ "$1" == -* ]]; do shift; done
PATH="$FAKE_STUB_DIR/local-bin:$PATH" exec "$@"
EOF
cat >"$T/stub/local-bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1%:}" >"$FAKE_OWNERS/$(/usr/bin/stat -c %i "$2")"
EOF
cat >"$T/stub/local-bin/stat" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "-c %U" ]] && { cat "$FAKE_OWNERS/$(/usr/bin/stat -c %i "$3")" 2>/dev/null || echo nobody; exit 0; }
exec /usr/bin/stat "$@"
EOF
cat >"$T/stub/getent" <<'EOF'
#!/usr/bin/env bash
[[ -d "$FAKE_LOCAL_ROOT/$2" ]] || exit 2
echo "$2:x:1:1::$FAKE_LOCAL_ROOT/$2:/bin/bash"
EOF
chmod +x "$T/stub/ssh" "$T/stub/sudo" "$T/stub/getent" "$T/stub/remote-bin/sudo" "$T/stub/local-bin/chown" "$T/stub/local-bin/stat"

run_pull() {
  SNIPPET=do_spl_private_overlay_pull in_orc FAKE_BOX_ENV="$T/box.env" FAKE_STUB_DIR="$T/stub" \
    FAKE_REMOTE_ROOT="$T/remote" FAKE_LOCAL_ROOT="$T/local" FAKE_OWNERS="$T/owners" "$@" >"$T/o" 2>&1
}
no_leak() { ! grep -qF "$MARK" "$T/o" "$T/calls.log"; }
dst() { echo "$T/local/$1/.gcp/.csi/csi-spl-private.yaml"; }

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "FROM_BOX=SAT" "FROM_BOX=sat;id" "FROM_BOX=-x" "DRY_RUN=2"; do
  if run_pull DRY_RUN=0 "$bad"; then fail "accepts $bad"; else pass "refuses $bad"; fi
done
[[ ! -s "$T/calls.log" ]] && pass "refusals make no ssh call" || fail "refusals called: $(cat "$T/calls.log")"

# --- 2. DRY_RUN default --------------------------------------------------------------------
: >"$T/calls.log"
run_pull; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was pulled" "$T/o" && [[ ! -e "$T/local/ownr/.gcp" && ! -e "$T/local/agnt/.gcp" ]] &&
  ! grep -q '^sudo ' "$T/calls.log" && pass "dry run by default: nothing written, no local sudo" || fail "dry run: rc=$rc out=$(cat "$T/o")"
[[ "$(grep -c "would: pull" "$T/o")" == 2 ]] && no_leak && pass "dry run names both users, no content" || fail "dry run text: $(cat "$T/o")"

# --- 3. the pull: both users ---------------------------------------------------------------
: >"$T/calls.log"
run_pull DRY_RUN=0; rc=$?
ok=1
for u in ownr agnt; do
  f="$(dst "$u")"
  cmp -s "$f" "$T/remote/$u/.gcp/.csi/csi-spl-private.yaml" || ok=0
  [[ "$(stat -c %a "$f")" == 600 && "$(stat -c %a "$T/local/$u/.gcp/.csi")" == 700 ]] || ok=0
  [[ "$(cat "$T/owners/$(stat -c %i "$f")")" == "$u" ]] || ok=0
  grep -q "^verify user=$u path=$f mode=600 owner=$u sha256_equal=yes$" "$T/o" || ok=0
done
[[ $rc -eq 0 && $ok == 1 ]] && grep -q "INFO ownr: copied" "$T/o" && pass "pulled both: bytes, 600/700, owner, verify lines" ||
  fail "pull: rc=$rc out=$(cat "$T/o")"
compgen -G "$T/local/ownr/.gcp/.csi/*.pull.*" >/dev/null && fail "a temp file is left" || pass "no temp file left"
no_leak && pass "pull: no content in output or argv" || fail "pull leaks the content"

# --- 4. idempotent; a changed source replaces ------------------------------------------------
run_pull DRY_RUN=0 && grep -q "INFO agnt: already-there" "$T/o" && pass "second run: already-there" || fail "rerun: $(cat "$T/o")"
put_src agnt c
run_pull DRY_RUN=0 && grep -q "INFO agnt: replaced" "$T/o" && cmp -s "$(dst agnt)" "$T/remote/agnt/.gcp/.csi/csi-spl-private.yaml" &&
  pass "a changed source replaces the local copy" || fail "replace: $(cat "$T/o")"

# --- 4b. a shared ~/.gcp (the agent's is a symlink to the owner's): one file, the owner's -------
rm -rf "$T/local/agnt/.gcp"; ln -s "$T/local/ownr/.gcp" "$T/local/agnt/.gcp"
run_pull DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(cat "$T/owners/$(stat -c %i "$(dst ownr)")")" == ownr ]] && grep -q "INFO agnt: .* one file, owned by ownr" "$T/o" &&
  grep -q "WARN agnt's overlay on sat differs" "$T/o" && [[ "$(grep -c '^verify ' "$T/o")" == 1 ]] &&
  pass "shared ~/.gcp: pulled once, owned by the owner, a differing source warned" || fail "shared: rc=$rc out=$(cat "$T/o")"
rm -f "$T/local/agnt/.gcp"

# --- 5. fail fast on a missing or empty source ------------------------------------------------
rm -rf "$T/local/ownr/.gcp" "$T/local/agnt/.gcp"
mv "$T/remote/agnt/.gcp/.csi/csi-spl-private.yaml" "$T/agnt.bak"
run_pull DRY_RUN=0 && fail "a missing source passes" ||
  { grep -q "FATAL no overlay for agnt on sat" "$T/o" && [[ ! -e "$T/local/ownr/.gcp" ]] &&
    pass "missing source: FATAL names the user, nothing written" || fail "missing source: $(cat "$T/o")"; }
: >"$T/remote/agnt/.gcp/.csi/csi-spl-private.yaml"
run_pull DRY_RUN=0 && fail "an empty source passes" || pass "refuses an empty source"
mv "$T/agnt.bak" "$T/remote/agnt/.gcp/.csi/csi-spl-private.yaml"

# --- 6. wrong box, unknown local user ----------------------------------------------------------
printf 'OWNER_USER=ownr\nAGENT_USER=agnt\nBOX_TAG=other\n' >"$T/box.env"
run_pull DRY_RUN=0 && fail "another BOX_TAG passes" || { grep -q "answers as box 'other'" "$T/o" && pass "refuses another BOX_TAG" || fail "BOX_TAG: $(cat "$T/o")"; }
printf 'OWNER_USER=ownr\nAGENT_USER=ghost\nBOX_TAG=sat\n' >"$T/box.env"
run_pull DRY_RUN=0 && fail "an unknown local user passes" || { grep -q "user ghost (of box sat) does not exist here" "$T/o" && pass "refuses an unknown local user" || fail "unknown user: $(cat "$T/o")"; }
[[ ! -e "$T/local/ownr/.gcp" ]] && pass "refused runs wrote nothing" || fail "a refused run wrote"

# --- 7/8. no leak anywhere; CONTROL: the stub records ssh calls ---------------------------------
grep -qF "$MARK" "$T/calls.log" && fail "content in an argv" || pass "no content in any argv"
grep -q "^ssh satellite " "$T/calls.log" && pass "CONTROL: ssh calls are recorded" || fail "CONTROL: no ssh call recorded"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
