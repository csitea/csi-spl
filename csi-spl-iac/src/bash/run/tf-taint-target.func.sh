#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform taint command informs Terraform that a particular object has become degraded or damaged. Terraform represents this by marking the object as "tainted" in the Terraform state, and Terraform will propose to replace it in the next plan you create. https://developer.hashicorp.com/terraform/cli/commands/taint
# @example ORG=csi APP=csi-spl ENV=dev STEP=<step> TARGET=<address>[,<address>] make do-tf-taint-target
#------------------------------------------------------------------------------
_tf_taint_target_one() {
  terraform -chdir="${tf_run_path}" taint -lock=false -allow-missing "$1"
}

do_tf_taint_target() {
  do_tf_each_target "tf taint" _tf_taint_target_one
}
