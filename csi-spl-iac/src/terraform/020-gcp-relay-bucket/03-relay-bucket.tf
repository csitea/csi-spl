# The git-rel relay bucket.
#
# ACCESS MODEL = bnc-cpt-all-relay's, MEASURED read-only on 2026-09-17 with the
# bnc SA through a throwaway CLOUDSDK_CONFIG (owner decision: "the same access
# model which existing for the git-relay bucket"):
#   uniform_bucket_level_access  true
#   public_access_prevention     enforced   -> no object can be public; git-rel
#                                              v2 reaches objects with signed
#                                              GET/PUT URLs only
#   versioning                   off
#   soft delete                  604800 s (7 days)
#   lifecycle                    NONE       -> object_max_age_days = 0
#   labels / CORS / retention    none
#   location / class             EUROPE-NORTH1 (region) / STANDARD
#   bucket IAM                   only the GCS-default legacy convenience
#                                bindings, which GCS adds itself on creation
# The one deliberate addition is the bucket-scoped binding for the relay SA in
# 04-relay-sa.tf: the bnc SA reaches its bucket through project roles/owner.
resource "google_storage_bucket" "relay" {
  name     = var.relay_bucket_name
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

  # No labels, no cors, no retention_policy: none on bnc-cpt-all-relay.
}
