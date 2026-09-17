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
    cp "$APP_ROOT/csi-spl-cnf/csi-spl/$env.env.yaml" "$tgt/csi-spl/"
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

# --- 3. fmt + validate ----------------------------------------------------------
TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
if [[ -x "$TF" ]]; then
  "$TF" fmt -check -recursive "$PROJ_ROOT/src/terraform" >/dev/null && pass "terraform fmt clean" || fail "terraform fmt -check"
  for step in "$PROJ_ROOT"/src/terraform/*/; do
    tmp=$(mktemp -d); cp -r "$step." "$tmp/"
    if TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache" "$TF" -chdir="$tmp" init -backend=false -input=false >/dev/null 2>&1 \
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
