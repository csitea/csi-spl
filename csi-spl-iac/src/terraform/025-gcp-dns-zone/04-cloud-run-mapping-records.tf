# DNS records for the Cloud Run domain mappings (step 032), as csi-rel
# 007-dns/05.03.api-dns-records.tf does, the hub's hosts, owner 2026-09-19
# ("exactly csi-rel: no load balancer"):
#
#   prd zone (<BASE_DOMAIN>):
#     api.<BASE_DOMAIN>       A + AAAA -> Cloud Run anycast (csi-rel: A/AAAA so
#                             other types can coexist there later)
#     dev.api.<BASE_DOMAIN>   CNAME ghs.googlehosted.com. (dev's api host sits
#                             in the apex zone, written by the PRD run, as csi-rel)
#     <tenant>.<BASE_DOMAIN>  A 199.36.158.100 + TXT "hosting-site=<site>"
#   dev subzone (dev.<BASE_DOMAIN>):
#     <tenant>.dev.<BASE_DOMAIN> A 199.36.158.100 + TXT "hosting-site=<site>"
#   (SPL-959: a tenant host is a Firebase custom domain of the WUI site, 019)
#
# Names are relative to fqdn; the domain itself comes from cnf only. There is
# no *.<fqdn> wildcard (the M1 031 LB that held it is gone): every tenant host
# is listed in env.dns.mapped_tenants and gets its own records + 019 domain.
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
