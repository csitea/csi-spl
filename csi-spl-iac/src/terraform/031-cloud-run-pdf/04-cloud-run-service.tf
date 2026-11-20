# The topic PDF renderer (spec 183 7.1.6; owner Q5 SVC, msg 58733d06): a
# second Cloud Run service that only the hub may call. It answers
# POST /render (HTML in, PDF out) with headless Chrome; the hub's own image,
# memory and start time stay as they are.
#
# Started ad hoc, nothing held while idle (spec 183 1.2 R1, owner msg
# ac761f15: "no need to permanently use resources"):
#   - min_instance_count = 0, and it is NOT a variable: only a render request
#     starts an instance; Cloud Run stops it again when it idles
#   - cpu_idle = true: CPU only while a request runs
#   - no startup_cpu_boost
#   - no probe the hub or a scheduler calls, no uptime check: nothing keeps
#     it warm. renderer-scale-to-zero-031.tst.sh fails on any of these.
# A render after an idle period waits for the cold start (R2): the hub waits
# up to cnf hub.pdf.timeout and the request timeout below covers it.
#
# Ingress all with IAM (7.1.6): no allUsers invoker; the hub's runtime
# service account calls it with its own ID token (05-invoker.tf).
#
# The image is terraform's (cnf pdf.image.tag), so the 20 pipeline never rolls
# this service: it only builds and pushes a new tag when the renderer's inputs
# change (do_build_push_pdf_image), and a new renderer is a cnf tag bump plus
# an apply of this step, with the owner's go.
resource "google_cloud_run_v2_service" "pdf" {
  name                = var.service_name
  project             = var.gcp_project
  location            = var.gcp_region
  deletion_protection = var.deletion_protection
  ingress             = "INGRESS_TRAFFIC_ALL"

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "pdf"
  }

  template {
    service_account                  = google_service_account.pdf.email
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = var.concurrency

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }
    }
  }

  lifecycle {
    # The client stamps gcloud / the console leave behind, and the
    # service-level scaling block: the API's own default, declared nowhere
    # here, which every plan would null (the same three as 030).
    ignore_changes = [
      client,
      client_version,
      scaling,
    ]
  }
}
