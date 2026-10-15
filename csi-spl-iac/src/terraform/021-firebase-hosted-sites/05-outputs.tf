output "sites" {
  description = "Per site: its default URL, its host and the custom domain's live state."
  value = {
    for k, s in local.sites : k => {
      default_url     = "https://${google_firebase_hosting_site.site[k].site_id}.web.app"
      https_url       = "https://${s.host}/"
      host_state      = google_firebase_hosting_custom_domain.site[k].host_state
      ownership_state = google_firebase_hosting_custom_domain.site[k].ownership_state
      cert_state      = try(google_firebase_hosting_custom_domain.site[k].cert[0].state, null)
    }
  }
}
