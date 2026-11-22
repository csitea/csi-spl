#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the customer box role set (spec 181 row B6, spec 122 4 point 4),
#          src/ansible/customer-box, offline: no VM, no ssh, no ansible.
#   1. the playbook parses, names roles 01..04 in order, every role it names
#      has tasks/main.yml and no role dir is orphaned.
#   2. do_spl_customer_box_role_check passes the shipped set: no estate key,
#      no AI login of ours, do_spl_box_workspace_setup and the 127 5.3
#      checks run.
#   3. CONTROLS on a copy of the set, each one refused by its check name: a
#      synthetic dummy key file (by name, by JSON or YAML content), a symlink,
#      a vault file, token content, key-like names, a task reading the
#      controller's gcp, gh or gcloud files, its env (plain or FQCN lookup), a
#      CLI login file, a task delegated to the controller (bare, and
#      delegate_to / connection quoted: one YAML value), an inline !vault
#      value, the workspace setup or the desk checks left only in a name:
#      line, a when: false.
#      A comment line naming a token stays green (comments are not read).
#   4. role 01's kernel and mount settings pass the desk start checks they
#      serve (ptrace, dumpable, hidepid, swap), run with the orc code on a
#      fixture; CONTROL: ptrace_scope 1 in the fixture is refused. Role 01
#      loads them itself (no handler, which would run after role 04).
#   5. the play holds no per-VM value (no vars:, no literal URL or /opt
#      path) and asserts the inventory's; role 03 hands the cnf's user and
#      base to do_spl_box_workspace_setup, whose dry run then needs no yq
#      (a failing yq stub first on PATH); role 02 installs perl and acl;
#      role 04 checks as the workspace user.
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
# refused <label> <want substring>: the copy in $T/set is refused with it.
refused() {
  local out
  if out=$(check "$T/set"); then fail "$1 passed: $out"; return; fi
  [[ "$out" == *"$2"* ]] && pass "CONTROL $1 is refused" || fail "CONTROL $1: refused, but not as '$2': $out"
}
plant_task() { copy_set; printf '%s\n' "- name: planted" "$@" >>"$T/set/roles/02_spool_harness/tasks/main.yml"; }

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
if "vars" in play or "handlers" in play: print("play vars/handlers", sorted(play)); sys.exit(1)
PY
) && pass "the playbook names roles 01..04, each with tasks/main.yml, none orphaned; no play vars or handlers" || fail "playbook / roles: $out"

# 2. the shipped set
out=$(check "$SET") && [[ "$out" == *"OK the customer box role set"* ]] \
  && pass "the shipped role set passes the check" || fail "the shipped role set is refused: $out"

# 3. controls. Every key and token is synthetic, built here from parts, never
# a real key or path.
sa_json='{"type": "service_'"account"'", "private_'"key"'": "DUMMY-NOT-A-KEY"}'
F="$T/set/roles/02_spool_harness/files"
copy_set; mkdir -p "$F"; printf '%s\n' "$sa_json" >"$F/key-dummy.json"
refused "a: a planted estate key file" "REFUSED key-file: roles/02_spool_harness/files/key-dummy.json is named like a key"
copy_set; mkdir -p "$F"; printf '%s\n' "$sa_json" >"$F/data.json"
refused "b: key content under an innocent name" "REFUSED key-file: roles/02_spool_harness/files/data.json holds key material"
copy_set; mkdir -p "$T/set/roles/02_spool_harness/defaults"; printf '%s\n' "type: service_""account" "project: x" >"$T/set/roles/02_spool_harness/defaults/main.yml"
refused "c: a service account in YAML" "REFUSED key-file: roles/02_spool_harness/defaults/main.yml holds key material"
copy_set; mkdir -p "$F"; printf 'x\n' >"$T/outside.json"; ln -s "$T/outside.json" "$F/sa.json"
refused "d: a symlink to a file outside the set" "REFUSED link: roles/02_spool_harness/files/sa.json is a symlink"
copy_set; mkdir -p "$T/set/roles/02_spool_harness/vars"; printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' '6162' >"$T/set/roles/02_spool_harness/vars/main.yml"
refused "e: an Ansible Vault file" "REFUSED vault: roles/02_spool_harness/vars/main.yml is an Ansible Vault file"
copy_set; mkdir -p "$F"; printf 'value: %s\n' "gh""p_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123" >"$F/a.yml"
refused "f: a GitHub token in content" "REFUSED key-file: roles/02_spool_harness/files/a.yml holds key material"
copy_set; mkdir -p "$F"; printf 'value: %s\n' "sk-""ant-api03-DUMMYDUMMYDUMMY" >"$F/b.yml"
refused "g: a vendor API key in content" "REFUSED key-file: roles/02_spool_harness/files/b.yml holds key material"
for n in id_ecdsa .netrc gh-token; do
  copy_set; mkdir -p "$F"; printf 'x\n' >"$F/$n"
  refused "h: a file named $n" "REFUSED key-file: roles/02_spool_harness/files/$n is named like a key"
done
plant_task "  ansible.builtin.copy:" "    content: \"{{ lookup('file', lookup('env', 'HOME') + '/.gcp/x.json') }}\"" "    dest: /tmp/x"
refused "i: a task reading the controller's gcp key dir" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
plant_task "  ansible.builtin.copy:" "    src: \"{{ lookup('ansible.builtin.env', 'HOME') }}/.config/gh/hosts.yml\"" "    dest: /tmp/x"
refused "j: an FQCN env lookup of the gh login" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
plant_task "  ansible.builtin.slurp:" "    src: \"{{ ansible_env.HOME }}/.config/x/y.json\"" "  delegate_to: localhost"
refused "k: a task delegated to the controller" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
plant_task "  ansible.builtin.command: \"true\"" '  delegate_to: "localhost"'
refused "k2 (b36-02 dq): delegate_to double-quoted" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
plant_task "  ansible.builtin.command: \"true\"" "  connection: 'local'"
refused "k3 (b36-02 sq): connection single-quoted" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
D="$T/set/roles/02_spool_harness/defaults"
copy_set; mkdir -p "$D"; printf '%s\n' 'planted_secret: !vault |' '  $ANSIBLE_VAULT;1.1;AES256' '  6231356533396433' >>"$D/main.yml"
refused "e2 (b36-02 ivault): an inline vaulted value in a vars file" "REFUSED vault: roles/02_spool_harness/defaults/main.yml holds an inline Ansible Vault value"
copy_set; mkdir -p "$D"; printf '%s\n' 'planted_secret:' '  !vault |' '  $ANSIBLE_VAULT;1.1;AES256' '  6231' >>"$D/main.yml"
refused "e3: a !vault tag on its own line" "REFUSED vault: roles/02_spool_harness/defaults/main.yml holds an inline Ansible Vault value"
for p in "/srv/.codex/x.json" "/srv/.gemini/oauth_creds.json" "files/.credentials.json"; do
  plant_task "  ansible.builtin.copy:" "    src: $p" "    dest: /tmp/x"
  refused "l: a task copying $p" "REFUSED estate-ref: roles/02_spool_harness/tasks/main.yml:"
done
copy_set; sed -i '/\.\/run -a do_spl_box_workspace_setup/d' "$T/set/roles/03_workspace/tasks/main.yml"
printf '%s\n' "- name: Enrol (./run -a do_spl_box_workspace_setup)" "  ansible.builtin.debug: msg=x" >>"$T/set/roles/03_workspace/tasks/main.yml"
refused "m: the workspace setup only in a name: line" "REFUSED ws-setup:"
copy_set; sed -i '/^[[:space:]]*spl_desk_start_checks /d' "$T/set/roles/04_desk_start_checks/tasks/main.yml"
refused "n: no spl_desk_start_checks call" "REFUSED checks:"
copy_set; sed -i 's/^  changed_when: false$/  changed_when: false\n  when: false/' "$T/set/roles/04_desk_start_checks/tasks/main.yml"
refused "o: the desk checks switched off with when: false" "REFUSED when-false: roles/04_desk_start_checks/tasks/main.yml:"
copy_set; printf '%s\n' "# a comment may name GITHUB_TOKEN: the set leaves it out" >>"$T/set/roles/02_spool_harness/tasks/main.yml"
out=$(check "$T/set") && pass "a comment naming a token stays green (comments are not read)" || fail "a comment line was refused: $out"
copy_set; printf '%s\n' "# a value may never be !vault here" >>"$T/set/roles/02_spool_harness/tasks/main.yml"
out=$(check "$T/set") && pass "a comment naming !vault stays green" || fail "a !vault comment line was refused: $out"

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
! grep -q 'notify:' "$R1" && grep -A1 'ansible.builtin.command: sysctl --system' "$R1" | grep 'when: sysctl_conf.changed' >/dev/null \
  && pass "role 01 loads the kernel settings itself, before role 04 (no handler)" || fail "role 01 leaves the sysctl load to a handler"
grep -q '\* hard core 0' "$R1" && pass "role 01 sets a hard core limit of 0" || fail "role 01 sets no core limit"

# 5. no per-VM value in the play; the enrol and the checks
grep -rnE 'https?://[A-Za-z0-9]|/opt/' "$PB" "$SET/roles" | grep -vE ':[0-9]+:[[:space:]]*#' \
  && fail "a literal URL or /opt path in the play or a role" || pass "no literal URL or /opt path in the play or a role"
grep -q "tenant_id is defined" "$PB" && grep -q "repo_url is defined" "$PB" && grep -q "repo_dir is defined" "$PB" \
  && pass "the play asserts tenant_id, repo_url and repo_dir from the inventory" || fail "the play does not assert the inventory's values"
R2="$SET/roles/02_spool_harness/tasks/main.yml" R3="$SET/roles/03_workspace/tasks/main.yml" R4="$SET/roles/04_desk_start_checks/tasks/main.yml"
grep -q 'name: \[git, perl, acl\]' "$R2" && pass "role 02 installs git, perl (./run) and acl (become_user)" || fail "role 02 misses perl or acl"
grep -q 'TENANT_ID="{{ tenant_id }}" SPL_WS_USER="{{ ws_user }}" SPL_WS_BASE="{{ ws_base }}" DRY_RUN=0 ./run -a do_spl_box_workspace_setup' "$R3" \
  && grep -q 'ws_user: "{{ ws_prefix }}{{ tenant_id }}"' "$SET/tasks/ws-facts.yml" \
  && grep -q "ws_user is match('^\[a-z_\]\[a-z0-9_-\]{0,31}\$')" "$SET/tasks/ws-facts.yml" \
  && pass "role 03 enrols with DRY_RUN=0 as the cnf's user (at most 32 chars) and base" || fail "role 03 does not enrol as the cnf's user and base"
stub yq 'exit 127'
out=$(cd "$APP_ROOT/csi-spl-orc" && PATH="$T/bin:$PATH" SPOOL_TEST=1 TENANT_ID=acme SPL_WS_USER=spl-acme SPL_WS_BASE="$T/ws" \
  ./run -a do_spl_box_workspace_setup 2>&1) && [[ "$out" == *"OK DRY_RUN nothing was touched"* ]] \
  && pass "with role 03's user and base the enrol dry run needs no yq (a failing yq stub first on PATH)" || fail "the enrol dry run needs yq: $out"
grep -q 'become_user: "{{ ws_user }}"' "$R4" && grep -q 'spl_desk_start_checks "{{ ws_user }}" "{{ ws_prefix }}"' "$R4" \
  && pass "role 04 runs the desk start checks as the workspace user" || fail "role 04 does not run the checks as the workspace user"

echo "--- customer-box-role-set: $fails failure(s)"
(( fails == 0 ))
