#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the satellite's data filesystem grow (SPL-5224), offline: the
#          on-box script satellite-data-fs-grow.sh against stub findmnt,
#          lsblk, blockdev, tune2fs, xfs_info, df, resize2fs and xfs_growfs
#          (no disk is touched), and do_satellite_data_fs_grow against a stub
#          ssh that runs the piped script locally.
#   1. ext4 on a grown disk, dry run (default): PLAN resize2fs, nothing run.
#   2. ext4, FS_DRY=0: resize2fs <dev> once, GREW + BEFORE/AFTER df lines.
#   3. the filesystem already fills the disk: OK, nothing run.
#   4. a partition is refused (exit 2, nothing run). CONTROL: the same case
#      against a copy without the partition guard runs resize2fs.
#   5. xfs, FS_DRY=0: xfs_growfs <mnt>, not resize2fs.
#   6. a bad FS_DRY and an unknown fs type are refused (exit 2).
#   7. the action: dry run by default (FS_DRY='1' to the box, as root over
#      the satellite ssh opts), DRY_RUN=0 passes FS_DRY='0', a bad DRY_RUN or
#      mountpoint is refused before any ssh.
#   8. box-playbook role 01 runs the same script after the mount, FS_DRY 0.
#   9. the cnf sizes the satellite data disk at 200 GB, and the prd tfvars say so.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_PATH=$(cd "$TEST_DIR/../../.." && pwd)
export PROJ_PATH
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SCRIPT="$PROJ_PATH/src/bash/scripts/satellite-data-fs-grow.sh"
CALLS="$T/calls.log"
mkdir -p "$T/bin"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub findmnt '[[ "$*" == *SOURCE* ]] && echo "$STUB_SRC"; [[ "$*" == *FSTYPE* ]] && echo "$STUB_FSTYPE"; exit 0'
stub lsblk 'echo "$STUB_TYPE"'
stub blockdev 'echo "$STUB_DEV_BYTES"'
stub tune2fs 'printf "Block count:              %s\nBlock size:               4096\n" "$STUB_BLOCKS"'
stub xfs_info 'echo "data     =                       bsize=4096   blocks=${STUB_BLOCKS}, imaxpct=25"'
stub df 'echo "Filesystem Size Used Avail Use% Mounted on"; echo "$STUB_SRC 98G 60G 39G 62% /mnt/data"'
stub resize2fs "echo \"resize2fs \$*\" >>'$CALLS'"
stub xfs_growfs "echo \"xfs_growfs \$*\" >>'$CALLS'"
export PATH="$T/bin:$PATH"
# 100 GiB of filesystem on a 200 GiB disk
export STUB_SRC=/dev/sda STUB_FSTYPE=ext4 STUB_TYPE=disk STUB_DEV_BYTES=214748364800 STUB_BLOCKS=26214400
run() { : >"$CALLS"; out=$(env "$@" bash "${S:-$SCRIPT}" 2>&1); rc=$?; }

# 1. dry run by default
run
[[ $rc == 0 && "$out" == *"PLAN resize2fs /dev/sda (102400 MiB to add)"* && "$out" == *"BEFORE /dev/sda"* && ! -s "$CALLS" ]] \
  && pass "1. ext4 dry run plans resize2fs, runs nothing" || fail "1. dry run (rc=$rc, out=$out, calls=$(cat "$CALLS"))"

# 2. apply
run FS_DRY=0
[[ $rc == 0 && "$(cat "$CALLS")" == "resize2fs /dev/sda" && "$out" == *"GREW resize2fs /dev/sda"* && "$out" == *"AFTER /dev/sda"* ]] \
  && pass "2. FS_DRY=0 runs resize2fs on the device once, prints df after" || fail "2. apply (rc=$rc, out=$out, calls=$(cat "$CALLS"))"

# 3. nothing to grow
run FS_DRY=0 STUB_DEV_BYTES=107374182400
[[ $rc == 0 && "$out" == *"OK /mnt/data already fills /dev/sda"* && ! -s "$CALLS" ]] \
  && pass "3. a filesystem that fills its disk is left alone" || fail "3. no-op (rc=$rc, out=$out)"

# 4. a partition is refused; CONTROL: without the guard it would be grown
run FS_DRY=0 STUB_SRC=/dev/sda1 STUB_TYPE=part
case4() { [[ $rc == 2 && "$out" == *"needs growpart"* && ! -s "$CALLS" ]]; }
case4 && pass "4. a partition is refused, nothing run" || fail "4. partition (rc=$rc, out=$out, calls=$(cat "$CALLS"))"
grep -v 'needs growpart' "$SCRIPT" >"$T/unguarded.sh"
S="$T/unguarded.sh" run FS_DRY=0 STUB_SRC=/dev/sda1 STUB_TYPE=part
case4 && fail "4. CONTROL: the check passed a script without the partition guard" \
  || pass "4. CONTROL: without the guard the partition is grown (calls: $(cat "$CALLS"))"

# 5. xfs grows by mountpoint
run FS_DRY=0 STUB_FSTYPE=xfs
[[ $rc == 0 && "$(cat "$CALLS")" == "xfs_growfs /mnt/data" ]] \
  && pass "5. xfs grows with xfs_growfs on the mountpoint" || fail "5. xfs (rc=$rc, out=$out, calls=$(cat "$CALLS"))"

# 6. refusals
run FS_DRY=yes
[[ $rc == 2 && ! -s "$CALLS" ]] && pass "6. a bad FS_DRY is refused" || fail "6. bad FS_DRY (rc=$rc, out=$out)"
run FS_DRY=0 STUB_FSTYPE=btrfs
[[ $rc == 2 && ! -s "$CALLS" ]] && pass "6. an fs type other than ext4/xfs is refused" || fail "6. btrfs (rc=$rc, out=$out)"

# 7. the action, through a stub ssh that runs the remote command on the piped script
do_log() { echo "$*"; }
do_satellite_ssh_opts() { SATELLITE_SSH=(-o "ProxyCommand=stub" debian@test-satellite); }
stub ssh "echo \"ssh \$*\" >>'$CALLS'; cmd=\"\${!#}\"; cmd=\"\${cmd#sudo -n }\"; eval \"\$cmd\""
# shellcheck disable=SC1091
source "$PROJ_PATH/src/bash/run/satellite-data-fs-grow.func.sh"
: >"$CALLS"; out=$(unset DRY_RUN; do_satellite_data_fs_grow 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"PLAN resize2fs"* ]] && grep -q "^ssh -o BatchMode=yes -o ProxyCommand=stub debian@test-satellite sudo -n env FS_MNT='/mnt/data' FS_DRY='1' bash -s$" "$CALLS" \
  && ! grep -q '^resize2fs' "$CALLS" \
  && pass "7. the action is a dry run by default, as root over the satellite ssh" || fail "7. action dry (rc=$rc, out=$out, calls=$(cat "$CALLS"))"
: >"$CALLS"; out=$(DRY_RUN=0 do_satellite_data_fs_grow 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q "FS_DRY='0' bash -s$" "$CALLS" && grep -qx 'resize2fs /dev/sda' "$CALLS" \
  && pass "7. DRY_RUN=0 grows through the action" || fail "7. action apply (rc=$rc, out=$out, calls=$(cat "$CALLS"))"
: >"$CALLS"; out=$(DRY_RUN=2 do_satellite_data_fs_grow 2>&1); rc1=$?
out2=$(SATELLITE_DATA_MNT="/mnt/data;x" do_satellite_data_fs_grow 2>&1); rc2=$?
[[ $rc1 == 2 && $rc2 == 2 && ! -s "$CALLS" ]] \
  && pass "7. a bad DRY_RUN or mountpoint is refused before any ssh" || fail "7. refusals (rc=$rc1/$rc2, out=$out $out2)"

# 8. the playbook grows it on every run, after the mount
R01="$PROJ_PATH/src/terraform/060-gcp-vm-satellite/roles/01_data_disk/tasks/main.yml"
order=$(grep -nE '^- name: (Mount the data disk|Grow the data filesystem)' "$R01" | cut -d: -f3- | tr '\n' '|')
[[ "$order" == " Mount the data disk| Grow the data filesystem into the whole disk|" ]] \
  && grep -q 'bash/scripts/satellite-data-fs-grow.sh"$' "$R01" && grep -q 'FS_DRY: "0"' "$R01" \
  && [[ -f "$PROJ_PATH/src/terraform/060-gcp-vm-satellite/../../bash/scripts/satellite-data-fs-grow.sh" ]] \
  && pass "8. role 01 runs the grow script after the mount, FS_DRY 0" || fail "8. role 01 grow task (order: $order)"

# 9. the size
CNF="$PROJ_PATH/../csi-spl-cnf/csi-spl"
size=$(yq -r '.env.steps."060-gcp-vm-satellite".data_disk_size_gb' "$CNF/prd.env.yaml" 2>/dev/null)
[[ "$size" == 200 ]] && grep -qx 'data_disk_size_gb = 200' "$CNF/prd/tf/060-gcp-vm-satellite.vars.tfvars" \
  && pass "9. the satellite data disk is 200 GB in the cnf and the prd tfvars" || fail "9. data_disk_size_gb is '$size'"

echo "---"
[[ $fails == 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
