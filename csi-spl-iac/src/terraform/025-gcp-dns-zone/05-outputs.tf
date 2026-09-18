# The name servers the registrar must delegate <fqdn> to.
output "name_servers" {
  value = { for k, z in google_dns_managed_zone.env : k => z.name_servers }
}
