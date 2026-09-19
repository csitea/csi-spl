# The spool hub (spec 007 T008; milestones M1): stateless Cloud Run, HTTPS +
# WebSocket (/v1/ws) + REST files/pins. Nothing durable in the container:
# Postgres (040) and the files bucket (050) hold everything.
#
# WebSocket on Cloud Run:
#   - a WS is one request for its lifetime, so timeout = the longest a socket
#     lives (3600 s max); the box reconnects with backoff + re-hello (OQ-05)
#   - max_instances 1 in M1: every box socket terminates on the one instance,
#     so delivery to a live to_box needs no cross-instance fan-out (OQ-05)
#   - CPU always allocated (cpu_idle = false): the hub pushes frames and
#     expires the queue between requests, which throttled CPU would stall
#   - session affinity keeps a reconnecting box on the same instance once
#     max_instances is raised post-M1
locals {
  ingress_map = {
    "all"                               = "INGRESS_TRAFFIC_ALL"
    "internal"                          = "INGRESS_TRAFFIC_INTERNAL_ONLY"
    "internal-and-cloud-load-balancing" = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  }
  cloud_sql_connection_name = "${var.gcp_project}:${var.gcp_region}:${var.cloud_sql_instance_name}"
}

resource "google_cloud_run_v2_service" "hub" {
  name     = var.service_name
  project  = var.gcp_project
  location = var.gcp_region
  # the provider refuses to destroy the service while this is true; a destroy
  # run flips it through cnf (hub.cloud_run.deletion_protection), then back
  deletion_protection = var.deletion_protection
  # M1: not the open internet (owner 2026-09-18, spec 007 "M1 constraints").
  # With internal-and-cloud-load-balancing the run.app URL refuses outside
  # traffic; the IP allowlist / IAP sits on the load balancer in front.
  ingress = local.ingress_map[var.ingress]

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub"
  }

  template {
    service_account                  = google_service_account.hub.email
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = var.concurrency
    session_affinity                 = true

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloud_sql_connection_name]
      }
    }

    containers {
      image = var.image

      ports {
        container_port = var.container_port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = false
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_environment_variables
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = var.health_path
          port = var.container_port
        }
        initial_delay_seconds = 2
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 24
      }

      liveness_probe {
        http_get {
          path = var.health_path
          port = var.container_port
        }
        timeout_seconds   = 3
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  # The secret accessor must exist before a revision tries to read the DSN.
  depends_on = [
    google_secret_manager_secret_iam_member.hub_secret_accessor,
    google_project_iam_member.hub_cloudsql_client,
  ]

  lifecycle {
    # The image is terraform's (var.image = cnf hub.image.ref, an immutable
    # 028 tag): a deploy is a new tag, re-render, plan + apply. Only the
    # client stamps gcloud/console leave behind are ignored.
    ignore_changes = [
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.gcp_project
  location = google_cloud_run_v2_service.hub.location
  name     = google_cloud_run_v2_service.hub.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
