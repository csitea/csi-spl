# Only when the zone for fqdn is a Cloud DNS zone (dns_managed_zone set), in
# dns_zone_project (default: this project; dev writes into the prd zone). Otherwise nothing is created here and
# dns_records_to_create lists what to add wherever the zone lives.
locals {
  manage_dns  = var.dns_managed_zone != ""
  dns_project = var.dns_zone_project != "" ? var.dns_zone_project : var.gcp_project
  acme        = google_certificate_manager_dns_authorization.hub.dns_resource_record[0]

  # Extra hosts sit outside <fqdn>: in dev (zone = the dev.<domain> subzone)
  # their records live in the parent apex zone and are written by the "extra"
  # provider on that project's key; prd leaves both empty = same zone, same
  # project, same identity as before (a provider switch, no diff).
  extra_zone    = var.extra_dns_managed_zone != "" ? var.extra_dns_managed_zone : var.dns_managed_zone
  extra_project = var.extra_dns_zone_project != "" ? var.extra_dns_zone_project : local.dns_project
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

resource "google_dns_record_set" "extra_acme" {
  for_each = local.manage_dns ? local.extra_hosts : {}
  provider = google.extra

  project      = local.extra_project
  managed_zone = local.extra_zone
  name         = google_certificate_manager_dns_authorization.extra[each.key].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.extra[each.key].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.extra[each.key].dns_resource_record[0].data]
}

resource "google_dns_record_set" "extra" {
  for_each = local.manage_dns ? local.extra_hosts : {}
  provider = google.extra

  project      = local.extra_project
  managed_zone = local.extra_zone
  name         = "${each.value}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.hub.address]
}
