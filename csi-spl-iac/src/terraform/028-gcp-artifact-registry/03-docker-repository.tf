# The hub image registry (spec 007 T007, pas-psf's 028): one Docker repository
# per env project, in the spool's region. csi-spl-orc do_build_push_hub_image
# builds the image (the static `spool` binary + the csi-spl-rdb DDL) and pushes
# <region>-docker.pkg.dev/<project>/<repository_id>/<hub.image.name>:<hub.image.tag>;
# 030 runs exactly that reference (cnf hub.image.ref, derived at render time).
#
# No IAM here: Cloud Run pulls with its service agent, which reads Artifact
# Registry in its own project by default, and the operator pushes with their
# own identity (roles/artifactregistry.writer or owner). No CI identity yet.
resource "google_artifact_registry_repository" "hub" {
  project       = var.gcp_project
  location      = var.gcp_region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "${var.org}-${var.app}-${var.env} spool hub images"

  docker_config {
    immutable_tags = var.immutable_tags
  }

  # Tagged images are never deleted by policy: a running revision names one.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.untagged_max_age_days * 86400}s"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-images"
  }
}
