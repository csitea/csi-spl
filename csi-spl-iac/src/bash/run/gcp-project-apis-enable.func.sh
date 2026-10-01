#!/bin/bash

#------------------------------------------------------------------------------
# @description enable common GCP APIs for a project (CloudRun, Storage, IAM, etc.)
# @example ORG=csi APP=csi-spl ENV=dev GCP_BILLING_ACCOUNT_ID=xxx ./run -a do_gcp_project_apis_enable
#------------------------------------------------------------------------------
do_gcp_project_apis_enable() {
  do_gcp_project_apis enable do_gcp_project_apis_enable \
    cloudresourcemanager.googleapis.com \
    dns.googleapis.com \
    servicemanagement.googleapis.com \
    secretmanager.googleapis.com \
    iam.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudrun.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    cloudapis.googleapis.com
}
