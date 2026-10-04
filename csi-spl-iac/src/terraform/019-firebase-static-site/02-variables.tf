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
  description = "The environment: a cnf env name, e.g. dev or prd (lde is local docker only, never terraform)."

  validation {
    # spec 072 A8: the env names are the cnf's <env>.env.yaml files, not a
    # fixed pair; lde is local docker only and never reaches terraform.
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.env)) && var.env != "lde"
    error_message = "env must be a cnf env name (<env>.env.yaml: 2-10 lowercase letters or digits, a letter first), never lde."
  }
}

variable "gcp_project" {
  type        = string
  description = "The GCP project id: cnf env.gcp.gcp_project (by default <org>-<app>-<env>)."
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
    condition     = can(regex("^[a-z0-9][a-z0-9-]{4,28}[a-z0-9]$", var.site_id))
    error_message = "site_id must be a Firebase Hosting site id: 6-30 lowercase letters, digits or -, a letter or digit at each end. Site ids are GLOBAL across every Firebase project (a taken one fails at apply): derive it from env.gcp.gcp_project in cnf."
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

# Hosts that only REDIRECT to var.fqdn (owner 2026-09-29, topic e802196b: "you
# should fix the infra too" - www.<apex> had no DNS). Each is a Firebase custom
# domain with redirect_target = var.fqdn: Hosting answers 301 to https://<fqdn>,
# keeping path and query. Its DNS (A + TXT hosting-site) is 025's, rendered from
# the same cnf list env.dns.redirect_hosts.
variable "redirect_fqdns" {
  type        = list(string)
  description = "Custom domains that 301-redirect to var.fqdn (cnf env.dns.redirect_hosts, e.g. www). Default empty."
  default     = []

  validation {
    condition     = length(var.redirect_fqdns) == length(distinct(var.redirect_fqdns))
    error_message = "redirect_fqdns must not repeat a domain."
  }
}
