#!/usr/bin/env bash
# pre-push-tier: slow
# test-timeout: 300
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_sudoers against a REAL sudo (SPL-2187), in a
# throwaway container (no network, removed after): an agent and an owner user,
# the agent's sudoers as the box has it today (NOPASSWD: ALL).
#   1. RED CONTROL, before the action: the agent's sudo apt-get install,
#      systemctl stop and tee /etc are ALLOWED (what made the incident possible)
#   2. DRY_RUN=0: every probe of the action holds (rc 0)
#   3. after: as the agent, sudo apt-get install, apt update, dpkg -i,
#      systemctl stop, tee /etc/x, cp into /etc/sudoers.d, sudo -i, sudo -s,
#      sudo -u '#0', sudoedit /etc/hosts, journalctl --vacuum are refused by
#      sudo ("not allowed" / "password is required"), and find -exec as root
#      runs nothing (NOEXEC: no file created)
#   4. still allowed: sudo -u <owner> (any command), sudo -n true, cat, du,
#      find /proc -printf, readlink, kill, journalctl -n as root
#   5. the revert (SPL_AGENT_SUDO_MODE=all) allows apt-get again
# Needs docker and a local image with sudo (the infra stack's tpl-gen,
# conf-validator or tf-runner image); otherwise SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$RUN/spl-agent-sudoers.func.sh"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon"; exit 0; }
img=""
for i in ${SPL_SUDO_TEST_IMAGE:-} img-csi-spl-tpl-gen:latest img-csi-spl-conf-validator:latest img-csi-spl-tf-runner:latest; do
  docker image inspect "$i" >/dev/null 2>&1 || continue
  docker run --rm --network none --user 0 --entrypoint sh "$i" -c 'command -v sudo && test -x /usr/sbin/useradd' >/dev/null 2>&1 &&
    { img="$i"; break; }
done
[[ -n "$img" ]] || { echo "SKIP: no local image with sudo + useradd (make do-setup-app-inf builds tpl-gen)"; exit 0; }
echo "INFO image $img"

cp "$RUN/spl-agent-sudoers.func.sh" "$T/"
cat >"$T/in.sh" <<'IN'
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "127.0.0.1 $(hostname)" >>/etc/hosts
useradd -m box-owner && useradd -m box-agent || exit 9
# the image has no systemd: exit-0 stand-ins, so sudo's policy alone decides
for b in systemctl journalctl kill; do
  [ -x "/usr/bin/$b" ] || { printf '#!/bin/sh\nexit 0\n' >"/usr/bin/$b"; chmod 755 "/usr/bin/$b"; }
done
echo 'box-agent ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-box-agent-nopasswd
chmod 0440 /etc/sudoers.d/90-box-agent-nopasswd
# verdict <label> <command as the agent>: "refused" only when sudo itself said no
verdict() {
  local err
  err="$(su box-agent -s /bin/bash -c "$2" 2>&1 >/dev/null </dev/null)"
  if grep -qiE 'not allowed|password is required|may not run|is not in the sudoers' <<<"$err"; then
    echo "$1=refused"
  else
    echo "$1=allowed"
  fi
}
listv() {  # <label> <command>: sudo -l as the agent, exit 0 = allowed
  su box-agent -s /bin/bash -c "sudo -n -l $2" >/dev/null 2>&1 </dev/null && echo "$1=allowed" || echo "$1=refused"
}
listv before.apt '/usr/bin/apt-get install -y jq'
listv before.systemctl '/usr/bin/systemctl stop cron'
listv before.tee '/usr/bin/tee /etc/x'
do_log() { echo "$*"; }
source /w/spl-agent-sudoers.func.sh
SPL_AGENT_SUDO_USER=box-agent SPL_AGENT_SUDO_OWNER=box-owner DRY_RUN=0 do_spl_agent_sudoers >/root/act.log 2>&1
echo "action=$?"
verdict apt 'sudo -n apt-get install -y jq'
verdict aptupdate 'sudo -n apt update'
verdict dpkg 'sudo -n dpkg -i /tmp/x.deb'
verdict systemctl 'sudo -n systemctl stop cron'
verdict tee 'echo x | sudo -n tee /etc/x'
verdict cp 'sudo -n cp /etc/hostname /etc/sudoers.d/x'
verdict sudo_i 'sudo -n -i true'
verdict sudo_s 'sudo -n -s true'
verdict uid0 'sudo -n -u "#0" apt-get install -y jq'
verdict sudoedit 'EDITOR=true sudo -n -e /etc/hosts'
verdict vacuum 'sudo -n journalctl --vacuum-size=1M'
su box-agent -s /bin/bash -c 'sudo -n find /etc/hostname -exec touch /etc/noexec-proof ";"' >/dev/null 2>&1 </dev/null
[ -e /etc/noexec-proof ] && echo "noexec=ran" || echo "noexec=blocked"
verdict owner_id 'sudo -n -u box-owner id -un'
verdict owner_sh 'sudo -n -u box-owner bash -c "id -un"'
verdict true 'sudo -n true'
verdict cat 'sudo -n cat /etc/shadow'
verdict du 'sudo -n du -sk /root'
verdict find 'sudo -n find /proc -mindepth 2 -maxdepth 2 -path "/proc/1/cwd" -printf "%l\n"'
verdict readlink 'sudo -n readlink /proc/1/cwd'
verdict kill 'sudo -n kill -0 1'
verdict journal 'sudo -n journalctl -n 5 --no-pager'
SPL_AGENT_SUDO_USER=box-agent SPL_AGENT_SUDO_OWNER=box-owner SPL_AGENT_SUDO_MODE=all DRY_RUN=0 do_spl_agent_sudoers >>/root/act.log 2>&1
echo "revert=$?"
listv after_revert.apt '/usr/bin/apt-get install -y jq'
sed 's/^/act| /' /root/act.log
IN
timeout 240 docker run --rm --network none --user 0 -v "$T:/w:ro" --entrypoint bash "$img" /w/in.sh >"$T/out" 2>&1
v() { sed -n "s/^$1=//p" "$T/out" | tail -1; }

# 1. red control
for k in apt systemctl tee; do
  [[ "$(v before.$k)" == allowed ]] && pass "1. control: before the action the agent may sudo $k (the incident's opening)" ||
    fail "1. control: before.$k=$(v before.$k) - the fixture does not reproduce today's box"
done
# 2.
[[ "$(v action)" == 0 ]] && pass "2. DRY_RUN=0: every probe holds" || fail "2. action rc=$(v action): $(grep '^act|' "$T/out")"
# 3.
for k in apt aptupdate dpkg systemctl tee cp sudo_i sudo_s uid0 sudoedit vacuum; do
  [[ "$(v $k)" == refused ]] && pass "3. the agent's sudo $k is refused by sudo" || fail "3. $k=$(v $k)"
done
[[ "$(v noexec)" == blocked ]] && pass "3. find -exec as root runs nothing (NOEXEC)" || fail "3. noexec=$(v noexec)"
# 4.
for k in owner_id owner_sh true cat du find readlink kill journal; do
  [[ "$(v $k)" == allowed ]] && pass "4. still allowed: $k" || fail "4. $k=$(v $k)"
done
# 5.
[[ "$(v revert)" == 0 && "$(v after_revert.apt)" == allowed ]] && pass "5. the revert allows apt-get again" ||
  fail "5. revert=$(v revert) apt=$(v after_revert.apt)"

[[ "$fails" -eq 0 ]] || sed -n '1,80p' "$T/out"
[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
