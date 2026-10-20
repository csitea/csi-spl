#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_private_overlay_sync (SPL-2677) keeps the two users of the
#          overlay's master box equal, offline: two temp homes, sudo, getent,
#          id, chown and stat are stubs. The overlay is placeholder text.
#   1. refusals: DRY_RUN=2, another box than the master, a bad SYNC_FROM_USER,
#      a missing source - nothing written
#   2. RED CONTROL: a new hidden line (spl_private_add) on the master box
#      writes only the running user's copy: the agent's is left behind
#   3. DRY_RUN is the default: sha256_equal=no named, nothing written
#   4. DRY_RUN=0: byte-equal, mode 600, owner, verify lines; rerun already-there
#   5. a differing target that is NEWER is refused by default; SYNC_FROM_USER
#      picks it as the master copy
#   6. the provision path (spl_th_token new) syncs both users at once
#   7. the overlay content never reaches any output or argv
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

MARK="placeholder-overlay-$RANDOM$RANDOM"
mkdir -p "$T/local/ownr/.gcp/.csi" "$T/local/agnt/.gcp/.csi" "$T/stub/local-bin" "$T/owners"
printf 'OWNER_USER=ownr\nAGENT_USER=agnt\nBOX_TAG=sat\n' >"$T/box.env"
ovl() { echo "$T/local/$1/.gcp/.csi/csi-spl-private.yaml"; }
put() { printf 'workspaces:\n  ws-hidden-01: %s-%s\n' "$MARK" "$2" >"$(ovl "$1")" && chmod 600 "$(ovl "$1")"; }
put ownr a; put agnt a

cat >"$T/stub/sudo" <<'EOF2'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" | head -c 200 >>"$STUB_LOG"; echo >>"$STUB_LOG"
while [[ "$1" == -* ]]; do shift; done
PATH="$FAKE_STUB_DIR/local-bin:$PATH" exec "$@"
EOF2
cat >"$T/stub/local-bin/chown" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "${1%:}" >"$FAKE_OWNERS/$(/usr/bin/stat -c %i "$2")"
EOF2
cat >"$T/stub/local-bin/stat" <<'EOF2'
#!/usr/bin/env bash
# not chowned: the user whose temp home holds it (a write by that user)
if [[ "$1 $2" == "-c %U" ]]; then
  cat "$FAKE_OWNERS/$(/usr/bin/stat -c %i "$3")" 2>/dev/null && exit 0
  r="${3#"$FAKE_LOCAL_ROOT"/}"; echo "${r%%/*}"; exit 0
fi
exec /usr/bin/stat "$@"
EOF2
cat >"$T/stub/getent" <<'EOF2'
#!/usr/bin/env bash
[[ -d "$FAKE_LOCAL_ROOT/$2" ]] || exit 2
echo "$2:x:1:1::$FAKE_LOCAL_ROOT/$2:/bin/bash"
EOF2
cat >"$T/stub/id" <<'EOF2'
#!/usr/bin/env bash
[[ "$*" == -un ]] && { echo "$FAKE_ID_USER"; exit 0; }
exec /usr/bin/id "$@"
EOF2
chmod +x "$T/stub/sudo" "$T/stub/getent" "$T/stub/id" "$T/stub/local-bin/chown" "$T/stub/local-bin/stat"

# SPL_PRIVATE_CNF empty: the per-user $HOME file, as on a box (never the real one: HOME is a temp home)
run_sync() {
  SNIPPET="${SNIP:-do_spl_private_overlay_sync}" in_orc HOME="$T/local/ownr" SPL_PRIVATE_CNF= SPOOL_DESK_BOX=sat \
    SATELLITE_ENV_FILE="$T/box.env" FAKE_STUB_DIR="$T/stub" FAKE_LOCAL_ROOT="$T/local" FAKE_OWNERS="$T/owners" \
    FAKE_ID_USER=ownr "$@" >"$T/o" 2>&1
}
same() { cmp -s "$(ovl ownr)" "$(ovl agnt)"; }
no_leak() { ! grep -qF "$MARK" "$T/o" "$T/calls.log"; }

# --- 1. refusals ---------------------------------------------------------------------------
put agnt b; cp "$(ovl agnt)" "$T/agnt.before"
for bad in "DRY_RUN=2" "SPOOL_DESK_BOX=pc" "SYNC_FROM_USER=ghost"; do
  if run_sync DRY_RUN=0 "$bad"; then fail "accepts $bad"; else pass "refuses $bad"; fi
done
grep -q "FATAL SYNC_FROM_USER must be ownr or agnt" "$T/o" && pass "a bad SYNC_FROM_USER names the users" || fail "bad user: $(cat "$T/o")"
run_sync DRY_RUN=0 SPOOL_DESK_BOX=pc; grep -q "FROM_BOX=sat ./run -a do_spl_private_overlay_pull" "$T/o" &&
  pass "another box is pointed to the pull" || fail "other box: $(cat "$T/o")"
mv "$(ovl ownr)" "$T/ownr.bak"
run_sync DRY_RUN=0 && fail "a missing source passes" ||
  { grep -q "FATAL no overlay for ownr here" "$T/o" && pass "missing source: FATAL names the user" || fail "missing: $(cat "$T/o")"; }
mv "$T/ownr.bak" "$(ovl ownr)"
cmp -s "$(ovl agnt)" "$T/agnt.before" && pass "refused runs wrote nothing" || fail "a refused run wrote"
put agnt a

# --- 2. RED CONTROL: the overlay write on the master box leaves the agent behind -------------
SNIP='spl_th_private_lib && spl_private_add newhid' run_sync; rc=$?
[[ $rc -eq 0 ]] && grep -q "^ws-hidden-02$" "$T/o" && ! same &&
  pass "CONTROL: spl_private_add writes only the running user's copy (the agent's is behind)" ||
  fail "CONTROL: rc=$rc same=$(same && echo yes || echo no) out=$(cat "$T/o")"

# --- 3. dry run by default ---------------------------------------------------------------------
: >"$T/calls.log"; cp "$(ovl agnt)" "$T/agnt.before"
run_sync; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was synced" "$T/o" && cmp -s "$(ovl agnt)" "$T/agnt.before" &&
  grep -q "^verify user=agnt .* sha256_equal=no$" "$T/o" && grep -q "^verify user=ownr .* sha256_equal=yes$" "$T/o" &&
  pass "dry run: names the drift (sha256_equal=no), writes nothing" || fail "dry run: rc=$rc out=$(cat "$T/o")"
# the agent copy is older than the owner's on the box; keep that order here
touch -d '-1 hour' "$(ovl agnt)"

# --- 4. the sync ---------------------------------------------------------------------------------
run_sync DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && same && [[ "$(stat -c %a "$(ovl agnt)")" == 600 && "$(cat "$T/owners/$(stat -c %i "$(ovl agnt)")")" == agnt ]] &&
  grep -q "INFO agnt: replaced" "$T/o" && grep -q "^verify user=agnt path=$(ovl agnt) mode=600 closed=yes owner=agnt sha256_equal=yes$" "$T/o" &&
  pass "DRY_RUN=0: byte-equal, 600, owner agnt, verify line" || fail "sync: rc=$rc out=$(cat "$T/o")"
compgen -G "$T/local/agnt/.gcp/.csi/*.pull.*" >/dev/null && fail "a temp file is left" || pass "no temp file left"
run_sync DRY_RUN=0 && grep -q "INFO agnt: already-there" "$T/o" && pass "rerun: already-there" || fail "rerun: $(cat "$T/o")"

# --- 5. a newer differing target is refused by default ------------------------------------------
put agnt c; touch -d '+1 hour' "$(ovl agnt)"; cp "$(ovl agnt)" "$T/agnt.before"
run_sync DRY_RUN=0 && fail "a newer target is overwritten" ||
  { grep -q "FATAL agnt's overlay differs from ownr's and is newer" "$T/o" && cmp -s "$(ovl agnt)" "$T/agnt.before" &&
    pass "a newer differing target is refused, untouched" || fail "newer: $(cat "$T/o")"; }
run_sync DRY_RUN=0 SYNC_FROM_USER=agnt && same && [[ "$(cat "$T/owners/$(stat -c %i "$(ovl ownr)")")" == ownr ]] &&
  pass "SYNC_FROM_USER=agnt copies the agent's copy to the owner" || fail "from agnt: $(cat "$T/o")"

# --- 6. the provision path syncs both at once ------------------------------------------------------
SNIP='spl_th_token zq-new new' run_sync MARK_DB=0 TENANT_VISIBLE=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^ws-hidden-0[0-9]$" "$T/o" && same && grep -q "INFO agnt: replaced" "$T/o" &&
  pass "a new hidden tenant on the master box reaches both users" || fail "provision: rc=$rc out=$(cat "$T/o")"

# --- 7. no leak ---------------------------------------------------------------------------------
grep -qF "$MARK" "$T/calls.log" && fail "content in an argv" || pass "no content in any argv"
grep -q '^sudo ' "$T/calls.log" && pass "CONTROL: sudo calls are recorded" || fail "CONTROL: no sudo call recorded"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
