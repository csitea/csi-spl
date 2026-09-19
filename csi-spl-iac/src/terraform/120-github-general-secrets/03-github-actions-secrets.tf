# GitHub Actions secret GCP_KEY_<ORG>_<APP>_<ENV> = this env's project SA key
# (gcp-002: ~/.gcp/.<org>/key-<org>-<app>-<env>.json). The deploy workflows
# (20 hub, 00 lag watch, 30 WUI) authenticate with it (credentials_json).
#
# Ported from csi-rel-iac 120-github-general-secrets, with ONE deliberate
# difference. csi-rel publishes through github_actions_secret.plaintext_value
# and mirrors the key into Secret Manager, and both put the whole private key
# in terraform state. This repo forbids a key in state (CLAUDE.md, spec 007
# FR-007). So the value never enters terraform: `gh secret set` reads the file
# on stdin and seals it client-side to the repo's public key. The key's sha256 is the only
# thing state holds, and a new key (a changed hash) re-publishes it.
#
# A missing key file publishes nothing (count 0) and the output says so, as
# csi-rel skips missing keys. The caller's `gh` must be logged in with rights
# to set repo secrets.

locals {
  key_path    = pathexpand("~/.gcp/.${var.org}/key-${var.gcp_project}.json")
  key_present = fileexists(local.key_path)
  secret_name = "GCP_KEY_${upper(var.org)}_${upper(var.app)}_${upper(var.env)}"
}

resource "terraform_data" "gcp_key_secret" {
  count = local.key_present ? 1 : 0

  triggers_replace = [filesha256(local.key_path), var.gh_repo, local.secret_name]

  provisioner "local-exec" {
    quiet       = true
    interpreter = ["bash", "-c"]
    command     = "set -euo pipefail; gh secret set \"$SECRET_NAME\" --repo \"$GH_REPO\" <\"$KEY_PATH\""
    environment = {
      SECRET_NAME = local.secret_name
      GH_REPO     = var.gh_repo
      KEY_PATH    = local.key_path
    }
  }
}
