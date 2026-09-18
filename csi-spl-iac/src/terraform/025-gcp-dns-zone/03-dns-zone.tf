# The env's public DNS zone. ADOPTED, never created: the registrar's NS
# delegation points at the name servers Cloud DNS assigned when the zone was
# created out of band, and a destroy + create would assign new ones and break
# the delegation. So the zone is brought into state by the import block below
# (a no-op once it is in state; a plan fails loudly if the zone is missing)
# and prevent_destroy refuses any plan that would delete or replace it.
#
# 031 writes the hub's records (ACME CNAME, <fqdn>, *.<fqdn>) into this zone
# through its dns_managed_zone / dns_zone_project.
locals {
  zones = var.zone_name == "" ? {} : { (var.zone_name) = "${var.fqdn}." }
}

import {
  for_each = local.zones
  to       = google_dns_managed_zone.env[each.key]
  id       = "projects/${var.gcp_project}/managedZones/${each.key}"
}

resource "google_dns_managed_zone" "env" {
  for_each = local.zones

  project       = var.gcp_project
  name          = each.key
  dns_name      = each.value
  description   = var.zone_description
  visibility    = "public"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}
