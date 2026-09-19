#!/bin/bash
#------------------------------------------------------------------------------
# @description Provision / deprovision the tenant hosts the hub DB asks for
# @description (specs/022; run by .github/workflows/40_tenant-host-reconcile.yml
# @description on a schedule, the owner's standing go of 2026-09-19). Reads
# @description tenant_hosts (rdb 0015: a trigger queues every new tenant,
# @description a delete marks it removing) as the env SA, then in ONE pass:
# @description   pending / failed -> add to env.dns.mapped_tenants
# @description   removing         -> drop from env.dns.mapped_tenants
# @description   (a tenant whose billing_status is unpaid is left pending)
# @description render 032 + 025, optionally commit + push that cnf change
# @description (CNF_PUSH=1, BEFORE the apply: a run that dies mid-apply leaves
# @description trunk declaring the host, and the next run completes it), plan
# @description with the destroy gate (only the removing tenants' addresses),
# @description provision, then per added tenant: cert wait + probe -> ready
# @description (or failed + detail, retried next run); removed tenants ->
# @description removed. Nothing open: exits 0 before touching terraform.
# @description Prints `open=<n>` on stdout (and to GITHUB_OUTPUT when set).
# @description DRY_RUN=1 (default): list what it would do, touch nothing.
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param CNF_PUSH (optional) - 1: commit the cnf/tfvars change and push it to
# @param   the trunk (fetch + rebase + push, verified by merge-base, 5 tries)
# @param CNF_GIT_BRANCH (optional) - trunk branch, default master
# @example ENV=dev ./run -a do_spl_tenant_host_reconcile
# @example ENV=dev DRY_RUN=0 CNF_PUSH=1 ./run -a do_spl_tenant_host_reconcile
#------------------------------------------------------------------------------
do_spl_tenant_host_reconcile() {
  do_require_bin yq psql flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local rows
  rows="$(spl_via_proxy _spl_th_open_rows)" || { do_log "FATAL cannot read tenant_hosts in $ENV"; return 1; }
  local -a add=() del=() held=()
  local tag t st bill
  # only `row <tenant> <status> <billing>` lines: the proxy start logs to
  # stdout too, and a log line must never read as a tenant
  while read -r tag t st bill; do
    [[ "$tag" == row && -n "$t" ]] || continue
    spl_th_valid_slug "$t" 2>/dev/null || { do_log "WARN skipping invalid tenant id '$t'"; continue; }
    if [[ "$st" == removing ]]; then del+=("$t")
    elif [[ "$bill" == unpaid ]]; then held+=("$t")
    else add+=("$t"); fi
  done <<<"$rows"
  local open=$(( ${#add[@]} + ${#del[@]} ))
  printf 'open=%s\n' "$open"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'open=%s\n' "$open" >>"$GITHUB_OUTPUT"
  (( ${#held[@]} )) && do_log "INFO left pending (billing unpaid): ${held[*]}"
  if (( open == 0 )); then
    do_log "OK nothing to reconcile in $ENV"
    return 0
  fi
  do_log "INFO $ENV reconcile: add [${add[*]}] remove [${del[*]}]"
  if (( dry )); then
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  spl_th_lock || return 1
  local cnf
  cnf="$(spl_th_cnf_file)" || return 1
  for t in "${add[@]}"; do spl_th_cnf_set "$cnf" add "$t" || return 1; done
  for t in "${del[@]}"; do spl_th_cnf_set "$cnf" del "$t" || return 1; done
  spl_th_render || return 1
  if [[ "${CNF_PUSH:-0}" == 1 ]]; then
    spl_th_cnf_push "cnf(022): $ENV tenant hosts${add[*]:+ +${add[*]}}${del[*]:+ -${del[*]}} (do_spl_tenant_host_reconcile)" || return 1
  fi

  if ! spl_th_apply "$(spl_th_destroy_allow "${del[@]}")"; then
    for t in "${add[@]}" "${del[@]}"; do spl_th_mark_one "$t" failed "plan / apply refused or failed"; done
    return 1
  fi
  for t in "${del[@]}"; do spl_th_mark_one "$t" removed ""; done
  local fails=0
  for t in "${add[@]}"; do spl_th_finish "$t" || fails=$((fails + 1)); done
  (( fails == 0 )) || { do_log "FATAL $fails tenant host(s) not ready in $ENV (tenant_hosts.status = failed, retried next run)"; return 1; }
  do_log "OK $ENV tenant hosts reconciled: add [${add[*]}] remove [${del[*]}]"
}

_spl_th_open_rows() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT 'row', h.tenant_id, h.status, coalesce(t.billing_status, '-')
  FROM tenant_hosts h LEFT JOIN tenants t USING (tenant_id)
 WHERE h.status IN ('pending', 'failed', 'removing')
 ORDER BY h.requested_at, h.tenant_id;
ROLLBACK;
SQL
}

# spl_th_cnf_push <message> -> commits the env's cnf + rendered files and
# pushes them to the trunk. The identity is the one the trunk's own cnf
# history carries (no literal in the tree, no AI trailer); rebase retries on a
# race; success is read from the repository (merge-base), never the push text.
spl_th_cnf_push() {
  local msg="$1" br="${CNF_GIT_BRANCH:-master}" root name email i
  root="$(git -C "$APP_PATH" rev-parse --show-toplevel)" || return 1
  local -a paths=(
    "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.yaml" "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.json"
    "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/032-gcp-cloud-run-domain-mapping.vars.tfvars"
    "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/025-gcp-dns-zone.vars.tfvars"
  )
  local other
  other="$(git -C "$root" status --porcelain --untracked-files=no -- . "${paths[@]/#/:!}")"
  [[ -z "$other" ]] || { do_log "FATAL CNF_PUSH needs a tree with no other change (rebase would refuse): $(tr '\n' ' ' <<<"$other")"; return 1; }
  git -C "$root" add -- "${paths[@]}" || return 1
  if git -C "$root" diff --cached --quiet; then do_log "INFO cnf unchanged: nothing to push"; return 0; fi
  name="$(git -C "$root" log -1 --no-mailmap --format=%an -- "$SPL_ORG_APP-cnf")"
  email="$(git -C "$root" log -1 --no-mailmap --format=%ae -- "$SPL_ORG_APP-cnf")"
  [[ -n "$name" && -n "$email" && "$email" != *noreply* ]] || { do_log "FATAL cannot read the cnf author from the history"; return 1; }
  local -a id=(-c "user.name=$name" -c "user.email=$email")
  git -C "$root" "${id[@]}" commit -q -m "$msg" || return 1
  for i in 1 2 3 4 5; do
    git -C "$root" fetch -q origin "$br" && git -C "$root" "${id[@]}" rebase -q "origin/$br" ||
      { git -C "$root" rebase --abort 2>/dev/null; do_log "FATAL cannot rebase the cnf commit onto origin/$br"; return 1; }
    git -C "$root" push -q origin "HEAD:$br" 2>/dev/null
    git -C "$root" fetch -q origin "$br"
    if git -C "$root" merge-base --is-ancestor HEAD "origin/$br"; then
      do_log "OK cnf pushed: $(git -C "$root" rev-parse --short HEAD) $msg"; return 0
    fi
    do_log "INFO push $i did not land (trunk moved); retrying"
    sleep $((i * 3))
  done
  do_log "FATAL the cnf commit did not land on $br after 5 tries"
  return 1
}
