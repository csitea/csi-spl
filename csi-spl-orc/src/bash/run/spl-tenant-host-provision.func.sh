#!/bin/bash
#------------------------------------------------------------------------------
# @description Give ONE tenant its public WUI host <tenant>.<fqdn> (SPL-959,
# @description owner option B 2026-09-26; the apex stays t1's and is never
# @description mapped). There is no wildcard: the host is one Firebase Hosting
# @description custom domain of the env's WUI site (019 additional_fqdns) + its
# @description records A 199.36.158.100 and TXT hosting-site=<site> (025), both
# @description rendered from cnf env.dns.mapped_tenants. The hub stays on the
# @description api host (spec-024's 032 hub mappings are gone). So:
# @description   1. add the tenant to env.dns.mapped_tenants in <env>.env.yaml
# @description      (the list terraform reads: a re-apply keeps every tenant)
# @description   2. render 019 + 025 (make do-generate-config-for-step)
# @description   3. make do-tf-plan per step, GATE: stop on an error, a
# @description      replace, an in-place update or ANY destroy (the apex,
# @description      api. and dev. records are never touched); then provision
# @description   4. do_spl_wait_for_firebase_domain, then do_spl_probe_wui_host
# @description      until it passes (edge propagation lags the cert)
# @description   5. tenant_hosts.status = ready + detail (failed + why)
# @description The apex tenant (steps.019 wui_default_tenant) maps nothing: its
# @description host is https://<fqdn>; the run probes it and marks it ready.
# @description Idempotent: a mapped tenant re-runs as a no-op plan, a cert
# @description check and a probe. Terraform only through the make / tf-runner
# @description path; every gcloud / terraform call runs as the env SA from its
# @description key. One run per env at a time (flock). The cnf / tfvars change
# @description is left in the tree: commit it (the reconcile workflow does).
# @description DRY_RUN=1 (default): print what would change, touch nothing.
# @param TENANT_ID - the tenant slug (^[a-z0-9][a-z0-9-]{0,31}$, not reserved)
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param MARK_ONLY (optional) - 1: no cnf edit, no render, no terraform: check
# @param   an already-mapped host (custom domain + WUI probe) and record it
# @param MARK_DB (optional) - 1 (default): write tenant_hosts. 0: skip the DB
# @param CERT_TIMEOUT_SECONDS (optional) - cert wait, default 3600
# @param PROBE_TIMEOUT_SECONDS (optional) - probe retry window, default 1200
# @param PROBE_POLL_SECONDS (optional) - default 30
# @example ENV=dev TENANT_ID=acme ./run -a do_spl_tenant_host_provision
# @example ENV=dev TENANT_ID=acme DRY_RUN=0 ./run -a do_spl_tenant_host_provision
#------------------------------------------------------------------------------
do_spl_tenant_host_provision() {
  local tenant="${TENANT_ID:-}"
  spl_th_valid_slug "$tenant" || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local host="$tenant.$SPL_FQDN" cnf
  cnf="$(spl_th_cnf_file)" || return 1
  # The apex tenant (steps.019 wui_default_tenant, t1) IS https://<fqdn>: no
  # cnf, no terraform. Probe the apex and record it (SPL-959).
  if [[ "$tenant" == "$(yq -r '.env.steps."019-firebase-static-site".wui_default_tenant // ""' "$cnf")" ]]; then
    if (( dry )); then
      do_log "OK DRY_RUN $tenant is the apex tenant: would probe https://$SPL_FQDN and mark it ready (no host to map)"
      return 0
    fi
    ( HOST="$SPL_FQDN" do_spl_probe_wui_host ) || { spl_th_mark_one "$tenant" failed "apex https://$SPL_FQDN WUI probe failed"; return 1; }
    spl_th_mark_one "$tenant" ready "apex https://$SPL_FQDN (the apex tenant has no subdomain), WUI probe verified TLS $(date -u +%FT%TZ)"
    do_log "OK $tenant is the apex tenant: https://$SPL_FQDN serves it"
    return 0
  fi

  if (( dry )); then
    if spl_th_cnf_has "$cnf" "$tenant"; then
      do_log "INFO DRY_RUN $tenant is already in env.dns.mapped_tenants ($cnf): the apply would be a no-op"
    else
      do_log "INFO DRY_RUN would add $tenant to env.dns.mapped_tenants in $cnf"
    fi
    do_log "INFO DRY_RUN would render + plan + provision $SPL_TH_STEPS for $ENV (no destroy allowed), wait for the $host cert, probe it, mark it ready"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  # MARK_ONLY=1: no cnf, no render, no terraform at all (an infra freeze):
  # a host already mapped in cnf is only checked (domain, probe) and recorded
  if [[ "${MARK_ONLY:-0}" == 1 ]]; then
    spl_th_cnf_has "$cnf" "$tenant" || { do_log "FATAL MARK_ONLY: $tenant is not in env.dns.mapped_tenants ($cnf)"; return 1; }
    spl_th_finish "$tenant"
    return
  fi
  spl_th_lock || return 1
  spl_th_cnf_set "$cnf" add "$tenant" || return 1
  spl_th_render || { spl_th_mark_one "$tenant" failed "render failed"; return 1; }
  spl_th_apply "" || { spl_th_mark_one "$tenant" failed "plan / apply refused or failed"; return 1; }
  spl_th_finish "$tenant"
}

# The steps a tenant host lives in, in apply order: the Firebase custom domain,
# then its records (a deprovision removes them in the same order).
SPL_TH_STEPS="019-firebase-static-site 025-gcp-dns-zone"

# spl_th_valid_slug <tenant>: the hub's tenant alphabet and reserved labels
# (csi-spl-api internal/msg ValidTenantID; spl-tenant-host.tst.sh keeps the
# two lists equal).
SPL_TH_RESERVED="dev prd lde stg tst www api app hub wui admin auth login mail status docs help support"
spl_th_valid_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
    do_log "FATAL TENANT_ID must match ^[a-z0-9][a-z0-9-]{0,31}$, got: '$1'"; return 1; }
  [[ " $SPL_TH_RESERVED " != *" $1 "* ]] || { do_log "FATAL TENANT_ID '$1' is a reserved label"; return 1; }
}

# spl_th_cnf_file -> the committed <env>.env.yaml that holds env.dns.mapped_tenants
spl_th_cnf_file() {
  local f="$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.yaml"
  [[ -f "$f" ]] || { do_log "FATAL no cnf file $f"; return 1; }
  printf '%s' "$f"
}

spl_th_cnf_has() {
  yq -e "(.env.dns.mapped_tenants // []) | any_c(. == \"$2\")" "$1" >/dev/null 2>&1
}

# spl_th_cnf_set <file> <add|del> <tenant>: edits the ONE flow-style line
# `mapped_tenants: [a, b]` in place (yq -i would drop every blank line of the
# file), then re-reads it with yq to prove the edit. No-op when already so.
spl_th_cnf_set() {
  local f="$1" op="$2" t="$3" out
  out="$(python3 - "$f" "$op" "$t" <<'PY'
import re, sys
path, op, t = sys.argv[1:]
lines = open(path).read().split("\n")
hits = [i for i, l in enumerate(lines) if re.match(r"^    mapped_tenants: \[[a-z0-9, -]*\]\s*$", l)]
if len(hits) != 1:
    print("ERR expected exactly one `    mapped_tenants: [..]` line, found %d" % len(hits)); sys.exit(1)
i = hits[0]
cur = [x.strip() for x in lines[i].split("[", 1)[1].rsplit("]", 1)[0].split(",") if x.strip()]
new = [x for x in cur if x != t] + ([t] if op == "add" else [])
if op == "add" and t in cur:
    new = cur
if new == cur:
    print("same"); sys.exit(0)
lines[i] = "    mapped_tenants: [" + ", ".join(new) + "]"
open(path, "w").write("\n".join(lines))
print("changed")
PY
)" || { do_log "FATAL cannot edit $f: $out"; return 1; }
  if [[ "$op" == add ]]; then spl_th_cnf_has "$f" "$t"; else ! spl_th_cnf_has "$f" "$t"; fi ||
    { do_log "FATAL $f: $op $t did not take (yq disagrees)"; return 1; }
  do_log "INFO env.dns.mapped_tenants $op $t: $out ($f)"
}

# spl_th_make <target> [VAR=value ...] -> the make target's output, ANSI
# stripped. SPL_TH_MAKE overrides the make binary (tests).
spl_th_make() {
  local target="$1"; shift
  "${SPL_TH_MAKE:-make}" -C "$PROJ_PATH" "$target" ENV="$ENV" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  return "${PIPESTATUS[0]}"
}

# spl_th_render -> renders the tfvars of every SPL_TH_STEPS step (conf-validator
# + tpl-gen containers) and proves the 019 tfvars now lists exactly the cnf
# tenants: a render that silently kept the old list would plan a no-op.
# (019's additional_fqdns is the list of tenant hosts.)
spl_th_render() {
  local s out
  for s in $SPL_TH_STEPS; do
    out="$(spl_th_make do-generate-config-for-step STEP="$s")" ||
      { printf '%s\n' "$out" | tail -20 >&2; do_log "FATAL render of $s for $ENV failed"; return 1; }
  done
  local tfv="$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/019-firebase-static-site.vars.tfvars" t
  for t in $(yq -r '(.env.dns.mapped_tenants // [])[]' "$(spl_th_cnf_file)"); do
    grep -qF "\"$t.$SPL_FQDN\"" "$tfv" || { do_log "FATAL $tfv does not list $t.$SPL_FQDN after the render"; return 1; }
  done
  do_log "INFO rendered $SPL_TH_STEPS for $ENV"
}

# spl_th_plan_gate <plan output> <allowed destroy addresses, newline separated>
# -> 0 apply, 3 no changes, 1 refuse. Refuses: no summary, an Error, a
# replace, an in-place update (the steps also hold the apex, api. and dev.
# records and the apex custom domain: a tenant host only ever adds), and any
# destroy of an address not in the allow list.
spl_th_plan_gate() {
  local o="$1" allow="$2" sum a
  sum="$(grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes' <<<"$o" | head -1)"
  # outputs-only: terraform prints neither summary, and touches no resource
  # (measured 2026-09-26: 019 after new custom domains changed its outputs)
  [[ -z "$sum" ]] && grep -q 'without changing any real infrastructure' <<<"$o" && sum="No changes"
  [[ -n "$sum" ]] || { do_log "FATAL plan has no summary"; return 1; }
  grep -qE '^(│ )?Error' <<<"$o" && { do_log "FATAL plan has an Error"; return 1; }
  grep -q 'must be replaced' <<<"$o" && { do_log "FATAL plan replaces a resource"; return 1; }
  grep -qE 'will be updated in-place|Plan: [0-9]+ to add, [1-9][0-9]* to change' <<<"$o" &&
    { do_log "FATAL plan updates a resource in place"; return 1; }
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    grep -qxF -- "$a" <<<"$allow" || { do_log "FATAL plan destroys $a, which is not a deprovisioned tenant's"; return 1; }
  done < <(sed -nE 's/^ *# (.+) will be destroyed$/\1/p' <<<"$o")
  do_log "INFO plan: $sum"
  [[ "$sum" == "No changes" ]] && return 3
  return 0
}

# spl_th_apply <allowed destroy addresses> -> plan, gate and provision every
# SPL_TH_STEPS step for ENV through make (tf-runner, env SA key).
spl_th_apply() {
  local allow="$1" s o rc
  for s in $SPL_TH_STEPS; do
    o="$(spl_th_make do-tf-plan STEP="$s")"
    spl_th_plan_gate "$o" "$allow"; rc=$?
    [[ $rc == 3 ]] && { do_log "INFO $s $ENV: no changes, apply skipped"; continue; }
    [[ $rc == 0 ]] || { printf '%s\n' "$o" | grep -E '^ *# |Plan:|Error' | head -40 >&2; do_log "FATAL STOP $s $ENV: plan refused"; return 1; }
    printf '%s\n' "$o" | grep -E '^ *# .* will be' >&2
    o="$(spl_th_make do-provision STEP="$s")"
    grep -qE 'Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed' <<<"$o" ||
      { printf '%s\n' "$o" | tail -30 >&2; do_log "FATAL STOP $s $ENV: apply failed"; return 1; }
    do_log "OK $s $ENV: $(grep -oE 'Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed' <<<"$o" | head -1)"
  done
}

# spl_th_finish <tenant> -> waits for the Firebase custom domain (host,
# ownership, cert), probes the WUI on the host until it passes, and records
# ready with its detail (or failed + why).
spl_th_finish() {
  local t="$1" host="$1.$SPL_FQDN"
  # CERT_PROPAGATING passes here: the WUI probe below verifies the served cert
  if ! ( DOMAIN="$host" TIMEOUT_SECONDS="${CERT_TIMEOUT_SECONDS:-3600}" ACCEPT_PROPAGATING=1 do_spl_wait_for_firebase_domain ); then
    spl_th_mark_one "$t" failed "firebase custom domain $host not active (host/ownership/cert)"; return 1
  fi
  local deadline=$(($(date +%s) + ${PROBE_TIMEOUT_SECONDS:-1200}))
  until ( HOST="$host" do_spl_probe_wui_host ); do
    if [[ $(date +%s) -ge $deadline ]]; then
      spl_th_mark_one "$t" failed "probe of $host did not pass"; return 1
    fi
    do_log "INFO $host does not answer yet (edge propagation); retrying in ${PROBE_POLL_SECONDS:-30}s"
    sleep "${PROBE_POLL_SECONDS:-30}"
  done
  spl_th_mark_one "$t" ready "https://$host firebase $SPL_ORG_APP-$ENV-site cert issued, WUI probe verified TLS $(date -u +%FT%TZ)"
  do_log "OK tenant host $host is served (custom domain, records, cert, WUI probe)"
}

# spl_th_lock -> one tenant-host run per env on this machine (do_tf_init wipes
# the step's bin dir, so two runs on one env + step break each other). The CI
# workflow adds a concurrency group per env on top.
spl_th_lock() {
  local d="${SPL_STATE_DIR:?}"
  exec {SPL_TH_LOCK_FD}>"$d/tenant-host.lock" || return 1
  flock -n "$SPL_TH_LOCK_FD" || { do_log "FATAL another tenant-host run holds $d/tenant-host.lock"; return 1; }
}

# spl_th_mark_one <tenant> <status> <detail> -> tenant_hosts upsert as the
# env SA through the Cloud SQL proxy, operator RLS scope. MARK_DB=0 skips.
spl_th_mark_one() {
  [[ "${MARK_DB:-1}" == 1 ]] || { do_log "INFO MARK_DB=0: tenant_hosts $1 -> $2 not written"; return 0; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  spl_via_proxy _spl_th_mark_sql "$1" "$2" "$3" ||
    { do_log "WARN tenant_hosts $1 -> $2 not written"; return 1; }
  do_log "INFO tenant_hosts $1 -> $2${3:+ ($3)}"
}

_spl_th_mark_sql() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -v ON_ERROR_STOP=1 -v t="$1" -v s="$2" -v d="$3" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
INSERT INTO tenant_hosts (tenant_id, status, detail, updated_at) VALUES (:'t', :'s', :'d', now())
  ON CONFLICT (tenant_id) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail, updated_at = now();
COMMIT;
SQL
}
