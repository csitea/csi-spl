#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 123 section 15 (SPL-5265): terraform step 002-gcp-billing-sa
#          stays what the owner asked for, statically (no terraform, no
#          network; fast tier):
#   1. it creates ONLY the SA, its roles/bigquery.jobUser on its project,
#      roles/billing.viewer + roles/billing.user on each billing account
#      (SPL-5506, owner a508c121: "I grant csi-spl-all Billing Admin once;
#      Terraform does the rest"), roles/bigquery.dataViewer on the billing
#      export dataset (SPL-5799, owner 303bd484) and its one key written to
#      a file: those seven resources, of those six types, and those four
#      roles.
#   2. the key (SPL-5457, owner HUM-10 #laskut f655b326 msg 8d767855: "change
#      the Terraform code to actually provision the key on the file system
#      while provisioning the account") is written, never shown: a
#      local_sensitive_file of the SA's own key, mode 0600, at
#      ~/.gcp/.<org>/key-<org>-<app>-billing.json via pathexpand (no literal
#      home or user), and no output names the key. No other billing-account
#      or dataset resource: no tls_private_key,
#      google_billing_account_iam_{binding,policy},
#      google_bigquery_dataset_iam_{binding,policy}.
#   2c. the dataset grant (SPL-5799; owner HUM-10, #laskut f655b326, msg
#      303bd484: "Second provider in terraform step 002, running as the
#      csi-spl-prd service account"): a dataset-level member (never a
#      project-level dataViewer) on var.export_source_project /
#      var.export_source_dataset, made through the google.export_source
#      provider, which runs as key-<export_source_project>.json by
#      pathexpand (the 025 pattern), not as the step's own identity; it is
#      the step's ONE provider line, so the six other resources stay on the
#      default provider (the csi-spl-all SA): R7 W1, c-060 b2f7d59e; and
#      that default provider carries no credentials, access_token or
#      impersonate_service_account, so do_tf_init's key (the csi-spl-all SA)
#      is what it runs as (R7 W1, c-070 124808a2).
#   2b. the billing-account grants: for_each over the ids of
#      var.billing_account_ids, which has no default and refuses an empty or
#      malformed value (the ids are never committed); no id literal in a .tf.
#   3. prd only: the env validation refuses any other env, and the dev
#      renders carry no step values.
#   4. the prd render reads the one fact: gcp_project = cnf
#      env.cost.gcp.export_project, billing_sa = env.cost.gcp.billing_sa,
#      export_source_{project,dataset} = env.cost.gcp.export_source_*; it
#      runs as the csi-spl-all SA (tf_key_project) with its state in
#      csi-spl-all-tfstate under terraform/002-gcp-billing-sa.
#   5. do_gcp_billing_sa_create runs no create and no IAM binding (one creator
#      of the SA: this step); its owner steps are printed (do_log) only.
#   6. CONTROLS: a planted output of the key, a 0644 key file and a literal
#      home path are caught by 2, a planted billing account policy by 2, a
#      planted eighth resource by 1, a planted id literal and a default on
#      the ids by 2b, a project-level dataViewer, the grant on the
#      default provider, the SA moved onto google.export_source and the
#      export project's key on the default provider by 2c,
#      and a planted gcloud create in the action by 5.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP=002-gcp-billing-sa
SD="$PROJ_ROOT/src/terraform/$STEP"
ACT="$PROJ_ROOT/src/bash/run/gcp-billing-sa-create.func.sh"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[[ -d "$SD" ]] && pass "$STEP exists" || fail "$STEP dir missing"

# only_sa_and_job_user <dir> - exactly the SA, one jobUser member, the two
# billing-account members, the dataset member, its key and the key file,
# nothing else
only_sa_and_job_user() {
  local got
  got=$(grep -hoE '^resource "[a-z0-9_]+"' "$1"/*.tf | sort | tr '\n' ' ')
  [[ "$got" == 'resource "google_bigquery_dataset_iam_member" resource "google_billing_account_iam_member" resource "google_billing_account_iam_member" resource "google_project_iam_member" resource "google_service_account" resource "google_service_account_key" resource "local_sensitive_file" ' ]] \
    && [[ "$(grep -hE '^\s*role\s*=' "$1"/*.tf | tr -d ' ' | LC_ALL=C sort | tr '\n' ' ')" == 'role="roles/bigquery.dataViewer" role="roles/bigquery.jobUser" role="roles/billing.user" role="roles/billing.viewer" ' ]]
}
# no_billing_grant <dir> - no authoritative dataset or billing-account
# binding/policy, no other key
no_billing_grant() {
  ! grep -qhE '"(tls_private_key|google_billing_account_iam_(binding|policy)|google_bigquery_dataset_iam_(binding|policy))"' "$1"/*.tf
}
# dataset_grant_as_source <dir> - the dataViewer is a dataset member on the
# export_source vars, through google.export_source; that alias runs on the
# export project's own key (pathexpand, no literal home); no project-level
# dataViewer; no other resource names a provider, and the default (unaliased)
# provider names no identity of its own
dataset_grant_as_source() {
  local all
  all=$(cat "$1"/*.tf)
  awk '/^resource "google_bigquery_dataset_iam_member" "billing_export_viewer"/ { r = 1 }
       r && /provider *= *google\.export_source$/ { p = 1 }
       r && /project *= *var\.export_source_project$/ { j = 1 }
       r && /dataset_id *= *var\.export_source_dataset$/ { d = 1 }
       r && /role *= *"roles\/bigquery\.dataViewer"$/ { o = 1 }
       r && /^}/ { r = 0 }
       END { exit !(p && j && d && o) }' <<<"$all" \
    && awk '/^provider "google"/ { v = 1; a = 0 } v && /alias *= *"export_source"/ { a = 1 }
       v && a && /project *= *var\.export_source_project$/ { j = 1 }
       v && a && /credentials *= *var\.export_source_project != var\.gcp_project \? file\(pathexpand\("~\/\.gcp\/\.\$\{var\.org\}\/key-\$\{var\.export_source_project\}\.json"\)\) : null$/ { c = 1 }
       v && /^}/ { v = 0 } END { exit !(j && c) }' <<<"$all" \
    && awk '/^resource "/ { r = 1; n = $0 } r && /^[[:space:]]*provider[[:space:]]*=/ { c++; if (n !~ /"billing_export_viewer"/) bad = 1 }
       r && /^}/ { r = 0 } END { exit !(c == 1 && !bad) }' <<<"$all" \
    && awk '/^provider "google"/ { v = 1; a = 0; i = 0 } v && /^[[:space:]]*alias[[:space:]]*=/ { a = 1 }
       v && /^[[:space:]]*(credentials|access_token|impersonate_service_account)[[:space:]]*=/ { i = 1 }
       v && /^}/ { v = 0; if (!a && i) bad = 1 } END { exit bad }' <<<"$all" \
    && ! awk '/^resource "google_project_iam_[a-z]+"/ { r = 1 } r && /bigquery\.dataViewer/ { f = 1 } r && /^}/ { r = 0 } END { exit !f }' <<<"$all"
}
# billing_grants_from_var <dir> - both members for_each the ids of the
# variable, granted to the step's SA; the variable has no default and a
# validation; no billing account id literal in any .tf
billing_grants_from_var() {
  local all
  all=$(cat "$1"/*.tf)
  [[ $(grep -cE 'for_each\s*=\s*local\.billing_account_ids$' <<<"$all") == 2 ]] \
    && [[ $(grep -cE 'billing_account_id\s*=\s*each\.value$' <<<"$all") == 2 ]] \
    && [[ $(grep -cE 'member\s*=\s*"serviceAccount:\$\{google_service_account\.billing\.email\}"' <<<"$all") == 4 ]] \
    && grep -qE 'billing_account_ids\s*=\s*toset\(compact\(split\(",", replace\(var\.billing_account_ids, " ", ""\)\)\)\)' <<<"$all" \
    && awk '/^variable "billing_account_ids"/ { v = 1 } v && /^[[:space:]]*default[[:space:]]*=/ { d = 1 } v && /validation/ { ok = 1 } v && /^}/ { v = 0 } END { exit !(ok && !d) }' "$1"/02-variables.tf \
    && ! grep -qE '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' <<<"$all"
}
# key_written_not_shown <dir> - the SA's key goes to the one file, 0600, by
# pathexpand of ~ (no literal home), and no output names it
key_written_not_shown() {
  local all
  all=$(cat "$1"/*.tf)
  grep -qE 'service_account_id\s*=\s*google_service_account\.billing\.name' <<<"$all" \
    && grep -qE 'content_base64\s*=\s*google_service_account_key\.billing\.private_key$' <<<"$all" \
    && grep -qF 'filename             = pathexpand("~/.gcp/.${var.org}/key-${var.org}-${var.app}-billing.json")' <<<"$all" \
    && grep -qE 'file_permission\s*=\s*"0600"' <<<"$all" \
    && ! grep -qE '/home/|/root/' <<<"$(grep -vE '^\s*#' <<<"$all")" \
    && ! awk '/^output / { o = 1 } o && /google_service_account_key|private_key|local_sensitive_file/ { f = 1 } /^}/ { o = 0 } END { exit !f }' "$1"/*.tf
}
# action_creates_nothing <file> - no executed gcloud create / IAM binding: a
# gcloud call outside a comment and outside a do_log line (the printed owner
# steps)
action_creates_nothing() {
  ! awk '/^[[:space:]]*#/ || /do_log/ { next } /gcloud .*(service-accounts (keys )?create|add-iam-policy-binding)/ { f = 1 } END { exit !f }' "$1"
}

# --- 1. + 2. -------------------------------------------------------------------
only_sa_and_job_user "$SD" && pass "$STEP makes only the SA, its jobUser, its billing-account members, its export dataViewer, its key and the key file" || fail "$STEP resources are not exactly the SA + jobUser + billing members + dataset member + key + key file"
no_billing_grant "$SD" && pass "$STEP holds no dataset or billing-account binding/policy" || fail "$STEP has a dataset or billing-account binding/policy"
dataset_grant_as_source "$SD" && pass "$STEP grants dataViewer on var.export_source_dataset only, through google.export_source (the export project's own key)" || fail "$STEP dataset grant: not a dataset member on the export_source vars through google.export_source, or a project-level dataViewer"
billing_grants_from_var "$SD" && pass "$STEP grants billing.viewer + billing.user to its SA on each id of var.billing_account_ids (no default, validated, no id literal)" || fail "$STEP billing-account grants are not for_each over the ids of a validated, default-less var"
key_written_not_shown "$SD" && pass "$STEP writes the SA's key to ~/.gcp/.<org>/key-<org>-<app>-billing.json, 0600, and no output shows it" || fail "$STEP key: not the SA's own, not that file, not 0600, a literal home, or an output shows it"
grep -qE 'member\s*=\s*"serviceAccount:\$\{google_service_account\.billing\.email\}"' "$SD/03-sa.tf" \
  && grep -qE 'project\s*=\s*var\.gcp_project' "$SD/03-sa.tf" \
  && pass "the jobUser is granted to the step's SA on var.gcp_project" || fail "the jobUser member/project is not the step's SA on var.gcp_project"

# --- 3. prd only ---------------------------------------------------------------
grep -qE 'condition\s*=\s*var\.env == "prd"' "$SD/02-variables.tf" && pass "$STEP refuses any env but prd" || fail "$STEP has no prd-only env validation"
f="$CNF/dev/tf/$STEP.vars.tfvars"
# awk, not grep -v: the box grep is ugrep, whose -qv exit code differs
if [[ -f "$f" ]] && grep -qx '# prd-only-step' "$f" && awk '!/^(#.*|org .*|app .*|env .*|gcp_project .*|gcp_region .*|)$/ { bad = 1 } END { exit bad }' "$f"; then
  pass "dev $STEP render carries no step values"
else
  fail "dev $STEP render carries step values (the billing SA is prd only)"
fi

# --- 4. the prd render ---------------------------------------------------------
ep=$(yq -r '.env.cost.gcp.export_project' "$CNF/all.env.yaml")
bs=$(yq -r '.env.cost.gcp.billing_sa' "$CNF/all.env.yaml")
kp=$(yq -r ".env.steps.\"$STEP\".tf_key_project" "$CNF/prd.env.yaml")
v="$CNF/prd/tf/$STEP.vars.tfvars" b="$CNF/prd/tf/$STEP.backend-config.tfvars"
[[ "$ep" == csi-spl-all && "$bs" == spl-billing ]] && grep -qx "gcp_project = \"$ep\"" "$v" && grep -qx "billing_sa = \"$bs\"" "$v" \
  && pass "prd render: gcp_project=$ep billing_sa=$bs, from env.cost.gcp" || fail "prd render does not carry env.cost.gcp ($ep/$bs): $(cat "$v")"
sp=$(yq -r '.env.cost.gcp.export_source_project // .env.cost.gcp.export_project' "$CNF/all.env.yaml")
sd=$(yq -r '.env.cost.gcp.export_source_dataset // .env.cost.gcp.export_dataset' "$CNF/all.env.yaml")
[[ -n "$sp" && -n "$sd" ]] && grep -qx "export_source_project = \"$sp\"" "$v" && grep -qx "export_source_dataset = \"$sd\"" "$v" \
  && pass "prd render: export_source=$sp.$sd, from env.cost.gcp" || fail "prd render does not carry the export source ($sp.$sd): $(cat "$v")"
[[ "$kp" == "$ep" ]] && grep -qx 'bucket = "csi-spl-all-tfstate"' "$b" && grep -qx "prefix = \"terraform/$STEP\"" "$b" \
  && pass "$STEP runs as the $kp SA, state in csi-spl-all-tfstate/terraform/$STEP" || fail "$STEP key/state wiring ($kp): $(cat "$b")"

# --- 5. the action ---------------------------------------------------------------
action_creates_nothing "$ACT" && pass "do_gcp_billing_sa_create runs no create and no IAM binding" || fail "do_gcp_billing_sa_create still creates or binds"
grep -q "_GBS_STEP=$STEP" "$ACT" && pass "do_gcp_billing_sa_create points to $STEP" || fail "do_gcp_billing_sa_create does not name $STEP"

# --- 6. controls -----------------------------------------------------------------
c="$tmp/out"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"
printf '%s\n' 'output "billing_key" {' '  value     = google_service_account_key.billing.private_key' '  sensitive = true' '}' >"$c/99-planted.tf"
key_written_not_shown "$c" && fail "control: a planted output of the key was NOT caught" || pass "control: a planted output of the key is caught"
c="$tmp/mode"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i 's/"0600"/"0644"/' "$c/03-sa.tf"
key_written_not_shown "$c" && fail "control: a 0644 key file was NOT caught" || pass "control: a 0644 key file is caught"
c="$tmp/home"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i 's#pathexpand("~/#pathexpand("/root/#' "$c/03-sa.tf"
key_written_not_shown "$c" && fail "control: a literal home path was NOT caught" || pass "control: a literal home path is caught"
c="$tmp/bill"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"
printf '%s\n' 'resource "google_billing_account_iam_policy" "v" {' '  billing_account_id = "x"' '  policy_data = "x"' '}' >"$c/99-planted.tf"
no_billing_grant "$c" && fail "control: a planted billing-account policy was NOT caught" || pass "control: a planted billing-account policy is caught"
only_sa_and_job_user "$c" && fail "control: a planted eighth resource was NOT caught" || pass "control: a planted eighth resource is caught"
c="$tmp/proj"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i 's#"roles/bigquery.jobUser"#"roles/bigquery.dataViewer"#' "$c/03-sa.tf"
dataset_grant_as_source "$c" && fail "control: a project-level dataViewer was NOT caught" || pass "control: a project-level dataViewer is caught"
c="$tmp/prov"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i '/provider   = google.export_source/d' "$c/03-sa.tf"
dataset_grant_as_source "$c" && fail "control: the dataset grant on the step's own provider was NOT caught" || pass "control: the dataset grant on the step's own provider is caught"
c="$tmp/saprov"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i '/^resource "google_service_account" "billing"/a\  provider     = google.export_source' "$c/03-sa.tf"
dataset_grant_as_source "$c" && fail "control: the SA moved onto google.export_source was NOT caught" || pass "control: the SA moved onto google.export_source is caught"
c="$tmp/defcred"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i '0,/^  region  = var.gcp_region$/s##  region  = var.gcp_region\n  credentials = file(pathexpand("~/.gcp/.${var.org}/key-${var.export_source_project}.json"))#' "$c/01-providers.tf"
awk '/^provider "google" \{/ { v++ } v == 1 && /^  credentials = / { f = 1 } END { exit !f }' "$c/01-providers.tf" || fail "control setup: the default provider plant did not apply"
dataset_grant_as_source "$c" && fail "control: the export project's key on the default provider was NOT caught" || pass "control: the export project's key on the default provider is caught"
c="$tmp/lit"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i 's/billing_account_id = each.value/billing_account_id = "0A1B2C-3D4E5F-678901"/' "$c/03-sa.tf"
billing_grants_from_var "$c" && fail "control: a planted billing account id literal was NOT caught" || pass "control: a planted billing account id literal is caught"
c="$tmp/def"; mkdir -p "$c"; cp "$SD"/*.tf "$c/"; sed -i '/^variable "billing_account_ids"/a\  default = ""' "$c/02-variables.tf"
billing_grants_from_var "$c" && fail "control: a default on billing_account_ids was NOT caught" || pass "control: a default on billing_account_ids is caught"
sed 's/gcloud iam service-accounts describe/gcloud iam service-accounts create/' "$ACT" >"$tmp/act.sh"
action_creates_nothing "$tmp/act.sh" && fail "control: a planted gcloud create was NOT caught" || pass "control: a planted gcloud create in the action is caught"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
