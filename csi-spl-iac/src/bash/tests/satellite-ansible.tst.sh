#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the satellite's Ansible setup (owner topic 6f10f92b, the eli-vta
#          pattern), offline - no GCP, no ssh, no ansible needed:
#   1. step 060 writes the inventory + run-ansible script with local_file
#      (never a sensitive file), the inventory reaches the VM through the IAP
#      proxy (no public IP), and the script name is the one do_tf_apply runs.
#   2. both generated files are git-ignored (they carry run-time paths).
#   3. box-playbook.yaml parses, names roles 01..09 in order, and every role
#      it names has tasks/main.yml (and no role dir is orphaned).
#   4. secrets: every task that reads a key or the token is no_log, the token
#      reaches git through a helper (never a URL), no .credentials.json is
#      copied, and terraform never reads GITHUB_TOKEN or a key file's content.
#   5. users come from the overlay's box.env (BOX_USER / BOX_AGENT_USER),
#      sudoers is visudo-validated, homes are on the data disk.
#   6. do_satellite_playbook refuses with no running tf-runner (stub docker),
#      and do_satellite_verify carries the users block.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_PATH=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
STEP="$PROJ_PATH/src/terraform/060-gcp-vm-satellite"
TF="$STEP/07-ansible.tf"
PB="$STEP/box-playbook.yaml"
R="$STEP/roles"

# 1. terraform writes the two files, eli-vta style
grep -q '^resource "local_file" "ansible_inventory"' "$TF" && grep -q '^resource "local_file" "ansible_script"' "$TF" \
  && pass "060 writes the inventory and the run-ansible script (local_file)" || fail "060 does not write the ansible files"
grep -q 'ProxyCommand="bash ${local.iap_proxy}' "$TF" && ! grep -q 'nat_ip\|access_config' "$TF" \
  && pass "the inventory reaches the VM through the IAP proxy" || fail "the inventory does not use the IAP proxy"
grep -q 'run-ansible-${var.org}-${var.app}-${var.env}-${local.ansible_step}.sh' "$TF" \
  && grep -q 'run-ansible-${ORG}-${APP}-${ENV}-${STEP}.sh' "$PROJ_PATH/src/bash/run/tf-apply.func.sh" \
  && pass "the script name is the one do_tf_apply runs after the apply" || fail "the script name does not match do_tf_apply's hook"
grep -q 'ansible-playbook --syntax-check' "$TF" && pass "the script syntax-checks before it runs" || fail "no syntax check in the script"
grep -nE 'GITHUB_TOKEN|private_key\b|file\(.*key-' "$TF" | grep -v '^\s*#' | grep -v 'ssh_private_key' \
  && fail "terraform reads a secret for the ansible files" || pass "terraform reads no secret for the ansible files"

# 2. generated files are git-ignored
if git -C "$PROJ_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$PROJ_PATH" check-ignore -q "src/terraform/060-gcp-vm-satellite/inventory.prd.ini" \
    && git -C "$PROJ_PATH" check-ignore -q "src/bash/scripts/run-ansible-csi-spl-prd-060-gcp-vm-satellite.sh" \
    && pass "the generated inventory + script are git-ignored" || fail "a generated ansible file is not git-ignored"
else
  pass "not a git checkout: the git-ignore check needs one (exported tree)"
fi

# 3. the playbook and its roles
out=$(python3 - "$PB" "$R" <<'PY'
import os, sys, yaml
pb, rdir = sys.argv[1], sys.argv[2]
plays = yaml.safe_load(open(pb))
roles = [r["role"] if isinstance(r, dict) else r for r in plays[0]["roles"]]
print("roles " + " ".join(roles))
print("sorted " + str(roles == sorted(roles)))
print("missing " + " ".join(r for r in roles if not os.path.isfile(os.path.join(rdir, r, "tasks", "main.yml"))))
print("orphan " + " ".join(d for d in sorted(os.listdir(rdir)) if d not in roles))
for r in roles:
    yaml.safe_load(open(os.path.join(rdir, r, "tasks", "main.yml")))
for f in ("tasks/git-sync.yml",):
    yaml.safe_load(open(os.path.join(os.path.dirname(pb), f)))
print("parsed ok")
# ansible splits a free-form shell body on quotes: an odd ' or " (an apostrophe
# in a comment) fails the syntax check (loop run 2 prep, 2026-10-01)
files = [os.path.join(rdir, r, "tasks", "main.yml") for r in roles] + [os.path.join(os.path.dirname(pb), "tasks/git-sync.yml")]
bad = []
for f in files:
    for t in yaml.safe_load(open(f)) or []:
        sh = t.get("ansible.builtin.shell")
        if isinstance(sh, str) and (sh.count("'") % 2 or sh.count('"') % 2):
            bad.append(os.path.basename(os.path.dirname(os.path.dirname(f))) + ":" + t.get("name", "?"))
print("unbalanced " + ", ".join(bad))
PY
)
grep -qx 'roles 01_data_disk 02_os_binaries 03_timezone 04_ssh_hardening 05_users 06_secrets 07_ysg_box 08_spool_harness 09_agent_tools' <<<"$out" \
  && pass "the playbook runs roles 01..09" || fail "the playbook roles are not 01..09 ($(grep '^roles' <<<"$out"))"
grep -qx 'sorted True' <<<"$out" && pass "the roles run in their numbered order" || fail "the roles are out of order"
grep -qx 'missing ' <<<"$out" && pass "every role has tasks/main.yml" || fail "a role has no tasks/main.yml ($(grep '^missing' <<<"$out"))"
grep -qx 'orphan ' <<<"$out" && pass "no orphaned role dir" || fail "a role dir is not in the playbook ($(grep '^orphan' <<<"$out"))"
grep -qx 'parsed ok' <<<"$out" && pass "the playbook, its roles and tasks/ parse as YAML" || fail "a playbook YAML does not parse"
grep -qx 'unbalanced ' <<<"$out" && pass "every shell body has balanced quotes (ansible's splitter)" || fail "a shell body has an odd quote ($(grep '^unbalanced' <<<"$out"))"

# 4. secrets
n=$(grep -c 'no_log: true' "$R/06_secrets/tasks/main.yml")
[[ "$n" -ge 3 ]] && pass "06_secrets: the key, assert and token tasks are no_log ($n)" || fail "06_secrets has $n no_log tasks, want 3"
grep -q 'no_log: true' "$STEP/tasks/git-sync.yml" && grep -q 'password=$GH_TOKEN' "$STEP/tasks/git-sync.yml" \
  && ! grep -q 'x-access-token:' "$STEP/tasks/git-sync.yml" \
  && pass "git-sync: the token goes through a helper, no_log, never in a URL" || fail "git-sync leaks the token"
grep -rn 'credentials\.json' "$R" | grep -v 'grep -q' | grep -v '^\S*:\s*#' | grep -vi 'no \.credentials\|never\|FAIL a credentials' \
  && fail "a role copies .credentials.json" || pass "no role copies an AI CLI login (.credentials.json)"
grep -q "grep -q 'credentials'" "$R/07_ysg_box/tasks/main.yml" && pass "07 refuses a render that carries a credentials file" || fail "07 does not check the render for credentials"

# 5. users
grep -q 'BOX_USER=' "$R/05_users/tasks/main.yml" && grep -q 'BOX_AGENT_USER=' "$R/05_users/tasks/main.yml" \
  && pass "05 reads the users from the overlay's box.env" || fail "05 does not read box.env"
grep -q 'validate: /usr/sbin/visudo -cf %s' "$R/05_users/tasks/main.yml" && pass "sudoers is visudo-validated" || fail "sudoers is not validated"
grep -q 'owner_home: "{{ home_root }}/' "$R/05_users/tasks/main.yml" && grep -q 'home_root: /mnt/data/home' "$PB" \
  && pass "homes live on the data disk" || fail "homes are not on the data disk"
grep -q 'validate: /usr/sbin/sshd -t -f %s' "$R/04_ssh_hardening/tasks/main.yml" && pass "the sshd drop-in is validated" || fail "the sshd drop-in is not validated"
grep -q 'force: false' "$R/01_data_disk/tasks/main.yml" && pass "01 formats only a blank disk" || fail "01 may reformat the data disk"
grep -q 'checksum: "sha256:' "$R/09_agent_tools/tasks/main.yml" && pass "cloud-sql-proxy is sha256-pinned" || fail "cloud-sql-proxy is not sha256-pinned"

# 4b. no task fights become's pty (loop run 1 hung on claude-apply's `bash -ic`)
grep -q 'timeout 600 setsid -w bash "$ENGINE/ysg-box-orc/src/bash/features/claude-config/scripts/claude-apply.sh"' "$R/07_ysg_box/tasks/main.yml" \
  && pass "07 applies the claude-config with no controlling tty, bounded" || fail "07 runs claude-apply on become's pty (it hangs)"
grep -q 'timeout 1800 setsid -w bash csi-spl-orc/src/bash/features/spool-install/install.sh' "$R/08_spool_harness/tasks/main.yml" \
  && pass "08 runs install.sh with no controlling tty, bounded" || fail "08 runs install.sh on become's pty"
grep -q '"SPOOL_DESK_BOX={{ box_tag }}"' "$R/08_spool_harness/tasks/main.yml" && grep -q '^    box_tag: sat$' "$PB" \
  && pass "08 writes SPOOL_DESK_BOX=<box_tag> (sat) with box-config.sh" || fail "08 does not set SPOOL_DESK_BOX"
grep -q '^  hostname     = var.vm_hostname$' "$STEP/03-vm.tf" && pass "060 sets the OS hostname from cnf vm_hostname" || fail "060 does not set the hostname"

# 6. the host action and verify
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/docker"; chmod +x "$T/bin/docker"
o=$(PATH="$T/bin:$PATH" bash -c '
  do_log() { echo "$*"; }; do_resolve_oap() { :; }; export ORG=csi APP=spl
  source "'"$PROJ_PATH"'/src/bash/run/satellite-playbook.func.sh"; do_satellite_playbook; echo "rc=$?"' 2>&1)
grep -q 'FATAL the tf-runner con-csi-csi-spl-tf-runner is not running' <<<"$o" && grep -qx 'rc=1' <<<"$o" \
  && pass "do_satellite_playbook refuses without a running tf-runner" || fail "do_satellite_playbook did not refuse ($o)"
grep -q 'docker exec -i "$con" bash "$script"' "$PROJ_PATH/src/bash/run/satellite-playbook.func.sh" \
  && pass "do_satellite_playbook runs the generated script inside the container" || fail "do_satellite_playbook does not run in the container"
v="$PROJ_PATH/src/bash/run/satellite-verify.func.sh"
grep -q '^_satellite_verify_users()' "$v" && grep -q '/etc/csi-spl-satellite.env' "$v" && grep -q '/etc/csi-spl-satellite.env' "$R/05_users/tasks/main.yml" \
  && pass "verify reads the users the playbook recorded" || fail "verify has no users block"
grep -q 'sudo -n -u ${agent} -H bash -s' "$v" && pass "verify runs the replica checks as the agent user" || fail "verify does not check as the agent"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
