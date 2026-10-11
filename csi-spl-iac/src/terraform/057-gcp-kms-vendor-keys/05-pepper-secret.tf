# The HMAC pepper of the vendor key fingerprints (spec 127 section 4.2), one
# per env. An EMPTY slot: no google_secret_manager_secret_version, since a
# version resource puts the value into state. do_spl_vendor_key_pepper_put
# adds the one version out of band (random bytes piped to gcloud on stdin:
# never argv, a file, a log or state).
resource "google_secret_manager_secret" "pepper" {
  project   = var.gcp_project
  secret_id = var.pepper_secret_id

  replication {
    user_managed {
      replicas {
        location = var.gcp_region
      }
    }
  }

  labels = {
    org  = var.org
    app  = var.app
    env  = var.env
    role = "hub-vendor-key-pepper"
  }

  lifecycle {
    prevent_destroy = true
  }
}
