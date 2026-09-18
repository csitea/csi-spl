#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the committed tfvars are what tpl-gen renders from the committed
#          yaml TODAY (an edited yaml that was never re-rendered fails here),
#          the relay bucket carries the measured bnc-cpt-all-relay access model,
#          and every step is terraform-fmt clean and validates.
#          A missing tpl-gen clone or terraform binary is a SKIP, not a pass.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }

# --- 1. renders are in sync with the yaml -------------------------------------
TPG="$APP_ROOT/tpl-gen/src/python/tpl-gen"
if [[ -x "$TPG/.venv/bin/python" ]]; then
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
    if [[ -d "$tgt/csi-spl/$env/tf" ]] && diff -r "$tgt/csi-spl/$env/tf" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf" >/dev/null; then
      pass "$env tfvars are in sync with $env.env.yaml"
    else
      fail "$env tfvars differ from a fresh render (run ENV=$env ./run -a do_tpl_gen)"
    fi
    rm -rf "$tmp"
  done
else
  skip "no tpl-gen venv at $TPG"
fi

# --- 2. the relay bucket is bnc-cpt-all-relay's access model ------------------
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/020-gcp-relay-bucket.vars.tfvars"
  grep -qx "relay_bucket_name = \"csi-spl-$env-rel\"" "$v" && pass "$env relay bucket is csi-spl-$env-rel" || fail "$env relay bucket name"
done
b="$PROJ_ROOT/src/terraform/020-gcp-relay-bucket/03-relay-bucket.tf"
grep -qE '^\s*uniform_bucket_level_access\s*=\s*true' "$b" && pass "uniform bucket-level access on" || fail "uniform bucket-level access is not true"
grep -qE '^\s*public_access_prevention\s*=\s*"enforced"' "$b" && pass "public access prevention enforced" || fail "public access prevention is not enforced"
grep -qE 'predefined_acl|default_acl|allUsers|allAuthenticatedUsers' "$PROJ_ROOT/src/terraform/020-gcp-relay-bucket/"*.tf && fail "a public/ACL grant appears in 020" || pass "no ACL or allUsers grant in 020"

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
  grep -qx 'ingress                      = "internal-and-cloud-load-balancing"' "$v" && pass "$env hub ingress is LB-only (M1: IAP/IP allowlist, not the open internet)" || fail "$env hub ingress is not internal-and-cloud-load-balancing"
  grep -qx 'min_instances                = 1' "$v" && pass "$env hub min_instances = 1 (M1)" || fail "$env hub min_instances is not 1"
  grep -q "\"SPOOL_HUB_FILES_BUCKET\": \"csi-spl-$env-files\"" "$v" && pass "$env hub env names the 050 bucket" || fail "$env SPOOL_HUB_FILES_BUCKET is not csi-spl-$env-files"
  grep -E '^environment_variables ' "$v" | grep -q 'SPOOL_HUB_DB_DSN' && fail "$env DSN is a plain env var" || pass "$env DSN is not a plain env var"
  grep -E '^secret_environment_variables ' "$v" | grep -q '"SPOOL_HUB_DB_DSN": "csi-spl-hub-db-dsn"' && pass "$env DSN comes from Secret Manager" || fail "$env DSN is not a secret_environment_variable"
  grep -q "^files_bucket_name = \"csi-spl-$env-files\"" "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/050-gcs-files.vars.tfvars" && pass "$env files bucket is csi-spl-$env-files" || fail "$env files bucket name"
done

# --- 3. fmt + validate ----------------------------------------------------------
TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
if [[ -x "$TF" ]]; then
  "$TF" fmt -check -recursive "$PROJ_ROOT/src/terraform" >/dev/null && pass "terraform fmt clean" || fail "terraform fmt -check"
  # A private plugin cache: the shared one is not safe for concurrent inits
  # (measured 2026-09-17: validate failed once in 3 runs during another
  # operator's apply, and passed alone).
  tf_cache="$HOME/.terraform.d/plugin-cache/csi/spl/test"
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
else
  skip "no terraform under \$HOME/.local/share/csi-spl/bin"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
