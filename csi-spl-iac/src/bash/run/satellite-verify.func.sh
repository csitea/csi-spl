#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057: verify the satellite end to end, read-only, as the
# @description csi-spl-all SA ONLY (its key; ACCOUNT / GCP_ACCOUNT are ignored,
# @description so the owner account can never be the identity here). One
# @description `PASS|FAIL <check>` line each; returns non-zero on any FAIL:
# @description   VM RUNNING, no public IP, the ONE ingress rule = tcp/22 from
# @description   the IAP range, ssh over IAP, the data disk on /mnt/data + /opt +
# @description   /var/spool-hub + /var/csi, claude / spool / spool-agent present,
# @description   SPOOL_BOX_TAG=sat, the pushed keys 0600, the budget exists;
# @description   then the replica of the box PC (owner topic 5fe56859): every
# @description   tool of cnf/satellite-replica.tsv, its version on THIS box and
# @description   on the satellite (missing there = FAIL); the users of the
# @description   playbook (box-playbook.yaml 05, owner topic 6f10f92b): owner +
# @description   agent from /etc/csi-spl-satellite.env, uid, home on the data
# @description   disk, NOPASSWD sudo, docker, linger, spool + spool-agent for the
# @description   owner (the box user runs the desks), /opt/csi/csi-spl on a clean
# @description   master at trunk; and, AS THE AGENT, the AI-user setup
# @description   (home dirs on the data disk, ~/.claude config + skills +
# @description   memory, tmux, git identity, gh auth, docker, tpl-gen, and
# @description   whether claude is logged in there: the loggedIn flag only).
# @param GCP_BILLING_ACCOUNT_ID (optional) - lists the budget on the billing
# @param        account; without it (or without that right) the budget check
# @param        reads step 059's terraform state instead, and says so
# @param SATELLITE_REPO_LAG (optional) - commits the clone may trail trunk (default 10)
# @example ./run -a do_satellite_verify
#------------------------------------------------------------------------------
do_satellite_verify() {
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  local proj zone vm iap tag="${SATELLITE_BOX_TAG:-sat}" fails=0 out key sa
  proj=$(do_satellite_cnf gcp_project) || return 1
  zone=$(do_satellite_cnf gcp_zone) || return 1
  vm=$(do_satellite_cnf vm_name) || return 1
  iap=$(yq -r '.env.steps."060-gcp-vm-satellite".ssh_source_ranges | join(",")' "$(_satellite_cnf_file)") || return 1

  # the csi-spl-all SA and nothing else
  unset ACCOUNT GCP_ACCOUNT
  export PROJ_ID="$proj"
  do_gcp_pin_account || return 1
  key="$HOME/.gcp/.csi/key-${proj}.json"
  sa=$(jq -r .client_email "$key" 2>/dev/null)
  [[ -n "$sa" && "$GCP_ACCOUNT" == "$sa" ]] || { do_log "FATAL the identity is ${GCP_ACCOUNT:-none}, not the ${proj} SA ${sa:-<no key>}: refusing"; return 1; }
  local acct="--account=${GCP_ACCOUNT}"
  ok() { echo "PASS $1"; }
  ko() { echo "FAIL $1"; fails=$((fails + 1)); }

  out=$(gcloud compute instances describe "$vm" --zone="$zone" --project="$proj" "$acct" --format=json 2>&1) \
    || { ko "VM $vm exists (${out:0:200})"; out='{}'; }
  [[ "$(jq -r '.status // ""' <<<"$out")" == RUNNING ]] && ok "VM $vm is RUNNING" || ko "VM $vm is RUNNING (status $(jq -r '.status // "?"' <<<"$out"))"
  [[ "$(jq '[.networkInterfaces[]?.accessConfigs[]?] | length' <<<"$out")" == 0 ]] && ok "VM has no public IP" || ko "VM has no public IP"

  out=$(gcloud compute firewall-rules list --project="$proj" "$acct" \
    --filter="network~/${vm}-vpc$ AND direction=INGRESS" --format=json 2>&1) || { ko "firewall rules readable (${out:0:200})"; out='[]'; }
  local rules
  rules=$(jq -r '[.[] | "\(.allowed | map(.IPProtocol + ":" + ((.ports // []) | join(","))) | join(";"))|\(.sourceRanges | join(","))"] | join(" ")' <<<"$out")
  [[ "$rules" == "tcp:22|${iap}" ]] && ok "the only ingress rule is tcp:22 from ${iap}" || ko "the only ingress rule is tcp:22 from ${iap} (found: ${rules:-none})"

  do_satellite_ssh_opts || return 1
  local remote
  _satellite_verify_users
  # shellcheck disable=SC2016
  remote=$("${SATELLITE_AS_AGENT[@]}" 2>/dev/null <<'REMOTE'
for m in /mnt/data /opt /var/spool-hub /var/csi; do mountpoint -q "$m" && echo "mnt $m ok" || echo "mnt $m no"; done
for b in claude spool spool-agent; do [ -x "$HOME/.local/bin/$b" ] && echo "bin $b ok" || echo "bin $b no"; done
grep -h "^export SPOOL_BOX_TAG=" /etc/profile.d/csi-spl-satellite.sh "$HOME/.bashrc" 2>/dev/null | head -n 1 | sed "s/^export /tag /"
for f in .gcp/.csi/key-csi-spl-dev.json .gcp/.csi/key-csi-spl-prd.json .github/token; do echo "key $f $(stat -c %a "$HOME/$f" 2>/dev/null || echo missing)"; done
REMOTE
)
  if [[ -n "$remote" ]]; then ok "ssh over IAP as the ${proj} SA"; else ko "ssh over IAP as the ${proj} SA"; fi
  local m b f
  for m in /mnt/data /opt /var/spool-hub /var/csi; do grep -qx "mnt $m ok" <<<"$remote" && ok "data disk mounted on $m" || ko "data disk mounted on $m"; done
  for b in claude spool spool-agent; do grep -qx "bin $b ok" <<<"$remote" && ok "$b installed for ${SATELLITE_AGENT}" || ko "$b installed for ${SATELLITE_AGENT}"; done
  grep -qx "tag SPOOL_BOX_TAG=${tag}" <<<"$remote" && ok "SPOOL_BOX_TAG=${tag}" || ko "SPOOL_BOX_TAG=${tag}"
  for f in .gcp/.csi/key-csi-spl-dev.json .gcp/.csi/key-csi-spl-prd.json .github/token; do
    grep -qx "key $f 600" <<<"$remote" && ok "${SATELLITE_AGENT}: ~/$f is 0600" || ko "${SATELLITE_AGENT}: ~/$f is 0600 ($(sed -n "s#^key $f ##p" <<<"$remote"))"
  done

  local ba="${GCP_BILLING_ACCOUNT_ID:-}" bname
  bname=$(do_satellite_cnf budget_display_name 059-gcp-satellite-budget) || return 1
  if [[ -n "$ba" ]] && out=$(gcloud billing budgets list --billing-account="${ba#billingAccounts/}" "$acct" --format='value(displayName)' 2>/dev/null); then
    grep -qx "$bname" <<<"$out" && ok "budget $bname exists on the billing account" || ko "budget $bname exists on the billing account"
  else
    local state
    state=$(gcloud storage cat "gs://$(do_satellite_cnf tf_state_bucket 059-gcp-satellite-budget)/terraform/059-gcp-satellite-budget/default.tfstate" "$acct" 2>/dev/null)
    [[ "$(jq '[.resources[]? | select(.type == "google_billing_budget")] | length' <<<"${state:-{\}}")" == 1 ]] \
      && ok "budget $bname is in step 059's terraform state (billing account not readable as the SA)" \
      || ko "budget $bname is in step 059's terraform state"
  fi

  _satellite_verify_replica
  _satellite_verify_claude_start

  echo "SATELLITE-VERIFY fails=${fails}"
  return $((fails > 0))
}

# The bash that prints `ver <name> <version|present|MISSING>` per row of the
# replica manifest; it runs on this box and, over ssh, on the satellite.
_satellite_versions_script() {
  local tsv="${PROJ_PATH}/cnf/satellite-replica.tsv" name cmd
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/.local/bin:/usr/local/go/bin:$HOME/.local/share/spool-agent/tools/bin:$HOME/.local/share/spool-agent/tools/go/bin:$HOME/go/bin:$HOME/bin:/usr/local/bin:$PATH"'
  while IFS=$'\t' read -r name cmd _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    printf 'o=$( (%s) 2>&1 ); r=$?; v=$(grep -m1 -oE "[0-9]+\\.[0-9]+(\\.[0-9]+)?" <<<"$o" | head -n1); ' "$cmd"
    printf '[ -n "$v" ] && [ $r = 0 ] || { [ $r = 0 ] && v=present || v=MISSING; }; echo "ver %s $v"\n' "$name"
  done <"$tsv"
}

# The replica checks of do_satellite_verify (it shares ok / ko / fails and
# SATELLITE_SSH with the caller).
_satellite_verify_replica() {
  local script here there name hv sv d
  script=$(_satellite_versions_script)
  here=$(bash -c "$script" 2>/dev/null)
  there=$("${SATELLITE_AS_AGENT[@]}" <<<"$script" 2>/dev/null)
  # present = PASS, the box PC's version is shown for reference; go is held to
  # CI's pin (go.mod), which the playbook installs, not to the box PC's drift
  local gopin
  # the sibling *-api dir: ./run sets APP to the checkout's dir name, so no ${APP} here
  gopin=$(sed -n 's/^go \([0-9.]*\)$/\1/p' "${PROJ_PATH}"/../*-api/src/go/spool-hub-api/go.mod 2>/dev/null | head -n 1)
  while read -r _ name hv; do
    sv=$(awk -v n="$name" '$1 == "ver" && $2 == n { print $3 }' <<<"$there")
    if [[ "$name" == go && -n "$gopin" ]]; then
      [[ "$sv" == "$gopin" ]] && ok "tool go satellite=$sv = go.mod pin (box=$hv)" || ko "tool go satellite=${sv:-MISSING}, want the go.mod pin $gopin (box=$hv)"
    elif [[ -n "$sv" && "$sv" != MISSING ]]; then ok "tool $name box=$hv satellite=$sv"; else ko "tool $name box=$hv satellite=${sv:-MISSING}"; fi
  done <<<"$here"

  local remote repo
  repo=$(do_satellite_cnf gh_repo 120-github-general-secrets) || return 1
  # shellcheck disable=SC2016
  remote=$({ printf "DIR='%s'\n" "/opt/csi/${repo##*/}"; cat <<'REMOTE'
export PATH="$HOME/.local/bin:$PATH"
[ -s "$HOME/.claude/CLAUDE.md" ] && echo "cfg claude-md ok"
jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1 && grep -q '^\.claude/settings\.json	' "$HOME/.claude/.claude-config.tsv" 2>/dev/null && echo "cfg settings ok"
echo "cfg skills $(find "$HOME/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
echo "cfg memory $(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | wc -l)"
[ -s "$HOME/.tmux.conf" ] && echo "cfg tmux ok"
[ -n "$(git config --global user.email)" ] && echo "cfg git ok"
gh auth status -h github.com >/dev/null 2>&1 && echo "cfg gh ok"
docker info >/dev/null 2>&1 && echo "cfg docker ok"
echo "cfg tz $(timedatectl show -p Timezone --value 2>/dev/null)"
[ "$(claude auth status --json 2>/dev/null | jq -r .loggedIn 2>/dev/null)" = true ] && echo "cfg claude-login ok"
[ -d "$DIR/tpl-gen/src/python/tpl-gen/.venv" ] && echo "cfg tpl-gen ok"
REMOTE
} | "${SATELLITE_AS_AGENT[@]}" 2>/dev/null)
  local c
  for c in claude-md:"~/.claude/CLAUDE.md" settings:"~/.claude/settings.json (valid, managed by claude-config)" tmux:"~/.tmux.conf" \
    git:"git identity" gh:"gh is authenticated" docker:"docker runs without sudo" claude-login:"claude is logged in (claude auth status)" tpl-gen:"tpl-gen cloned (+ its .venv)"; do
    grep -qx "cfg ${c%%:*} ok" <<<"$remote" && ok "${SATELLITE_AGENT}: ${c#*:}" || ko "${SATELLITE_AGENT}: ${c#*:}"
  done
  local n tz="${BOX_TIMEZONE:-Europe/Helsinki}"
  n=$(sed -n 's/^cfg tz //p' <<<"$remote"); [[ "$n" == "$tz" ]] && ok "timezone $tz" || ko "timezone $tz (is ${n:-?})"
  n=$(sed -n 's/^cfg skills //p' <<<"$remote"); [[ "${n:-0}" -gt 0 ]] && ok "~/.claude/skills: $n" || ko "~/.claude/skills: ${n:-0}"
  # the agents' memory grows on the satellite itself: informational, never a FAIL
  n=$(sed -n 's/^cfg memory //p' <<<"$remote"); echo "INFO ${SATELLITE_AGENT}: ~/.claude/projects/*/memory: ${n:-0}"
}

# The users of box-playbook.yaml role 05 (owner topic 6f10f92b): read from
# the box's own /etc/csi-spl-satellite.env (the names are not in this repo),
# then one row per property, as on the box PC. Sets SATELLITE_AGENT and
# SATELLITE_AS_AGENT (the command that runs a stdin script as the agent);
# before the playbook ran there are no users: a FAIL, and the checks that
# follow run as the ssh login user, as before.
_satellite_verify_users() {
  local envf owner agent out
  envf=$(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" 'cat /etc/csi-spl-satellite.env 2>/dev/null' 2>/dev/null)
  owner=$(sed -n 's/^OWNER_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")
  agent=$(sed -n 's/^AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' <<<"$envf")
  if [[ -z "$owner" || -z "$agent" ]]; then
    ko "the owner + agent users exist (/etc/csi-spl-satellite.env: run the playbook, ./run -a do_satellite_playbook)"
    SATELLITE_AGENT="the ssh user"
    SATELLITE_AS_AGENT=(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" bash -s)
    return 0
  fi
  SATELLITE_AGENT="$agent"
  # cd "$HOME": the ssh login's cwd (its home, 0750) is unreadable to the agent,
  # and go / terraform / trivy / pnpm then fail to start (run 4: four false FAILs)
  SATELLITE_AS_AGENT=(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" "sudo -n -u ${agent} -H bash -c 'cd \"\$HOME\" && exec bash -s'")
  # shellcheck disable=SC2029
  # the names go AFTER sudo: sudo drops env set before it (run 4: 13 false FAILs)
  local owner_tools="yq jq python3 psql pandoc curl git gh docker setsid flock sha256sum setfacl getfacl crontab openssl perl tmux gcloud"
  out=$(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" "sudo -n env O='${owner}' A='${agent}' OWNER_TOOLS='${owner_tools}' bash -s" 2>/dev/null <<'REMOTE'
for u in "$O" "$A"; do
  id "$u" >/dev/null 2>&1 || { echo "user $u missing"; continue; }
  echo "user $u uid $(id -u "$u")"
  case "$(getent passwd "$u" | cut -d: -f6)" in /mnt/data/home/*) echo "user $u home-data" ;; esac
  grep -qx "$u ALL=(ALL) NOPASSWD:ALL" "/etc/sudoers.d/90-$u-nopasswd" 2>/dev/null && echo "user $u sudo"
  id -nG "$u" | tr ' ' '\n' | grep -qx docker && echo "user $u docker"
  [ -f "/var/lib/systemd/linger/$u" ] && echo "user $u linger"
done
id -nG "$A" 2>/dev/null | tr ' ' '\n' | grep -qx "$O" && echo "agent in-owner-group"
[ "$(stat -c %U /opt/csi 2>/dev/null)" = "$O" ] && echo "owner owns /opt/csi"
[ "$(stat -c %U:%G /var/spool-hub 2>/dev/null)" = "$O:spool-agents" ] && echo "owner owns /var/spool-hub"
echo "hostname $(hostname -s)"
grep -h '^SPOOL_DESK_BOX=' /var/spool-hub/box.env 2>/dev/null | sed 's/^/boxenv /'
# the owner runs the desks: its harness (role 08), as the agent has its own
oh=$(getent passwd "$O" | cut -d: -f6)
for b in spool spool-agent; do [ -x "$oh/.local/bin/$b" ] && echo "owner bin $b"; done
# the tools the csi-spl actions require (do_require_bin), on the owner's LOGIN
# PATH: the box user runs the desk / lease / pin actions, and install.sh's
# per-user tools dir is not on that PATH (2026-10-02: yq missing)
for b in $OWNER_TOOLS; do sudo -n -u "$O" -i bash -lc "command -v $b" >/dev/null 2>&1 || echo "owner tool-missing $b"; done
echo "owner tools-checked"
# the run actions' state + log dir: writable by the owner, and by the agent
# through the owner's group (2026-10-02: desk-reconcile could not be created)
for u in "$O" "$A"; do sudo -n -u "$u" test -w /var/csi/csi-spl && echo "varcsi writable $u"; done
# the owner's tmux session main, kept by the systemd user unit tmux-main (role 08)
sudo -n -u "$O" tmux has-session -t main 2>/dev/null && echo "owner tmux-main"
sudo -n -u "$O" env XDG_RUNTIME_DIR="/run/user/$(id -u "$O")" systemctl --user is-enabled -q tmux-main.service 2>/dev/null && echo "owner tmux-unit"
# the clone: on master, clean, and its HEAD (compared with trunk on this box)
r=/opt/csi/csi-spl
g() { git -c safe.directory="$r" -C "$r" "$@"; }
echo "repo branch $(g rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "repo head $(g rev-parse HEAD 2>/dev/null)"
echo "repo dirty $(g status --porcelain 2>/dev/null | wc -l)"
REMOTE
)
  local u r uid
  for u in "$owner" "$agent"; do
    [[ "$u" == "$owner" ]] && uid=2000 || uid=2001
    grep -qx "user $u uid $uid" <<<"$out" && ok "user $u exists, uid $uid" || ko "user $u exists, uid $uid"
    for r in home-data:"home on the data disk" sudo:"passwordless sudo (as on the box PC)" docker:"in the docker group" linger:"lingers"; do
      grep -qx "user $u ${r%%:*}" <<<"$out" && ok "$u: ${r#*:}" || ko "$u: ${r#*:}"
    done
  done
  grep -qx "agent in-owner-group" <<<"$out" && ok "$agent is in $owner's group" || ko "$agent is in $owner's group"
  grep -qx "owner owns /opt/csi" <<<"$out" && ok "/opt/csi belongs to $owner" || ko "/opt/csi belongs to $owner"
  grep -qx "owner owns /var/spool-hub" <<<"$out" && ok "/var/spool-hub is $owner:spool-agents" || ko "/var/spool-hub is $owner:spool-agents"
  local box
  box=$(sed -n 's/^BOX_TAG=\([a-z0-9-]*\)$/\1/p' <<<"$envf")
  grep -qx "hostname ${box}" <<<"$out" && ok "hostname -s = ${box}" || ko "hostname -s = ${box} (is $(sed -n 's/^hostname //p' <<<"$out"))"
  grep -qx "boxenv SPOOL_DESK_BOX=${box}" <<<"$out" && ok "/var/spool-hub/box.env SPOOL_DESK_BOX=${box}" || ko "/var/spool-hub/box.env SPOOL_DESK_BOX=${box}"
  _satellite_verify_owner_rows "$out" "$owner" "$agent"
}


# The owner-side rows of _satellite_verify_users (its remote script's output):
# the box user's harness and tools, its tmux main, /var/csi, the clone.
_satellite_verify_owner_rows() {
  local out="$1" owner="$2" agent="$3" b u
  for b in spool spool-agent; do
    grep -qx "owner bin $b" <<<"$out" && ok "$b installed for $owner (the box user runs the desks)" || ko "$b installed for $owner (the box user runs the desks)"
  done
  local missing
  missing=$(sed -n 's/^owner tool-missing //p' <<<"$out" | tr '\n' ' ')
  if grep -qx "owner tools-checked" <<<"$out" && [[ -z "$missing" ]]; then ok "$owner has the actions' required tools on its login PATH ($owner_tools)"
  else ko "$owner has the actions' required tools on its login PATH (missing: ${missing:-unreadable})"; fi
  grep -qx "owner tmux-main" <<<"$out" && ok "$owner's tmux session main runs" || ko "$owner's tmux session main runs"
  grep -qx "owner tmux-unit" <<<"$out" && ok "$owner's systemd user unit tmux-main is enabled (back after a reboot)" || ko "$owner's systemd user unit tmux-main is enabled"
  for u in "$owner" "$agent"; do
    grep -qx "varcsi writable $u" <<<"$out" && ok "/var/csi/csi-spl is writable by $u (the run actions' state + logs)" || ko "/var/csi/csi-spl is writable by $u (the run actions' state + logs)"
  done
  _satellite_verify_repo "$out"
}

# The clone at /opt/csi/csi-spl: on master, clean, and at trunk. Trunk is
# read on THIS box (git fetch origin master here), so the satellite needs no
# extra credential for the check. "At trunk" allows SATELLITE_REPO_LAG
# commits (default 10): trunk moves every few minutes, and the commits pushed
# between the playbook's fast-forward and this check are not a defect.
_satellite_verify_repo() {
  local out="$1" br head dirty behind lag="${SATELLITE_REPO_LAG:-10}" top
  br=$(sed -n 's/^repo branch //p' <<<"$out"); head=$(sed -n 's/^repo head //p' <<<"$out"); dirty=$(sed -n 's/^repo dirty //p' <<<"$out")
  [[ "$br" == master ]] && ok "/opt/csi/csi-spl is on master" || ko "/opt/csi/csi-spl is on master (is ${br:-unreadable})"
  [[ "$dirty" == 0 ]] && ok "/opt/csi/csi-spl has no local changes" || ko "/opt/csi/csi-spl has no local changes (${dirty:-?} paths)"
  top=$(cd "$PROJ_PATH" && git rev-parse --show-toplevel 2>/dev/null)
  git -C "$top" fetch -q origin master 2>/dev/null
  if [[ "$head" =~ ^[0-9a-f]{40}$ ]] && git -C "$top" merge-base --is-ancestor "$head" origin/master 2>/dev/null; then
    behind=$(git -C "$top" rev-list --count "$head..origin/master")
    (( behind <= lag )) && ok "/opt/csi/csi-spl is at trunk (${behind} behind, <= ${lag})" \
      || ko "/opt/csi/csi-spl is at trunk (${behind} behind: re-run ./run -a do_satellite_playbook)"
  else
    ko "/opt/csi/csi-spl is at trunk (HEAD ${head:-unreadable} is not on origin/master)"
  fi
}

# Claude Code starts for the agent with NO first-run menu (2026-10-02: the
# three satellite agents stopped at the theme picker / "Select login method"
# with loggedIn:true). Two rows, as the agent: `claude --print` answers, and an
# interactive claude in a throwaway tmux server (its own -L socket; the owner's
# server is not touched) shows no onboarding text within 20 s. The folder is
# pre-trusted the way a spawn does it (trust-workdir.sh), so the trust dialog
# cannot make a false FAIL. Costs one tiny model call.
_satellite_verify_claude_start() {
  local out
  # shellcheck disable=SC2016
  out=$("${SATELLITE_AS_AGENT[@]}" 2>/dev/null <<'REMOTE'
export PATH="$HOME/.local/bin:$PATH"
p=$(timeout 120 claude -p "Reply with exactly the word ok" 2>&1 | tr -d '\r' | tr '[:upper:]' '[:lower:]' | head -c 300)
grep -qw ok <<<"$p" && echo "print ok" || echo "print fail $(tr '\n' ' ' <<<"$p" | cut -c1-120)"
d=$(mktemp -d)
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/trust-workdir.sh "$d" "$(id -un)" claude >/dev/null 2>&1
s="verify-smoke-$$"
tmux -L "$s" new-session -d -s smoke -x 200 -y 50 -c "$d" "$HOME/.local/bin/claude" 2>/dev/null
sleep 20
screen=$(tmux -L "$s" capture-pane -p -t smoke 2>/dev/null)
tmux -L "$s" kill-server 2>/dev/null
rm -rf "$d"
hit=$(grep -m1 -iE "select login method|choose the text style|let.s get started|trust this folder|do you trust|dark mode|light mode" <<<"$screen")
if [ -z "$screen" ]; then echo "smoke none"
elif [ -n "$hit" ]; then echo "smoke onboarding $hit"
else echo "smoke ok"; fi
REMOTE
)
  grep -qx "print ok" <<<"$out" && ok "${SATELLITE_AGENT}: claude --print answers" || ko "${SATELLITE_AGENT}: claude --print answers ($(sed -n 's/^print fail //p' <<<"$out"))"
  if grep -qx "smoke ok" <<<"$out"; then ok "${SATELLITE_AGENT}: an interactive claude starts with no first-run menu (20 s)"
  else ko "${SATELLITE_AGENT}: an interactive claude starts with no first-run menu ($(sed -n 's/^smoke //p' <<<"$out" | cut -c1-120))"; fi
}
