#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the satellite's Ansible setup (owner topic 6f10f92b, the eli-vta
#          pattern), offline - no GCP, no ssh, no ansible needed:
#   1. step 060 writes the inventory + run-ansible script with local_file
#      (never a sensitive file), the inventory reaches the VM through the IAP
#      proxy (no public IP), and the script name is the one do_tf_apply runs.
#   2. both generated files are git-ignored (they carry run-time paths).
#   3. box-playbook.yaml parses, names roles 01..10 in order, and every role
#      it names has tasks/main.yml (and no role dir is orphaned).
#   4. secrets: every task that reads a key or the token is no_log, the token
#      reaches git through a helper (never a URL), no .credentials.json is
#      copied, and terraform never reads GITHUB_TOKEN or a key file's content.
#   5. users come from the overlay's box.env (BOX_USER / BOX_AGENT_USER),
#      sudoers is visudo-validated, homes are on the data disk.
#   6. do_satellite_playbook refuses with no running tf-runner (stub docker),
#      and do_satellite_verify carries the users block.
#   7. the repo is fast-forwarded to origin/master on every run (a non-ff is a
#      FAIL, never left as is), the box user gets spool + spool-agent, and
#      verify has rows for both; the repo row is run against a real git repo.
#   8. yq (pinned), psql and pandoc are system-wide (the box user runs the
#      actions), and verify checks every tool the orc actions require on the
#      box user's login PATH.
#  10. the agent's claude first-run state is seeded (only those keys), the
#      owner's tmux main is a systemd user unit, and verify starts claude
#      (--print + an interactive no-menu smoke).
#  14. the toolchain gaps 10/12/13/14: terraform system-wide, the api gates'
#      images pre-pulled (tags read from the tests, = the manifest rows),
#      pnpm + a warm store for both users, Google Chrome; verify checks them.
#  15. role 10 installs both hourly rotation crons (orch :05, dispatch :15)
#      for the box user through the named install actions, then checks them;
#      run against a stub ./run + crontab: one line each, idempotent.
#   9. /var/csi lives on the data disk, /var/csi/csi-spl is the owner's and
#      group-writable, and verify checks both users can write it.
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
grep -qx 'roles 01_data_disk 02_os_binaries 03_timezone 04_ssh_hardening 05_users 06_secrets 07_ysg_box 08_spool_harness 09_agent_tools 10_rotation_cron' <<<"$out" \
  && pass "the playbook runs roles 01..10" || fail "the playbook roles are not 01..10 ($(grep '^roles' <<<"$out"))"
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
grep -q 'SUM: "{{ cloud_sql_proxy_sha256 }}"' "$R/09_agent_tools/tasks/main.yml" && grep -q 'FAIL sha256 mismatch' "$R/09_agent_tools/tasks/main.yml" \
  && pass "cloud-sql-proxy is sha256-pinned" || fail "cloud-sql-proxy is not sha256-pinned"
# ansible-core 2.14's url modules pass cert_file, gone from Python 3.12+ (Debian 13): loop run 2
grep -rnE '^\s*(ansible\.builtin\.)?(get_url|uri):' "$R" "$STEP/tasks" && fail "a role uses get_url/uri (breaks on the VM's Python)" \
  || pass "no role uses get_url/uri (ansible 2.14 vs Python 3.13)"
grep -q 'FAIL no ~/.local/bin/$b after install.sh' "$R/08_spool_harness/tasks/main.yml" && pass "08 proves claude/spool/spool-agent exist after install.sh" || fail "08 trusts an empty install.sh ok"

# 4b. no task fights become's pty (loop run 1 hung on claude-apply's `bash -ic`)
grep -q 'timeout 600 setsid -w bash "$ENGINE/ysg-box-orc/src/bash/features/claude-config/scripts/claude-apply.sh"' "$R/07_ysg_box/tasks/main.yml" \
  && pass "07 applies the claude-config with no controlling tty, bounded" || fail "07 runs claude-apply on become's pty (it hangs)"
grep -q 'timeout 1800 setsid -w bash csi-spl-orc/src/bash/features/spool-install/install.sh' "$R/08_spool_harness/tasks/main.yml" \
  && pass "08 runs install.sh with no controlling tty, bounded" || fail "08 runs install.sh on become's pty"
grep -q '"SPOOL_DESK_BOX={{ box_tag }}"' "$R/08_spool_harness/tasks/main.yml" && grep -q '^    box_tag: sat$' "$PB" \
  && pass "08 writes SPOOL_DESK_BOX=<box_tag> (sat) with box-config.sh" || fail "08 does not set SPOOL_DESK_BOX"
grep -q '"SPOOL_FLEET_ENV={{ fleet_env }}" "SPOOL_FLEET_TENANT={{ fleet_tenant }}"' "$R/08_spool_harness/tasks/main.yml" \
  && pass "08 names the fleet desk (SPOOL_FLEET_ENV/TENANT) for cross-machine sends" || fail "08 does not name the fleet desk"
gv=$(sed -n 's/^go_version: //p' "$R/02_os_binaries/defaults/main.yml")
mv=$(sed -n 's/^go \([0-9.]*\)$/\1/p' "$PROJ_PATH/../csi-spl-api/src/go/spool-hub-api/go.mod")
[[ -n "$gv" && "$gv" == "$mv" ]] && grep -q 'FAIL go$VER sha256 mismatch' "$R/02_os_binaries/tasks/main.yml" \
  && pass "02 installs Go $gv, sha256-pinned, = go.mod (CI's go-version-file)" || fail "02 Go pin ($gv) != go.mod ($mv), or no sha check"
grep -q '/usr/local/go/bin' "$R/09_agent_tools/tasks/main.yml" && pass "09 runs the lint tools with Go on PATH (loop run 3)" || fail "09 has no Go on PATH"
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
grep -qF "sudo -n -u \${agent} -H bash -c 'cd \\\"\\\$HOME\\\" && exec bash -s'" "$v" && pass "verify runs the replica checks as the agent, from its home (run 4)" || fail "verify does not check as the agent from its home"
grep -qF "sudo -n env O='\${owner}' A='\${agent}' OWNER_TOOLS='\${owner_tools}' bash -s" "$v" && pass "verify passes the user names through sudo (env, run 4)" || fail "verify sets the user names before sudo (sudo drops them)"

# 7. the repo at trunk, and the box user's harness (CLE-77911)
gs="$STEP/tasks/git-sync.yml"; h8="$R/08_spool_harness/tasks/main.yml"
grep -q 'merge -q --ff-only "origin/$BRANCH"' "$gs" && grep -q 'FAIL $DIR did not fast-forward' "$gs" && grep -q "BRANCH: \"{{ git_branch | default('') }}\"" "$gs" \
  && pass "git-sync: with git_branch, fetch + merge --ff-only, a non-ff FAILS" || fail "git-sync does not fast-forward to origin/<branch> strictly"
grep -q 'git_branch: master' "$h8" && pass "role 08 syncs the repo on master" || fail "role 08 does not pin the repo to master"
grep -q 'install.sh --cli none --no-seat --no-hooks --no-skills' "$h8" && grep -q 'become_user: "{{ owner_user }}"' "$h8" \
  && pass "role 08 installs spool + spool-agent for the owner (box user), no AI CLI, no hooks/skills" || fail "role 08 does not install the owner's harness"
grep -q 'installed for $owner (the box user runs the desks)' "$v" && grep -q '^_satellite_verify_repo()' "$v" \
  && pass "verify has the owner-harness and repo rows" || fail "verify lacks the owner-harness or repo rows"
G="$T/git"; mkdir -p "$G"
( set -e; cd "$G"; git init -q -b master up; cd up; git -c user.email=a@b -c user.name=n commit -q --allow-empty -m c1
  for i in 2 3 4 5; do git -c user.email=a@b -c user.name=n commit -q --allow-empty -m "c$i"; done
  cd "$G"; git clone -q up here ) || fail "7. git fixture"
repo_rows() {
  env -u GIT_DIR bash -c '
    fails=0; ok() { echo "PASS $1"; }; ko() { echo "FAIL $1"; fails=$((fails + 1)); }
    source "'"$v"'"; PROJ_PATH="$1"; shift
    _satellite_verify_repo "$1"' _ "$G/here" "$@"
}
c1=$(git -C "$G/up" rev-list --max-parents=0 HEAD); tip=$(git -C "$G/up" rev-parse HEAD)
o=$(repo_rows "$(printf 'repo branch master\nrepo head %s\nrepo dirty 0\n' "$tip")")
[[ "$(grep -c '^PASS' <<<"$o")" == 3 ]] && pass "7. repo row: master, clean, at the tip -> 3 PASS" || fail "7. at tip: $o"
o=$(SATELLITE_REPO_LAG=2 repo_rows "$(printf 'repo branch master\nrepo head %s\nrepo dirty 0\n' "$c1")")
grep -q '^FAIL .* is at trunk (4 behind' <<<"$o" && pass "7. repo row: 4 behind with a lag of 2 is a FAIL" || fail "7. lagging: $o"
o=$(repo_rows "$(printf 'repo branch master\nrepo head %s\nrepo dirty 0\n' "$c1")")
grep -q '^PASS .* is at trunk (4 behind, <= 10)' <<<"$o" && pass "7. repo row: within the default lag is a PASS" || fail "7. within lag: $o"
o=$(repo_rows "$(printf 'repo branch feature\nrepo head %s\nrepo dirty 2\n' "$(printf '%040d' 7)")")
[[ "$(grep -c '^FAIL' <<<"$o")" == 3 ]] && pass "7. repo row: another branch, local changes and a HEAD off trunk are 3 FAILs" || fail "7. bad clone: $o"

# 8. the box user's required tools (2026-10-02: do_spl_desk_pin as the box
#    user -> "Missing required tool(s): yq")
r2="$R/02_os_binaries"
grep -q 'yq_sha256: [0-9a-f]\{64\}$' "$r2/defaults/main.yml" && grep -q 'sha256sum "$t/yq"' "$r2/tasks/main.yml" && grep -q 'install -m 0755 "$t/yq" /usr/local/bin/yq' "$r2/tasks/main.yml" \
  && pass "role 02 installs yq system-wide, sha256-pinned" || fail "role 02 has no pinned system-wide yq"
grep -q '^      - postgresql-client$' "$r2/tasks/main.yml" && grep -q '^      - pandoc$' "$r2/tasks/main.yml" \
  && pass "role 02 installs psql (postgresql-client) and pandoc" || fail "role 02 lacks postgresql-client or pandoc"
miss=""
for b in $(grep -rhoE 'do_require_bin [a-z0-9 _.-]+' "$PROJ_PATH/../csi-spl-orc/src/bash/run" | sed 's/do_require_bin //' | tr ' ' '\n' | grep -E '^[a-z0-9_-]+$' | sort -u); do
  case "$b" in yq|python3|psql|curl|gcloud|jq|sha256sum|git|setsid|flock|docker|gh|crontab|setfacl|getfacl|perl|pandoc|openssl|tmux) ;;
    # coreutils / base system, or not a box-user tool: pnpm + node (WUI lanes, the agent), sudo, systemctl, install, getent, tee ...
    sudo|pnpm|node|install|getent|tee|sed|mkdir|hostname|find|date|awk|tar|systemctl) ;;
    *) miss="$miss $b" ;; esac
done
[[ -z "$miss" ]] && pass "every do_require_bin tool of the orc actions is in verify's owner list or the base system" || fail "orc requires tools verify does not check for the box user:$miss"
grep -q 'owner_tools="yq jq python3 psql pandoc' "$v" && grep -q "required tools on its login PATH" "$v" \
  && pass "verify checks the actions' tools on the box user's login PATH" || fail "verify has no owner-tools row"

# 9. /var/csi: on the data disk, the owner's, group-writable; verify rows
grep -q '{ src: var-csi, dst: /var/csi }' "$R/01_data_disk/tasks/main.yml" && grep -q 'loop: \[opt, spool-hub, var-csi, docker, home\]' "$R/01_data_disk/tasks/main.yml" \
  && pass "role 01 binds /var/csi onto the data disk" || fail "role 01 does not put /var/csi on the data disk"
grep -q 'path: /var/csi/csi-spl' "$R/05_users/tasks/main.yml" && grep -A5 'path: /var/csi/csi-spl$' "$R/05_users/tasks/main.yml" | grep -q 'mode: "2775"' \
  && pass "role 05 gives /var/csi/csi-spl to the owner, 2775" || fail "role 05 has no owner-writable /var/csi/csi-spl"
grep -q 'test -w /var/csi/csi-spl && echo "varcsi writable $u"' "$v" && grep -q 'for m in /mnt/data /opt /var/spool-hub /var/csi; do grep' "$v" \
  && pass "verify checks /var/csi is mounted and writable by both users" || fail "verify lacks the /var/csi rows"
# every /var/<org>/<org>-<app> path the orc actions write sits under the dir role 05 makes
bad=$(grep -rhoE '/var/(\$\{?[A-Za-z_%*-]+\}?|csi)/[^ "]*(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)' "$PROJ_PATH/../csi-spl-orc/src/bash" "$PROJ_PATH/src/bash" | grep -vE '^/var/(csi/csi-spl|\$\{?(org|ORG|SPL_ORG_APP%%-\*|ORG_APP%%-\*)\}?/)' || true)
n_sd=$(grep -rhoE '/var/(\$\{?[A-Za-z_%*-]+\}?|csi)/[^ "]*(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)' "$PROJ_PATH/../csi-spl-orc/src/bash" "$PROJ_PATH/src/bash" | sort -u | wc -l)
[[ -z "$bad" && "$n_sd" -ge 5 ]] && pass "every state dir the actions write ($n_sd paths, desk-reconcile included) is under /var/<org>/<org>-<app>" || fail "state dirs outside /var/<org>/<org>-<app>: $bad"

# 10. claude starts with no first-run menu; tmux main is a user unit (2026-10-02)
H="$T/home"; mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho "2.1.160 (Claude Code)"\n' >"$H/.local/bin/claude"; chmod +x "$H/.local/bin/claude"
printf '{"oauthAccount": {"emailAddress": "x@example.com"}, "hasCompletedOnboarding": false, "numStartups": 3}' >"$H/.claude.json"
fr=$(python3 -c "
import yaml,sys
for t in yaml.safe_load(open('$h8')):
    if t.get('name','').startswith('Claude Code first-run state'): print(t['ansible.builtin.shell'])")
[[ -n "$fr" ]] || fail "10. no first-run task in role 08"
o1=$(HOME="$H" bash -c "$fr" 2>&1); o2=$(HOME="$H" bash -c "$fr" 2>&1)
python3 -c "
import json,sys
d=json.load(open('$H/.claude.json'))
ok = d['hasCompletedOnboarding'] is True and d['lastOnboardingVersion']=='2.1.160' and d['oauthAccount']=={'emailAddress':'x@example.com'} and d['numStartups']==3 and d['hasSeenAutoModeEntryWarning'] is True
sys.exit(0 if ok else 1)" && [[ "$o1" == CHANGED* && "$o2" == OK && "$(stat -c %a "$H/.claude.json")" == 600 ]] \
  && pass "10. the first-run seed sets onboarding + version, keeps every other key (the login too), 0600, idempotent" || fail "10. first-run seed: o1=$o1 o2=$o2 $(cat "$H/.claude.json")"
grep -qF 'has-session -t main 2>/dev/null || /usr/bin/tmux -S /tmp/tmux-%U/default new-session -d -s main' "$h8" && grep -q 'Type=oneshot' "$h8" && grep -q 'KillMode=process' "$h8" && ! grep -q '^      ExecStop=' "$h8" && ! grep -q '^      ExecStart=.*\$' "$h8" && grep -q 'systemctl --user enable -q tmux-main.service' "$h8" \
  && pass "10. role 08 keeps the owner's tmux main as an enabled systemd user unit: adopts an existing main, agents survive a unit restart" || fail "10. no tmux-main user unit"
grep -q '^_satellite_verify_claude_start()' "$v" && grep -q 'claude -p "Reply with exactly the word ok"' "$v" && grep -q 'select login method' "$v" && grep -q 'trust-workdir.sh "$d"' "$v" && grep -q 'owner tmux-unit' "$v" \
  && pass "10. verify: claude --print, the interactive no-menu smoke (pre-trusted dir), tmux main + its unit" || fail "10. verify lacks the claude-start or tmux rows"

# 11. the order bug of 203b20f2: the unit's dir is made BEFORE the unit is copied
python3 -c "
import yaml,sys
names=[t.get('name','') for t in yaml.safe_load(open('$h8'))]
d=next(i for i,n in enumerate(names) if n.startswith(\"The owner's systemd user dir\"))
c=next(i for i,n in enumerate(names) if n.startswith(\"The owner's tmux session\"))
sys.exit(0 if d < c else 1)" && pass "11. role 08 makes ~/.config/systemd/user before it copies tmux-main.service" || fail "11. the unit is copied before its dir exists"
# 12. the claude-start rows run the whole remote script although claude reads
#     stdin (the script itself arrives on stdin): a fake claude that drains
#     stdin is the control - without </dev/null both rows read empty
CB="$T/cbin"; mkdir -p "$CB/home/.local/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho ok\n' >"$CB/home/.local/bin/claude"; chmod +x "$CB/home/.local/bin/claude"
printf '#!/usr/bin/env bash\ncase " $* " in *" capture-pane "*) echo "> try a prompt" ;; esac\nexit 0\n' >"$CB/tmux"; chmod +x "$CB/tmux"
o=$(env HOME="$CB/home" PATH="$CB:$PATH" bash -c '
  fails=0; ok() { echo "PASS $1"; }; ko() { echo "FAIL $1"; }
  sleep() { :; }; export -f sleep
  source "'"$v"'"; SATELLITE_AGENT=agentx; SATELLITE_AS_AGENT=(bash -s)
  _satellite_verify_claude_start' 2>&1)
[[ "$(grep -c '^PASS' <<<"$o")" == 2 ]] && pass "12. claude --print + the no-menu smoke both run, with a claude that reads stdin" || fail "12. claude-start rows: $o"

# 13. the tmux-main task: an active unit with main visible -> OK; a has-session
#     miss with the unit active and the socket present -> WARN with tmux's
#     error, exit 0 (playbook 916d1d4f failed the run here); no socket -> FAIL
tm=$(python3 -c "
import yaml
for t in yaml.safe_load(open('$h8')):
    if t.get('name','').startswith('Enable + start tmux-main'): print(t['ansible.builtin.shell'])")
TB="$T/tmuxbin"; mkdir -p "$TB"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TB/systemctl"; chmod +x "$TB/systemctl"
printf '#!/usr/bin/env bash\n[ "$TMUX_FAKE" = up ] && exit 0; echo "no server running on $2" >&2; exit 1\n' >"$TB/tmux"; chmod +x "$TB/tmux"
run_tm() { local sock="$1"; shift; env PATH="$TB:$PATH" "$@" bash -c "$(sed "s#/usr/bin/tmux#$TB/tmux#g; s#/tmp/tmux-\$(id -u)/default#$sock#g" <<<"$tm")" 2>&1; }
SK="$T/sock"; python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$SK"
o=$(run_tm "$SK" TMUX_FAKE=up); r=$?
[[ $r -eq 0 && "$o" == OK* ]] && pass "13. tmux task: unit active, main visible -> OK" || fail "13. visible: rc=$r $o"
o=$(run_tm "$SK" TMUX_FAKE=down); r=$?
[[ $r -eq 0 && "$o" == *"WARN unit active, socket"*"no server running"* ]] && pass "13. tmux task: a has-session miss with the unit active is a WARN carrying tmux's error, not a failed run" || fail "13. miss: rc=$r $o"
o=$(run_tm "$T/no-such-sock" TMUX_FAKE=down); r=$?
[[ $r -ne 0 && "$o" == *"FAIL no tmux server socket"* ]] && pass "13. tmux task: no server socket at all is a FAIL" || fail "13. no socket: rc=$r $o"

# 14. the toolchain gaps that kept lane classes off the satellite (HOWTO-satellite-work.md 4: 10, 12, 13, 14)
tsv="$PROJ_PATH/cnf/satellite-replica.tsv"
grep -q 'for t in shellcheck actionlint hadolint trufflehog gosec typos gitleaks ruff terraform; do' "$PROJ_PATH/src/bash/run/install-lint-tools.func.sh" \
  && pass "14. LINT_TOOLS_SYSTEM=1 copies terraform to /usr/local/bin too (the box user runs the iac suite, gap 10)" || fail "14. terraform stays per-user (gap 10)"
grep -q 'google-chrome-stable_current_amd64.deb' "$R/02_os_binaries/tasks/main.yml" && grep -q '\[ -x /usr/bin/google-chrome \]' "$R/02_os_binaries/tasks/main.yml" \
  && grep -q '^google-chrome	google-chrome --version	box-playbook 02_os_binaries' "$tsv" \
  && pass "14. role 02 installs Google Chrome at /usr/bin/google-chrome, and the manifest checks it (gap 14)" || fail "14. no Chrome install + manifest row (gap 14)"
p9=$(python3 -c "
import yaml
for t in yaml.safe_load(open('$R/09_agent_tools/tasks/main.yml')):
    if t.get('name','').startswith('pnpm,'): print(t.get('loop'), t.get('become_user')); print(t['ansible.builtin.shell'])")
grep -qF '{{ [owner_user, agent_user] }} {{ item }}' <<<"$p9" && grep -q 'pnpm install --frozen-lockfile --ignore-scripts' <<<"$p9" \
  && pass "14. role 09 puts pnpm on the box user's AND the agent's PATH and warms each pnpm store (gap 13)" || fail "14. pnpm is not set up for both users with a warm store (gap 13)"
grep -q 'setsid -w ./run -a do_pull_test_images' "$R/09_agent_tools/tasks/main.yml" \
  && pass "14. role 09 pre-pulls the api gates' images through do_pull_test_images (gap 12)" || fail "14. role 09 does not pull the test images (gap 12)"
imgs=$(cd "$PROJ_PATH" && bash -c 'do_log() { echo "$*" >&2; }; PROJ_PATH="'"$PROJ_PATH"'"; source src/bash/run/pull-test-images.func.sh; DRY_RUN=1 do_pull_test_images' 2>/dev/null | sed -n 's/^PLAN pull //p')
grep -qx 'postgres:16-alpine' <<<"$imgs" && grep -qx 'fsouza/fake-gcs-server:[0-9.]*' <<<"$imgs" \
  && pass "14. do_pull_test_images reads hub-pg's and hub-gcs's image defaults from the tests ($(tr '\n' ' ' <<<"$imgs"))" || fail "14. do_pull_test_images lists: ${imgs:-nothing}"
rows=$(sed -nE "s/^img-[a-z-]+	docker image inspect -f '\{\{\.Id\}\}' ([^	]+)	.*/\1/p" "$tsv" | sort)
[[ -n "$rows" && "$rows" == "$imgs" ]] && pass "14. the manifest's img-* rows are exactly the images the tests use" || fail "14. manifest img rows ($(tr '\n' ' ' <<<"$rows")) != test images ($(tr '\n' ' ' <<<"$imgs"))"
for b in terraform pnpm google-chrome; do
  grep -qE "owner_tools=\"[^\"]* $b( |\")" "$v" || { fail "14. verify does not check $b on the box user's PATH"; continue; }
  pass "14. verify checks $b on the box user's login PATH"
done

# 15. the hourly role rotation on the satellite too (owner t1 6a02db62)
r10="$R/10_rotation_cron/tasks/main.yml"
rt=$(python3 -c "
import yaml
for t in yaml.safe_load(open('$r10')):
    if t.get('name','').startswith('Rotation cron'):
        print(t.get('loop'), t.get('become_user')); print(t['ansible.builtin.shell'])")
grep -qx "\['orch', 'dispatch'\] {{ owner_user }}" <<<"$(head -n1 <<<"$rt")" \
  && pass "15. role 10 installs the orch AND dispatch rotation crons as the box user" || fail "15. role 10 loop/user: $(head -n1 <<<"$rt")"
grep -q 'DRY_RUN=0 ./run -a do_spl_{{ item }}_rotate_install_cron' <<<"$rt" && grep -q 'ROTATE_CRON_ACTION=check ./run -a do_spl_{{ item }}_rotate_install_cron' <<<"$rt" \
  && pass "15. role 10 goes through the named install actions and their check" || fail "15. role 10 does not use the install actions"
O="$PROJ_PATH/../csi-spl-orc/src/bash/run"
[[ -f "$O/spl-orch-rotate-install-cron.func.sh" && -f "$O/spl-dispatch-rotate-install-cron.func.sh" ]] \
  && grep -q 'tag="$SPL_ORG_APP:orch-rotate"' "$O/spl-orch-rotate-install-cron.func.sh" && grep -q 'tag="$SPL_ORG_APP:dispatch-rotate"' "$O/spl-dispatch-rotate-install-cron.func.sh" \
  && pass "15. the actions role 10 calls exist and tag their lines <org>-<app>:{orch,dispatch}-rotate" || fail "15. the install actions or their tags moved"
RB="$T/rot"; mkdir -p "$RB/repo/csi-spl-orc" "$RB/bin" "$RB/spool/dispatch"; : >"$RB/spool/dispatch/lease.conf"
cat >"$RB/bin/crontab" <<'CR'
#!/usr/bin/env bash
[ "$1" = -l ] && { cat "$FAKE_CRON" 2>/dev/null; exit 0; }
cat >"$FAKE_CRON"
CR
cat >"$RB/repo/csi-spl-orc/run" <<'RUN'
#!/usr/bin/env bash
w=${2#do_spl_}; w=${w%_rotate_install_cron}; m=5; [ "$w" = dispatch ] && m=15
if [ "${ROTATE_CRON_ACTION:-}" = check ]; then grep -q " # csi-spl:$w-rotate$" "$FAKE_CRON"; exit; fi
[ "${DRY_RUN:-1}" = 0 ] || exit 0
{ grep -v " # csi-spl:$w-rotate$" "$FAKE_CRON" 2>/dev/null; echo "$m * * * * x/$w-rotate-cron.sh # csi-spl:$w-rotate"; } >"$FAKE_CRON.n"; mv "$FAKE_CRON.n" "$FAKE_CRON"
RUN
chmod +x "$RB/bin/crontab" "$RB/repo/csi-spl-orc/run"
echo '*/5 * * * * desk # csi-spl:desk-reconcile-prd' >"$RB/cron"
run_rot() { local it="$1" body; body=$(tail -n +2 <<<"$rt" | sed "s#{{ spool_root }}#$RB/spool#g; s#{{ repo_dir }}#$RB/repo#g; s#{{ item }}#$it#g")
  env FAKE_CRON="$RB/cron" PATH="$RB/bin:$PATH" bash -c "$body" 2>&1; }
o1=$(run_rot orch); o2=$(run_rot dispatch); o3=$(run_rot orch)
[[ "$o1" == *"CHANGED 5 * * * *"*"csi-spl:orch-rotate" && "$o2" == *"CHANGED 15 * * * *"*"csi-spl:dispatch-rotate" && "$o3" == *"OK 5 * * * *"* ]] \
  && [[ "$(grep -c 'csi-spl:orch-rotate$' "$RB/cron")" == 1 && "$(grep -c 'csi-spl:dispatch-rotate$' "$RB/cron")" == 1 && "$(grep -c 'desk-reconcile-prd$' "$RB/cron")" == 1 ]] \
  && pass "15. role 10 against a stub: :05 orch + :15 dispatch, one line each, the desk line kept, a re-run is OK (no change)" || fail "15. role 10 run: o1=$o1 o2=$o2 o3=$o3 cron=$(cat "$RB/cron")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
