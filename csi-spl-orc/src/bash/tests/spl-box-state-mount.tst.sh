#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box state bucket as two folders (owner t1 151d85fc msgs
# 6a6dcd7e, 68b543b1, ec950b4b) and the gcloud storage file actions, on
# fixtures. No cloud call is real: gcsfuse, gcloud, mountpoint and fusermount3
# are stubs that log, the account pin is stubbed.
#   1. spl_box_state_mounts: SPL_BOX_STATE_RO / _RW / _RW_PREFIX from cnf
#      ("~/" = $HOME, %env% = $ENV); refuses relative, "..", equal or nested
#      dirs, a prefix with a slash, a missing key
#   2. do_spl_box_state_mount: RO = the whole bucket, -o ro, the project SA
#      key; RW = --only-dir <prefix>, an impersonated_service_account
#      credential of the writer SA, shredded once the mount is up; already
#      mounted = no gcsfuse call; a non-empty dir and a bad MOUNT refused
#   3. do_spl_box_state_unmount: only what is mounted
#   4. ls / get / put / sync: refusals, dry runs make no gcloud call, every
#      call carries --account, uploads impersonate the writer and land under
#      the RW prefix only; put is --no-clobber, sync never deletes
#   5. the upload scan (c-846's box-state-pack.sh): a secret anywhere under
#      SRC refuses the whole upload with exit 3 and no gcloud call, naming
#      counts only; CONTROL: a clean dir passes
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

H="$T/home"
mkdir -p "$H/.gcp/.csi" "$T/tmp"
printf '{"type":"service_account","client_email":"csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"}\n' >"$H/.gcp/.csi/key-csi-spl-dev.json"
cat >"$T/cnf.yaml" <<'EOF'
env:
  box:
    box_state_mount:
      ro_dir: "~/mnt/box-state/%env%/ro"
      rw_dir: "~/mnt/box-state/%env%/rw"
      rw_prefix: shared
  steps:
    056-gcs-box-state:
      state_bucket_name: csi-spl-dev-box-state
      writer_sa_account_id: csi-spl-dev-box-state
EOF
orc_stub 0 gcloud fusermount3
# gcsfuse: logs its args and, for the RW mount, the credential's type and writer
cat >"$T/stub/gcsfuse" <<'EOF'
#!/bin/bash
echo "gcsfuse $*" >>"$STUB_LOG"
prev=""
for a in "$@"; do
  [[ "$prev" == --key-file ]] && { echo "cred $a $(jq -r '.type + " " + (.service_account_impersonation_url // "")' "$a")" >>"$STUB_LOG"; echo "$a" >"$T_CRED"; }
  prev="$a"
done
exit "${GCSFUSE_RC:-0}"
EOF
# mountpoint: a dir listed in $MOUNTED is mounted
printf '#!/bin/bash\nd="${@: -1}"\ngrep -qxF "$d" "$MOUNTED" 2>/dev/null\n' >"$T/stub/mountpoint"
chmod +x "$T/stub/"*
# a PATH with no gcsfuse (and an apt-get that does nothing)
mkdir -p "$T/nogcs"; for b in bash env yq jq sed tr head mkdir cat ls find stat grep awk sort uniq; do ln -sf "$(command -v $b)" "$T/nogcs/$b"; done
printf '#!/bin/sh\nexit 0\n' >"$T/nogcs/apt-get"; chmod +x "$T/nogcs/apt-get"
: >"$T/mounted"
STUBS='do_spl_cloud_cnf() { SPL_CNF="$CNF"; SPL_PROJECT=csi-spl-dev; }
do_gcp_pin_account() { GCP_ACCOUNT=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com; }
do_gcp_require_live_account() { return 0; }'
run_a() { : >"$T/calls.log"; SNIPPET="$STUBS; ${PRE:-} $1" in_orc CNF="$T/cnf.yaml" HOME="$H" TMPDIR="$T/tmp" \
  MOUNTED="$T/mounted" T_CRED="$T/cred.path" SPL_PROJECT=csi-spl-dev "${@:2}" >"$T/out" 2>&1; }
RO="$H/mnt/box-state/dev/ro"
RW="$H/mnt/box-state/dev/rw"
W=csi-spl-dev-box-state@csi-spl-dev.iam.gserviceaccount.com
A=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com

# 1 -------------------------------------------------------------------------
run_a 'spl_box_state_mounts && echo "RO=$SPL_BOX_STATE_RO RW=$SPL_BOX_STATE_RW P=$SPL_BOX_STATE_RW_PREFIX"'; rc=$?
[[ $rc -eq 0 ]] && grep -qx "RO=$RO RW=$RW P=shared" "$T/out" \
  && pass "1. the resolver: ~/ = HOME, %env% = ENV, prefix from cnf" || fail "1. resolver: rc=$rc $(cat "$T/out")"
bad() { # <label> <yq edit>
  cp "$T/cnf.yaml" "$T/bad.yaml"; yq -i "$2" "$T/bad.yaml"
  run_a 'spl_box_state_mounts' CNF="$T/bad.yaml"; rc=$?
  [[ $rc -ne 0 ]] && grep -q FATAL "$T/out" && pass "1. refused: $1" || fail "1. not refused: $1: rc=$rc $(cat "$T/out")"
}
bad "a relative dir" '.env.box.box_state_mount.ro_dir = "mnt/ro"'
bad "a '..' dir" '.env.box.box_state_mount.rw_dir = "/var/tmp/../etc"'
bad "RO = RW" '.env.box.box_state_mount.rw_dir = .env.box.box_state_mount.ro_dir'
bad "RW nested in RO" '.env.box.box_state_mount.rw_dir = "~/mnt/box-state/%env%/ro/rw"'
bad "a prefix with a slash" '.env.box.box_state_mount.rw_prefix = "shared/x"'
bad "a missing key" 'del(.env.box.box_state_mount.rw_prefix)'
run_a 'spl_box_state_mounts' ENV=lde; [[ $? -ne 0 ]] && pass "1. ENV=lde refused" || fail "1. ENV=lde: $(cat "$T/out")"

# 2 -------------------------------------------------------------------------
run_a do_spl_box_state_mount MOUNT=all; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. MOUNT=all refused, no gcsfuse call" || fail "2. MOUNT=all: rc=$rc $(cat "$T/out")"
run_a do_spl_box_state_mount; rc=$?
[[ $rc -eq 0 ]] && grep -qx "gcsfuse --key-file $H/.gcp/.csi/key-csi-spl-dev.json -o ro --implicit-dirs --log-severity warning --log-file $T/state/dev/gcsfuse-dev-ro.log csi-spl-dev-box-state $RO" "$T/calls.log" \
  && pass "2. RO: the whole bucket, -o ro, as the project SA key" || fail "2. RO: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qE "^gcsfuse --key-file $T/tmp/[^ ]+/impersonated.json --only-dir shared --implicit-dirs .* csi-spl-dev-box-state $RW\$" "$T/calls.log" \
  && pass "2. RW: --only-dir shared only" || fail "2. RW: $(cat "$T/calls.log")"
grep -qE "^cred [^ ]+ impersonated_service_account https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$W:generateAccessToken\$" "$T/calls.log" \
  && pass "2. RW: as the writer SA through an impersonated credential" || fail "2. RW cred: $(cat "$T/calls.log")"
[[ ! -e "$(cat "$T/cred.path")" && -z "$(ls -A "$T/tmp")" ]] && pass "2. RW: the credential is gone once the mount is up" || fail "2. cred left: $(ls -AR "$T/tmp")"
[[ "$(stat -c %a "$RO")" == 700 ]] && pass "2. the mount dirs are made 0700" || fail "2. mode $(stat -c %a "$RO")"
printf '%s\n%s\n' "$RO" "$RW" >"$T/mounted"
run_a do_spl_box_state_mount; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && [[ "$(grep -c 'is already mounted' "$T/out")" == 2 ]] \
  && pass "2. already mounted: OK, no gcsfuse call" || fail "2. idempotent: rc=$rc $(cat "$T/calls.log" "$T/out")"
: >"$T/mounted"; echo x >"$RW/stray"
run_a do_spl_box_state_mount MOUNT=rw; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'is not empty' "$T/out" && pass "2. a non-empty dir is refused" || fail "2. non-empty: rc=$rc $(cat "$T/out")"
rm -f "$RW/stray"
echo 'Error: PermissionDenied desc = x does not have storage.objects.list access' >"$T/state/dev/gcsfuse-dev-rw.log"
run_a do_spl_box_state_mount MOUNT=rw GCSFUSE_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL dev rw' "$T/out" && grep -q 'step 056 grant' "$T/out" && [[ -z "$(ls -A "$T/tmp")" ]] \
  && pass "2. RW refused by IAM: FAIL names the 056 grant, the credential still removed" || fail "2. rw fail: rc=$rc $(cat "$T/out")"
run_a do_spl_box_state_mount MOUNT=ro PATH="$T/nogcs"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'missing tool(s): gcsfuse' "$T/out" && pass "2. no gcsfuse: refused, names do_install_gcsfuse" || fail "2. no gcsfuse: rc=$rc $(cat "$T/out")"

# 3 -------------------------------------------------------------------------
echo "$RO" >"$T/mounted"
run_a do_spl_box_state_unmount; rc=$?
[[ $rc -eq 0 ]] && grep -qx "fusermount3 -u $RO" "$T/calls.log" && [[ "$(wc -l <"$T/calls.log")" == 1 ]] && grep -q "$RW is not mounted" "$T/out" \
  && pass "3. unmount: only the mounted RO dir" || fail "3. unmount: rc=$rc $(cat "$T/calls.log" "$T/out")"

# 4 -------------------------------------------------------------------------
for kv in "PREFIX=../x" "PREFIX=/abs" "RECURSIVE=2"; do
  run_a do_spl_box_state_ls "$kv"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. ls $kv refused" || fail "4. ls $kv: rc=$rc $(cat "$T/out")"
done
run_a do_spl_box_state_ls PREFIX=shared/ RECURSIVE=1; rc=$?
[[ $rc -eq 0 ]] && grep -qx "gcloud storage ls -l -r gs://csi-spl-dev-box-state/shared/ --account=$A" "$T/calls.log" \
  && pass "4. ls: one call, --account pinned" || fail "4. ls: rc=$rc $(cat "$T/calls.log")"
for kv in "SRC=" "SRC=a/../b" "DEST="; do
  run_a do_spl_box_state_get SRC=shared/x DEST="$T/dl" "$kv"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. get $kv refused" || fail "4. get $kv: rc=$rc $(cat "$T/out")"
done
run_a do_spl_box_state_get SRC=shared/notes/ DEST="$T/dl"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" && ! -e "$T/dl" ]] && grep -q 'DRY_RUN: would download gs://csi-spl-dev-box-state/shared/notes/' "$T/out" \
  && pass "4. get dry run: no gcloud call, no dir" || fail "4. get dry: rc=$rc $(cat "$T/out")"
run_a do_spl_box_state_get SRC=shared/notes/ DEST="$T/dl" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "gcloud storage cp -r gs://csi-spl-dev-box-state/shared/notes/\* $T/dl/ --account=$A" "$T/calls.log" \
  && [[ "$(stat -c %a "$T/dl")" == 700 ]] && pass "4. get: cp -r as the project SA into a 0700 dir" || fail "4. get: rc=$rc $(cat "$T/calls.log")"

mkdir -p "$T/up/sub"; echo 'a note' >"$T/up/sub/n.md"; echo 'b' >"$T/up/b.txt"
run_a do_spl_box_state_put SRC="$T/up" PREFIX=proof; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q "would upload it to gs://csi-spl-dev-box-state/shared/proof/ as $W" "$T/out" \
  && pass "4. put dry run: scanned, no gcloud call, dest under shared/" || fail "4. put dry: rc=$rc $(cat "$T/out")"
run_a do_spl_box_state_put SRC="$T/up" PREFIX=proof DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "gcloud storage cp -r --no-clobber $T/up gs://csi-spl-dev-box-state/shared/proof/ --account=$A --impersonate-service-account=$W" "$T/calls.log" \
  && pass "4. put: --no-clobber, as the writer, under shared/" || fail "4. put: rc=$rc $(cat "$T/calls.log")"
run_a do_spl_box_state_put SRC="$T/up" DRY_RUN=0; rc=$?
grep -q " gs://csi-spl-dev-box-state/shared/ --account" "$T/calls.log" && pass "4. put with no PREFIX: the RW prefix root" || fail "4. put root: $(cat "$T/calls.log")"
for kv in "PREFIX=" "PREFIX=../box1" "SRC=$T/up/b.txt"; do
  run_a do_spl_box_state_sync SRC="$T/up" PREFIX=proof DRY_RUN=0 "$kv"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "4. sync $kv refused" || fail "4. sync $kv: rc=$rc $(cat "$T/out")"
done
run_a do_spl_box_state_sync SRC="$T/up" PREFIX=proof DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "gcloud storage rsync -r $T/up gs://csi-spl-dev-box-state/shared/proof/ --account=$A --impersonate-service-account=$W" "$T/calls.log" \
  && pass "4. sync: rsync as the writer under shared/, no delete flag" || fail "4. sync: rc=$rc $(cat "$T/calls.log")"
grep -q -- '--delete' "$T/calls.log" && fail "4. sync passed a delete flag" || pass "4. ...and no --delete-unmatched-destination-objects"

# 5 -------------------------------------------------------------------------
pem_head="-----BEGIN $(printf 'PRI%s' 'VATE') KEY-----"
mkdir -p "$T/sec/.ssh" "$T/sec2"
echo 'fine' >"$T/sec/ok.txt"; echo 'id' >"$T/sec/.ssh/id_x"
printf 'x\n%s\nMIIsecretbytes\n' "$pem_head" >"$T/sec2/notes.txt"
echo 'NV-BYTES' >"$T/sec2/NetVisor-api.json"
for s in "$T/sec" "$T/sec2"; do
  for a in do_spl_box_state_put do_spl_box_state_sync; do
    run_a "$a" SRC="$s" PREFIX=proof DRY_RUN=0; rc=$?
    [[ $rc -eq 3 && ! -s "$T/calls.log" ]] && grep -q 'upload REFUSED, nothing sent' "$T/out" \
      && pass "5. $a ${s##*/}: a secret refuses the upload (exit 3, no gcloud call)" || fail "5. $a ${s##*/}: rc=$rc $(cat "$T/calls.log" "$T/out")"
  done
done
run_a do_spl_box_state_put SRC="$T/sec2" PREFIX=proof; grep -q '(cred=1 key=1)' "$T/out" && pass "5. the refusal counts per reason" || fail "5. counts: $(cat "$T/out")"
grep -qE 'MIIsecretbytes|NetVisor|notes.txt|id_x' "$T/out" && fail "5. the refusal printed a name or bytes" || pass "5. ...and prints no file name, no bytes"
run_a do_spl_box_state_put SRC="$T/sec/.ssh/id_x" DRY_RUN=0; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && pass "5. a single file under .ssh is refused (the path rule sees its real path)" || fail "5. single .ssh: rc=$rc $(cat "$T/out")"
echo 'p' >"$T/p600"; chmod 600 "$T/p600"
run_a do_spl_box_state_put SRC="$T/p600" DRY_RUN=0; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && pass "5. a single 0600 file is refused" || fail "5. 0600: rc=$rc $(cat "$T/out")"
run_a do_spl_box_state_put SRC="$T/sec/ok.txt" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "cp -r --no-clobber $T/sec/ok.txt " "$T/calls.log" && pass "5. CONTROL: a clean single file goes" || fail "5. control file: rc=$rc $(cat "$T/out")"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "5. no scan dir left behind" || fail "5. left: $(ls -A "$T/tmp")"

# 6 -------------------------------------------------------------------------
run_a do_install_gcsfuse; rc=$?
[[ $rc -eq 0 ]] && grep -q 'gcsfuse is installed' "$T/out" && pass "6. install: present = OK, nothing changed" || fail "6. install present: rc=$rc $(cat "$T/out")"
printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$T/os-release"
run_a do_install_gcsfuse PATH="$T/nogcs" GCSFUSE_OS_RELEASE="$T/os-release"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN: would write /usr/share/keyrings/gcsfuse-archive-keyring.gpg' "$T/out" && grep -q 'gcsfuse-trixie main' "$T/out" \
  && pass "6. install dry run: the plan names the signed-by repo of this codename" || fail "6. install dry: rc=$rc $(cat "$T/out")"
printf 'ID=x\n' >"$T/os-release"
run_a do_install_gcsfuse PATH="$T/nogcs" GCSFUSE_OS_RELEASE="$T/os-release"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no VERSION_CODENAME' "$T/out" && pass "6. install: no codename refused" || fail "6. no codename: rc=$rc $(cat "$T/out")"

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
