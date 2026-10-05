output "notification_channels" {
  value = local.channels
}

# verification_status per sms channel: VERIFIED once the owner entered the code.
output "sms_verification_status" {
  value = { for k, c in google_monitoring_notification_channel.sms : k => c.verification_status }
}

output "uptime_check_id" {
  value = google_monitoring_uptime_check_config.hub_health.uptime_check_id
}

output "alert_policies" {
  value = [
    google_monitoring_alert_policy.uptime.name,
    google_monitoring_alert_policy.rate_429.name,
    google_monitoring_alert_policy.rate_5xx.name,
    google_monitoring_alert_policy.error_logs.name,
    google_monitoring_alert_policy.sql_down.name,
  ]
}
