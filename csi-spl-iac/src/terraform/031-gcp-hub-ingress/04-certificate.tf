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
