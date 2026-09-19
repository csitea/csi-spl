# The name servers the registrar must delegate <fqdn> to.
output "name_servers" {
  value = merge({ for k, z in google_dns_managed_zone.env : k => z.name_servers }, { for z in google_dns_managed_zone.sub : z.name => z.name_servers })
}

# The subzone (dev) and the delegation written for it into the parent zone.
output "subzone_name_servers" {
  value = [for z in google_dns_managed_zone.sub : z.name_servers]
}
