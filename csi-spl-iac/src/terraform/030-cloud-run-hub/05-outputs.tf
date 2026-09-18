# The run.app URL. The product URL is https://<tenant>.<env.dns.fqdn> once
# 007-dns + 031 domain mapping exist; this one is for smoke tests only.
output "service_uri" {
  value = google_cloud_run_v2_service.hub.uri
}

output "runtime_sa_email" {
  value = google_service_account.hub.email
}
