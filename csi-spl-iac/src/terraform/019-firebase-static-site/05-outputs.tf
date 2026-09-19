output "site_id" {
  description = "Firebase Hosting site ID"
  value       = google_firebase_hosting_site.default.site_id
}

output "firebase_default_url" {
  description = "Default Firebase URL (free, always works once the site exists)"
  value       = "https://${google_firebase_hosting_site.default.site_id}.web.app"
}

output "firebase_alt_url" {
  description = "Alternate Firebase URL"
  value       = "https://${google_firebase_hosting_site.default.site_id}.firebaseapp.com"
}

output "custom_domain_https_url" {
  description = "Public HTTPS URL on the custom domain (works once DNS is in place and the cert provisions). Null when bind_custom_domain = false."
  value       = var.bind_custom_domain ? "https://${var.fqdn}/" : null
}

output "lb_origin_host" {
  description = "The site's default host <site_id>.web.app (the M1 031 LB targeted it; that LB is gone since 2026-09-19)."
  value       = "${google_firebase_hosting_site.default.site_id}.web.app"
}

output "required_dns_updates" {
  description = "Records Firebase needs in DNS. Add them via the DNS step / gcloud, then Firebase verifies asynchronously."
  value       = one(google_firebase_hosting_custom_domain.default[*].required_dns_updates)
}

output "ownership_state" {
  description = "Verification state: PENDING_VERIFICATION / VERIFIED / etc."
  value       = one(google_firebase_hosting_custom_domain.default[*].ownership_state)
}

output "host_state" {
  description = "Live state: HOST_PENDING_VERIFICATION / HOST_ACTIVE / etc."
  value       = one(google_firebase_hosting_custom_domain.default[*].host_state)
}

output "additional_custom_domains" {
  description = "Per-domain live state for every entry in var.additional_fqdns. Empty map when the site has only one custom domain."
  value = {
    for d, r in google_firebase_hosting_custom_domain.additional : d => {
      https_url       = "https://${d}/"
      host_state      = r.host_state
      ownership_state = r.ownership_state
    }
  }
}

output "custom_domains" {
  description = "Every custom domain this site binds — the primary plus the additional ones."
  value       = var.bind_custom_domain ? sort(concat([var.fqdn], var.additional_fqdns)) : []
}
