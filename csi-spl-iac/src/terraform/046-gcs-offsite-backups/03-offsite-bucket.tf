# The OFF-PROJECT copy of an env's backups (spec 044 contingency T077; owner
# "4. yes", 2026-09-29). The daily dump bucket (045) and the files bucket (050)
# live in csi-spl-<env>; the owner's contingency policy is "destroy the infra
# and re-create", which destroys both. This bucket lives in csi-spl-bkp, a
# project nothing in the env can reach, and holds:
#   <env>/db/<dump>.sql.gz      every 045 dump   (do_spl_backup_offsite)
#   <env>/files/<object path>   every 050 object (do_spl_backup_offsite)
#
# Hygiene is 045's plus the three things a copy that must survive a
# compromise needs:
#   versioning        on        -> a replaced object keeps its old version
#   retention policy  N days    -> nobody, the project owner included, can
#                                  delete or overwrite an object younger than
#                                  N days while the policy stands. NOT locked:
#                                  a lock is irreversible (the owner's call)
#   soft delete       30 days   -> a deleted object is recoverable
resource "google_storage_bucket" "offsite" {
  name     = var.offsite_bucket_name
  project  = var.tf_key_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = var.retention_days * 86400
    is_locked        = false
  }

  soft_delete_policy {
    retention_duration_seconds = var.soft_delete_retention_seconds
  }

  lifecycle_rule {
    condition {
      age = var.max_age_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.noncurrent_max_age_days
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "offsite-backups"
  }
}

# WRITE-ONLY for the env. objectCreator can create an object and nothing
# else: no get, no delete, so it cannot overwrite either (an overwrite needs
# delete). legacyBucketReader adds buckets.get + objects.list: object NAMES,
# which the copy needs to skip what is already here; it cannot read a byte.
# A compromised csi-spl-<env> key can therefore add junk, and cannot read,
# replace or remove a single backup. Restores read as the csi-spl-bkp SA.
resource "google_storage_bucket_iam_member" "env_writer" {
  bucket = google_storage_bucket.offsite.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${var.writer_service_account}"
}

resource "google_storage_bucket_iam_member" "env_lister" {
  bucket = google_storage_bucket.offsite.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${var.writer_service_account}"
}
