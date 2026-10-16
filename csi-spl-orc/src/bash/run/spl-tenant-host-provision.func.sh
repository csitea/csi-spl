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
# @description      AND to steps.052-gcs-workspace-docs.workspaces, its Docs
# @description      bucket (without it the workspace's Docs answer 503)
# @description   2. render 052 + 019 + 025 (make do-generate-config-for-step)
# @description   3. make do-tf-plan per step, GATE: stop on an error, a
# @description      replace, an in-place update or ANY destroy (the apex,
# @description      api. and dev. records are never touched); then provision
# @description   4. do_spl_wait_for_firebase_domain, then do_spl_probe_wui_host
# @description      until it passes (edge propagation lags the cert)
# @description   5. tenant_hosts.status = ready + detail (failed + why); a
# @description      host that TURNS ready is announced (spl_th_notify_ready)
# @description The apex tenant (steps.019 wui_default_tenant) maps nothing: its
# @description host is https://<fqdn>; the run probes it and marks it ready.
# @description Idempotent: a mapped tenant re-runs as a no-op plan, a cert
# @description check and a probe. Terraform only through the make / tf-runner
# @description path; every gcloud / terraform call runs as the env SA from its
# @description key. One run per env at a time (flock). The cnf / tfvars change
# @description is PUSHED to the trunk by the action itself, from a throwaway
# @description worktree, before the apply (spl_th_cnf_push; dispatch c7b6e8db:
# @description ws-d's commit sat unpushed in the shared checkout for 1h40m);
# @description a push that does not land fails the run, the tenant marked failed.
# @description DRY_RUN=1 (default): print what would change, touch nothing.
# @param TENANT_ID - the tenant slug (^[a-z0-9][a-z0-9-]{0,31}$, not reserved)
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param MARK_ONLY (optional) - 1: no cnf edit, no render, no terraform: check
# @param   an already-mapped host (custom domain + WUI probe) and record it
# @param MARK_DB (optional) - 1 (default): write tenant_hosts. 0: skip the DB
# @param CNF_PUSH (optional) - 1 (default): push the cnf change to the trunk.
# @param   0: leave it uncommitted in the tree (warned loudly)
# @param TH_NOTIFY (optional) - 1 (default): announce a host that turns ready
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
  if spl_th_is_apex "$cnf" "$tenant"; then
    if (( dry )); then
      do_log "OK DRY_RUN $tenant is the apex tenant: would probe https://$SPL_FQDN and mark it ready (no host to map)"
      return 0
    fi
    spl_th_finish "$tenant"
    return
  fi

  # SPL-2278: a new hidden workspace only on the overlay's master box,
  # refused here before the lock, the cnf edit, the push and any apply
  if [[ "${MARK_ONLY:-0}" != 1 ]] && spl_th_new_hidden "$tenant"; then
    spl_th_overlay_box_ok "$tenant" || return 1
  fi
  if (( dry )); then
    if spl_th_cnf_has "$cnf" "$tenant"; then
      do_log "INFO DRY_RUN $tenant is already in env.dns.mapped_tenants ($cnf)"
    else
      do_log "INFO DRY_RUN would add $tenant to env.dns.mapped_tenants in $cnf"
    fi
    if spl_th_docs_has "$cnf" "$tenant"; then
      do_log "INFO DRY_RUN $tenant already has its docs bucket in steps.052-gcs-workspace-docs.workspaces ($cnf)"
    else
      do_log "INFO DRY_RUN would add $tenant to steps.052-gcs-workspace-docs.workspaces in $cnf (its Docs bucket)"
    fi
    if [[ "${CNF_PUSH:-1}" == 1 ]]; then
      do_log "INFO DRY_RUN would render $SPL_TH_STEPS, then PUSH that cnf to origin/${CNF_GIT_BRANCH:-master} from a throwaway worktree before any apply (a push that does not land fails the run)"
    else
      do_log "INFO DRY_RUN CNF_PUSH=0: the cnf edit would stay UNCOMMITTED in $APP_PATH"
    fi
    do_log "INFO DRY_RUN would plan + provision $SPL_TH_STEPS for $ENV (no destroy allowed), wait for the $host cert, probe it, mark tenant_hosts ready (pending -> ready) and announce it"
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
  spl_th_tenant_set "$cnf" add "$tenant" || return 1
  spl_th_render || { spl_th_mark_one "$tenant" failed "render failed"; return 1; }
  spl_th_cnf_publish "cnf(orc): $ENV tenant host +$tenant (do_spl_tenant_host_provision)" ||
    { spl_th_mark_one "$tenant" failed "cnf push to the trunk failed"; return 1; }
  spl_th_apply "" || { spl_th_mark_one "$tenant" failed "plan / apply refused or failed"; return 1; }
  spl_th_finish "$tenant"
}

# The steps a tenant lives in, in apply order: its workspace docs bucket, the
# Firebase custom domain, then its records (a deprovision removes them in the
# same order: a docs bucket that still holds objects fails the destroy, as
# force_destroy is off, before the host is touched).
SPL_TH_STEPS="052-gcs-workspace-docs 019-firebase-static-site 025-gcp-dns-zone"

# spl_th_valid_slug <tenant>: the hub's tenant alphabet and reserved labels
# (csi-spl-api internal/msg ValidTenantID;
# csi-spl-orc/src/bash/tests/tenant-host.tst.sh keeps the two lists equal
# by comparing SPL_TH_RESERVED).
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

# spl_th_is_apex <cnf> <tenant>: the apex tenant (steps.019 wui_default_tenant)
spl_th_is_apex() {
  [[ "$2" == "$(yq -r '.env.steps."019-firebase-static-site".wui_default_tenant // ""' "$1")" ]]
}

spl_th_cnf_has() {
  local t
  t="$(spl_th_token "$2")" || return 1
  yq -e "(.env.dns.mapped_tenants // []) | any_c(. == \"$t\")" "$1" >/dev/null 2>&1
}

# spl_th_docs_has <file> <tenant>: the tenant has a 052 docs bucket in cnf
spl_th_docs_has() {
  local t
  t="$(spl_th_token "$2")" || return 1
  yq -e "(.env.steps.\"052-gcs-workspace-docs\".workspaces // []) | any_c(. == \"$t\")" "$1" >/dev/null 2>&1
}

# SPL-1874 (owner HUM-10, poll 6c701ac9: "csitea and relishbg visible, and the
# rest not visible"): a hidden workspace stands in the PUBLIC cnf as its
# placeholder (ws-hidden-NN), mapped in the private overlay
# (csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh).
spl_th_private_lib() {
  declare -f spl_private_token >/dev/null && return 0
  # shellcheck source=/dev/null
  source "${BASH_SOURCE[0]%/*}/../../../../csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh"
}

# spl_th_token <tenant|placeholder> [new] -> what the cnf lists for it: its
# placeholder when hidden, a placeholder as is, else the slug. With "new" an
# unknown slug is HIDDEN by default (a new placeholder line in the overlay),
# except e2e* test workspaces and TENANT_VISIBLE=1; never in CI, where the
# overlay is a copy of a secret and the line would be lost.
spl_th_token() {
  local t="$1" tok
  spl_th_private_lib || return 1
  [[ "$t" =~ ^$SPL_PRIVATE_TOKEN_RE$ ]] && { printf '%s\n' "$t"; return 0; }
  tok="$(spl_private_token "$t")" || return 1
  if [[ "${2:-}" == new && "$tok" == "$t" && "${TENANT_VISIBLE:-0}" != 1 && "$t" != e2e* ]]; then
    [[ "${GITHUB_ACTIONS:-}" != true ]] ||
      { do_log "FATAL $(spl_th_mask "$t") would be a new HIDDEN workspace: add it on the operator box (overlay $(spl_private_cnf_path)), or TENANT_VISIBLE=1" >&2; return 1; }
    spl_th_overlay_box_ok "$t" || return 1
    tok="$(spl_private_add "$t")" || return 1
    do_log "INFO a new hidden workspace: $tok in the private overlay (TENANT_VISIBLE=1 to list the slug publicly)" >&2
  fi
  printf '%s\n' "$tok"
}

# spl_th_new_hidden <tenant> -> 0 when a run would add the tenant as a NEW
# hidden workspace (a new line in the private overlay): the test spl_th_token
# applies with "new".
spl_th_new_hidden() {
  local t="$1" tok
  [[ "${TENANT_VISIBLE:-0}" != 1 && "$t" != e2e* ]] || return 1
  spl_th_private_lib || return 1
  [[ "$t" =~ ^$SPL_PRIVATE_TOKEN_RE$ ]] && return 1
  tok="$(spl_private_token "$t" 2>/dev/null)" || return 0
  [[ "$tok" == "$t" ]]
}

# spl_th_overlay_box_ok <tenant> (SPL-2278): the master copy of the private
# overlay lives on ONE box (SPL_PRIVATE_MASTER_BOX, default sat: the box
# do_spl_private_overlay_pull copies from); every other box only pulls it.
# A new hidden line written on another box stayed there and the master never
# got it (2026-10-16: lane-map --check FATALed on the master box until a hand
# copy). So a new hidden workspace is refused on any other box, before any
# overlay, cnf, push or terraform step, with the commands that do it right.
spl_th_overlay_box_ok() {
  local master="${SPL_PRIVATE_MASTER_BOX:-sat}" here
  here="$(spl_desk_box_default)"
  [[ "$here" == "$master" ]] && return 0
  do_log "FATAL $1 would be a new HIDDEN workspace, and this box ($here) does not hold the master private overlay (box $master): nothing changed. Run it on box $master: cd csi-spl-orc && ENV=$ENV TENANT_ID=$1 DRY_RUN=0 ./run -a do_spl_tenant_host_provision ; then here: cd csi-spl-orc && DRY_RUN=0 FROM_BOX=$master ./run -a do_spl_private_overlay_pull (or TENANT_VISIBLE=1 for a public workspace)" >&2
  return 1
}

# spl_th_mask <text> -> the text with every hidden slug as its placeholder
# (commit messages and logs that reach the public trunk)
spl_th_mask() {
  local txt="$1" k v
  spl_th_private_lib || return 1
  [[ -s "$(spl_private_cnf_path)" ]] || { printf '%s\n' "$txt"; return 0; }
  while IFS=$'\t' read -r k v; do
    [[ -n "$v" ]] && txt="$(sed -E "s/(^|[^a-z0-9-])$v([^a-z0-9-]|\$)/\1$k\2/g" <<<"$txt")"
  done < <(spl_private_map)
  printf '%s\n' "$txt"
}

# spl_th_tenant_set <file> <add|del> <tenant>: a tenant's host AND its
# workspace docs bucket, together: env.dns.mapped_tenants and
# steps.052-gcs-workspace-docs.workspaces. ws-b's Docs answered 503 because
# provision mapped its host but never listed it for 052: no bucket (c9af31f4f).
spl_th_tenant_set() {
  spl_th_cnf_set "$1" "$2" "$3" mapped && spl_th_cnf_set "$1" "$2" "$3" docs
}

# spl_th_cnf_set <file> <add|del> <tenant> [mapped|docs]: edits the ONE
# flow-style list line in place (yq -i would drop every blank line of the
# file), then re-reads it with yq to prove the edit. No-op when already so.
#   mapped (default) `    mapped_tenants: [a, b]`
#   docs             `      workspaces: [a, b]` of `    052-gcs-workspace-docs:`
spl_th_cnf_set() {
  local f="$1" op="$2" t="$3" which="${4:-mapped}" out
  t="$(spl_th_token "$t" "$([[ "$op" == add ]] && echo new)")" || return 1
  out="$(python3 - "$f" "$op" "$t" "$which" <<'PY'
import re, sys
path, op, t, which = sys.argv[1:]
lines = open(path).read().split("\n")
if which == "docs":
    key, what = "      workspaces: [", "`      workspaces: [..]` line in `    052-gcs-workspace-docs:`"
    top = [i for i, l in enumerate(lines) if re.match(r"^    052-gcs-workspace-docs:\s*$", l)]
    rows = []
    if len(top) == 1:
        for i in range(top[0] + 1, len(lines)):
            if re.match(r"^ {0,4}\S", lines[i]):
                break
            rows.append(i)
else:
    key, what = "    mapped_tenants: [", "`    mapped_tenants: [..]` line"
    rows = range(len(lines))
hits = [i for i in rows if re.match("^" + re.escape(key) + r"[a-z0-9, -]*\]\s*$", lines[i])]
if len(hits) != 1:
    print("ERR expected exactly one %s, found %d" % (what, len(hits))); sys.exit(1)
i = hits[0]
cur = [x.strip() for x in lines[i].split("[", 1)[1].rsplit("]", 1)[0].split(",") if x.strip()]
new = [x for x in cur if x != t] + ([t] if op == "add" else [])
if op == "add" and t in cur:
    new = cur
if new == cur:
    print("same"); sys.exit(0)
lines[i] = key + ", ".join(new) + "]"
open(path, "w").write("\n".join(lines))
print("changed")
PY
)" || { do_log "FATAL cannot edit $f: $out"; return 1; }
  local has=spl_th_cnf_has lst=env.dns.mapped_tenants
  [[ "$which" == docs ]] && { has=spl_th_docs_has; lst=steps.052-gcs-workspace-docs.workspaces; }
  if [[ "$op" == add ]]; then "$has" "$f" "$t"; else ! "$has" "$f" "$t"; fi ||
    { do_log "FATAL $f: $lst $op $t did not take (yq disagrees)"; return 1; }
  do_log "INFO $lst $op $t: $out ($f)"
}

# spl_th_make <target> [VAR=value ...] -> the make target's output, ANSI
# stripped. SPL_TH_MAKE overrides the make binary (tests).
spl_th_make() {
  local target="$1"; shift
  "${SPL_TH_MAKE:-make}" -C "$PROJ_PATH" "$target" ENV="$ENV" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  return "${PIPESTATUS[0]}"
}

# spl_th_render -> renders the tfvars of every SPL_TH_STEPS step (conf-validator
# + tpl-gen containers) and proves the 019 and 052 tfvars now list every cnf
# tenant: a render that silently kept the old list would plan a no-op.
# (019's additional_fqdns is the list of tenant hosts, 052's workspaces the
# list of docs buckets.)
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
  # the same proof for 052: a tenant whose bucket the render dropped has no Docs
  tfv="$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/052-gcs-workspace-docs.vars.tfvars"
  for t in $(yq -r '(.env.steps."052-gcs-workspace-docs".workspaces // [])[]' "$(spl_th_cnf_file)"); do
    grep -E '^workspaces = ' "$tfv" | grep -F "\"$t\"" >/dev/null || { do_log "FATAL $tfv does not list workspace $t after the render"; return 1; }
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
  sum="$(grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes' <<<"$o" | sed -n 1p)"
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
    [[ $rc == 0 ]] || { printf '%s\n' "$o" | grep -E '^ *# |Plan:|Error' | sed -n 1,40p >&2; do_log "FATAL STOP $s $ENV: plan refused"; return 1; }
    printf '%s\n' "$o" | grep -E '^ *# .* will be' >&2
    o="$(spl_th_make do-provision STEP="$s")"
    grep -qE 'Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed' <<<"$o" ||
      { printf '%s\n' "$o" | tail -30 >&2; do_log "FATAL STOP $s $ENV: apply failed"; return 1; }
    do_log "OK $s $ENV: $(grep -oE 'Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed' <<<"$o" | sed -n 1p)"
  done
}

# spl_th_finish <tenant> -> waits for the Firebase custom domain (host,
# ownership, cert), probes the WUI on the host until it passes (DNS, TLS,
# HTTP 200), and records ready with its detail (or failed + why). The apex
# tenant has no custom domain: its host https://<fqdn> is only probed. A host
# that was not ready before is announced (spl_th_notify_ready).
spl_th_finish() {
  local t="$1" host="$1.$SPL_FQDN" what
  if spl_th_is_apex "$(spl_th_cnf_file)" "$t"; then
    host="$SPL_FQDN"; what="apex https://$host (the apex tenant has no subdomain), WUI probe verified TLS"
  else
    what="https://$host firebase $SPL_ORG_APP-$ENV-site cert issued, WUI probe verified TLS"
    # CERT_PROPAGATING passes here: the WUI probe below verifies the served cert
    if ! ( DOMAIN="$host" TIMEOUT_SECONDS="${CERT_TIMEOUT_SECONDS:-3600}" ACCEPT_PROPAGATING=1 do_spl_wait_for_firebase_domain ); then
      spl_th_mark_one "$t" failed "firebase custom domain $host not active (host/ownership/cert)"; return 1
    fi
  fi
  local deadline=$(($(date +%s) + ${PROBE_TIMEOUT_SECONDS:-1200}))
  until ( HOST="$host" do_spl_probe_wui_host ); do
    if [[ $(date +%s) -ge $deadline ]]; then
      spl_th_mark_one "$t" failed "probe of $host did not pass"; return 1
    fi
    do_log "INFO $host does not answer yet (edge propagation); retrying in ${PROBE_POLL_SECONDS:-30}s"
    sleep "${PROBE_POLL_SECONDS:-30}"
  done
  SPL_TH_PREV=""
  spl_th_mark_one "$t" ready "$what $(date -u +%FT%TZ)" || return 1
  do_log "OK tenant host $host is served (custom domain, records, cert, WUI probe)"
  [[ "$SPL_TH_PREV" == ready ]] || spl_th_notify_ready "$t" "$host"
  return 0
}

# spl_th_notify_ready <tenant> <host> (dispatch c7b6e8db, option 7): ONE line
# into the fleet's t1 channel cnf env.tenant_hosts.notify_channel, posted by
# the dispatch lease master's desk (do_spl_desk_post; env, tenant, agent and
# box from <spool root>/dispatch/lease.conf), naming the workspace's owner(s)
# and the fleet owner (ASKS_OWNER). Unset channel, no lease.conf or a refused
# post is logged, never a failure: the host IS ready.
spl_th_notify_ready() {
  local t="$1" host="$2" ch owners lc="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf"
  [[ "${TH_NOTIFY:-1}" == 1 ]] || { do_log "INFO TH_NOTIFY=0: $host ready, not announced"; return 0; }
  ch="$(spl_th_merged_get "$(spl_th_cnf_file)" '.env.tenant_hosts.notify_channel')"
  [[ -n "$ch" ]] || { do_log "INFO no env.tenant_hosts.notify_channel in cnf: $host ready, not announced"; return 0; }
  [[ -r "$lc" ]] || { do_log "WARN $host ready, not announced: no $lc (the lease master posts it)"; return 0; }
  local lenv ltenant master box cc
  lenv="$(_spl_th_lease LEASE_ENV "$lc")"; ltenant="$(_spl_th_lease LEASE_TENANT "$lc")"
  master="$(_spl_th_lease LEASE_MASTER "$lc")"; box="$(_spl_th_lease LEASE_DESK_BOX "$lc")"
  cc="$(_spl_th_lease ASKS_OWNER "$lc")"
  [[ -n "$lenv" && -n "$ltenant" && -n "$master" ]] || { do_log "WARN $host ready, not announced: $lc lacks LEASE_ENV / LEASE_TENANT / LEASE_MASTER"; return 0; }
  owners="$(spl_th_owners "$t")"
  local body="$ENV: workspace **$t** is live at https://$host (certificate + WUI probe ok). Owner: ${owners:-none (no biz_owner or admin member)}${cc:+, cc $cc}"
  # a clean cnf for the lease env: this run's exported SPL_* (state dir, cnf,
  # hub) and its pinned account are the HOST's env, and made a dev run's post
  # look for the prd desk under the dev state dir (dev demo 2026-10-07)
  local post="${SPL_TH_NOTIFY_FN:-do_spl_desk_post}"
  if ( unset "${!SPL_@}" GCP_ACCOUNT CLOUDSDK_CONFIG; ENV="$lenv" TENANT_ID="$ltenant" DESK_AGENT="$master" DESK_BOX="$box" DESK_CHANNEL="$ch" DESK_BODY="$body" DRY_RUN=0 \
      "$post" ) >/dev/null; then
    do_log "OK announced in $ltenant #$ch as $master: $body"
  else
    do_log "WARN $host ready, the notice was NOT posted; post it with: ENV=$lenv TENANT_ID=$ltenant DESK_AGENT=$master DESK_CHANNEL=$ch DESK_BODY='$body' DRY_RUN=0 ./run -a do_spl_desk_post"
  fi
  return 0
}

# _spl_th_lease <KEY> <lease.conf>: one value, read, never sourced
_spl_th_lease() {
  sed -n "s/^$1=\([A-Za-z0-9_.-]*\)\$/\1/p" "$2" 2>/dev/null | tail -1
}

# spl_th_merged_get <env cnf> <yq path>: the value with all.env.yaml merged under
spl_th_merged_get() {
  yq eval-all ". as \$i ireduce ({}; . * \$i) | ($2 // \"\")" "$(dirname "$1")/all.env.yaml" "$1"
}

# spl_th_owners <tenant> -> the tenant's owner HUM ids (space separated): its
# biz_owner members (047 W1: the buyer), else its admins; read as the env SA;
# empty with MARK_DB=0 or when the read fails
spl_th_owners() {
  [[ "${MARK_DB:-1}" == 1 ]] || return 0
  spl_via_proxy _spl_th_owners_sql "$1" 2>/dev/null | sed -n 's/^owner //p' | tr '\n' ' ' | sed 's/ $//'
}

_spl_th_owners_sql() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -v t="$1" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT 'owner', human_id FROM tenant_memberships
 WHERE tenant_id = :'t'
   AND role = CASE WHEN EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = :'t' AND role = 'biz_owner')
                   THEN 'biz_owner' ELSE 'admin' END
 ORDER BY human_id;
ROLLBACK;
SQL
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
# Sets SPL_TH_PREV to the status the row had before (none: no row).
spl_th_mark_one() {
  [[ "${MARK_DB:-1}" == 1 ]] || { do_log "INFO MARK_DB=0: tenant_hosts $1 -> $2 not written"; return 0; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  local out
  out="$(spl_via_proxy _spl_th_mark_sql "$1" "$2" "$3")" ||
    { do_log "WARN tenant_hosts $1 -> $2 not written"; return 1; }
  SPL_TH_PREV="$(awk '$1 == "prev" { print $2 }' <<<"$out" | tail -1)"
  do_log "INFO tenant_hosts $1 ${SPL_TH_PREV:-none} -> $2${3:+ ($3)}"
}

_spl_th_mark_sql() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -v t="$1" -v s="$2" -v d="$3" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
WITH prev AS (SELECT status FROM tenant_hosts WHERE tenant_id = :'t' FOR UPDATE),
     up AS (INSERT INTO tenant_hosts (tenant_id, status, detail, updated_at) VALUES (:'t', :'s', :'d', now())
              ON CONFLICT (tenant_id) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail, updated_at = now()
            RETURNING 1)
SELECT 'prev', coalesce((SELECT status FROM prev), 'none'), (SELECT count(*) FROM up);
COMMIT;
SQL
}
