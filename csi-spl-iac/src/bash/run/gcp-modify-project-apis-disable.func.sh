#!/bin/bash

#------------------------------------------------------------------------------
# @description disable common GCP APIs on an existing project
# @description Destructive: never run without the owner's go for that call.
# @example ORG=csi APP=csi-spl ENV=dev GCP_BILLING_ACCOUNT_ID=xxx ./run -a do_gcp_modify_project_apis_disable
#------------------------------------------------------------------------------
do_gcp_modify_project_apis_disable() {
  do_gcp_project_apis disable do_gcp_modify_project_apis_disable \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    sheets.googleapis.com \
    dns.googleapis.com \
    servicemanagement.googleapis.com \
    secretmanager.googleapis.com \
    iam.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    storage.googleapis.com \
    cloudapis.googleapis.com
}
