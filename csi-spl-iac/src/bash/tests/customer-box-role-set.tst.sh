#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the customer box role set (spec 181 row B6, spec 122 4 point 4),
#          src/ansible/customer-box, offline: no VM, no ssh, no ansible.
#   1. the playbook parses, names roles 01..04 in order, every role it names
#      has tasks/main.yml and no role dir is orphaned.
#   2. do_spl_customer_box_role_check passes the shipped set: no estate key,
#      no AI login of ours, do_spl_box_workspace_setup and the 127 5.3
#      checks run.
#   3. CONTROLS on a copy of the set, each one refused by name:
#      a. a synthetic dummy key file planted in a role (key-file)
#      b. the same content under an innocent name (key-file)
#      c. a task reading the controller's gcp key dir (estate-ref)
#      d. a task copying a CLI credentials file (estate-ref)
#      e. the workspace setup removed (ws-setup); the desk checks removed
#         (checks)
#      and a comment line naming a token stays green (comments are not read).
#   4. role 01's kernel and mount settings pass the desk start checks they
#      serve (ptrace, dumpable, hidepid, swap), run with the orc code on a
#      fixture; CONTROL: ptrace_scope 1 in the fixture is refused.
#   5. role 03 enrols with DRY_RUN=0 and the cnf's user, role 04 runs the
#      checks as that user.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SET="$PROJ_ROOT/src/ansible/customer-box"
PB="$SET/customer-box-playbook.yaml"
ACTION="$PROJ_ROOT/src/bash/run/spl-customer-box-role-check.func.sh"
require_action "$ACTION"
tmp_dir

check() { (cd "$PROJ_ROOT" && CUSTOMER_BOX_ROLE_DIR="$1" ./run -a do_spl_customer_box_role_check 2>&1); }
copy_set() { rm -rf "$T/set"; cp -a "$SET" "$T/set"; }

# 1. the playbook and its roles
out=$(python3 - "$PB" "$SET/roles" <<'PY'
import os, sys, yaml
pb, rd = sys.argv[1], sys.argv[2]
play = yaml.safe_load(open(pb))[0]
names = [r["role"] for r in play["roles"]]
want = ["01_box_hardening", "02_spool_harness", "03_workspace", "04_desk_start_checks"]
if names != want: print("roles", names); sys.exit(1)
for n in names:
    if not os.path.isfile(os.path.join(rd, n, "tasks", "main.yml")): print("no tasks", n); sys.exit(1)
    yaml.safe_load(open(os.path.join(rd, n, "tasks", "main.yml")))
extra = sorted(set(os.listdir(rd)) - set(names))
if extra: print("orphan", extra); sys.exit(1)
PY
) && pass "the playbook names roles 01..04, each with tasks/main.yml, none orphaned" || fail "playbook / roles: $out"

# 2. the shipped set
out=$(check "$SET") && [[ "$out" == *"OK the customer box role set"* ]] \
  && pass "the shipped role set passes the check" || fail "the shipped role set is refused: $out"

# 3. controls. The dummy key is synthetic: built here, never a real key or path.
sa_json='{"type": "service_'"account"'", "private_'"key"'": "DUMMY-NOT-A-KEY"}'
copy_set; mkdir -p "$T/set/roles/02_spool_harness/files"
printf '%s\n' "$sa_json" >"$T/set/roles/02_spool_harness/files/key-dummy.json"
out=$(check "$T/set") && fail "a planted estate key file passed: $out" \
  || { [[ "$out" == *"REFUSED key-file: roles/02_spool_harness/files/key-dummy.json"* ]] \
    && pass "CONTROL a: a planted estate key file is refused by name" || fail "CONTROL a: refused, but not by name: $out"; }

copy_set; mkdir -p "$T/set/roles/02_spool_harness/files"
printf '%s\n' "$sa_json" >"$T/set/roles/02_spool_harness/files/data.json"
out=$(check "$T/set") && fail "key content under an innocent name passed: $out" \
  || { [[ "$out" == *"REFUSED key-file: roles/02_spool_harness/files/data.json holds key material"* ]] \
    && pass "CONTROL b: key content under an innocent name is refused" || fail "CONTROL b: $out"; }

copy_set
printf '%s\n' "- name: planted" "  ansible.builtin.copy:" \
  "    content: \"{{ lookup('file', lookup('env', 'HOME') + '/.gcp/x.json') }}\"" "    dest: /tmp/x" \
  >>"$T/set/roles/02_spool_harness/tasks/main.yml"
out=$(check "$T/set") && fail "a task reading the gcp key dir passed: $out" \
  || { [[ "$out" == *"REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"* ]] \
    && pass "CONTROL c: a task reading the controller's gcp key dir is refused" || fail "CONTROL c: $out"; }

copy_set
printf '%s\n' "- name: planted" "  ansible.builtin.copy:" "    src: files/.credentials.json" "    dest: /tmp/x" \
  >>"$T/set/roles/03_workspace/tasks/main.yml"
out=$(check "$T/set") && fail "a task copying a CLI login passed: $out" \
  || { [[ "$out" == *"REFUSED estate-ref: roles/03_workspace/tasks/main.yml:"* ]] \
    && pass "CONTROL d: a task copying a CLI credentials file is refused" || fail "CONTROL d: $out"; }

copy_set; sed -i '/do_spl_box_workspace_setup/{/^[[:space:]]*#/!d}' "$T/set/roles/03_workspace/tasks/main.yml"
sed -i 's/(do_spl_box_workspace_setup)//' "$T/set/roles/03_workspace/tasks/main.yml"
out=$(check "$T/set") && fail "a set without the workspace setup passed: $out" \
  || { [[ "$out" == *"REFUSED ws-setup:"* ]] && pass "CONTROL e: no do_spl_box_workspace_setup is refused" || fail "CONTROL e: $out"; }

copy_set; sed -i '/spl_desk_start_checks/d' "$T/set/roles/04_desk_start_checks/tasks/main.yml"
out=$(check "$T/set") && fail "a set without the desk start checks passed: $out" \
  || { [[ "$out" == *"REFUSED checks:"* ]] && pass "CONTROL e: no spl_desk_start_checks is refused" || fail "CONTROL e: $out"; }

copy_set; printf '%s\n' "# a comment may name GITHUB_TOKEN: the set leaves it out" >>"$T/set/roles/02_spool_harness/tasks/main.yml"
out=$(check "$T/set") && pass "a comment naming a token stays green (comments are not read)" || fail "a comment line was refused: $out"

# 4. role 01's settings pass the desk start checks they serve
R1="$SET/roles/01_box_hardening/tasks/main.yml"
mk_fixture() {
  local f="$T/fx" ptrace="$1"
  rm -rf "$f"; mkdir -p "$f/sys/kernel/yama" "$f/sys/fs"
  sed -n 's/^ *kernel\.core_pattern = //p' "$R1" >"$f/sys/kernel/core_pattern"
  sed -n 's/^ *fs\.suid_dumpable = //p' "$R1" >"$f/sys/fs/suid_dumpable"
  printf '%s\n' "$ptrace" >"$f/sys/kernel/yama/ptrace_scope"
  awk -F'"' '/line: "proc \/proc proc/ { print $2 }' "$R1" >"$f/mounts"
  printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$f/swaps"
  : >"$f/group"; : >"$f/passwd"
}
run_dsc() {
  (
    do_log() { printf '%s\n' "$*"; }
    # shellcheck source=/dev/null
    . "$APP_ROOT/csi-spl-orc/lib/bash/funcs/spl-desk-start-checks.func.sh"
    export SPL_DSC_SYSCTL="$T/fx/sys" SPL_DSC_MOUNTS="$T/fx/mounts" SPL_DSC_SWAPS="$T/fx/swaps" \
      SPL_DSC_GROUP="$T/fx/group" SPL_DSC_PASSWD="$T/fx/passwd"
    bad=0
    for c in ptrace dumpable hidepid swap; do "spl_dsc_$c" spl-acme spl- || bad=1; done
    exit "$bad"
  ) 2>&1
}
mk_fixture "$(sed -n 's/^ *kernel\.yama\.ptrace_scope = //p' "$R1")"
out=$(run_dsc) && pass "role 01's settings pass the ptrace, dumpable, hidepid and swap checks" || fail "role 01's settings fail a desk start check: $out"
mk_fixture 1
out=$(run_dsc) && fail "CONTROL: ptrace_scope 1 passed the fixture: $out" \
  || { [[ "$out" == *"REFUSED ptrace"* ]] && pass "CONTROL: ptrace_scope 1 in the fixture is refused" || fail "CONTROL ptrace: $out"; }

# 5. role 03 enrols for real as the cnf's user, role 04 checks as that user
R3="$SET/roles/03_workspace/tasks/main.yml" R4="$SET/roles/04_desk_start_checks/tasks/main.yml"
grep -q 'TENANT_ID="{{ tenant_id }}" SPL_WS_USER="{{ ws_user }}" DRY_RUN=0 ./run -a do_spl_box_workspace_setup' "$R3" \
  && grep -q 'env.box.workspace_user_prefix }}{{ tenant_id }}' "$R3" \
  && pass "role 03 enrols with DRY_RUN=0 as the cnf's workspace user" || fail "role 03 does not enrol as the cnf's user"
grep -q 'become_user: "{{ ws_user }}"' "$R4" && grep -q 'spl_desk_start_checks "{{ ws_user }}" "{{ ws_prefix }}"' "$R4" \
  && pass "role 04 runs the desk start checks as the workspace user" || fail "role 04 does not run the checks as the workspace user"

echo "--- customer-box-role-set: $fails failure(s)"
(( fails == 0 ))
