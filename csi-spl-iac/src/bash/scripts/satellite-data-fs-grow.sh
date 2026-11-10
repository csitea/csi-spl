#!/usr/bin/env bash
#------------------------------------------------------------------------------
# satellite-data-fs-grow.sh - runs ON the satellite, as root (SPL-5224).
#
# Grows the filesystem on FS_MNT (default /mnt/data) online into the whole of
# its block device, after terraform 060 grew google_compute_disk.data. The
# disk carries the filesystem directly (no partition table, 01_data_disk
# formats the whole device): a partition is refused, it would need growpart.
# ext4 grows with resize2fs <dev>, xfs with xfs_growfs <mnt>; both online.
# Dry run unless FS_DRY=0. Callers: do_satellite_data_fs_grow (over IAP) and
# box-playbook.yaml role 01 (FS_DRY=0, on every run, so a rebuild grows too).
# One line per fact: BEFORE / DEVICE / PLAN / OK / GREW / AFTER / FAIL.
# Exit 0 done or nothing to do, 1 failed, 2 refused (bad input, partition).
#------------------------------------------------------------------------------
set -uo pipefail
mnt="${FS_MNT:-/mnt/data}" dry="${FS_DRY:-1}"
# a gap smaller than this is block / group rounding, not a grown disk
slack=$((16 * 1024 * 1024))
[[ "$dry" == 0 || "$dry" == 1 ]] || { echo "FAIL FS_DRY must be 0 or 1, got '$dry'"; exit 2; }

src=$(findmnt -n -o SOURCE --mountpoint "$mnt") || { echo "FAIL nothing is mounted on $mnt"; exit 2; }
fstype=$(findmnt -n -o FSTYPE --mountpoint "$mnt")
echo "BEFORE $(df -h --output=source,size,used,avail,pcent,target "$mnt" | tail -n 1)"
dtype=$(lsblk -dn -o TYPE "$src")
[[ "$dtype" == disk ]] || { echo "FAIL $src is a '$dtype', not a whole disk: growing it needs growpart first, refusing"; exit 2; }

dev_bytes=$(blockdev --getsize64 "$src") || { echo "FAIL blockdev --getsize64 $src"; exit 1; }
case "$fstype" in
  ext4)
    fs_bytes=$(tune2fs -l "$src" | awk -F: '
      /^Block count:/ { c = $2 + 0 } /^Block size:/ { s = $2 + 0 }
      END { if (c && s) printf "%.0f\n", c * s }')
    grow=(resize2fs "$src") ;;
  xfs)
    fs_bytes=$(xfs_info "$mnt" | awk '
      /^data/ { for (i = 1; i <= NF; i++) { if ($i ~ /^bsize=/) { split($i, a, "="); s = a[2] }
                                             if ($i ~ /^blocks=/) { split($i, b, "=");  c = b[2] + 0 } } }
      END { if (c && s) printf "%.0f\n", c * s }')
    grow=(xfs_growfs "$mnt") ;;
  *) echo "FAIL $mnt is $fstype: only ext4 and xfs are grown here"; exit 2 ;;
esac
[[ "$fs_bytes" =~ ^[0-9]+$ ]] || { echo "FAIL cannot read the $fstype size of $src"; exit 1; }
echo "DEVICE $src $fstype device=${dev_bytes} filesystem=${fs_bytes}"

if (( dev_bytes - fs_bytes < slack )); then
  echo "OK $mnt already fills $src, nothing to grow"
  exit 0
fi
if [[ "$dry" == 1 ]]; then
  echo "PLAN ${grow[*]} ($(( (dev_bytes - fs_bytes) / 1024 / 1024 )) MiB to add)"
  echo "FS_DRY=1: nothing changed; DRY_RUN=0 grows it"
  exit 0
fi
"${grow[@]}" || { echo "FAIL ${grow[*]}"; exit 1; }
echo "GREW ${grow[*]}"
echo "AFTER $(df -h --output=source,size,used,avail,pcent,target "$mnt" | tail -n 1)"
