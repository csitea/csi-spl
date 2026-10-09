#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: print one workspace's agent vendor split (rdb 0109)
# @description as one line the orchestrator can read:
# @description   claude=40 grok=50 agy=10 qwen=0 mistral=0
# @description The five whole numbers (mistral: rdb 0155, spec 110) are a guideline, not a quota. They sum
# @description to 100. The hub stores them and does not refuse a spawn that
# @description drifts; spawn routing reads this line. Through the Cloud SQL
# @description proxy as the env's project service account, one SELECT, values
# @description as psql variables. Prints no secret.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @description With --kind <k> (spec 115 HUB-1, rdb 0163) it prints that task
# @description kind's row instead, the LANE_MIX_SPLIT line plus its backup:
# @description   claude=80 grok=0 agy=0 qwen=0 mistral=20 backup=mistral
# @description A kind the workspace has not set prints the cnf
# @description env.box.agent_split_by_kind row (the log says source=cnf).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param --kind <k> (optional) - specs_and_docs, tests, simple_coding,
# @param   complex_coding, i18n or secret; the picker's aliases spec, hard and
# @param   default are read as specs_and_docs, complex_coding, simple_coding
# @param SPL_SA_KEY (optional) - default the env project SA key; or set
# @param   GCP_SA_KEY_FILE, which do_gcp_pin_account reads
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_agent_split_show
# @example ENV=prd TENANT_ID=t1 ./run -a do_spl_agent_split_show
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_agent_split_show --kind complex_coding
#------------------------------------------------------------------------------
do_spl_agent_split_show() {
  local kind=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 || { do_log "FATAL --kind needs a value"; return 1; } ;;
      --kind=*) kind="${1#--kind=}"; shift ;;
      *) shift ;;
    esac
  done
  _spl_agent_split_kind "$kind" || return 1
  kind="$SPL_SPLIT_KIND"
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if [[ -n "$kind" ]]; then
    spl_via_proxy _spl_agent_split_kind_run "$tenant" "$kind"
  else
    spl_via_proxy _spl_agent_split_show_run "$tenant"
  fi
}

# _spl_agent_split_kind <k> -> SPL_SPLIT_KIND, the stored kind name (aliases
# resolved; "" stays "", the five-column split), or a FATAL for anything
# else. The six names are rdb 0163's kind CHECK.
_spl_agent_split_kind() {
  case "$1" in
    "" | specs_and_docs | tests | simple_coding | complex_coding | i18n | secret) SPL_SPLIT_KIND="$1" ;;
    spec) SPL_SPLIT_KIND=specs_and_docs ;;
    hard) SPL_SPLIT_KIND=complex_coding ;;
    default) SPL_SPLIT_KIND=simple_coding ;;
    *) do_log "FATAL --kind must be specs_and_docs, tests, simple_coding, complex_coding, i18n or secret (or spec, hard, default), got '$1'"; return 1 ;;
  esac
}

# _spl_agent_split_kind_line <source> <kind> <rows> -> the kind's line from
# "vendor|weight|is_backup" rows (one per line), checked against the spec 115
# section 2 rules a router relies on: five known vendors at most, 0..100,
# a sum of 100, one backup.
_spl_agent_split_kind_line() {
  local src="$1" kind="$2" rows="$3" v line backup="" sum=0 n
  declare -A w=([claude]=0 [grok]=0 [agy]=0 [qwen]=0 [mistral]=0)
  while IFS='|' read -r v n line; do
    [[ -z "$v" ]] && continue
    if ! [[ -n "${w[$v]+x}" && "$n" =~ ^[0-9]+$ ]] || (( n > 100 )); then
      do_log "FATAL agent split $kind ($src) has a bad row '$v|$n|$line'"; return 1
    fi
    w[$v]="$n"
    sum=$(( sum + n ))
    [[ "$line" == t || "$line" == true ]] && backup="$v"
  done <<<"$rows"
  (( sum == 100 )) || { do_log "FATAL agent split $kind ($src) sums to $sum, not 100"; return 1; }
  [[ -n "$backup" ]] || { do_log "FATAL agent split $kind ($src) names no backup"; return 1; }
  printf 'claude=%s grok=%s agy=%s qwen=%s mistral=%s backup=%s\n' \
    "${w[claude]}" "${w[grok]}" "${w[agy]}" "${w[qwen]}" "${w[mistral]}" "$backup"
}

# _spl_agent_split_kind_cnf <kind> -> the cnf env.box.agent_split_by_kind
# row as "vendor|weight|is_backup" rows; a vendor left out is 0.
_spl_agent_split_kind_cnf() {
  local kind="$1" backup kv v n seen=""
  backup="$(yq -r ".env.box.agent_split_by_kind.$kind.backup // \"\"" "$SPL_CNF")"
  kv="$(yq -r ".env.box.agent_split_by_kind.$kind // {} | to_entries[] | select(.key != \"backup\") | .key + \"|\" + (.value | tostring)" "$SPL_CNF")"
  [[ -n "$backup" && -n "$kv" ]] || { do_log "FATAL no cnf env.box.agent_split_by_kind.$kind in $SPL_CNF"; return 1; }
  while IFS='|' read -r v n; do
    [[ "$v" == "$backup" ]] && { echo "$v|$n|true"; seen=1; } || echo "$v|$n|false"
  done <<<"$kv"
  [[ -n "$seen" ]] || echo "$backup|0|true"
}

# _spl_agent_split_kind_run <tenant> <kind> -> the kind's line: the
# workspace's rows (rdb 0163), else the cnf env.box.agent_split_by_kind row.
_spl_agent_split_kind_run() {
  local tenant="$1" kind="$2" out src=workspace line
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" -v kind="$kind" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT vendor || '|' || weight::text || '|' || is_backup::text
  FROM tenant_agent_split_kind WHERE tenant_id = :'tenant' AND kind = :'kind'
 ORDER BY vendor;
ROLLBACK;
SQL
)" || { do_log "FATAL agent split $kind read of $tenant failed: ${out:-}"; return 1; }
  if [[ -z "$out" ]]; then
    src=cnf
    out="$(_spl_agent_split_kind_cnf "$kind")" || return 1
  fi
  line="$(_spl_agent_split_kind_line "$src" "$kind" "$out")" || { echo "$line"; return 1; }
  echo "$line"
  do_log "OK agent split $kind of $tenant on $SPL_SQL_CONN: $line (source=$src, read-only, as $GCP_ACCOUNT)"
}

# _spl_agent_split_show_run <tenant> -> one "claude=N grok=N agy=N qwen=N mistral=N" line.
# The tenant id travels as a psql variable. A row whose numbers are outside
# 0..100 or do not sum to 100 is a FATAL, not a line a router should trust.
_spl_agent_split_show_run() {
  local tenant="$1" out claude grok agy qwen mistral sum
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT agent_split_claude::text || '|' || agent_split_grok::text || '|' ||
       agent_split_agy::text || '|' || agent_split_qwen::text || '|' ||
       agent_split_mistral::text
  FROM tenants WHERE tenant_id = :'tenant';
ROLLBACK;
SQL
)" || { do_log "FATAL agent split read of $tenant failed: ${out:-}"; return 1; }
  if [[ "$out" =~ ([0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+) ]]; then
    claude="${BASH_REMATCH[1]}"
    grok="${BASH_REMATCH[2]}"
    agy="${BASH_REMATCH[3]}"
    qwen="${BASH_REMATCH[4]}"
    mistral="${BASH_REMATCH[5]}"
  else
    do_log "FATAL no agent split row for tenant $tenant"
    return 1
  fi
  if (( claude > 100 || grok > 100 || agy > 100 || qwen > 100 || mistral > 100 )); then
    do_log "FATAL agent split of $tenant is outside 0..100"
    return 1
  fi
  sum=$(( claude + grok + agy + qwen + mistral ))
  if (( sum != 100 )); then
    do_log "FATAL agent split of $tenant sums to $sum, not 100"
    return 1
  fi
  printf 'claude=%s grok=%s agy=%s qwen=%s mistral=%s\n' "$claude" "$grok" "$agy" "$qwen" "$mistral"
  do_log "OK agent split of $tenant on $SPL_SQL_CONN: claude=$claude grok=$grok agy=$agy qwen=$qwen mistral=$mistral (read-only, as $GCP_ACCOUNT)"
}
