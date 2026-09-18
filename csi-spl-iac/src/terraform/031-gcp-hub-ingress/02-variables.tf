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

variable "service_name" {
  type        = string
  description = "The 030 Cloud Run service the load balancer fronts (cnf hub.service_name)."
}

variable "fqdn" {
  type        = string
  description = "The env's DNS name (cnf env.dns.fqdn, derived from env.dns.BASE_DOMAIN). Tenants are <tenant>.<fqdn>; the certificate covers <fqdn> and *.<fqdn>."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.fqdn))
    error_message = "fqdn must be a lower-case DNS name with at least one dot."
  }
}

variable "allowed_ip_ranges" {
  type        = list(string)
  description = "The M1 Cloud Armor allowlist (cnf steps.031-gcp-hub-ingress.allowed_ip_ranges): the source CIDRs that may reach the hub. Everything else gets 403. Empty = nobody (the default rule denies)."
  default     = []

  validation {
    condition     = alltrue([for r in var.allowed_ip_ranges : can(cidrhost(r, 0))])
    error_message = "every allowed_ip_ranges entry must be a CIDR, e.g. 203.0.113.7/32."
  }
}

variable "dns_managed_zone" {
  type        = string
  description = "A Cloud DNS managed zone that serves fqdn (in dns_zone_project). Empty (default) = the zone is not Cloud DNS: terraform creates no record, and the dns_records_to_create output names the records to add by hand."
  default     = ""
}

variable "dns_zone_project" {
  type        = string
  description = "The project holding dns_managed_zone. Empty (default) = gcp_project. dev sets the prd project: its dev.<domain> records live in the one zone 025 adopts there."
  default     = ""
}
