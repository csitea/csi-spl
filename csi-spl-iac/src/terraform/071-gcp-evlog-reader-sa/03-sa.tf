# Spec 162 section 10.4.3 and row T7a (SPL-5882; owner poll 00d28227 Q1 B):
# the box reader of Cloud Logging (do_spl_evlog_read, row T7) runs as its own
# read-only service account, not as the env's project SA.
#   - ONE role, roles/logging.viewer, on this env's own project: a stolen
#     reader key reads logs and cannot change the project.
#   - NO key here (repo CLAUDE.md: no key in terraform state). The key is
#     minted out of band, one per env on each reader box, by
#     do_gcp_evlog_reader_key (csi-spl-iac/src/bash/run/gcp-evlog-reader-key.func.sh),
#     on the owner's go.
# Guarded by csi-spl-iac/src/bash/tests/tf-071-evlog-reader-sa.tst.sh (C46).
resource "google_service_account" "evlog_reader" {
  account_id   = var.evlog_reader_sa_id
  display_name = var.evlog_reader_sa_id
  description  = "Reads the hub's Cloud Logging lines of ${var.org}-${var.app}-${var.env} for the event log (spec 162 section 10.4.3); logging.viewer only."
}

resource "google_project_iam_member" "evlog_reader_logging_viewer" {
  project = var.gcp_project
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.evlog_reader.email}"
}
