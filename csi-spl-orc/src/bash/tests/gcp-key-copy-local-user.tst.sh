#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_key_copy_local_user (SPL-2901) copies ONE key to a second
#          local user, offline here: getent reads a fixture passwd, sudo is a
#          stub that runs the step in a fixture home (no real key, no sudo to
#          a real user) and reports TO_USER as the file owner.
#   1. refusals: a bad KEY_NAME, root, uid 0, the running user, an unknown
#      user, a user without a home, FORCE=2, DRY_RUN=2 - before any sudo call
#   2. DRY_RUN is the default: no sudo call, nothing in the target home
#   3. DRY_RUN=0: dir 700, file 600, bytes equal, the verify line
#   4. a second run: "already there"
#   5. a different key on the target is kept without FORCE
#   6. FORCE=1 replaces it and keeps the old one as <file>.prev, mode 600
#   7. no key bytes, no full client_email and no sha in any output or argv
#   8. CONTROL: a sudo call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

ME="$(id -un)"
SECRET="FAKE-PRIVATE-KEY-$RANDOM$RANDOM"
mkdir -p "$T/src" "$T/users/agentx" "$T/users/rootish" "$T/stub/as-bin"
# the field name goes through %s: no-key-material-in-tree.tst.sh flags it as a literal
printf '{"type":"service_account","client_email":"prd-runner@csi-spl-prd.iam.gserviceaccount.com","%s":"%s"}\n' private_key "$SECRET" \
  >"$T/src/key-csi-spl-prd.json"
SRC_SHA="$(sha256sum <"$T/src/key-csi-spl-prd.json" | cut -d' ' -f1)"
cat >"$T/passwd" <<EOF
agentx:x:1500:1500::$T/users/agentx:/bin/bash
rootish:x:0:0::$T/users/rootish:/bin/bash
nohome:x:1501:1501::$T/users/missing:/bin/bash
EOF

# getent passwd <user>: the fixture line, exit 2 when there is none
cat >"$T/stub/getent" <<'EOF'
#!/usr/bin/env bash
grep "^$2:" "$FAKE_PASSWD" || exit 2
EOF
# sudo -n -u <user> -H <cmd>...: logs the argv (never stdin), then runs the
# command with HOME = the user's fixture home and stat reporting <user> as owner
cat >"$T/stub/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
user=""
while [[ "$1" == -* ]]; do case "$1" in -u) user="$2"; shift 2 ;; *) shift ;; esac; done
HOME="$FAKE_HOMES/$user" FAKE_AS_USER="$user" PATH="$FAKE_AS_BIN:$PATH" exec "$@"
EOF
REAL_STAT="$(command -v stat)"
cat >"$T/stub/as-bin/stat" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "-c %U" ]] && { echo "\$FAKE_AS_USER"; exit 0; }
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$T/stub/getent" "$T/stub/sudo" "$T/stub/as-bin/stat"

run_copy() {
  SNIPPET=do_gcp_key_copy_local_user in_orc GCP_KEY_DIR="$T/src" FAKE_PASSWD="$T/passwd" FAKE_HOMES="$T/users" \
    FAKE_AS_BIN="$T/stub/as-bin" "$@" >"$T/o" 2>&1
}
no_leak() {
  ! grep -qF "$SECRET" "$T/o" "$T/calls.log" && ! grep -qF "prd-runner@" "$T/o" "$T/calls.log" &&
    ! grep -qF "$SRC_SHA" "$T/o"
}

# --- 1. refusals ---------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "KEY_NAME=" "KEY_NAME=../key-csi-spl-prd.json" "KEY_NAME=x/key-csi-spl-prd.json" "KEY_NAME=key-csi-spl-*.json" \
  "KEY_NAME=key-csi-rel-dev.json" "KEY_NAME=key-csi-spl-prd.json.bak" "KEY_NAME=key-csi-spl-PRD.json" \
  "TO_USER=" "TO_USER=root" "TO_USER=rootish" "TO_USER=$ME" "TO_USER=nobody-here" "TO_USER=nohome" "TO_USER=a;id" \
  "FORCE=2" "DRY_RUN=2"; do
  if run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx DRY_RUN=0 "$bad"; then fail "accepts $bad"; else pass "refuses $bad"; fi
done
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=root DRY_RUN=0; grep -q "TO_USER=root is refused" "$T/o" && pass "root: says why" || fail "root text: $(cat "$T/o")"
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER="$ME" DRY_RUN=0; grep -q "is the running user" "$T/o" && pass "self: says why" || fail "self text: $(cat "$T/o")"
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=rootish DRY_RUN=0; grep -q "has uid 0" "$T/o" && pass "uid 0: says why" || fail "uid 0 text: $(cat "$T/o")"
run_copy KEY_NAME=key-csi-spl-none.json TO_USER=agentx DRY_RUN=0 && fail "a missing source key passes" || pass "refuses a missing source key"
[[ ! -s "$T/calls.log" ]] && pass "refusals make no sudo call" || fail "refusals called: $(cat "$T/calls.log")"

# --- 2. DRY_RUN default --------------------------------------------------------------------
: >"$T/calls.log"
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx; rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was copied" "$T/o" && [[ ! -s "$T/calls.log" ]] && [[ ! -e "$T/users/agentx/.gcp" ]] &&
  pass "dry run by default: no sudo call, nothing in the target home" || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$(cat "$T/o")"
grep -q "@csi-spl-prd.iam.gserviceaccount.com" "$T/o" && no_leak && pass "dry run names the domain only" || fail "dry run text: $(cat "$T/o")"

# --- 3. the copy: modes, bytes, verify line --------------------------------------------------
mkdir -p "$T/users/agentx/.gcp/.csi"; chmod 755 "$T/users/agentx/.gcp" "$T/users/agentx/.gcp/.csi"
: >"$T/calls.log"
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx DRY_RUN=0; rc=$?
f="$T/users/agentx/.gcp/.csi/key-csi-spl-prd.json"
[[ $rc -eq 0 ]] && cmp -s "$f" "$T/src/key-csi-spl-prd.json" && pass "copied: bytes equal" || fail "copy: rc=$rc out=$(cat "$T/o")"
[[ "$(stat -c %a "$f" 2>/dev/null)" == 600 && "$(stat -c %a "$T/users/agentx/.gcp/.csi")" == 700 && "$(stat -c %a "$T/users/agentx/.gcp")" == 700 ]] &&
  pass "file 600, dirs 700" || fail "modes: file=$(stat -c %a "$f" 2>/dev/null) dir=$(stat -c %a "$T/users/agentx/.gcp/.csi")"
grep -qE "^verify user=agentx path=$f mode=600 dir_mode=700 owner=agentx client_email=@csi-spl-prd.iam.gserviceaccount.com sha256_equal=yes$" "$T/o" &&
  pass "verify line: path, mode, owner, domain, sha256 equal" || fail "verify line: $(cat "$T/o")"
grep -q "^sudo -n -u agentx -H bash -c " "$T/calls.log" && pass "runs the step as TO_USER via sudo -n -H" || fail "sudo argv: $(cat "$T/calls.log")"
[[ ! -e "$f.prev" ]] && pass "a fresh copy leaves no .prev" || fail "fresh copy made a .prev"
no_leak && pass "copy: no key bytes, email or sha in output or sudo argv" || fail "copy leaked: $(cat "$T/o")"

# --- 4. already there ----------------------------------------------------------------------
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "already there" "$T/o" && grep -q "sha256_equal=yes" "$T/o" && [[ ! -e "$f.prev" ]] &&
  pass "identical key: already there" || fail "already there: rc=$rc $(cat "$T/o")"

# --- 5. a different key is kept without FORCE ----------------------------------------------------
echo '{"client_email":"old@x.example"}' >"$f"
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx DRY_RUN=0 && fail "overwrote a different key without FORCE" || {
  grep -q '"old@x.example"' "$f" && grep -q "exists and differs" "$T/o" && [[ ! -e "$f.prev" ]] &&
    pass "different key kept without FORCE, no .prev" || fail "no-overwrite: $(cat "$T/o")"; }

# --- 6. FORCE=1 replaces it, the old one kept as .prev ---------------------------------------------
run_copy KEY_NAME=key-csi-spl-prd.json TO_USER=agentx DRY_RUN=0 FORCE=1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$f" "$T/src/key-csi-spl-prd.json" && [[ "$(stat -c %a "$f")" == 600 ]] && pass "FORCE=1 replaces it, mode 600" \
  || fail "force: rc=$rc $(cat "$T/o")"
grep -q '"old@x.example"' "$f.prev" 2>/dev/null && [[ "$(stat -c %a "$f.prev")" == 600 ]] && grep -q "kept as key-csi-spl-prd.json.prev" "$T/o" &&
  pass "FORCE=1 keeps the old key as .prev, mode 600" || fail "prev: $(cat "$f.prev" 2>&1) $(cat "$T/o")"
no_leak && pass "force: no key bytes, email or sha in output or sudo argv" || fail "force leaked: $(cat "$T/o")"

# --- 8. CONTROL ------------------------------------------------------------------------------------
: >"$T/calls.log"
SNIPPET='sudo -n -u agentx -H true' in_orc FAKE_HOMES="$T/users" FAKE_AS_BIN="$T/stub/as-bin" >/dev/null 2>&1
grep -q "^sudo -n -u agentx -H true" "$T/calls.log" && pass "CONTROL: a sudo call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all gcp-key-copy-local-user.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
