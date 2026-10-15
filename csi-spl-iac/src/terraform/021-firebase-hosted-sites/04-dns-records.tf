# The records Firebase asks of a custom domain, as 025 writes them for the WUI
# site's hosts (SPL-959): A 199.36.158.100 + TXT "hosting-site=<site_id>".
# NEW records only, one name per site; the zone and every other record stay
# 025's.
resource "google_dns_record_set" "site_a" {
  for_each = local.sites

  project      = var.gcp_project
  managed_zone = var.zone_name
  name         = "${each.value.host}."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.158.100"]
}

resource "google_dns_record_set" "site_txt" {
  for_each = local.sites

  project      = var.gcp_project
  managed_zone = var.zone_name
  name         = "${each.value.host}."
  type         = "TXT"
  ttl          = 300
  rrdatas      = ["\"hosting-site=${each.value.site_id}\""]
}
