# 005-gcp-domain-verification step vars.
#
# Cloud Run domain mapping (in csi-spl-dev, csi-spl-prd) requires
# the SA performing the mapping to be a *verified owner* of the parent domain
# (<BASE_DOMAIN>). Google's site-verification API offers two DNS-based proofs:
#   DNS_TXT   -> place a TXT record at <BASE_DOMAIN>   (collides with an apex SPF
#                TXT record, which we own elsewhere; avoided here)
#   DNS_CNAME -> place a unique CNAME at <token>.<BASE_DOMAIN> that points to
#                <token>.dv.googlehosted.com (per-project unique, no collision)
#
# We use DNS_CNAME: each non-prd project supplies its (source, target) pair,
# obtained once via the siteVerification REST API (the public gcloud CLI
# does NOT expose webresource subcommands -- see runbook in
# csi-spl-doc/specs/010-orc-deploy/spec.md; csi-spl: ./run -a do_spl_domain_verify). Summary:
#   - POST https://www.googleapis.com/siteVerification/v1/token
#     with Bearer token from
#     gcloud auth print-access-token --scopes=...siteverification
#     returns {method:DNS_CNAME, token:"<src-prefix> <target-host>"}.
#   - Add the (source, target) pair to <env>.env.yaml under
#     steps.005-gcp-domain-verification.verification_records and apply 005.
#   - After DNS propagates, POST .../v1/webResource?verificationMethod=DNS_CNAME
#     with the same Bearer token to finalise ownership.
#
# verification_records is empty by default -- an env that doesn't need
# verification leaves the list empty and the step is a no-op. csi-spl: BOTH
# csi-spl-dev@ and csi-spl-prd@ need it (measured 2026-09-19: `gcloud domains
# list-user-verified` empty for each); the zone is 025's apex zone in csi-spl-prd.
variable "verification_records" {
  type = list(object({
    source = string # left-hand CNAME name, e.g. <token>.<BASE_DOMAIN>.
    target = string # right-hand target,    e.g. <token>.dv.googlehosted.com.
  }))
  description = "Per-project Google site-verification DNS_CNAME records placed in the prd zone."
  default     = []
}

variable "tld_domain" {
  type        = string
  description = "Top-level domain being verified (e.g. <BASE_DOMAIN>)."
}

variable "prd_zone_name" {
  type        = string
  description = "Cloud DNS managed-zone name that owns the tld_domain (csi-spl: 025-gcp-dns-zone's apex zone)."
}

variable "parent_zone_project" {
  type        = string
  description = "GCP project that owns prd_zone_name (e.g. csi-spl-prd)."
}
