# The demo workspace of one env (spec 077 T023/T024, iac audit section 2.1):
# the tenant row, its root key and the box-wui pin, made by the named action
# do_spl_demo_workspace_create. Terraform only CALLS it (the csi-rel pattern,
# as 120 calls `gh secret set`); the action stays the one place that knows how.
#
# Idempotent: the action READS first. A workspace that exists is reported and
# left as it is: {"workspace":"demo","env":"<env>","created":false}. So a
# first apply on an env where the workspace was made by hand is a no-op.
#
# The root PRIVATE key never enters terraform. It is not an input, an output
# or a trigger; the action writes it to $HOME/.spool-hub/tenants/<env>-<ws>.json
# (0600), which the tf-runner mounts from the host (docker-compose-tf-infra).
# The action prints only the JSON line above, never the key.
#
# Re-runs only when an input changes: the env, the project or the workspace id.
# `make do-provision` builds the spool CLI on the host first (tf-tasks.func.mk),
# which the create path signs with; a read-only run never calls it.

locals {
  orc_path  = "${var.proj_path}/../${var.org}-${var.app}-orc"
  spool_bin = "${var.proj_path}/../${var.org}-${var.app}-api/src/go/spool-hub-api/bin/spool"
}

resource "terraform_data" "demo_workspace" {
  count = var.demo_enabled ? 1 : 0

  triggers_replace = [var.env, var.gcp_project, var.demo_workspace]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "set -euo pipefail; cd \"$ORC_PATH\" && ./run -a do_spl_demo_workspace_create"
    environment = {
      ORC_PATH  = local.orc_path
      ENV       = var.env
      DRY_RUN   = "0"
      SPOOL_BIN = local.spool_bin
    }
  }
}
