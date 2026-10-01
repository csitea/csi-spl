#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The terraform state show command is used to show the attributes of a single resource in the Terraform state. https://developer.hashicorp.com/terraform/cli/commands/state/show
# @example ORG=csi APP=csi-spl ENV=dev STEP=<step> TARGET=<address>[,<address>] ./run -a do_tf_state_show (in the tf-runner container)
#------------------------------------------------------------------------------
_tf_state_show_one() {
  terraform -chdir="${tf_run_path}" get -update=true && terraform -chdir="${tf_run_path}" state show "$1"
}

do_tf_state_show() {
  do_tf_each_target "tf state show" _tf_state_show_one
}
