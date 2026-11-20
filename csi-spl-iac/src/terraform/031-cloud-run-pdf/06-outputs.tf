# The run.app URL: after the apply it goes into cnf hub.pdf.url, which 030
# passes to the hub as SPOOL_PDF_URL (spec 183 7.1.6).
output "service_uri" {
  value = google_cloud_run_v2_service.pdf.uri
}

output "runtime_sa_email" {
  value = google_service_account.pdf.email
}
