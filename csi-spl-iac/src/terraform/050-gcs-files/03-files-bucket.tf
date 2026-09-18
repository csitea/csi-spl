# The hub's file_id content bucket (spec 003 contracts, milestones M1: one GCS
# bucket, objects at t/<tenant>/files/<sha256>). Tenant isolation is the
# object PREFIX plus the hub's own checks: nothing but the hub's runtime SA
# (granted in 030) reaches an object, and no object is ever public.
#
# Hygiene = the 020 relay bucket's, deliberately:
#   uniform_bucket_level_access  true      -> IAM only, no object ACLs
#   public_access_prevention     enforced  -> no object can be made public
#   versioning                   off       -> content-addressed: a file_id
#                                             never changes bytes
#   soft delete                  7 days    -> an accidental delete is
#                                             recoverable
# No CORS: boxes upload through the hub (POST /v1/files, OQ-10), never
# straight to the bucket from a browser.
resource "google_storage_bucket" "files" {
  name     = var.files_bucket_name
  project  = var.gcp_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_seconds
  }

  dynamic "lifecycle_rule" {
    for_each = var.object_max_age_days > 0 ? [var.object_max_age_days] : []
    content {
      condition {
        age = lifecycle_rule.value
      }
      action {
        type = "Delete"
      }
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-files"
  }
}
