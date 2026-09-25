# 032-gcp-cloud-run-domain-mapping step vars: csi-rel's
# 031-gcp-cloud-run-domain-mapping, copied unchanged (the number differs only
# because csi-spl's 031 was the hub LB it replaces; owner 2026-09-19).
#
# Scope:  ONLY the domain mapping resource(s) for the hub Cloud Run service
# in this env. The service itself is 030-cloud-run-hub; this step owns the
# mappings: api./dev.api.<BASE_DOMAIN> and one per tenant host.
#
# Provisioning order assumed:
#   025-gcp-dns-zone (CNAMEs/A/AAAA)
#   -> 005-gcp-domain-verification (per-project ownership)
#   -> 030-cloud-run-hub        (service exists)
#   -> 032-gcp-cloud-run-domain-mapping  (this step)
#   -> ./run -a do_spl_wait_for_mapping_cert (async cert wait)

variable "cloud_run_service_name" {
  type        = string
  description = "Name of the existing Cloud Run v2 service (e.g. csi-spl-hub-dev). Created out-of-band by the deploy workflow."
}

variable "cloud_run_custom_domain" {
  type        = string
  description = "Primary custom domain to map onto the service (e.g. dev.api.<BASE_DOMAIN>). Empty string skips the mapping."
  default     = ""
}

variable "cloud_run_additional_domains" {
  type        = list(string)
  description = "Additional domain aliases mapped to the same service (e.g. [\"prd.api.<BASE_DOMAIN>\"] in prd)."
  default     = []
}
