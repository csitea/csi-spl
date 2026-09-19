# Browser sign-in secrets (spec 010 T021; cnf env.auth.social.secret_env): the
# session key and one client secret per IdP, each an EMPTY slot. No
# google_secret_manager_secret_version: a version resource puts the value into
# state. The owner adds versions out of band (010 idp-registration-runbook.md).
#
# Every slot exists whether or not its provider is listed; the service only
# references (and the runtime SA only reads) the ones 030's tfvars inject,
# i.e. the session key and the listed providers' secrets.
resource "google_secret_manager_secret" "auth" {
  for_each = toset(var.auth_secret_ids)

  project   = var.gcp_project
  secret_id = each.value

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
    role = "hub-auth"
  }
}
