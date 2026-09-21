# Off-instance dumps of the hub DB (owner order 2026-09-20: "a backup job on
# the db - for now once daily, triggered from the github actions").
#
# WHY THIS EXISTS AT ALL, given 040 already has backups. Measured 2026-09-21 on
# both envs (csi-spl-orc do_spl_db_health, section cloudsql): automated backups
# ARE enabled, point-in-time recovery IS on, and the last four runs on each env
# read SUCCESSFUL. So this bucket is NOT a first line of defence. It buys the
# three things the built-in backups cannot:
#
#   1. a Cloud SQL backup can be restored only INTO Cloud SQL, and it lives
#      inside the instance's own project - it dies with the instance, and with
#      the project;
#   2. retainedBackups is 7, so one bad week that nobody notices loses every
#      copy. A bucket lifecycle rule is how we keep more than a week;
#   3. a logical pg_dump can be read, diffed, grepped and partially restored.
#      A Cloud SQL backup is opaque.
#
# The dumps are written by `gcloud sql export sql` (csi-spl-orc
# do_spl_db_backup), NOT by pg_dump on a runner: an export runs inside Google
# and streams instance -> bucket, so no row of tenant data ever transits a
# GitHub-hosted runner, and the runner needs no database password at all.
#
# Hygiene is 020's and 050's: IAM only, nothing can be made public, no
# versioning (each dump is a new, uniquely named object), 7-day soft delete.
resource "google_storage_bucket" "db_backups" {
  name     = var.backups_bucket_name
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

  # The retention of the off-instance copies. Unlike 050, this rule is NOT
  # optional: a backup bucket with no expiry grows forever and nobody notices
  # until it is the biggest line on the bill.
  lifecycle_rule {
    condition {
      age = var.backup_max_age_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-db-backups"
  }
}

# The instance's Google-managed service agent is the identity that performs an
# export, so it - not the runner, and not the project SA - is what needs write
# access to this bucket. It is READ from the live instance rather than written
# into the cnf: it is minted by Google, it differs per project, and a literal
# would be one more thing to get wrong on the next project.
data "google_sql_database_instance" "hub" {
  name    = var.instance_name
  project = var.gcp_project
}

# roles/storage.objectAdmin is what Cloud SQL's export documentation requires;
# it is wider than "create an object" (it can also delete one). That width is
# contained by giving this bucket to nothing else: the grant is on THIS bucket
# only, and this bucket holds only dumps. The instance agent has no role on the
# 020 relay bucket, the 050 files bucket or the state bucket.
resource "google_storage_bucket_iam_member" "sql_export_writer" {
  bucket = google_storage_bucket.db_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_sql_database_instance.hub.service_account_email_address}"
}
