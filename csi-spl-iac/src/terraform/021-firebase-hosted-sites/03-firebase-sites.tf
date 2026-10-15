# Static websites on Firebase Hosting, one SEPARATE site each, beside the WUI
# site (019): the WUI host serves the spool app, so a site that is no spool
# workspace gets its own Hosting site and its own host <name>.<fqdn>.
#
# The Firebase project and the hosting API are 019's (google_firebase_project,
# firebasehosting.googleapis.com): apply 019 before this step.
# The bundle is shipped by do_deploy_hosted_site (csi-spl-orc), never here.
locals {
  sites = { for s in var.sites : s.name => s }
}

resource "google_firebase_hosting_site" "site" {
  for_each = local.sites

  provider = google-beta
  project  = var.gcp_project
  site_id  = each.value.site_id

  # A deleted Hosting site id can never be used again, by anyone (Firebase
  # docs, multisites): a destroy must fail loudly, as 019's does.
  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = endswith(each.value.host, ".${var.fqdn}")
      error_message = "a site host must be a name under var.fqdn: the env's zone serves it."
    }
  }
}

resource "google_firebase_hosting_custom_domain" "site" {
  for_each = local.sites

  provider              = google-beta
  project               = var.gcp_project
  site_id               = google_firebase_hosting_site.site[each.key].site_id
  custom_domain         = each.value.host
  cert_preference       = var.cert_preference
  wait_dns_verification = var.wait_dns_verification
}
