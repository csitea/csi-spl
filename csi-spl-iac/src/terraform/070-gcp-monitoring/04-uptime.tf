# The hub's public health URL, called over https from several regions. A
# failure in more than uptime_failing_regions of them for uptime_fail_seconds
# pages (05-policies.tf).
resource "google_monitoring_uptime_check_config" "hub_health" {
  display_name     = "${var.org}-${var.app}-${var.env} hub health"
  period           = "${var.uptime_period_seconds}s"
  timeout          = "${var.uptime_timeout_seconds}s"
  selected_regions = var.uptime_regions

  http_check {
    path           = var.health_path
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  content_matchers {
    content = var.health_content
    matcher = "CONTAINS_STRING"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.gcp_project
      host       = var.uptime_host
    }
  }
}
