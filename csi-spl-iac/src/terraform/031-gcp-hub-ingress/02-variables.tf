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

variable "base_domain" {
  type        = string
  description = "The spool domain (cnf env.dns.BASE_DOMAIN): extra_host_labels are prefixed to it."
}

variable "extra_host_labels" {
  type        = list(string)
  description = "Hosts the hub also answers on outside <fqdn> / *.<fqdn>, as <label>.<base_domain> (cnf steps.031-gcp-hub-ingress.extra_host_labels; e.g. api, dev.api). Each gets its own DNS authorization, certificate, host-matched cert-map entry and, with dns_managed_zone, its A + ACME records."
  default     = []

  validation {
    condition     = alltrue([for l in var.extra_host_labels : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", l))])
    error_message = "every extra_host_labels entry must be lower-case DNS labels, e.g. api or dev.api."
  }
}

# Spec 007 §3 (T072): the WUI behind this load balancer. Non-empty = the
# Firebase Hosting site's default host (019 output lb_origin_host, e.g.
# <site_id>.web.app): <fqdn> and *.<fqdn> then send every path EXCEPT
# hub_paths to that site (internet NEG, Host rewritten to it), and hub_paths
# to the hub as before. Empty (default) = no WUI route; every path is the hub.
variable "wui_origin_host" {
  type        = string
  description = "Firebase Hosting default host the WUI path matcher targets (cnf steps.031-gcp-hub-ingress.wui_origin_host). Empty = no WUI route."
  default     = ""

  validation {
    condition     = var.wui_origin_host == "" || can(regex("^[a-z0-9-]+[.](web[.]app|firebaseapp[.]com)$", var.wui_origin_host))
    error_message = "wui_origin_host must be empty or a Firebase default host, <site>.web.app or <site>.firebaseapp.com."
  }
}

variable "hub_paths" {
  type        = list(string)
  description = "Paths that stay on the hub when wui_origin_host is set (URL-map path_rule syntax). WebSocket /v1/ws and /v1/wui/ws are under /v1/*."
  default     = ["/v1/*", "/api/*", "/healthz", "/version"]
}

# Spec 007 §4 (Cloud Armor transition, stage 2): L7 narrowing on the hub
# backend, BEFORE the IP allowlist rules. false (default) = the policy is the
# plain M1 allowlist. true adds two deny(403) rules: a Host that is not
# <fqdn>, <tenant>.<fqdn> or an extra host, and a path outside hub_path_regex.
# Boxes are unaffected: they use https://<tenant>.<fqdn>/v1/ws.
variable "l7_narrowing" {
  type        = bool
  description = "Add the stage-2 L7 deny rules (host + path) to the hub Cloud Armor policy (cnf steps.031-gcp-hub-ingress.l7_narrowing). dev true, prd false until the owner says so."
  default     = false
}

variable "hub_path_regex" {
  type        = string
  description = "RE2 over request.path that the hub serves; anything else is 403 when l7_narrowing is on."
  default     = "^/(v1/|api/v1/|healthz$|version$)"
}

# Extra hosts (<label>.<base_domain>) sit OUTSIDE <fqdn>, so in dev (whose zone
# is the subzone dev.<domain>) their records belong in the parent apex zone,
# written on the parent project's own key (owner decision 2026-09-19; csi-rel
# 007-dns pattern). Empty (prd) = the extra records go into dns_managed_zone
# with this env's provider, exactly as before.
variable "extra_dns_managed_zone" {
  type        = string
  description = "Zone for the extra_host_labels records when it is not dns_managed_zone (cnf steps.031-gcp-hub-ingress.extra_dns_managed_zone). Empty = dns_managed_zone."
  default     = ""
}

variable "extra_dns_zone_project" {
  type        = string
  description = "Project of extra_dns_managed_zone; its own key ~/.gcp/.<org>/key-<project>.json writes there (cnf steps.031-gcp-hub-ingress.extra_dns_zone_project)."
  default     = ""
}

# Owner 2026-09-19 (WUI domains exactly as csi-rel): <fqdn> itself is the WUI's
# Firebase custom domain (019 bind_custom_domain; records written by
# do_provision_firebase_dns), so this step must not hold an A record for it.
# *.<fqdn> (tenant hosts) and the extra hosts stay on this LB until the
# API-NO-LB lane moves them.
variable "fqdn_a_record" {
  type        = bool
  description = "Write the A record <fqdn> -> this LB (cnf steps.031-gcp-hub-ingress.fqdn_a_record). false = <fqdn> belongs to Firebase Hosting."
  default     = true
}
