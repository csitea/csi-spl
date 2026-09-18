# Firebase Hosting for the M3 WUI (SPEC-spool-wui.md). Copy of the
# pas-psf/csi-rel Hosting *shape* — site + custom domain + managed cert —
# without shop pages or public-site ACLs.
#
# Hub API stays on Cloud Run (030). The deploy render script adds Hosting
# rewrites from /v1/** to that service; this step only creates the site.
#
# fqdn is env.dns.fqdn from cnf (the env product host). Tenant wildcard
# hosts are the hub mapping (031), not extra Hosting custom domains.

resource "google_project_service" "firebase" {
  project            = var.gcp_project
  service            = "firebase.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "firebasehosting" {
  project            = var.gcp_project
  service            = "firebasehosting.googleapis.com"
  disable_on_destroy = false
}

resource "google_firebase_project" "default" {
  provider = google-beta
  project  = var.gcp_project

  depends_on = [google_project_service.firebase]
}

resource "google_firebase_hosting_site" "default" {
  provider = google-beta
  project  = var.gcp_project
  site_id  = var.site_id

  depends_on = [
    google_firebase_project.default,
    google_project_service.firebasehosting,
  ]
}

resource "google_firebase_hosting_custom_domain" "default" {
  provider              = google-beta
  project               = var.gcp_project
  site_id               = google_firebase_hosting_site.default.site_id
  custom_domain         = var.fqdn
  cert_preference       = var.cert_preference
  wait_dns_verification = var.wait_dns_verification

  depends_on = [google_firebase_hosting_site.default]
}

resource "google_firebase_hosting_custom_domain" "additional" {
  for_each = toset(var.additional_fqdns)

  provider              = google-beta
  project               = var.gcp_project
  site_id               = google_firebase_hosting_site.default.site_id
  custom_domain         = each.value
  cert_preference       = var.cert_preference
  wait_dns_verification = var.wait_dns_verification

  depends_on = [google_firebase_hosting_site.default]

  lifecycle {
    precondition {
      condition     = each.value != var.fqdn
      error_message = "additional_fqdns must not contain var.fqdn — that domain is already managed by google_firebase_hosting_custom_domain.default."
    }
  }
}
