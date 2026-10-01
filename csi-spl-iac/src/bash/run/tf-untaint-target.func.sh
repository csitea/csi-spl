#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description If Terraform currently considers a particular object as tainted but you've determined that it's actually functioning correctly and need not be replaced, you can use terraform untaint to remove the taint marker from that object. https://developer.hashicorp.com/terraform/cli/commands/untaint
# @example ORG=csi APP=csi-spl ENV=dev STEP=<step> TARGET=<address>[,<address>] make do-tf-untaint-target
#------------------------------------------------------------------------------
_tf_untaint_target_one() {
  terraform -chdir="${tf_run_path}" untaint -lock=false -allow-missing "$1"
}

do_tf_untaint_target() {
  do_tf_each_target "tf untaint" _tf_untaint_target_one
}
