# The name servers the registrar must delegate <fqdn> to.
output "name_servers" {
  value = merge({ for k, z in google_dns_managed_zone.env : k => z.name_servers }, { for z in google_dns_managed_zone.sub : z.name => z.name_servers })
}

# The subzone (dev) and the delegation written for it into the parent zone.
output "subzone_name_servers" {
  value = [for z in google_dns_managed_zone.sub : z.name_servers]
}

# The Cloud Run domain-mapping records this env's zone carries (032's hosts).
output "cloud_run_mapping_records" {
  value = { for k, r in google_dns_record_set.cloud_run_mapping : k => { name = r.name, rrdatas = r.rrdatas } }
}
