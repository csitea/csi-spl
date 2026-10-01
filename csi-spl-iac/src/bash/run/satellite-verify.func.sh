#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057: verify the satellite end to end, read-only, as the
# @description csi-spl-all SA ONLY (its key; ACCOUNT / GCP_ACCOUNT are ignored,
# @description so the owner account can never be the identity here). One
# @description `PASS|FAIL <check>` line each; returns non-zero on any FAIL:
# @description   VM RUNNING, no public IP, the ONE ingress rule = tcp/22 from
# @description   the IAP range, ssh over IAP, the data disk on /mnt/data + /opt +
# @description   /var/spool-hub, claude / spool / spool-agent present,
# @description   SPOOL_BOX_TAG=sat, the pushed keys 0600, the budget exists.
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

  echo "SATELLITE-VERIFY fails=${fails}"
  return $((fails > 0))
}
