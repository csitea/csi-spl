# The alert policies of row R03. Each pages every 03 channel (email and sms).
#
# NOT here, on purpose: a policy on the workflow 45 backup. That job runs on a
# GitHub-hosted runner, so Cloud Monitoring cannot see it fail; the one cloud
# trace it leaves, the cloudsql.instances.export audit entry, would need an
# absence condition, which caps at 23.5 h while the schedule drifts past 25 h
# (measured 2026-10-03T05:35Z -> 2026-10-04T07:09Z). A red scheduled run of
# 45 is already its alert (the workflow's own header).
locals {
  channels = concat(
    [for c in google_monitoring_notification_channel.email : c.name],
    [for c in google_monitoring_notification_channel.sms : c.name],
  )
  name     = "${var.org}-${var.app}-${var.env}"
  run      = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${var.hub_service_name}\""
  requests = "metric.type = \"run.googleapis.com/request_count\" AND ${local.run}"
}

resource "google_monitoring_alert_policy" "uptime" {
  display_name          = "${local.name} hub health check failing"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "https://${var.uptime_host}${var.health_path} fails from more than ${var.uptime_failing_regions} region(s)"
    condition_threshold {
      filter          = "metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type = \"uptime_url\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.hub_health.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.uptime_failing_regions
      duration        = "${var.uptime_fail_seconds}s"
      aggregations {
        alignment_period     = "${var.uptime_period_seconds}s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub's public health URL fails from several regions: the hub, its domain mapping or its certificate is down. Check `/version` and the Cloud Run revision of ${var.hub_service_name}."
  }
}

resource "google_monitoring_alert_policy" "rate_429" {
  display_name          = "${local.name} hub 429 streak"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "at least ${var.rate_429_per_min} HTTP 429 in one minute"
    condition_threshold {
      filter          = "${local.requests} AND metric.labels.response_code = \"429\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.rate_429_per_min - 1
      duration        = "0s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub is refusing requests with 429: the in-app edge limits or Cloud Run's max instances. Clients are being turned away."
  }
}

resource "google_monitoring_alert_policy" "rate_5xx" {
  display_name          = "${local.name} hub 5xx rate"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "at least ${var.rate_5xx_per_5min} HTTP 5xx in five minutes"
    condition_threshold {
      filter          = "${local.requests} AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.rate_5xx_per_5min - 1
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub answers 5xx. Read the hub's error logs for the same minutes."
  }
}

# The hub logs zerolog JSON: its level is jsonPayload.level, which Cloud
# Logging does not map to severity. Cloud Run's own entries (a crash, an OOM)
# carry severity. The request log is left out: 5xx are rate_5xx's.
resource "google_logging_metric" "hub_errors" {
  name        = "${local.name}-hub-error-logs"
  description = "R03: hub error log entries (severity>=ERROR or zerolog level error/fatal/panic), request log excluded."
  filter      = "${local.run} AND (severity >= ERROR OR jsonPayload.level = \"error\" OR jsonPayload.level = \"fatal\" OR jsonPayload.level = \"panic\") AND NOT logName : \"run.googleapis.com%2Frequests\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "error_logs" {
  display_name          = "${local.name} hub error log rate"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "at least ${var.error_logs_per_5min} error log entries in five minutes"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.hub_errors.name}\" AND resource.type = \"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_logs_per_5min - 1
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub writes errors (or Cloud Run reports a crash). Read the logs of ${var.hub_service_name} at severity>=ERROR."
  }
}

resource "google_monitoring_alert_policy" "sql_down" {
  display_name          = "${local.name} Cloud SQL down"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = "${var.cloud_sql_instance_name} database/up below 1 for ${var.sql_down_seconds}s"
    condition_threshold {
      filter          = "metric.type = \"cloudsql.googleapis.com/database/up\" AND resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"${var.gcp_project}:${var.cloud_sql_instance_name}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "${var.sql_down_seconds}s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub's Cloud SQL instance ${var.cloud_sql_instance_name} reports down. The hub cannot serve while it is."
  }
}
