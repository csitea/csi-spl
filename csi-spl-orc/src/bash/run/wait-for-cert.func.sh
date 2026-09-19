#!/bin/bash
#------------------------------------------------------------------------------
# @description Poll the 031 hub-ingress Certificate Manager certificate until
# @description its Google-managed wildcard TLS cert is ACTIVE.
# @description
# @description Morph of pas-psf-orc / csi-rel-orc do_wait_for_cert (spec 033).
# @description Those trees wait on a Cloud Run domain mapping
# @description (CertificateProvisioned). This repo's 031 is an HTTPS load
# @description balancer + Certificate Manager wildcard
# @description (<env.dns.fqdn> and *.<env.dns.fqdn>), so this action describes
# @description that certificate (google_certificate_manager_certificate.hub)
# @description and treats managed.state == ACTIVE as success. terraform apply
# @description of 031 returns before the cert is issued; this is the wait.
# @description
# @description Do NOT churn DNS while this runs: replacing the ACME CNAME
# @description restarts validation.
# @description
# @description Every gcloud call passes --account and --project. Nothing writes
# @description the shared gcloud config.
# @description
# @description Do not use --format='value(status.conditions[?type=...].status)'.
# @description The [?key=value] predicate is silently empty on this gcloud SDK,
# @description whether the field is True, False or absent. A scalar path
# @description (value(managed.state)) is the read; tests drive this function
# @description with a stubbed gcloud, not a grep of the source.
# @param ENV (optional) - dev or prd: fills DOMAIN / GCP_PROJECT / CERT_NAME from cnf
# @param DOMAIN (optional) - FQDN the cert covers; default: cnf env.dns.fqdn
# @param GCP_PROJECT (optional) - project owning the cert; default: cnf env.gcp.gcp_project
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account); passed as --account on every gcloud call
# @param CERT_NAME (optional) - default: <GCP_PROJECT>-hub-cert (031 name_prefix-cert)
# @param CERT_LOCATION (optional) - Certificate Manager location (default: global)
# @param TIMEOUT_SECONDS (optional) - max wait (default: 3600)
# @param POLL_SECONDS (optional) - poll interval (default: 30)
# @prereq gcloud, and a credential for GCP_ACCOUNT already on this box
# @example ENV=dev ./run -a do_wait_for_cert
# @example DOMAIN=dev.example.test GCP_PROJECT=csi-spl-dev GCP_ACCOUNT=<OPERATOR>@example.com ./run -a do_wait_for_cert
# @arg --env ENV
# @arg --domain DOMAIN
# @arg --gcp-project GCP_PROJECT
# @arg --gcp-account GCP_ACCOUNT
# @arg --cert-name CERT_NAME
# @arg --cert-location CERT_LOCATION
# @arg --timeout-seconds TIMEOUT_SECONDS
# @arg --poll-seconds POLL_SECONDS
#------------------------------------------------------------------------------
do_wait_for_cert() {
  do_require_bin gcloud || return $?

  local domain="${DOMAIN:-}"
  local project="${GCP_PROJECT:-}"
  local account=""
  local cert="${CERT_NAME:-}"
  local location="${CERT_LOCATION:-global}"
  local timeout="${TIMEOUT_SECONDS:-3600}"
  local poll="${POLL_SECONDS:-30}"

  if [[ -z "$domain" || -z "$project" || -z "$cert" ]]; then
    if [[ -n "${ENV:-}" ]] && declare -f do_spl_cloud_cnf >/dev/null; then
      do_spl_cloud_cnf || return 1
      domain="${domain:-$SPL_FQDN}"
      project="${project:-$SPL_PROJECT}"
      cert="${cert:-${SPL_ORG_APP}-${ENV}-hub-cert}"
    fi
  fi
  [[ -n "$cert" ]] || cert="${project:+${project}-hub-cert}"

  if [[ -z "$domain" ]]; then
    do_log "FATAL DOMAIN is required (or set ENV=dev|prd to read env.dns.fqdn from cnf)"
    return 1
  fi
  if [[ -z "$project" ]]; then
    do_log "FATAL GCP_PROJECT is required (or set ENV=dev|prd to read env.gcp.gcp_project from cnf)"
    return 1
  fi
  # every gcloud call carries --account; nothing writes the shared gcloud config
  do_gcp_pin_account "${SPL_CNF:-}" || return 1
  account="$GCP_ACCOUNT"
  if [[ -z "$cert" ]]; then
    do_log "FATAL CERT_NAME is required (default is <GCP_PROJECT>-hub-cert)"
    return 1
  fi

  do_log "INFO waiting for Certificate Manager cert $cert (domain=$domain project=$project account=$account location=$location timeout=${timeout}s poll=${poll}s)"

  local deadline=$(($(date +%s) + timeout))
  local attempt=0
  local status
  while :; do
    attempt=$((attempt + 1))

    status=$(gcloud certificate-manager certificates describe "$cert" \
      --location="$location" \
      --project="$project" \
      --account="$account" \
      --format='value(managed.state)' \
      2>/dev/null | tr -d '\r' | awk 'NF { print $1; exit }')

    if [[ "$status" == "ACTIVE" ]]; then
      do_log "INFO cert ACTIVE for $domain ($cert) after $attempt attempt(s)"
      do_log "INFO verify it is the RIGHT cert, not the edge default, with:"
      do_log "INFO   echo | openssl s_client -connect ${domain}:443 -servername ${domain} 2>/dev/null | openssl x509 -noout -subject -issuer"
      return 0
    fi

    if [[ $(date +%s) -ge $deadline ]]; then
      do_log "FATAL cert not ACTIVE for $domain ($cert) after ${timeout}s (last state='${status:-empty}')"
      do_log "FATAL an empty state usually means the certificate itself is absent -- check with:"
      do_log "FATAL   gcloud certificate-manager certificates list --location=$location --project=$project --account=$account"
      return 1
    fi

    do_log "INFO attempt=$attempt cert_state='${status:-pending}' -- sleeping ${poll}s"
    sleep "$poll"
  done
}
