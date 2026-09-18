# Only when the zone for fqdn is a Cloud DNS zone (dns_managed_zone set), in
# dns_zone_project (default: this project; dev writes into the prd zone). Otherwise nothing is created here and
# dns_records_to_create lists what to add wherever the zone lives.
locals {
  manage_dns  = var.dns_managed_zone != ""
  dns_project = var.dns_zone_project != "" ? var.dns_zone_project : var.gcp_project
  acme        = google_certificate_manager_dns_authorization.hub.dns_resource_record[0]
}

resource "google_dns_record_set" "acme_challenge" {
  count = local.manage_dns ? 1 : 0

  project      = local.dns_project
  managed_zone = var.dns_managed_zone
  name         = local.acme.name
  type         = local.acme.type
  ttl          = 300
  rrdatas      = [local.acme.data]
}

resource "google_dns_record_set" "hub" {
  for_each = local.manage_dns ? toset(["${var.fqdn}.", "*.${var.fqdn}."]) : toset([])

  project      = local.dns_project
  managed_zone = var.dns_managed_zone
  name         = each.value
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.hub.address]
}
