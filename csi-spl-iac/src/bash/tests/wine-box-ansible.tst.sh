#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the wine-box playbook is standalone and portable, offline (no
#          ansible run). Numbered roles, ansible.builtin only, localhost VNC,
#          the password task is no_log, a second disk is off unless asked.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
D="$PROJ_ROOT/src/terraform/061-gcp-vm-wine-box"
PB="$D/box-playbook.yaml"

[[ -f "$PB" && -f "$D/inventory.example.ini" && -f "$D/vars.example.yml" ]] \
  && pass "playbook, example inventory and example vars exist" || fail "a standalone file is missing"
grep -q 'hosts: wine_box' "$PB" && grep -q 'gather_facts: false' "$PB" \
  && pass "one play, facts after sshd answers" || fail "play header drifted"
for r in 01_data_disk 02_os_binaries 03_timezone 04_ssh_hardening 05_users 06_secrets 07_wine 08_vnc; do
  [[ -f "$D/roles/$r/tasks/main.yml" ]] && pass "role $r" || fail "role $r is missing"
done
grep -q -- '-e @vars.example.yml' "$PB" && grep -q '203.0.113.10' "$D/inventory.example.ini" \
  && pass "the standalone command and the TEST-NET inventory are named" || fail "standalone contract is not in the tree"

if grep -RInE 'community\.general|ansible\.posix|lookup\('"'"'file'"'"'|csi-spl-cnf|get_url:|^\s+-?\s*uri:' "$D/roles" "$PB" >/dev/null; then
  fail "a role uses a non-portable module or a fleet path"
else
  pass "roles are ansible.builtin only, with no fleet path"
fi
! grep -RInE 'MT5|metatrader|broker' "$D" >/dev/null \
  && pass "the tree does not name a trading program" || fail "a trading program is named"

grep -q '/usr/sbin/sshd -t' "$D/roles/04_ssh_hardening/tasks/main.yml" \
  && ! grep -q -- '-f %s' "$D/roles/04_ssh_hardening/tasks/main.yml" \
  && pass "sshd -t checks the installed config, not the drop-in as a whole file" || fail "sshd validate is wrong"
grep -q 'gpasswd -d' "$D/roles/05_users/tasks/main.yml" \
  && pass "the desktop user is removed from sudo" || fail "no sudo removal"
grep -q 'secrets_src' "$D/roles/06_secrets/tasks/main.yml" && grep -q 'no_log: true' "$D/roles/06_secrets/tasks/main.yml" \
  && pass "secrets are copied only from secrets_src, no_log" || fail "secrets role drifted"
grep -q 'data_disk_enabled' "$D/roles/01_data_disk/tasks/main.yml" \
  && grep -q 'mkfs.ext4' "$D/roles/01_data_disk/tasks/main.yml" \
  && pass "the data disk is formatted only when enabled and blank" || fail "data disk role drifted"
grep -q 'system.reg' "$D/roles/07_wine/tasks/main.yml" && grep -q 'install_recommends: false' "$D/roles/07_wine/tasks/main.yml" \
  && pass "the Wine prefix is initialised once, recommends off" || fail "wine role drifted"

VNC="$D/roles/08_vnc/tasks/main.yml"
grep -q '/root/wine-box-vnc.pass' "$VNC" && grep -q 'no_log: true' "$VNC" \
  && pass "the VNC password file is no_log" || fail "the VNC password task can print the secret"
grep -q '\-localhost yes' "$VNC" && grep -q '127.0.0.1' "$VNC" && grep -q '0\\.0\\.0\\.0' "$VNC" \
  && pass "the unit binds localhost and the assert rejects a public listen" || fail "VNC is not localhost-only"
grep -q 'wine explorer' "$VNC" \
  && pass "the desktop starts a Wine file window" || fail "no Wine window in the session startup"

# every {{ name }} the roles use is a key of vars.example.yml, except the
# optional password (defaulted in the task) and ansible's own names
missing=""
while read -r name; do
  case "$name" in
    item|vnc_password|vnc_pass_file|data_dev|data_fs|data_mounted|tz_now|gpasswd_out|foreign_arch|vnc_listen) continue ;;
  esac
  grep -q "^${name}:" "$D/vars.example.yml" || missing="$missing $name"
done < <(grep -RhoE '\{\{[[:space:]]*[a-z_][a-z0-9_]*' "$D/roles" | sed -E 's/\{\{[[:space:]]*//' | sort -u)
[[ -z "$missing" ]] && pass "every role variable is in vars.example.yml" || fail "vars.example.yml lacks:$missing"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
