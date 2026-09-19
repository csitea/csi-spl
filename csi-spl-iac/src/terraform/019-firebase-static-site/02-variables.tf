variable "org" {
  type        = string
  description = "The 3-letter organisation code (csi)."
}

variable "app" {
  type        = string
  description = "The application code (spl)."
}

variable "env" {
  type        = string
  description = "The environment: dev or prd (lde is local docker only, never terraform)."

  validation {
    condition     = contains(["dev", "prd"], var.env)
    error_message = "env must be dev or prd."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id, csi-spl-<env>."
}

variable "gcp_region" {
  type        = string
  description = "The GCP region every resource of the spool lives in."
  default     = "europe-north1"
}

variable "fqdn" {
  type        = string
  description = "Custom domain bound to this Hosting site. MUST come from cnf env.dns.fqdn (the env product host). Never a hostname literal in this step."
}

variable "site_id" {
  type        = string
  description = "Firebase Hosting site ID (cnf steps.019-firebase-static-site.site_id)."

  validation {
    condition     = can(regex("^csi-spl-(dev|prd)-site$", var.site_id))
    error_message = "site_id must be csi-spl-dev-site or csi-spl-prd-site."
  }
}

# Spec 007 §3 (T072, decided): the WUI is served THROUGH the 031 load balancer
# (a path matcher sends every non-hub path to this site as an internet NEG),
# so the product hosts stay on the LB certificate and are NOT Firebase custom
# domains. false (default) = no custom-domain resource at all; true binds
# var.fqdn (+ additional_fqdns) straight to Firebase, which only makes sense
# for a host whose DNS points at Firebase instead of the hub LB.
variable "bind_custom_domain" {
  type        = bool
  default     = false
  description = "Bind var.fqdn and additional_fqdns as Firebase custom domains (cnf steps.019-firebase-static-site.bind_custom_domain). Default false: the 031 LB fronts the site."
}

variable "cert_preference" {
  type        = string
  default     = "GROUPED"
  description = "GROUPED / PROJECT_GROUPED / DEDICATED."

  validation {
    condition     = contains(["GROUPED", "PROJECT_GROUPED", "DEDICATED"], var.cert_preference)
    error_message = "cert_preference must be GROUPED, PROJECT_GROUPED, or DEDICATED."
  }
}

variable "wait_dns_verification" {
  type        = bool
  default     = false
  description = "First apply: false (records not yet in place). Re-apply with true after DNS records exist if apply should block on the cert."
}

# Extra custom domains on the SAME Hosting site. Empty for spool: the env
# product host is var.fqdn; tenant hosts stay on the hub mapping (031). Do
# not copy shop www/apex pairs here.
variable "additional_fqdns" {
  type        = list(string)
  description = "Further custom domains bound to this site. Default empty."
  default     = []

  validation {
    condition     = length(var.additional_fqdns) == length(distinct(var.additional_fqdns))
    error_message = "additional_fqdns must not repeat a domain."
  }
}
