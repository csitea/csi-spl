# Where to point DNS: <fqdn> and *.<fqdn> -> this address.
output "lb_ip" {
  value = google_compute_global_address.hub.address
}

# The records the certificate and the tenants need. Created by 06-dns.tf when
# dns_managed_zone is set; otherwise add them by hand where the zone lives.
output "dns_records_to_create" {
  value = concat([
    { name = local.acme.name, type = local.acme.type, data = local.acme.data },
    { name = "${var.fqdn}.", type = "A", data = google_compute_global_address.hub.address },
    { name = "*.${var.fqdn}.", type = "A", data = google_compute_global_address.hub.address },
    ], flatten([for k, h in local.extra_hosts : [
      {
        name = google_certificate_manager_dns_authorization.extra[k].dns_resource_record[0].name
        type = google_certificate_manager_dns_authorization.extra[k].dns_resource_record[0].type
        data = google_certificate_manager_dns_authorization.extra[k].dns_resource_record[0].data
      },
      { name = "${h}.", type = "A", data = google_compute_global_address.hub.address },
  ]]))
}

# Every host the load balancer serves the hub on, besides <tenant>.<fqdn>.
output "hub_urls" {
  value = concat(["https://${var.fqdn}/"], [for h in values(local.extra_hosts) : "https://${h}/"])
}

output "certificate_id" {
  value = google_certificate_manager_certificate.hub.id
}

output "security_policy" {
  value = google_compute_security_policy.hub.name
}

output "hub_url_pattern" {
  value = "https://<tenant>.${var.fqdn}"
}
