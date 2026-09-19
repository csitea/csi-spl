#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Materialise every DNS record Firebase Hosting needs for the
#              custom domain bound to the given env. Queries the Firebase
#              Hosting REST API live (not TF state — which goes stale because
#              cert verification records are emitted after the first apply)
#              and upserts the matching record-sets into the GCP-managed zone.
#
#              Handles the apex-CNAME -> A swap because Cloud DNS forbids
#              CNAME at a zone apex. When swapped, also emits a
#              "hosting-site=<site_id>" TXT for ownership proof — the same
#              pattern Firebase auto-paired with the A record on the apex zone.
#
# @example  ENV=dev DNS_ZONE=subzone-csi-rel-dev DNS_ZONE_PROJECT=csi-rel-dev \
#             ./run -a do_provision_firebase_dns
#           ENV=prd DNS_ZONE=<cnf dns.tld_zone_name> DNS_ZONE_PROJECT=csi-rel-prd \
#             FQDN=relishbg.com ./run -a do_provision_firebase_dns
#------------------------------------------------------------------------------
do_provision_firebase_dns() {
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${DNS_ZONE_PROJECT:-<unset>}" "${account}" "do_provision_firebase_dns"


  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_var ENV              "${ENV:-}"
  do_require_var DNS_ZONE         "${DNS_ZONE:-}"
  do_require_var DNS_ZONE_PROJECT "${DNS_ZONE_PROJECT:-}"

  # Use APP_PATH basename ("csi-rel") rather than ${ORG}-${APP} since the
  # run.sh dialects disagree on what APP holds.
  local org_app
  org_app=$(basename "${APP_PATH}")

  # Firebase Hosting project: tst shares csi-rel-dev; everyone else owns theirs.
  local fb_proj
  case "${ENV}" in
    tst) fb_proj="${FIREBASE_PROJECT:-${org_app}-dev}" ;;
    *)   fb_proj="${FIREBASE_PROJECT:-${org_app}-${ENV}}" ;;
  esac

  local site_id="${SITE_ID:-${org_app}-${ENV}-site}"

  # Default FQDN derived from env: prd is the apex, others are <env>.<apex>.
  # The apex is taken from the DNS zone's dnsName when not passed in.
  local zone_apex
  zone_apex=$(gcloud dns managed-zones describe "${DNS_ZONE}" \
    --project="${DNS_ZONE_PROJECT}" \
    --format="value(dnsName)" \
    --account="${account}" 2>/dev/null | sed "s/\.$//")
  [[ -n "${zone_apex}" ]] || quit_on "DNS zone ${DNS_ZONE} not found in project ${DNS_ZONE_PROJECT}"

  local fqdn="${FQDN:-${zone_apex}}"

  # Auth: use the env's SA key for both Firebase REST API and gcloud DNS writes.
  local sa_key="${HOME}/.gcp/.${ORG}/key-${fb_proj}.json"
  [[ -f "${sa_key}" ]] || quit_on "SA key not found: ${sa_key} — run do_gcp_000_bootstrap_gcp_env first"

  local access_token
  access_token=$(GOOGLE_APPLICATION_CREDENTIALS="${sa_key}" \
    gcloud auth application-default print-access-token 2>/dev/null \
    || gcloud auth print-access-token --account="${account}" 2>/dev/null)
  [[ -n "${access_token}" ]] || quit_on "could not obtain a GCP access token"

  do_log "INFO Firebase live state — project=${fb_proj} site=${site_id} fqdn=${fqdn} zone=${DNS_ZONE} apex=${zone_apex}"

  local api_resp
  api_resp=$(curl -sS -H "Authorization: Bearer ${access_token}" \
    "https://firebasehosting.googleapis.com/v1beta1/projects/${fb_proj}/sites/${site_id}/customDomains/${fqdn}")

  if echo "${api_resp}" | grep -q "\"error\""; then
    echo "${api_resp}"
    quit_on "Firebase REST API returned an error for ${fb_proj}/${site_id}/${fqdn}"
  fi

  # Extract every desired record from both:
  #   requiredDnsUpdates.desired[].records[]            (host routing)
  #   cert.verification.dns.desired[].records[]         (ACME cert challenge)
  # Apply the apex-CNAME -> A swap. Emit hosting-site TXT alongside the A
  # for ownership proof (Firebase keys ownership off this when the A path
  # is used instead of CNAME). Output is TSV: type<TAB>fqdn<TAB>rdata.
  local rows
  # the python heredoc needs ZONE_APEX in env to compare against
  rows=$(ZONE_APEX="${zone_apex}" SITE_ID="${site_id}" python3 -c "$(cat <<'PYINLINE'
import json, os, sys
APEX_IP   = "199.36.158.100"
HOSTING_SITE_FMT = "hosting-site={site}"
data = json.loads(sys.stdin.read())
site = "{}".format(os.environ.get("SITE_ID", ""))
apex = "{}".format(os.environ.get("ZONE_APEX", ""))

def emit(rt, name, rdata):
    print(f"{rt}\t{name}\t{rdata}")

def walk(updates):
    for u in (updates or []):
        for r in u.get("records", []):
            yield r

for r in walk((data.get("requiredDnsUpdates") or {}).get("desired", [])):
    rt = r.get("type"); name = r.get("domainName", ""); rdata = r.get("rdata", "")
    if not (rt and rdata): continue
    if rt == "CNAME" and name == apex:
        emit("A",   name, APEX_IP)
        emit("TXT", name, HOSTING_SITE_FMT.format(site=site))
    else:
        emit(rt, name, rdata)

for r in walk(((data.get("cert") or {}).get("verification") or {}).get("dns", {}).get("desired", [])):
    rt = r.get("type"); name = r.get("domainName", ""); rdata = r.get("rdata", "")
    if rt and rdata:
        emit(rt, name, rdata)
PYINLINE
)" <<<"${api_resp}")

  if [[ -z "${rows}" ]]; then
    do_log "INFO Firebase reports no DNS updates needed for ${fqdn}"
    return 0
  fi

  do_log "INFO records to upsert in zone ${DNS_ZONE} (project ${DNS_ZONE_PROJECT}):"
  printf "%s\n" "${rows}" | column -t -s $'\t' >&2

  # Upsert each record. For TXT rrsets that already exist (SPF on apex etc.),
  # union with existing values to avoid clobbering.
  while IFS=$'\t' read -r rec_type rec_fqdn rec_rdata; do
    [[ -z "${rec_type}" ]] && continue

    # CNAME at zone apex would've already been swapped above; defensive double-check.
    if [[ "${rec_type}" == "CNAME" && "${rec_fqdn}" == "${zone_apex}" ]]; then
      do_log "INFO defensive apex-CNAME swap: ${rec_fqdn} -> A ${rec_rdata}"
      rec_type="A"; rec_rdata="199.36.158.100"
    fi

    # FQDN-normalise hostname-style rdata
    case "${rec_type}" in
      CNAME|NS|MX|SRV|PTR)
        [[ "${rec_rdata}" != *. ]] && rec_rdata="${rec_rdata}."
        ;;
    esac

    # Union with existing rrset (preserves SPF when adding hosting-site TXT)
    local existing merged
    existing=$(gcloud dns record-sets describe "${rec_fqdn}." \
      --type="${rec_type}" --zone="${DNS_ZONE}" --project="${DNS_ZONE_PROJECT}" \
      --format="value(rrdatas)" \
      --account="${account}" 2>/dev/null || true)
    # TXT rdata round-trips with surrounding double-quotes when gcloud reads
    # it back. Strip those before dedup so we don't try to "add" a value that
    # is already present, just unquoted.
    merged=$(
      { printf "%s\n" "${existing}" | tr ";" "\n"
        printf "%s\n" "${rec_rdata}"
      } \
        | awk "NF" \
        | sed -E 's/^"(.*)"$/\1/' \
        | sort -u \
        | paste -sd, -
    )

    do_log "INFO upsert ${rec_type} ${rec_fqdn}. -> ${merged}"

    gcloud dns record-sets delete "${rec_fqdn}." --type="${rec_type}" \
      --zone="${DNS_ZONE}" --project="${DNS_ZONE_PROJECT}" --quiet \
      --account="${account}" 2>/dev/null || true
    gcloud dns record-sets create "${rec_fqdn}." --type="${rec_type}" \
      --ttl=300 --rrdatas="${merged}" \
      --zone="${DNS_ZONE}" --project="${DNS_ZONE_PROJECT}" --quiet \
 \
      --account="${account}"      || quit_on "creating ${rec_type} record for ${rec_fqdn}"
  done <<< "${rows}"

  do_log "INFO Firebase will async-verify; cert provisioning typically completes within ~10-60 min after DNS propagation."
  do_log "INFO ===> NEXT: re-run do_deploy_static_site for ENV=${ENV} from csi-rel-orc."
  do_log "INFO      A fresh release after DNS bind issues a CDN purge — without it"
  do_log "INFO      browsers may hit a 1h-cached \"Site Not Found\" at the Fastly edge."
}
