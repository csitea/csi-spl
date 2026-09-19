#!/bin/bash
#------------------------------------------------------------------------------
# @description Take ONE deleted tenant's host <tenant>.<fqdn> down (specs/022),
# @description the twin of do_spl_tenant_host_provision: remove the tenant from
# @description env.dns.mapped_tenants, render 032 + 025, plan with a GATE that
# @description admits ONLY the destroy of this tenant's mapping
# @description (032 additional["<host>"]) and CNAME (025
# @description cloud_run_mapping["<tenant>/CNAME"]), provision, then
# @description tenant_hosts.status = removed. Refuses while the tenant row
# @description still exists in the hub DB (FORCE=1 overrides, e.g. a host that
# @description was mapped for a tenant never created). Terraform only through
# @description make / tf-runner, as the env SA. The cnf change is left in the
# @description tree to commit.
# @description DRY_RUN=1 (default): print what would change, touch nothing.
# @param TENANT_ID - the tenant slug
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param FORCE (optional) - 1: skip the "tenant still exists" check
# @param MARK_DB (optional) - 1 (default): write tenant_hosts. 0: skip the DB
# @example ENV=dev TENANT_ID=acme ./run -a do_spl_tenant_host_deprovision
# @example ENV=dev TENANT_ID=acme DRY_RUN=0 ./run -a do_spl_tenant_host_deprovision
#------------------------------------------------------------------------------
do_spl_tenant_host_deprovision() {
  local tenant="${TENANT_ID:-}"
  spl_th_valid_slug "$tenant" || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local cnf
  cnf="$(spl_th_cnf_file)" || return 1

  if (( dry )); then
    spl_th_cnf_has "$cnf" "$tenant" &&
      do_log "INFO DRY_RUN would remove $tenant from env.dns.mapped_tenants in $cnf" ||
      do_log "INFO DRY_RUN $tenant is not in env.dns.mapped_tenants: the apply would only drop leftovers"
    do_log "INFO DRY_RUN would destroy ONLY: $(spl_th_destroy_allow "$tenant" | tr '\n' ' ')"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  if [[ "${FORCE:-0}" != 1 && "${MARK_DB:-1}" == 1 ]]; then
    local n
    do_gcp_pin_account "$SPL_CNF" || return 1
    n="$(spl_via_proxy _spl_th_tenant_exists "$tenant")" || { do_log "FATAL cannot read tenants for $tenant"; return 1; }
    [[ "$n" == 0 ]] || { do_log "FATAL tenant $tenant still exists in the $ENV hub DB; delete it first (or FORCE=1)"; return 1; }
  fi

  spl_th_lock || return 1
  spl_th_cnf_set "$cnf" del "$tenant" || return 1
  spl_th_render || return 1
  spl_th_apply "$(spl_th_destroy_allow "$tenant")" || { spl_th_mark_one "$tenant" failed "deprovision plan / apply refused or failed"; return 1; }
  spl_th_mark_one "$tenant" removed ""
  do_log "OK tenant host $tenant.$SPL_FQDN deprovisioned (mapping + record)"
}

# spl_th_destroy_allow <tenant>... -> the terraform addresses a deprovision of
# those tenants may destroy, one per line
spl_th_destroy_allow() {
  local t
  for t in "$@"; do
    printf 'google_cloud_run_domain_mapping.additional["%s.%s"]\n' "$t" "$SPL_FQDN"
    printf 'google_dns_record_set.cloud_run_mapping["%s/CNAME"]\n' "$t"
  done
}

_spl_th_tenant_exists() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v t="$1" <<'SQL' | tail -1
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT count(*) FROM tenants WHERE tenant_id = :'t';
ROLLBACK;
SQL
}
