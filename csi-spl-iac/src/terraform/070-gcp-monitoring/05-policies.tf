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
  severity              = "CRITICAL"

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
  severity              = "ERROR"

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
  severity              = "ERROR"

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
# carry severity. The request log is left out: 5xx are rate_5xx's. So is the
# hub's own "http 5xx" line (logServerError, one per 5xx answer): counted here
# too, one stall paged twice (SPL-3232, 10-22 09:45-10:05Z).
resource "google_logging_metric" "hub_errors" {
  name        = "${local.name}-hub-error-logs"
  description = "R03: hub error log entries (severity>=ERROR or zerolog level error/fatal/panic), request log excluded."
  filter      = "${local.run} AND (severity >= ERROR OR jsonPayload.level = \"error\" OR jsonPayload.level = \"fatal\" OR jsonPayload.level = \"panic\") AND NOT logName : \"run.googleapis.com%2Frequests\" AND NOT jsonPayload.message = \"http 5xx\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "error_logs" {
  depends_on            = [time_sleep.log_metrics]
  display_name          = "${local.name} hub error log rate"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "ERROR"

  conditions {
    display_name = "at least ${var.error_logs_per_5min} error log entries in five minutes, for ${var.error_logs_duration_s}s"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.hub_errors.name}\" AND resource.type = \"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_logs_per_5min - 1
      duration        = "${var.error_logs_duration_s}s"
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
  severity              = "CRITICAL"

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

# SPL-2542 (Cloud Run radar step 5): capacity. max_instances is per revision,
# so both conditions group by revision: during a roll or a canary two
# revisions run side by side, each under its own ceiling.
# SPL-3424 (alerts fix round row 01, owner Q1 = A): at max alone paged 7 times
# on an idle hub (CPU p99 <= 0.06), so it pages only when the revision is
# also busy: CPU p99 above instances_at_max_cpu_p99 for the same duration.
resource "google_monitoring_alert_policy" "instances_at_max" {
  display_name          = "${local.name} hub at max instances"
  combiner              = "AND"
  notification_channels = local.channels
  severity              = "WARNING"

  conditions {
    display_name = "a revision runs ${var.hub_max_instances} instance(s), its max, for ${var.instances_at_max_seconds}s"
    condition_threshold {
      filter          = "metric.type = \"run.googleapis.com/container/instance_count\" AND ${local.run}"
      comparison      = "COMPARISON_GT"
      threshold_value = var.hub_max_instances - 1
      duration        = "${var.instances_at_max_seconds}s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.revision_name"]
      }
    }
  }

  conditions {
    display_name = "and its p99 CPU is above ${format("%.0f", var.instances_at_max_cpu_p99 * 100)}% for ${var.instances_at_max_seconds}s"
    condition_threshold {
      filter          = "metric.type = \"run.googleapis.com/container/cpu/utilizations\" AND ${local.run}"
      comparison      = "COMPARISON_GT"
      threshold_value = var.instances_at_max_cpu_p99
      duration        = "${var.instances_at_max_seconds}s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.label.revision_name"]
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The hub has run at its max instances (${var.hub_max_instances}) with p99 CPU above ${format("%.0f", var.instances_at_max_cpu_p99 * 100)}% for ${var.instances_at_max_seconds}s: no headroom left, the next load step is 429s. Check CPU and requests in flight (`ENV=<env> ./run -a do_spl_hub_run_metrics`) before raising cnf hub.cloud_run.max_instances; more instances need a bigger DB tier."
  }
}

resource "google_monitoring_alert_policy" "memory_high" {
  display_name          = "${local.name} hub memory high"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "WARNING"

  conditions {
    display_name = "p99 container memory above ${format("%.0f", var.memory_utilization_threshold * 100)}% for ${var.memory_high_seconds}s"
    condition_threshold {
      filter          = "metric.type = \"run.googleapis.com/container/memory/utilizations\" AND ${local.run}"
      comparison      = "COMPARISON_GT"
      threshold_value = var.memory_utilization_threshold
      duration        = "${var.memory_high_seconds}s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.label.revision_name"]
      }
    }
  }

  alert_strategy {
    auto_close = "${var.auto_close_seconds}s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A hub instance uses more than ${format("%.0f", var.memory_utilization_threshold * 100)}% of its container memory: near the Go GOMEMLIMIT, then an OOM kill that drops every socket on it. Check the hub's logs and memory graph of ${var.hub_service_name}."
  }
}

# SPL-2867 (prd incident 2026-10-22): sign-in answered 503 after 10 s and the
# read views took up to 193 s for half an hour while /v1/health stayed 200, so
# the uptime check could not see it. Cloud Run's request_count and
# request_latencies carry no path, so both read the hub's request log.
locals {
  request_log = "${local.run} AND logName : \"run.googleapis.com%2Frequests\""
}

resource "google_logging_metric" "signin_5xx" {
  name        = "${local.name}-hub-signin-5xx"
  description = "SPL-2867: hub sign-in requests (${var.signin_path}) answered with a 5xx, from Cloud Run's request log."
  filter      = "${local.request_log} AND httpRequest.requestUrl : \"${var.signin_path}\" AND httpRequest.status >= 500"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "signin_5xx" {
  depends_on            = [time_sleep.log_metrics]
  display_name          = "${local.name} hub sign-in 5xx"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "CRITICAL"

  conditions {
    display_name = "at least ${var.signin_5xx_per_5min} sign-in 5xx in five minutes"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.signin_5xx.name}\" AND resource.type = \"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.signin_5xx_per_5min - 1
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
    content   = "Sign-in (${var.signin_path}) answers 5xx: nobody can log in, though /v1/health may still be 200. A 503 after 10 s is the hub's DB pool wait: slow queries hold the pool (incident 2026-10-22). Read the hub's error logs and `do_spl_db_health`; the remedy that worked is `do_gcp_hub_restart` (csi-spl-doc/doc/md/hub-signin-view-alerts.md)."
  }
}

# The request log's httpRequest.latency is a duration string ("12.5s"): the
# extractor keeps its number of seconds. Buckets 0.01 s * 1.5^n, n = 0..36,
# up to ~6 h: Cloud Run's 3600 s request timeout falls inside them, and a
# bucket is at most 1.5 times its lower edge, so the p95 read stays close.
resource "google_logging_metric" "view_latency" {
  name            = "${local.name}-hub-view-latency"
  description     = "SPL-2867: latency in seconds of the hub's read views (${var.view_path}*), from Cloud Run's request log."
  filter          = "${local.request_log} AND httpRequest.requestUrl : \"${var.view_path}\""
  value_extractor = "REGEXP_EXTRACT(httpRequest.latency, \"([0-9.]+)s\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "s"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 36
      growth_factor      = 1.5
      scale              = 0.01
    }
  }
}

# The hub's per-view limit (SPL-2866) answers 503 view_timeout instead of a
# slow view, which caps the latency the p95 sees: the 5xx count catches it.
resource "google_logging_metric" "view_5xx" {
  name        = "${local.name}-hub-view-5xx"
  description = "SPL-2867: hub read view requests (${var.view_path}*) answered with a 5xx, from Cloud Run's request log."
  filter      = "${local.request_log} AND httpRequest.requestUrl : \"${var.view_path}\" AND httpRequest.status >= 500"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# SPL-2934: Cloud Monitoring learns a new log metric minutes after Logging
# creates it; a policy created in the same apply failed 404 on a 7 s old
# metric ("could take up to 10 minutes"; the second apply 4 min later passed,
# dev 2026-10-22). Each policy on a log metric of this step depends on this
# wait. It sleeps when it is created, and it is replaced (so sleeps again)
# only when a metric id in its triggers changes: an apply that adds no metric
# does not wait. A depends_on changes no policy attribute.
resource "time_sleep" "log_metrics" {
  create_duration = "5m"

  triggers = {
    hub_errors   = google_logging_metric.hub_errors.id
    signin_5xx   = google_logging_metric.signin_5xx.id
    view_latency = google_logging_metric.view_latency.id
    view_5xx     = google_logging_metric.view_5xx.id
  }
}

resource "google_monitoring_alert_policy" "view_slow" {
  depends_on            = [time_sleep.log_metrics]
  display_name          = "${local.name} hub views slow"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "WARNING"

  conditions {
    display_name = "p95 of ${var.view_path}* above ${var.view_p95_seconds}s for ${var.view_slow_seconds}s"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.view_latency.name}\" AND resource.type = \"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.view_p95_seconds
      duration        = "${var.view_slow_seconds}s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_PERCENTILE_95"
      }
    }
  }

  conditions {
    display_name = "at least ${var.view_5xx_per_5min} ${var.view_path}* 5xx in five minutes"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.view_5xx.name}\" AND resource.type = \"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.view_5xx_per_5min - 1
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
    content   = "The hub's read views (${var.view_path}*) answer slower than ${var.view_p95_seconds}s at p95, or with 5xx (a 503 view_timeout is the per-view limit cutting a slow query): the web UI hangs, and slow queries holding the hub's DB pool starve sign-in next. /v1/health does not touch the pool and stays 200. Read pg_stat_activity (`do_spl_db_query`) and the hub's error logs (csi-spl-doc/doc/md/hub-signin-view-alerts.md)."
  }
}
