# The env's public DNS zone. Two shapes, chosen by cnf (csi-rel 007-dns flow:
# registrar -> prd apex zone -> env subzones; apply prd -> dev, destroy dev -> prd):
#
# prd (parent_zone_name = ""): the apex zone is ADOPTED, never created. The
#   registrar's NS delegation points at the name servers Cloud DNS assigned when
#   the zone was created out of band; a destroy + create would assign new ones
#   and break the delegation. So it is brought into state by the import block
#   (a no-op once in state) and prevent_destroy refuses any delete or replace.
#
# dev (parent_zone_name set): the env subzone <fqdn> (dev.<domain>) is CREATED
#   in this env's project, and an NS record for it is written into the parent
#   (prd apex) zone through the "parent" provider, which runs on the parent
#   project's own key: the dev key has no rights in csi-spl-prd (owner decision
#   2026-09-19, which replaced dev records living in the prd zone). A recreate
#   of the subzone is safe: the delegation record follows its name servers.
#
# 031 writes the hub's records (ACME CNAME, <fqdn>, *.<fqdn>) into this zone.
locals {
  subzone = var.parent_zone_name != ""
  zones   = var.zone_name == "" || local.subzone ? {} : { (var.zone_name) = "${var.fqdn}." }
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

resource "google_dns_managed_zone" "sub" {
  count = local.subzone && var.zone_name != "" ? 1 : 0

  project       = var.gcp_project
  name          = var.zone_name
  dns_name      = "${var.fqdn}."
  description   = var.zone_description
  visibility    = "public"
  force_destroy = false
}

resource "google_dns_record_set" "delegation" {
  count    = length(google_dns_managed_zone.sub)
  provider = google.parent

  project      = var.parent_zone_project
  managed_zone = var.parent_zone_name
  name         = "${var.fqdn}."
  type         = "NS"
  ttl          = 21600
  rrdatas      = google_dns_managed_zone.sub[0].name_servers
}
