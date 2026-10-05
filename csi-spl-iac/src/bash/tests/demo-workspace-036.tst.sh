#!/usr/bin/env bash
# pre-push-tier: slow -- needs terraform (CI workflow 10 iac-suite)
#------------------------------------------------------------------------------
# Purpose: 036-spl-demo-workspace runs do_spl_demo_workspace_create through
#          terraform (077 iac audit) WITHOUT the demo root key entering state,
#          the plan or the apply output -- by APPLYING the step (local backend,
#          temp copy) with proj_path in a temp tree whose csi-spl-orc/run is a
#          stub that records its env and argv, writes a planted key into
#          $HOME/.spool-hub/tenants (as the real action does) and prints the
#          action's one JSON line. Then:
#            - the stub got `-a do_spl_demo_workspace_create` with ENV=dev,
#              DRY_RUN=0 and SPOOL_BIN=<api>/bin/spool
#            - the key is in neither the state nor the apply output
#            - an unchanged input does not re-run it; a new workspace id does
#            - demo_enabled=false runs nothing
#          Static: dev/prd tfvars = cnf env.demo (one key per fact); the
#          tf-runner image pins cloud-sql-proxy by version (= cnf
#          cloud_sql_proxy_image) and sha256 and installs psql; compose mounts
#          ~/.spool-hub; make makes it 0700 first and builds spool for 036.
#          The action's own read-first idempotency is csi-spl-orc's
#          demo-workspace-create.tst.sh.
#          terraform: $TF_BIN, else the newest $HOME/.local/share/csi-spl/bin/
#          terraform-*, else PATH. Missing terraform is a FAIL unless
#          SPL_TF_ALLOW_SKIP=1 (spec 007 T070).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP="$PROJ_ROOT/src/terraform/036-spl-demo-workspace"
ORC="$APP_ROOT/csi-spl-orc"
fails=0

[[ -d "$STEP" ]] || { echo "FAIL: missing $STEP"; exit 1; }

# --- static: the step ----------------------------------------------------------
code=$(grep -hvE '^[[:space:]]*#' "$STEP"/*.tf)
grep -qE 'run -a do_spl_demo_workspace_create' <<<"$code" && pass "036 calls the named action" || fail "036 does not call do_spl_demo_workspace_create"
grep -qE 'triggers_replace[[:space:]]*=[[:space:]]*\[var\.env, var\.gcp_project, var\.demo_workspace\]' <<<"$code" \
  && pass "036 re-runs only on env, project or workspace id" || fail "036 triggers_replace"
grep -qiE 'private_key|root_key|tenant_file|file\(' <<<"$code" && fail "036 reads or carries key material" || pass "036 carries no key material"
grep -qE 'resource "google_|provider "' <<<"$code" && fail "036 has a provider resource" || pass "036 has only terraform_data"
for e in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$e/tf/036-spl-demo-workspace.vars.tfvars"
  j="$APP_ROOT/csi-spl-cnf/csi-spl/$e.env.json"
  want_en=$(jq -r '.env.demo.enabled' "$j"); want_ws=$(jq -r '.env.demo.workspace' "$j")
  grep -qx "demo_enabled = $want_en" "$v" && grep -qx "demo_workspace = \"$want_ws\"" "$v" \
    && pass "$e 036 tfvars = cnf env.demo ($want_en, $want_ws)" || fail "$e 036 tfvars differ from cnf env.demo"
done

# --- static: the image, the mount, make ----------------------------------------
DF="$ORC/src/docker/tf-runner/Dockerfile"
img=$(jq -r '.env.hub.cloud_sql_proxy_image' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.json")
grep -qx "ARG CLOUD_SQL_PROXY_VERSION=${img##*:}" "$DF" && pass "tf-runner proxy version = cnf ${img##*:}" || fail "tf-runner proxy version != cnf $img"
grep -qE '^ARG CLOUD_SQL_PROXY_SHA256=[0-9a-f]{64}$' "$DF" && grep -q 'sha256sum -c' "$DF" \
  && pass "tf-runner checks the proxy's sha256" || fail "tf-runner proxy is not pinned by sha256"
grep -qE 'install .*postgresql-client' "$DF" && pass "tf-runner installs psql" || fail "tf-runner has no postgresql-client"
awk '/^  tf-runner:/,/^volumes:/' "$ORC/src/docker/docker-compose-tf-infra.yaml" | grep -qF '"~/.spool-hub:${DOCKER_HOME}/.spool-hub"' \
  && pass "tf-runner mounts ~/.spool-hub" || fail "tf-runner does not mount ~/.spool-hub"
MK="$ORC/src/make/setup-app-inf.func.mk"
n=$(grep -cE '^do-setup-app-inf(-no-cache|-up)?:.* do-spool-hub-dir$' "$MK")
[[ "$n" == 3 ]] && pass "all 3 setup targets make ~/.spool-hub first" || fail "do-spool-hub-dir prereq on $n of 3 setup targets"
grep -q 'mkdir -p -m 700 $(HOME)/.spool-hub' "$MK" && pass "~/.spool-hub is made 0700" || fail "~/.spool-hub mode"
grep -A2 '036-spl-demo-workspace)' "$ORC/src/make/tf-tasks.func.mk" | grep -q 'csi-spl-api/src/bash/build.sh' \
  && pass "do-provision builds spool for 036" || fail "do-provision does not build spool for 036"

# --- behaviour -----------------------------------------------------------------
TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ ! -x "$TF" ]]; then
  if [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then echo "SKIP: no terraform"; echo "PARTIAL: $(basename "$0")"; exit 0; fi
  fail "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH)"
  echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/tree/csi-spl-iac" "$T/tree/csi-spl-orc" "$T/run"
cp -r "$STEP/." "$T/run/"
printf 'terraform {\n  backend "local" {}\n}\n' >"$T/run/backend_override.tf"
MARK="STUB-ROOT-KEY-$$-$RANDOM"
cat >"$T/tree/csi-spl-orc/run" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$RUN_LOG".*.argv 2>/dev/null | wc -l)
echo "$*" >"$RUN_LOG.$n.argv"
echo "ENV=$ENV DRY_RUN=$DRY_RUN SPOOL_BIN=$SPOOL_BIN" >"$RUN_LOG.$n.env"
( umask 077 && mkdir -p "$HOME/.spool-hub/tenants" && echo "{\"root_private_key\":\"$STUB_MARK\"}" >"$HOME/.spool-hub/tenants/$ENV-demo.json" )
echo "{\"workspace\":\"demo\",\"env\":\"$ENV\",\"created\":false}"
STUB
chmod +x "$T/tree/csi-spl-orc/run"

tfrun() {  # apply the temp copy with the stub action
  env HOME="$T/home" RUN_LOG="$T/log" STUB_MARK="$MARK" TF_IN_AUTOMATION=1 \
    "$TF" -chdir="$T/run" "$@" -no-color \
    -var=org=csi -var=app=spl -var=env=dev -var=gcp_project=csi-spl-dev \
    -var=proj_path="$T/tree/csi-spl-iac"
}
env HOME="$T/home" "$TF" -chdir="$T/run" init -input=false -no-color >/dev/null 2>&1 || fail "terraform init (local backend)"

out=$(tfrun plan -input=false -var=demo_enabled=true -var=demo_workspace=demo 2>&1)
grep -q 'Plan: 1 to add, 0 to change, 0 to destroy' <<<"$out" && pass "a first plan adds only the terraform_data" || fail "first plan: $out"
out=$(tfrun apply -auto-approve -input=false -var=demo_enabled=true -var=demo_workspace=demo 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "apply succeeds" || fail "apply failed: $out"
[[ "$(cat "$T/log.0.argv" 2>/dev/null)" == "-a do_spl_demo_workspace_create" ]] && pass "run called: -a do_spl_demo_workspace_create" || fail "run argv: $(cat "$T/log.0.argv" 2>/dev/null)"
[[ "$(cat "$T/log.0.env" 2>/dev/null)" == "ENV=dev DRY_RUN=0 SPOOL_BIN=$T/tree/csi-spl-iac/../csi-spl-api/src/go/spool-hub-api/bin/spool" ]] \
  && pass "run env: ENV=dev DRY_RUN=0 SPOOL_BIN=<api>/bin/spool" || fail "run env: $(cat "$T/log.0.env" 2>/dev/null)"
grep -q '"created":false' <<<"$out" && pass "the action's created:false shows in the apply output" || fail "no created:false in the apply output"
grep -q "$MARK" "$T/home/.spool-hub/tenants/dev-demo.json" && pass "CONTROL: the stub wrote the key to the ~/.spool-hub file" || fail "CONTROL: no key in the tenants file"
grep -q "$MARK" "$T/run/terraform.tfstate" && fail "the ROOT KEY is in terraform state" || pass "the key is not in terraform state"
grep -q "$MARK" <<<"$out" && fail "the root key appeared in the apply output" || pass "the key never appears in the apply output"

out=$(tfrun apply -auto-approve -input=false -var=demo_enabled=true -var=demo_workspace=demo 2>&1)
[[ ! -e "$T/log.1.argv" ]] && pass "unchanged inputs do not re-run the action" || fail "re-ran on unchanged inputs"
out=$(tfrun plan -input=false -detailed-exitcode -var=demo_enabled=true -var=demo_workspace=demo 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "a re-plan shows no changes" || fail "re-plan rc=$rc: $out"

out=$(tfrun apply -auto-approve -input=false -var=demo_enabled=true -var=demo_workspace=demo2 2>&1)
[[ -e "$T/log.1.argv" ]] && pass "a new workspace id re-runs the action" || fail "a new workspace id did not re-run"

rm -f "$T"/log.*
out=$(tfrun apply -auto-approve -input=false -var=demo_enabled=false -var=demo_workspace=demo2 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$T/log.0.argv" ]] && pass "demo_enabled=false runs nothing" || fail "demo off: rc=$rc run=$(ls "$T"/log.* 2>/dev/null)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
