# The hub's Postgres (spec 007 US4 / FR-005): Cloud SQL, spool schema only.
# The schema is NOT terraform: it is csi-spl-rdb's SQL, applied by the hub's
# Go migrator (`spool migrate`), locally by csi-spl-orc do_setup_app_inf and
# against Cloud SQL only with the owner's go.
#
# NO DATABASE USER AND NO PASSWORD HERE, deliberately. A google_sql_user with
# a password (or a random_password feeding one) writes that password into the
# state bucket in clear -- the same reason 020 does not mint the relay SA key.
# The hub's user and the DSN built from it are created out of band by the
# owner, and the DSN is added as a VERSION of the secret slot below:
#   gcloud sql users create <user> --instance=<instance_name> --password=... --account=...
#   printf %s 'postgres://<user>:<pw>@/<db>?host=/cloudsql/<connection_name>' |
#     gcloud secrets versions add <dsn_secret_id> --data-file=- --account=...
# 030 mounts the instance's unix socket at /cloudsql and injects the secret as
# SPOOL_HUB_DB_DSN.
resource "google_sql_database_instance" "hub" {
  name             = var.instance_name
  project          = var.gcp_project
  region           = var.gcp_region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  settings {
    tier                        = var.tier
    edition                     = "ENTERPRISE"
    availability_type           = var.availability_type
    disk_type                   = "PD_SSD"
    disk_size                   = var.disk_size_gb
    disk_autoresize             = true
    deletion_protection_enabled = var.deletion_protection

    # Public IP with NO authorized network: the only way in is the Cloud SQL
    # connector (Cloud Run's /cloudsql socket, the Auth Proxy), which
    # authenticates with IAM (roles/cloudsql.client) and encrypts. No VPC,
    # no peering, nothing to open.
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = var.backup_enabled
      point_in_time_recovery_enabled = var.backup_enabled
      start_time                     = "01:00"
    }

    maintenance_window {
      day  = 7
      hour = 3
    }

    user_labels = {
      org  = var.org
      app  = var.app
      env  = var.env
      role = "hub-db"
    }
  }
}

resource "google_sql_database" "spool" {
  name     = var.database_name
  project  = var.gcp_project
  instance = google_sql_database_instance.hub.name
}

# The empty slot for the hub's DSN. No google_secret_manager_secret_version:
# a version resource puts the secret value into state.
resource "google_secret_manager_secret" "hub_db_dsn" {
  project   = var.gcp_project
  secret_id = var.dsn_secret_id

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
    role = "hub-db-dsn"
  }
}
