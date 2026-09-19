#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the committed tfvars are what tpl-gen renders from the committed
#          yaml TODAY (an edited yaml that was never re-rendered fails here),
#          the relay bucket carries the measured bnc-cpt-all-relay access model,
#          and every step is terraform-fmt clean and validates.
#          A missing tpl-gen clone or terraform binary is a FAIL (spec 007
#          T070): the suite used to SKIP both from any worktree or any user
#          but the owner and still print "PASS: all", having validated
#          nothing. SPL_TF_ALLOW_SKIP=1 turns the two back into SKIPs, and the
#          summary then says PARTIAL, never "all".
#          Control: a copy of 016 with a planted undeclared reference MUST
#          fail validate; a validate that accepts it proves nothing.
#
#          tpl-gen: $TPL_GEN_DIR, else <app>/tpl-gen, else the tpl-gen clone
#          beside the MAIN checkout (a worktree has none of its own: it is
#          git-ignored). terraform: $TF_BIN, else the newest
#          $HOME/.local/share/csi-spl/bin/terraform-*, else terraform on PATH.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skipped=0
skip() {
  if [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then echo "SKIP: $1"; skipped=$((skipped + 1));
  else fail "$1 (a skip validates nothing; install it, or SPL_TF_ALLOW_SKIP=1 to accept a PARTIAL run)"; fi
}

# --- 1. renders are in sync with the yaml -------------------------------------
TPG=""
main_root=$(git -C "$APP_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname)
for c in "${TPL_GEN_DIR:-}" "$APP_ROOT/tpl-gen" "${main_root:+$main_root/tpl-gen}"; do
  [[ -n "$c" && -x "$c/src/python/tpl-gen/.venv/bin/python" ]] && { TPG="$c/src/python/tpl-gen"; break; }
done
if [[ -n "$TPG" ]]; then
  for env in dev prd; do
    # tpl-gen maps a template to its output by stripping as many leading path
    # components as TGT has, so TGT must sit exactly as deep as PROJ_ROOT.
    tmp=$(mktemp -d) tgt=""
    tgt="$tmp"
    while (( $(tr -cd / <<<"$tgt" | wc -c) < $(tr -cd / <<<"$PROJ_ROOT" | wc -c) )); do tgt="$tgt/d"; done
    mkdir -p "$tgt/csi-spl"
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
    do_spl_merged_cnf "$APP_ROOT/csi-spl-cnf/csi-spl" "$env" "$tgt/csi-spl/$env.env.yaml"
    ( cd "$TPG" && ORG=csi APP=spl ENV="$env" CNF_SRC="$tgt/csi-spl/$env.env.yaml" \
        TPL_SRC="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf" TGT="$tgt" \
        .venv/bin/python tpl_gen/tpl_gen.py >/dev/null 2>&1 )
    n_new=$(find "$tgt/csi-spl/$env/tf" -name '*.tfvars' 2>/dev/null | wc -l)
    if (( n_new > 0 )) && diff -r "$tgt/csi-spl/$env/tf" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf" >/dev/null; then
      pass "$env tfvars are in sync with $env.env.yaml ($n_new files rendered)"
    else
      fail "$env tfvars differ from a fresh render (run ENV=$env ./run -a do_tpl_gen)"
    fi
    rm -rf "$tmp"
  done
else
  skip "no tpl-gen venv (TPL_GEN_DIR, $APP_ROOT/tpl-gen, ${main_root:-<main checkout>}/tpl-gen)"
fi

# --- 2. the relay bucket is bnc-cpt-all-relay's access model ------------------
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/020-gcp-relay-bucket.vars.tfvars"
  grep -qx "relay_bucket_name = \"csi-spl-$env-rel\"" "$v" && pass "$env relay bucket is csi-spl-$env-rel" || fail "$env relay bucket name"
  # spec 001 FR-002/FR-003: the one deliberate difference (1-day lifecycle),
  # the measured soft delete, and the relay SA id git-rel's key is named for.
  grep -qx 'object_max_age_days = 1' "$v" && pass "$env relay objects expire after 1 day" || fail "$env relay object_max_age_days is not 1"
  grep -qx 'soft_delete_retention_seconds = 604800' "$v" && pass "$env relay soft delete is 604800 s" || fail "$env relay soft delete is not 604800 s"
  grep -qx "relay_sa_account_id = \"csi-spl-rel-$env\"" "$v" && pass "$env relay SA is csi-spl-rel-$env" || fail "$env relay SA id"
done
b="$PROJ_ROOT/src/terraform/020-gcp-relay-bucket/03-relay-bucket.tf"
grep -qE '^\s*uniform_bucket_level_access\s*=\s*true' "$b" && pass "uniform bucket-level access on" || fail "uniform bucket-level access is not true"
grep -qE '^\s*public_access_prevention\s*=\s*"enforced"' "$b" && pass "public access prevention enforced" || fail "public access prevention is not enforced"
grep -qE 'predefined_acl|default_acl|allUsers|allAuthenticatedUsers' "$PROJ_ROOT/src/terraform/020-gcp-relay-bucket/"*.tf && fail "a public/ACL grant appears in 020" || pass "no ACL or allUsers grant in 020"
# spec 001 FR-003: the relay SA gets exactly ONE role, bucket-scoped, and no
# project-level IAM resource exists in 020.
r="$PROJ_ROOT/src/terraform/020-gcp-relay-bucket"
[[ "$(cat "$r"/*.tf | grep -cE '^resource "google_storage_bucket_iam_member"')" == 1 ]] \
  && grep -qE '^\s*role\s*=\s*"roles/storage.objectUser"' "$r/04-relay-sa.tf" \
  && pass "relay SA holds exactly one binding, roles/storage.objectUser" || fail "relay SA binding is not exactly one roles/storage.objectUser"
grep -qE '^resource "google_project_iam_' "$r"/*.tf && fail "020 grants a project-level role" || pass "020 grants no project-level role"

# --- 2b. the hub steps (030/040/050) ------------------------------------------
TFD="$PROJ_ROOT/src/terraform"
f="$TFD/050-gcs-files/03-files-bucket.tf"
grep -qE '^\s*uniform_bucket_level_access\s*=\s*true' "$f" && pass "files bucket: uniform bucket-level access on" || fail "files bucket: uniform access is not true"
grep -qE '^\s*public_access_prevention\s*=\s*"enforced"' "$f" && pass "files bucket: public access prevention enforced" || fail "files bucket: PAP is not enforced"
grep -qE 'predefined_acl|default_acl|allUsers|allAuthenticatedUsers' "$TFD/050-gcs-files/"*.tf && fail "a public/ACL grant appears in 050" || pass "no ACL or allUsers grant in 050"
# No secret may reach tf state: no password, no generated secret, no secret
# VERSION, no SA key anywhere in the terraform tree.
grep -lE 'resource "(random_password|google_secret_manager_secret_version|google_service_account_key)"|resource "google_sql_user"' "$TFD"/*/*.tf >/dev/null \
  && fail "a state-borne secret resource appears in src/terraform: $(grep -lE 'resource "(random_password|google_secret_manager_secret_version|google_service_account_key|google_sql_user)"' "$TFD"/*/*.tf | tr '\n' ' ')" \
  || pass "no password, secret version, SQL user or SA key resource in any step"
# M3 WUI Hosting (016/019): copy pas-psf/csi-rel Hosting shape, not the shop.
[[ -d "$TFD/016-firebase-deploy-iam" && -d "$TFD/019-firebase-static-site" ]] \
  && pass "016 and 019 WUI firebase steps exist" || fail "016/019 WUI firebase steps missing"
grep -qE 'credentials\s*=\s*file\(' "$TFD"/016-firebase-deploy-iam/*.tf "$TFD"/019-firebase-static-site/*.tf \
  && fail "016/019 bake a credentials file() path" || pass "016/019 use ADC (no credentials file())"
grep -qiE 'wordpress|recaptcha' "$TFD"/016-firebase-deploy-iam/*.tf "$TFD"/019-firebase-static-site/*.tf \
  && fail "016/019 still carry shop entities" || pass "016/019 have no shop entities"
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/016-firebase-deploy-iam.vars.tfvars"
  grep -qx "deploy_sa_account_id = \"csi-spl-$env-fb-deploy\"" "$v" && pass "$env firebase deploy SA is csi-spl-$env-fb-deploy" || fail "$env firebase deploy SA id"
  grep -qx "site_id = \"csi-spl-$env-site\"" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/019-firebase-static-site.vars.tfvars" \
    && pass "$env firebase site_id is csi-spl-$env-site" || fail "$env firebase site_id"
done
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/030-cloud-run-hub.vars.tfvars"
  grep -qx 'max_instances                = 1' "$v" && pass "$env hub max_instances = 1 (OQ-05)" || fail "$env hub max_instances is not 1"
  grep -qx 'ingress                      = "all"' "$v" && pass "$env hub ingress is all (owner 2026-09-19: csi-rel domain mappings, no LB)" || fail "$env hub ingress is not all"
  grep -qx 'min_instances                = 1' "$v" && pass "$env hub min_instances = 1 (M1)" || fail "$env hub min_instances is not 1"
  grep -q "\"SPOOL_HUB_FILES_BUCKET\": \"csi-spl-$env-files\"" "$v" && pass "$env hub env names the 050 bucket" || fail "$env SPOOL_HUB_FILES_BUCKET is not csi-spl-$env-files"
  # the exact key: SPOOL_HUB_DB_DSN_EPOCH (017 T029 roll trigger) is a plain env var on purpose
  grep -E '^environment_variables ' "$v" | grep -q '"SPOOL_HUB_DB_DSN":' && fail "$env DSN is a plain env var" || pass "$env DSN is not a plain env var"
  grep -E '^secret_environment_variables ' "$v" | grep -q '"SPOOL_HUB_DB_DSN": "csi-spl-hub-db-dsn"' && pass "$env DSN comes from Secret Manager" || fail "$env DSN is not a secret_environment_variable"
  grep -q "^files_bucket_name = \"csi-spl-$env-files\"" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/050-gcs-files.vars.tfvars" && pass "$env files bucket is csi-spl-$env-files" || fail "$env files bucket name"
  # 017 T029: the schema owner's DSN has its own 040 slot, and the hub never sees it
  grep -qx 'owner_dsn_secret_id = "csi-spl-hub-db-owner-dsn"' "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/040-cloud-sql-postgres.vars.tfvars" \
    && pass "$env 040 renders the owner DSN slot" || fail "$env 040 lacks owner_dsn_secret_id"
  grep -q 'csi-spl-hub-db-owner-dsn' "$v" && fail "$env 030 references the owner DSN secret (injected or granted to the hub)" \
    || pass "$env 030 never references the owner DSN secret"
done
# CONTROL for the plain-DSN check: the exact-key grep catches a planted DSN
printf '%s\n' 'environment_variables = {"SPOOL_HUB_DB_DSN_EPOCH": "1", "SPOOL_HUB_DB_DSN": "postgres://x"}' |
  grep -E '^environment_variables ' | grep -q '"SPOOL_HUB_DB_DSN":' && pass "CONTROL: a planted plain SPOOL_HUB_DB_DSN is caught" \
  || fail "CONTROL: plain-DSN grep misses a planted DSN"
# CONTROL for the check above: the owner slot id is a real string in 040's
# tfvars, so the 030 grep searches for something that exists.
grep -rq 'csi-spl-hub-db-owner-dsn' "$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/" && pass "CONTROL: the owner slot id appears in the rendered tfvars" \
  || fail "CONTROL: owner slot id not rendered anywhere"

# --- 2c. 017 GitHub WIF (CI deploy identity; no SA JSON key) --------------------
[[ -d "$TFD/017-github-wif-deploy" ]] \
  && pass "017 github WIF step exists" || fail "017-github-wif-deploy missing"
grep -qE 'credentials\s*=\s*file\(' "$TFD"/017-github-wif-deploy/*.tf \
  && fail "017 bakes a credentials file() path" || pass "017 uses ADC (no credentials file())"
grep -qE 'resource "google_service_account_key"' "$TFD"/017-github-wif-deploy/*.tf \
  && fail "017 has an SA key resource" || pass "017 has no SA key resource"
grep -qE 'resource "google_iam_workload_identity_pool"' "$TFD"/017-github-wif-deploy/*.tf \
  && pass "017 creates a WIF pool" || fail "017 has no WIF pool"
grep -qE 'attribute_condition' "$TFD"/017-github-wif-deploy/*.tf \
  && pass "017 pins trust with attribute_condition" || fail "017 has no attribute_condition"
# The deploy SA must be one 017 creates: binding WIF to an SA nobody made
# fails at apply (the owner SA <project>@<project> does not exist here).
grep -qE 'resource "google_service_account" "deploy"' "$TFD"/017-github-wif-deploy/*.tf \
  && pass "017 creates its deploy SA" || fail "017 does not create the deploy SA"
grep -q 'iam.gserviceaccount.com"' "$TFD"/017-github-wif-deploy/03-github-wif.tf \
  && grep -q 'project}@${var.gcp_project}' "$TFD"/017-github-wif-deploy/*.tf \
  && fail "017 still binds the non-existent <project>@<project> SA" || pass "017 binds no <project>@<project> SA"
for role in roles/artifactregistry.writer roles/run.developer roles/iam.serviceAccountUser roles/iam.workloadIdentityUser; do
  grep -q "\"$role\"" "$TFD"/017-github-wif-deploy/*.tf && pass "017 grants $role" || fail "017 lacks $role"
done
grep -qE 'role += "roles/(owner|editor)"' "$TFD"/017-github-wif-deploy/*.tf \
  && fail "017 grants a primitive role" || pass "017 grants no primitive role"
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/017-github-wif-deploy.vars.tfvars"
  grep -qx 'github_repository = "csitea/csi-spl"' "$v" \
    && pass "$env WIF github_repository is csitea/csi-spl" || fail "$env WIF github_repository"
  grep -qx "deploy_sa_account_id = \"csi-spl-deploy-$env\"" "$v" \
    && pass "$env deploy SA is csi-spl-deploy-$env" || fail "$env deploy_sa_account_id"
  grep -qx "hub_service_name          = \"csi-spl-hub-$env\"" "$v" \
    && pass "$env 017 targets csi-spl-hub-$env" || fail "$env 017 hub_service_name"
  for api in iamcredentials.googleapis.com sts.googleapis.com; do
    grep -q "\"$api\"" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/001-enable-gcp-services.vars.tfvars" \
      && pass "$env 001 enables $api (017 WIF)" || fail "$env 001 lacks $api"
  done
done

# --- 3. fmt + validate ----------------------------------------------------------
TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ -n "$TF" && -x "$TF" ]]; then
  "$TF" fmt -check -recursive "$PROJ_ROOT/src/terraform" >/dev/null && pass "terraform fmt clean" || fail "terraform fmt -check"
  # A private plugin cache: the shared one is not safe for concurrent inits
  # (measured 2026-09-17: validate failed once in 3 runs during another
  # operator's apply, and passed alone).
  tf_cache="$HOME/.terraform.d/plugin-cache/csi/spl/test-$$"
  mkdir -p "$tf_cache"
  for step in "$PROJ_ROOT"/src/terraform/*/; do
    tmp=$(mktemp -d); cp -r "$step." "$tmp/"
    if TF_PLUGIN_CACHE_DIR="$tf_cache" "$TF" -chdir="$tmp" init -backend=false -input=false >/dev/null 2>&1 \
       && "$TF" -chdir="$tmp" validate -no-color >/dev/null 2>&1; then
      pass "validate $(basename "$step")"
    else
      fail "validate $(basename "$step")"
    fi
    rm -rf "$tmp"
  done
  # Control (T070): a step with a planted undeclared reference must NOT validate.
  tmp=$(mktemp -d); cp -r "$PROJ_ROOT/src/terraform/016-firebase-deploy-iam/." "$tmp/"
  printf '%s\n' 'output "t070_control" {' '  value = var.t070_planted_undeclared' '}' >"$tmp/99-t070-control.tf"
  if TF_PLUGIN_CACHE_DIR="$tf_cache" "$TF" -chdir="$tmp" init -backend=false -input=false >/dev/null 2>&1 \
     && ! "$TF" -chdir="$tmp" validate -no-color >/dev/null 2>&1; then
    pass "control: validate rejects a planted undeclared reference"
  else
    fail "control: validate accepted (or could not init) a planted broken step, so every validate PASS above proves nothing"
  fi
  rm -rf "$tmp"
else
  skip "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH)"
fi

if [[ "$fails" -eq 0 && "$skipped" -gt 0 ]]; then
  echo "PARTIAL: $(basename "$0") -- $skipped check(s) SKIPPED under SPL_TF_ALLOW_SKIP=1, not validated"; exit 0
fi
[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
