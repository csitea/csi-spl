#!/usr/bin/env bash
#------------------------------------------------------------------------------
# satellite-box-setup.sh — runs ON the satellite as root (spec 057 5.4), sent
# over the IAP ssh by do_satellite_bootstrap. Idempotent: every role checks
# before it changes anything, and prints one verdict line:
#   ROLE <nn_name> OK|CHANGED|FAIL <detail>
# Roles (the eli-vta / csi-rel numbering):
#   01_data_disk     format (only if blank) + mount the data disk at /mnt/data;
#                    bind /opt, /var/spool-hub and docker's data-root onto it
#   02_os_user       the box user (GCE Debian default) in docker; /opt/csi and
#                    /var/spool-hub owned by it
#   03_os_packages   tmux git curl jq python3 perl docker node+npm gh gcloud ...
#   06_ssh_hardening keys only, no root login, no passwords
#   07_timezone      the box clock's zone, BOX_TIMEZONE (default Europe/Helsinki,
#                    owner topic 9a6e0f12); a recreate gets it back on the next run
# The agent harness (CLIs, yq, Go, the spool binary, hooks, skills) is the
# repo's own spool-install/install.sh, run as the box user by the bootstrap
# action AFTER the credentials push (it needs the clone).
# Env: BOX_USER (required), DATA_DEVICE (default the GCE by-id name of 060's
#      device_name satellite-data), BOX_TIMEZONE (optional, default
#      Europe/Helsinki).
#------------------------------------------------------------------------------
set -uo pipefail
BOX_USER=${BOX_USER:?BOX_USER must be set}
DATA_DEVICE=${DATA_DEVICE:-/dev/disk/by-id/google-satellite-data}
MNT=/mnt/data
export DEBIAN_FRONTEND=noninteractive
fails=0
verdict() { echo "ROLE $1 $2 ${3:-}"; [[ "$2" == FAIL ]] && fails=$((fails + 1)); return 0; }

role_01_data_disk() {
  local changed=0 d
  [[ -b "$DATA_DEVICE" ]] || { verdict 01_data_disk FAIL "no block device $DATA_DEVICE"; return; }
  if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    mkfs.ext4 -q -m 0 -L satellite-data "$DATA_DEVICE" || { verdict 01_data_disk FAIL "mkfs"; return; }
    changed=1
  fi
  mkdir -p "$MNT"
  grep -q " $MNT " /etc/fstab || { echo "LABEL=satellite-data $MNT ext4 defaults,nofail,discard 0 2" >>/etc/fstab; changed=1; }
  mountpoint -q "$MNT" || { mount "$MNT" || { verdict 01_data_disk FAIL "mount $MNT"; return; }; changed=1; }
  for d in opt spool-hub docker; do mkdir -p "$MNT/$d"; done
  local pair src dst
  for pair in "opt:/opt" "spool-hub:/var/spool-hub"; do
    src="$MNT/${pair%%:*}" dst="${pair#*:}"
    mkdir -p "$dst"
    grep -q " $dst none bind" /etc/fstab || { echo "$src $dst none bind,nofail,x-systemd.requires-mounts-for=$MNT 0 0" >>/etc/fstab; changed=1; }
    mountpoint -q "$dst" || { mount "$dst" || { verdict 01_data_disk FAIL "bind $dst"; return; }; changed=1; }
  done
  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    printf '{ "data-root": "%s/docker" }\n' "$MNT" >/etc/docker/daemon.json; changed=1
  fi
  ((changed)) && verdict 01_data_disk CHANGED "$MNT (+ /opt, /var/spool-hub, docker)" || verdict 01_data_disk OK "$MNT"
}

role_03_os_packages() {
  local want=(tmux git curl wget ca-certificates gnupg jq python3 python3-venv perl util-linux
    rsync acl make unzip zip build-essential docker.io docker-compose nodejs npm gh htop)
  local missing=() p
  for p in "${want[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  local gc=0
  command -v gcloud >/dev/null 2>&1 || gc=1
  if ((${#missing[@]} == 0 && gc == 0)); then verdict 03_os_packages OK "${#want[@]} packages + gcloud"; return; fi
  apt-get update -qq || { verdict 03_os_packages FAIL "apt-get update"; return; }
  if ((${#missing[@]})); then
    apt-get install -y -qq "${missing[@]}" >/dev/null || { verdict 03_os_packages FAIL "apt-get install ${missing[*]}"; return; }
  fi
  if ((gc)); then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" >/etc/apt/sources.list.d/google-cloud-sdk.list \
      && apt-get update -qq && apt-get install -y -qq google-cloud-cli >/dev/null \
      || { verdict 03_os_packages FAIL "google-cloud-cli"; return; }
  fi
  systemctl enable --now docker >/dev/null 2>&1
  verdict 03_os_packages CHANGED "installed: ${missing[*]}$( ((gc)) && echo ' google-cloud-cli')"
}

role_02_os_user() {
  local changed=0
  id "$BOX_USER" >/dev/null 2>&1 || { verdict 02_os_user FAIL "no user $BOX_USER"; return; }
  id -nG "$BOX_USER" | tr ' ' '\n' | grep -qx docker || { usermod -aG docker "$BOX_USER"; changed=1; }
  mkdir -p /opt/csi
  [[ "$(stat -c %U /opt/csi)" == "$BOX_USER" ]] || { chown "$BOX_USER:$BOX_USER" /opt/csi; changed=1; }
  [[ "$(stat -c %U /var/spool-hub)" == "$BOX_USER" ]] || { chown "$BOX_USER:$BOX_USER" /var/spool-hub; chmod 2775 /var/spool-hub; changed=1; }
  # agents stay alive after the ssh session ends (tmux under the box user)
  [[ -f "/var/lib/systemd/linger/$BOX_USER" ]] || { loginctl enable-linger "$BOX_USER" 2>/dev/null; changed=1; }
  ((changed)) && verdict 02_os_user CHANGED "$BOX_USER: docker, /opt/csi, /var/spool-hub, linger" || verdict 02_os_user OK "$BOX_USER"
}

role_06_ssh_hardening() {
  local f=/etc/ssh/sshd_config.d/60-satellite.conf want
  want=$'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nPubkeyAuthentication yes'
  if [[ -f "$f" && "$(cat "$f")" == "$want" ]]; then verdict 06_ssh_hardening OK "$f"; return; fi
  printf '%s\n' "$want" >"$f"
  sshd -t || { rm -f "$f"; verdict 06_ssh_hardening FAIL "sshd -t refused $f (removed)"; return; }
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
  verdict 06_ssh_hardening CHANGED "$f"
}

role_07_timezone() {
  local tz="${BOX_TIMEZONE:-Europe/Helsinki}" cur
  [[ -f "/usr/share/zoneinfo/$tz" ]] || { verdict 07_timezone FAIL "unknown zone $tz"; return; }
  cur=$(timedatectl show -p Timezone --value 2>/dev/null)
  [[ "$cur" == "$tz" ]] && { verdict 07_timezone OK "$tz"; return; }
  timedatectl set-timezone "$tz" || { verdict 07_timezone FAIL "timedatectl set-timezone $tz"; return; }
  verdict 07_timezone CHANGED "${cur:-?} -> $tz"
}

role_01_data_disk
role_03_os_packages
role_02_os_user
role_06_ssh_hardening
role_07_timezone
echo "SETUP fails=$fails"
exit $((fails > 0))
