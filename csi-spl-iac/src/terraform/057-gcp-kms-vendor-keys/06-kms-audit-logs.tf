# spec 127 section 5.1 guard: Cloud KMS Data Access audit logs ON, so every
# wrap/unwrap (and every IAM read the grant check makes) leaves a record.
# Authoritative for cloudkms.googleapis.com only, project-wide: it also logs
# 055's marketing key. No other step sets an audit config.
resource "google_project_iam_audit_config" "kms_data_access" {
  project = var.gcp_project
  service = "cloudkms.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
