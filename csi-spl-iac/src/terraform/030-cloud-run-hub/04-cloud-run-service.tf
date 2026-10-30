# The spool hub (spec 007 T008; milestones M1): stateless Cloud Run, HTTPS +
# WebSocket (/v1/ws) + REST files/pins. Nothing durable in the container:
# Postgres (040) and the files bucket (050) hold everything.
#
# WebSocket on Cloud Run:
#   - a WS is one request for its lifetime; the hub closes it at its max
#     life (SPOOL_HUB_WS_MAX_LIFE, SPL-1981) and the box reconnects with
#     backoff + re-hello (OQ-05). The request timeout sits above that max
#     life and bounds what the hub never answers (SPL-2252: a stuck instance
#     held 1751 such requests for the old 3600 s)
#   - max_instances 1 in M1: every box socket terminates on the one instance,
#     so delivery to a live to_box needs no cross-instance fan-out (OQ-05)
#   - CPU always allocated (cpu_idle = false): the hub pushes frames and
#     expires the queue between requests, which throttled CPU would stall
#   - session affinity keeps a reconnecting browser on the same instance
#     once max_instances is raised post-M1; with ONE instance it routes
#     nothing and only costs: the front end sets a fresh GAESA cookie on
#     every response, which the browser sends back on every request - 289 B
#     in + 226 B out per API call that HTTP/2 cannot compress (it changes
#     each time), 4.1 KB per signed-in /lobby load against 1.5 KB of API
#     payload (CLE-35076). So it is on only when there is more than one
#     instance. (Boxes never carried it: the Go client has no cookie jar.)
locals {
  ingress_map = {
    "all"                               = "INGRESS_TRAFFIC_ALL"
    "internal"                          = "INGRESS_TRAFFIC_INTERNAL_ONLY"
    "internal-and-cloud-load-balancing" = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  }
  cloud_sql_connection_name = "${var.gcp_project}:${var.gcp_region}:${var.cloud_sql_instance_name}"

  # SPL-4298: every template input terraform owns (the image is the 20
  # pipeline's), this file included so a changed constant counts too. It rides
  # the template as a label; a mismatch with the live label means "changed".
  template_hash = substr(sha1(jsonencode({
    file           = filesha1("${path.module}/04-cloud-run-service.tf")
    sa             = google_service_account.hub.email
    timeout        = var.timeout_seconds
    concurrency    = var.concurrency
    min            = var.min_instances
    max            = var.max_instances
    sql            = local.cloud_sql_connection_name
    port           = var.container_port
    cpu            = var.cpu
    memory         = var.memory
    env            = var.environment_variables
    secret_env     = var.secret_environment_variables
    secret_version = var.secret_versions
    health         = var.health_path
  })), 0, 16)
  live = var.service_exists ? data.google_cloud_run_v2_service.live[0].template[0] : null
  live_env = local.live == null ? {} : {
    for e in local.live.containers[0].env : e.name => (e.value == null ? "" : e.value) if try(length(e.value_source), 0) == 0
  }
}

# SPL-4298: the live template (its revision name, label and env) decides the
# revision name below. Read-only; the hub SA already reads it on refresh.
data "google_cloud_run_v2_service" "live" {
  count    = var.service_exists ? 1 : 0
  name     = var.service_name
  project  = var.gcp_project
  location = var.gcp_region
}

module "revision" {
  source             = "./revision-name"
  service_name       = var.service_name
  template_hash      = local.template_hash
  live_revision      = try(local.live.revision, null) == null ? "" : local.live.revision
  live_template_hash = try(local.live.labels["tf-template"], null) == null ? "" : local.live.labels["tf-template"]
  live_env           = local.live_env
  want_env           = var.environment_variables
}

resource "google_cloud_run_v2_service" "hub" {
  name     = var.service_name
  project  = var.gcp_project
  location = var.gcp_region
  # the provider refuses to destroy the service while this is true; a destroy
  # run flips it through cnf (hub.cloud_run.deletion_protection), then back
  deletion_protection = var.deletion_protection
  # cnf hub.cloud_run.ingress: "all" since owner 2026-09-19 ("exactly
  # csi-rel: no load balancer"): 032 domain mappings + the WUI's Firebase
  # rewrite reach the service directly. internal-and-cloud-load-balancing
  # was M1's LB-only shape (031).
  ingress = local.ingress_map[var.ingress]

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub"
  }

  template {
    # SPL-4298: the live name while nothing changed, a fresh one when it did
    revision = module.revision.revision
    labels   = { (module.revision.label_key) = local.template_hash }

    service_account                  = google_service_account.hub.email
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = var.concurrency
    session_affinity                 = var.max_instances > 1

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
              version = lookup(var.secret_versions, env.value, "") # unpinned: the precondition below fails the plan
            }
          }
        }
      }

      # Ask at once and every second (CLE-35076): the hub listens 0.76 s
      # after an instance starts (p50, n=20 prd revisions, 2026-09-28) but
      # the first probe waited a fixed 2 s, so every deploy and cold start
      # was ready at 2.21 s. The budget stays 120 s (120 x 1 s, was 24 x 5 s);
      # Cloud Run needs timeout <= period.
      startup_probe {
        http_get {
          path = var.health_path
          port = var.container_port
        }
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 1
        failure_threshold     = 120
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
    google_secret_manager_secret_iam_member.hub_github_app_key_accessor,
    google_project_iam_member.hub_cloudsql_client,
  ]

  lifecycle {
    # SPL-2251: every injected secret is pinned to a version number
    precondition {
      condition     = length(setsubtract(toset(values(var.secret_environment_variables)), toset(keys(var.secret_versions)))) == 0
      error_message = "Each injected secret needs a version pin in cnf hub.secret_versions: missing ${join(", ", sort(setsubtract(toset(values(var.secret_environment_variables)), toset(keys(var.secret_versions)))))}."
    }

    # The image is set at CREATE time (var.image = cnf hub.image.ref, the
    # floor) and then belongs to the 20 pipeline: every deploy rolls the
    # service to the release version CI mints for its commit
    # (do_release_version), which is ahead of cnf by design. Terraform must
    # therefore never roll it back to the floor. Also ignored: the client
    # stamps gcloud/console leave behind. And the service-level scaling block
    # (not template.scaling, which cnf sets): the API's own default {min 0,
    # manual 0}, declared nowhere here, so every plan would null it (spec 075
    # T13 plan, 2026-10-07). And the traffic split (SPL-2249): a canary
    # deploy (do_canary_hub_deploy) tags the new revision, sends it a share,
    # then promotes it to latest 100 % or pins the old revision back. That
    # split belongs to the 20 pipeline too; an apply mid-canary must never
    # snap it to latest, nor un-pin a rolled-back service.
    #
    # The revision name is NOT ignored. The 20 pipeline names each revision
    # it deploys (SPL-3997: dev planned `template.revision -> null` after
    # every deploy and the dev-leads-prd gate refused the prd apply). Ignoring
    # it (a8ffb12c3) made every template change re-send the deployed name, and
    # Cloud Run refused it with 409 (SPL-4298). template.revision is set by
    # module.revision instead: the live name while nothing changed, a fresh
    # one when it did.
    ignore_changes = [
      client,
      client_version,
      scaling,
      template[0].containers[0].image,
      traffic,
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
