# availability plan row R03: until this step nothing paged; every hub
# incident was found by a person. One email channel to the owner. Email
# channels need no verification.
resource "google_monitoring_notification_channel" "owner_email" {
  display_name = "${var.org}-${var.app}-${var.env} owner email"
  type         = "email"
  description  = "R03: hub alerts straight to the owner, not through the fleet (plan 2.5.4)."

  labels = {
    email_address = var.GCP_ACCOUNT_OWNER_EMAIL
  }
}
