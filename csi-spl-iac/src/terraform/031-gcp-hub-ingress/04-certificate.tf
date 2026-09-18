# One Google-managed certificate for <fqdn> AND *.<fqdn>: every tenant is
# <tenant>.<fqdn>, so the name set is open-ended and only a wildcard covers it.
# Classic google_compute_managed_ssl_certificate cannot issue a wildcard;
# Certificate Manager can, with DNS authorization: the CNAME in the
# dns_authorization output must exist before the certificate goes ACTIVE
# (06-dns.tf creates it when dns_managed_zone is set, otherwise add it by hand).
resource "google_certificate_manager_dns_authorization" "hub" {
  name        = "${local.name_prefix}-dnsauth"
  project     = var.gcp_project
  description = "ACME DNS-01 authorization for ${var.fqdn} and *.${var.fqdn}"
  domain      = var.fqdn

  labels = {
    org = var.org
    app = var.app
    env = var.env
  }
}

resource "google_certificate_manager_certificate" "hub" {
  name        = "${local.name_prefix}-cert"
  project     = var.gcp_project
  description = "${var.fqdn} + *.${var.fqdn}"
  scope       = "DEFAULT"

  managed {
    domains            = [var.fqdn, "*.${var.fqdn}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.hub.id]
  }

  labels = {
    org = var.org
    app = var.app
    env = var.env
  }
}

resource "google_certificate_manager_certificate_map" "hub" {
  name        = "${local.name_prefix}-certmap"
  project     = var.gcp_project
  description = "The hub load balancer's certificates"
}

# PRIMARY: served for every SNI name, the apex and every tenant alike.
resource "google_certificate_manager_certificate_map_entry" "hub" {
  name         = "${local.name_prefix}-certmap-primary"
  project      = var.gcp_project
  map          = google_certificate_manager_certificate_map.hub.name
  certificates = [google_certificate_manager_certificate.hub.id]
  matcher      = "PRIMARY"
}

# EXTRA HOSTS (<label>.<base_domain>, e.g. api / dev.api): one DNS
# authorization + certificate each, served by a HOSTNAME cert-map entry. Added
# beside the primary, never folded into it: changing the primary's domains
# would replace the certificate the tenants are served. The url map's default
# service already routes every host to the hub.
locals {
  extra_hosts = { for l in var.extra_host_labels : replace(l, ".", "-") => "${l}.${var.base_domain}" }
}

resource "google_certificate_manager_dns_authorization" "extra" {
  for_each = local.extra_hosts

  name        = "${local.name_prefix}-${each.key}-dnsauth"
  project     = var.gcp_project
  description = "ACME DNS-01 authorization for ${each.value}"
  domain      = each.value

  labels = {
    org = var.org
    app = var.app
    env = var.env
  }
}

resource "google_certificate_manager_certificate" "extra" {
  for_each = local.extra_hosts

  name        = "${local.name_prefix}-${each.key}-cert"
  project     = var.gcp_project
  description = each.value
  scope       = "DEFAULT"

  managed {
    domains            = [each.value]
    dns_authorizations = [google_certificate_manager_dns_authorization.extra[each.key].id]
  }

  labels = {
    org = var.org
    app = var.app
    env = var.env
  }
}

resource "google_certificate_manager_certificate_map_entry" "extra" {
  for_each = local.extra_hosts

  name         = "${local.name_prefix}-certmap-${each.key}"
  project      = var.gcp_project
  map          = google_certificate_manager_certificate_map.hub.name
  certificates = [google_certificate_manager_certificate.extra[each.key].id]
  hostname     = each.value
}
