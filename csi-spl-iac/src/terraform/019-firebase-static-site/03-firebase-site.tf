# Firebase Hosting for the M3 WUI (SPEC-spool-wui.md). Copy of the
# pas-psf/csi-rel Hosting *shape* — site + custom domain + managed cert —
# without shop pages or public-site ACLs.
#
# Hub API stays on Cloud Run (030). The product hosts (<fqdn>, *.<fqdn>) are
# served by the 031 load balancer: /v1/*, /api/*, /healthz, /version go to the
# hub, every other path to THIS site's <site_id>.web.app as an internet NEG
# (spec 007 §3, T072). So by default this step creates the site only; the
# custom-domain resources exist only with bind_custom_domain = true.

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

  # A deleted Hosting site id "cannot be reactivated by you or anyone else"
  # (Firebase docs, multisites: deleting a site). A destroy would burn
  # <org>-<app>-<env>-site forever, so it must fail loudly instead.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_firebase_hosting_custom_domain" "default" {
  count = var.bind_custom_domain ? 1 : 0

  provider              = google-beta
  project               = var.gcp_project
  site_id               = google_firebase_hosting_site.default.site_id
  custom_domain         = var.fqdn
  cert_preference       = var.cert_preference
  wait_dns_verification = var.wait_dns_verification

  depends_on = [google_firebase_hosting_site.default]
}

resource "google_firebase_hosting_custom_domain" "additional" {
  for_each = var.bind_custom_domain ? toset(var.additional_fqdns) : toset([])

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


resource "google_firebase_hosting_custom_domain" "redirect" {
  for_each = var.bind_custom_domain ? toset(var.redirect_fqdns) : toset([])

  provider              = google-beta
  project               = var.gcp_project
  site_id               = google_firebase_hosting_site.default.site_id
  custom_domain         = each.value
  redirect_target       = var.fqdn
  cert_preference       = var.cert_preference
  wait_dns_verification = var.wait_dns_verification

  depends_on = [google_firebase_hosting_custom_domain.default]

  lifecycle {
    precondition {
      condition     = each.value != var.fqdn && !contains(var.additional_fqdns, each.value)
      error_message = "redirect_fqdns must not contain var.fqdn or an additional_fqdns entry: a domain either serves the site or redirects to it."
    }
  }
}
