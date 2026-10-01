#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057: verify the satellite end to end, read-only, as the
# @description csi-spl-all SA ONLY (its key; ACCOUNT / GCP_ACCOUNT are ignored,
# @description so the owner account can never be the identity here). One
# @description `PASS|FAIL <check>` line each; returns non-zero on any FAIL:
# @description   VM RUNNING, no public IP, the ONE ingress rule = tcp/22 from
# @description   the IAP range, ssh over IAP, the data disk on /mnt/data + /opt +
# @description   /var/spool-hub, claude / spool / spool-agent present,
# @description   SPOOL_BOX_TAG=sat, the pushed keys 0600, the budget exists;
# @description   then the replica of the box PC (owner topic 5fe56859): every
# @description   tool of cnf/satellite-replica.tsv, its version on THIS box and
# @description   on the satellite (missing there = FAIL), and the AI-user setup
# @description   (home dirs on the data disk, ~/.claude config + skills +
# @description   memory, tmux, git identity, gh auth, docker, tpl-gen, and
# @description   whether claude is logged in there: the loggedIn flag only).
# @param GCP_BILLING_ACCOUNT_ID (optional) - lists the budget on the billing
# @param        account; without it (or without that right) the budget check
# @param        reads step 059's terraform state instead, and says so
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
  # shellcheck disable=SC2016
  remote=$(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" 'for m in /mnt/data /opt /var/spool-hub; do mountpoint -q "$m" && echo "mnt $m ok" || echo "mnt $m no"; done
    for b in claude spool spool-agent; do [ -x "$HOME/.local/bin/$b" ] && echo "bin $b ok" || echo "bin $b no"; done
    grep -h "^export SPOOL_BOX_TAG=" "$HOME/.bashrc" | sed "s/^export /tag /"
    for f in .gcp/.csi/key-csi-spl-dev.json .gcp/.csi/key-csi-spl-prd.json .github/token; do echo "key $f $(stat -c %a "$HOME/$f" 2>/dev/null || echo missing)"; done' 2>/dev/null)
  if [[ -n "$remote" ]]; then ok "ssh over IAP as the ${proj} SA"; else ko "ssh over IAP as the ${proj} SA"; fi
  local m b f
  for m in /mnt/data /opt /var/spool-hub; do grep -qx "mnt $m ok" <<<"$remote" && ok "data disk mounted on $m" || ko "data disk mounted on $m"; done
  for b in claude spool spool-agent; do grep -qx "bin $b ok" <<<"$remote" && ok "$b installed" || ko "$b installed"; done
  grep -qx "tag SPOOL_BOX_TAG=${tag}" <<<"$remote" && ok "SPOOL_BOX_TAG=${tag}" || ko "SPOOL_BOX_TAG=${tag}"
  for f in .gcp/.csi/key-csi-spl-dev.json .gcp/.csi/key-csi-spl-prd.json .github/token; do
    grep -qx "key $f 600" <<<"$remote" && ok "~/$f is 0600" || ko "~/$f is 0600 ($(sed -n "s#^key $f ##p" <<<"$remote"))"
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

  echo "SATELLITE-VERIFY fails=${fails}"
  return $((fails > 0))
}

# The bash that prints `ver <name> <version|present|MISSING>` per row of the
# replica manifest; it runs on this box and, over ssh, on the satellite.
_satellite_versions_script() {
  local tsv="${PROJ_PATH}/cnf/satellite-replica.tsv" name cmd
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/.local/bin:$HOME/.local/share/spool-agent/tools/bin:$HOME/.local/share/spool-agent/tools/go/bin:$HOME/go/bin:$HOME/bin:/usr/local/bin:$PATH"'
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
  there=$(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" bash -s <<<"$script" 2>/dev/null)
  while read -r _ name hv; do
    sv=$(awk -v n="$name" '$1 == "ver" && $2 == n { print $3 }' <<<"$there")
    if [[ -n "$sv" && "$sv" != MISSING ]]; then ok "tool $name box=$hv satellite=$sv"; else ko "tool $name box=$hv satellite=${sv:-MISSING}"; fi
  done <<<"$here"

  local persist="${SATELLITE_PERSIST:-.claude .local .config .cache .gcp .github go .npm .terraform.d .tmux}" remote repo
  repo=$(do_satellite_cnf gh_repo 120-github-general-secrets) || return 1
  # shellcheck disable=SC2016,SC2029
  remote=$(ssh -o BatchMode=yes "${SATELLITE_SSH[@]}" "PERSIST='${persist}' DIR='/opt/csi/${repo##*/}' bash -s" 2>/dev/null <<'REMOTE'
export PATH="$HOME/.local/bin:$PATH"
dh="/mnt/data/home/$(id -un)"
for d in $PERSIST; do [ "$(readlink "$HOME/$d")" = "$dh/$d" ] && echo "home $d ok" || echo "home $d no"; done
[ -s "$HOME/.claude/CLAUDE.md" ] && echo "cfg claude-md ok"
jq -e '.statusLine and .permissions' "$HOME/.claude/settings.json" >/dev/null 2>&1 && echo "cfg settings ok"
echo "cfg skills $(find "$HOME/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
echo "cfg memory $(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | wc -l)"
[ -s "$HOME/.tmux.conf" ] && echo "cfg tmux ok"
[ -n "$(git config --global user.email)" ] && echo "cfg git ok"
gh auth status -h github.com >/dev/null 2>&1 && echo "cfg gh ok"
docker info >/dev/null 2>&1 && echo "cfg docker ok"
[ "$(claude auth status --json 2>/dev/null | jq -r .loggedIn 2>/dev/null)" = true ] && echo "cfg claude-login ok"
[ -d "$DIR/tpl-gen/src/python/tpl-gen/.venv" ] && echo "cfg tpl-gen ok"
REMOTE
)
  for d in $persist; do grep -qx "home $d ok" <<<"$remote" && ok "~/$d lives on the data disk" || ko "~/$d lives on the data disk"; done
  local c
  for c in claude-md:"~/.claude/CLAUDE.md" settings:"~/.claude/settings.json (statusLine, permissions)" tmux:"~/.tmux.conf" \
    git:"git identity" gh:"gh is authenticated" docker:"docker runs without sudo" claude-login:"claude is logged in (claude auth status)" tpl-gen:"tpl-gen cloned (+ its .venv)"; do
    grep -qx "cfg ${c%%:*} ok" <<<"$remote" && ok "${c#*:}" || ko "${c#*:}"
  done
  local n
  n=$(sed -n 's/^cfg skills //p' <<<"$remote"); [[ "${n:-0}" -gt 0 ]] && ok "~/.claude/skills: $n" || ko "~/.claude/skills: ${n:-0}"
  n=$(sed -n 's/^cfg memory //p' <<<"$remote"); [[ "${n:-0}" -gt 0 ]] && ok "~/.claude/projects/*/memory: $n" || ko "~/.claude/projects/*/memory: ${n:-0}"
}
