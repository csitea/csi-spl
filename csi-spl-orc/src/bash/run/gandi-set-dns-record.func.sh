#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Upsert one LiveDNS record. MUTATING. Dry-run unless CONFIRM=yes.
#              REFUSES apex @ A/AAAA/CNAME and www A/AAAA/CNAME (Gandi parking
#              / webredir). Tenant records are * / dev / *.dev, including the
#              wildcard A/CNAME/TXT the follow-up allows.
# @param RRSET_NAME - required: relative name (e.g. * or dev)
# @param RRSET_TYPE - required: A, CNAME, TXT, ...
# @param RRSET_VALUES - required: comma-separated rdata
# @param RRSET_TTL - optional: seconds (default 300)
# @param CONFIRM - optional: yes to apply
# @param DOMAIN - optional: override cnf env.dns.BASE_DOMAIN
# @example RRSET_NAME=* RRSET_TYPE=A RRSET_VALUES=192.0.2.10 ./run -a do_gandi_set_dns_record
# @arg --domain DOMAIN
# @arg --rrset-name RRSET_NAME
# @arg --rrset-type RRSET_TYPE
# @arg --rrset-values RRSET_VALUES
# @arg --rrset-ttl RRSET_TTL
#------------------------------------------------------------------------------
do_gandi_set_dns_record() {
  local domain name type ttl values json type_up
  domain="$(_gandi_domain)" || return 1
  name="${RRSET_NAME:?set RRSET_NAME (e.g. * or dev)}"
  type="${RRSET_TYPE:?set RRSET_TYPE (e.g. A, CNAME, TXT)}"
  ttl="${RRSET_TTL:-300}"
  values="${RRSET_VALUES:?set RRSET_VALUES=comma,separated}"
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not installed"; return 1; }

  type_up=$(printf '%s' "$type" | tr '[:lower:]' '[:upper:]')
  if [[ "$name" == "@" || "$name" == "www" ]]; then
    case "$type_up" in
      A|AAAA|CNAME)
        do_log "FATAL refusing to change ${type_up} ${name} (Gandi parking / webredir)"
        do_log "FATAL apex @ stays on Gandi parking; tenant records are * / dev / *.dev"
        return 1
        ;;
    esac
  fi

  json="$(jq -nc --arg ttl "$ttl" --arg vals "$values" \
    '{rrset_ttl: ($ttl|tonumber), rrset_values: ($vals|split(",") | map(gsub("^\\s+|\\s+$";"")))}')"

  do_log "WARNING upserting ${type} ${name}.${domain} ttl=${ttl} -> ${values}"
  if [[ "${CONFIRM:-}" != "yes" ]]; then
    do_log "INFO dry-run: re-run with CONFIRM=yes to apply. Payload: ${json}"
    return 0
  fi
  local out
  out="$(_gandi_api PUT "/livedns/domains/${domain}/records/${name}/${type}" "$json")" || return 1
  do_log "OK record ${type} ${name}.${domain} upserted: $(echo "$out" | jq -rc '.message // .' 2>/dev/null || echo "$out")"
}
