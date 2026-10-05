# availability plan row R03: until this step nothing paged; every hub
# incident was found by a person. One email channel per cnf
# env.gcp.alert_email_<n> and one sms channel per alert_sms_<n> (owner order
# 2026-10-05), keyed by the slot so adding or dropping one recipient never
# recreates another's channel. Email channels need no verification. An sms
# channel is created UNVERIFIED and delivers nothing until the owner enters
# the code Google texts to it (console: Monitoring > Alerting > Edit
# notification channels > SMS > Verify). GCP charges nothing for either.
locals {
  alert_emails = { for k, v in {
    "1" = var.ALERT_EMAIL_1
    "2" = var.ALERT_EMAIL_2
    "3" = var.ALERT_EMAIL_3
  } : k => v if v != "" }
  alert_sms = { for k, v in {
    "1" = var.ALERT_SMS_1
    "2" = var.ALERT_SMS_2
  } : k => v if v != "" }
}

check "alert_recipients" {
  assert {
    condition     = length(local.alert_emails) > 0
    error_message = "No alert email: set cnf env.gcp.alert_email_1 (run through do_tf_init, which exports it as TF_VAR_ALERT_EMAIL_1). SMS alone is not a reliable channel."
  }
}

resource "google_monitoring_notification_channel" "email" {
  for_each = local.alert_emails

  display_name = "${var.org}-${var.app}-${var.env} alert email ${each.key}"
  type         = "email"
  description  = "R03: hub alerts straight to the owner, not through the fleet (plan 2.5.4)."

  labels = {
    email_address = each.value
  }
}

resource "google_monitoring_notification_channel" "sms" {
  for_each = local.alert_sms

  display_name = "${var.org}-${var.app}-${var.env} alert sms ${each.key}"
  type         = "sms"
  description  = "R03: hub alerts by text to the owner; needs the owner's verification code before it delivers."

  labels = {
    number = each.value
  }
}

# The single owner channel of the first 070 apply is slot 1: its address
# label updates in place, the channel (and every policy's reference) stays.
moved {
  from = google_monitoring_notification_channel.owner_email
  to   = google_monitoring_notification_channel.email["1"]
}
