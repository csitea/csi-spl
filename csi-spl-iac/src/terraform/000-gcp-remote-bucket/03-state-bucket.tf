resource "google_storage_bucket" "tfstate" {
  name     = var.bucket_name
  project  = var.gcp_project
  location = upper(var.gcp_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # State history is the undo for a bad apply.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "tfstate"
  }
}

output "state_bucket" {
  value = google_storage_bucket.tfstate.name
}
