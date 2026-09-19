# Site verification CNAMEs placed in the prd-owned zone.
#
# Resource key uses the env so re-applying from a different env never
# collides with another env's records in this step's terraform state.
# (Each env runs its own terraform state at this step; the for_each
# key just keeps map ordering stable across plans.)

resource "google_dns_record_set" "verification" {
  for_each = {
    for r in var.verification_records :
    "${var.env}-${replace(r.source, ".", "_")}" => r
  }
  provider     = google.prd
  name         = each.value.source
  type         = "CNAME"
  ttl          = 300
  managed_zone = var.prd_zone_name
  rrdatas      = [each.value.target]
}
