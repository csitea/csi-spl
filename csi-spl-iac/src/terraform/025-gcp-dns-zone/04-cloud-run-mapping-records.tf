# DNS records for the Cloud Run domain mappings (step 032), as csi-rel
# 007-dns/05.03.api-dns-records.tf does, the hub's hosts, owner 2026-09-19
# ("exactly csi-rel: no load balancer"):
#
#   prd zone (<BASE_DOMAIN>):
#     api.<BASE_DOMAIN>       A + AAAA -> Cloud Run anycast (csi-rel: A/AAAA so
#                             other types can coexist there later)
#     dev.api.<BASE_DOMAIN>   CNAME ghs.googlehosted.com. (dev's api host sits
#                             in the apex zone, written by the PRD run, as csi-rel)
#     <tenant>.<BASE_DOMAIN>  CNAME ghs.googlehosted.com.
#   dev subzone (dev.<BASE_DOMAIN>):
#     <tenant>.dev.<BASE_DOMAIN> CNAME ghs.googlehosted.com.
#
# Names are relative to fqdn; the domain itself comes from cnf only. A tenant
# record overrides 031's *.<fqdn> wildcard for that one host (DNS exact match
# wins), so records can be added while 031 still exists.
locals {
  mapping_records = {
    for r in var.cloud_run_mapping_records : "${r.name}/${r.type}" => r
  }
}

resource "google_dns_record_set" "cloud_run_mapping" {
  for_each = var.zone_name == "" ? {} : local.mapping_records

  project      = var.gcp_project
  managed_zone = var.zone_name
  name         = "${each.value.name}.${var.fqdn}."
  type         = each.value.type
  ttl          = 300
  rrdatas      = each.value.rrdatas

  depends_on = [google_dns_managed_zone.env, google_dns_managed_zone.sub]
}
