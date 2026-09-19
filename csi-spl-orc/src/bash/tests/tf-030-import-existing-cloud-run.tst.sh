#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 030 import tools (ported from csi-rel-orc) import and only import.
#   importer (src/bash/scripts/tf-030-import-existing-cloud-run.sh), run by sh
#   against the real dev + prd tfvars with a stubbed terraform:
#   1. imports exactly the addresses 030-cloud-run-hub declares, with the ids
#      derived from the tfvars (SA = runtime_sa_account_id, never compute)
#   2. every address maps to a resource declared in the step, and every
#      resource the step declares is covered (drift guard both ways)
#   3. an address already in state is skipped, not re-imported
#   4. a failed import is non-fatal (exit 0, failed=1)
#   5. never calls terraform apply / destroy / plan (CONTROL: stub logs calls)
#   6. missing tfvars -> exit 1
#   action (do_tf_030_import_existing_cloud_run), with docker stubbed:
#   7. ENV unset / inf / qa -> refused, docker never called
#   8. no project key under $HOME/.gcp/.<org>/ -> refused, docker never called
#   9. a work dir without tf-030 in its name -> refused
#  10. happy path: init with the step's backend-config, then the importer with
#      the step's tfvars, the project key as GOOGLE_APPLICATION_CREDENTIALS;
#      no apply anywhere
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
STEP=030-cloud-run-hub
STEP_DIR="$APP_ROOT/csi-spl-iac/src/terraform/$STEP"
IMPORTER="$PROJ_ROOT/src/bash/scripts/tf-030-import-existing-cloud-run.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# terraform stub: `state list` prints $STATE_FIXTURE; `import` succeeds unless
# the address is listed in $FAIL_ADDR; anything else is recorded and fails.
mkdir -p "$T/stub"
cat >"$T/stub/terraform" <<'EOF'
#!/bin/sh
echo "terraform $*" >>"$STUB_LOG"
case "$1" in
  state) [ "$2" = list ] && [ -n "${STATE_FIXTURE:-}" ] && cat "$STATE_FIXTURE"; exit 0 ;;
  import)
    for a in "$@"; do last2=$prev; prev=$a; done
    echo "ADDR $last2" >>"$STUB_LOG"
    [ -n "${FAIL_ADDR:-}" ] && [ "$last2" = "$FAIL_ADDR" ] && { echo "Error: Cannot import non-existent remote object" >&2; exit 1; }
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/stub/terraform"

run_importer() { # <env> [extra env assignments...]
  local e=$1; shift
  : >"$T/calls.log"
  (cd "$T" && env STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" "$@" \
    sh "$IMPORTER" "$APP_ROOT/csi-spl-cnf/csi-spl/$e/tf/$STEP.vars.tfvars")
}

# resources the step declares: type.name
declared=$(command grep -hoE '^resource "[^"]+" "[^"]+"' "$STEP_DIR"/*.tf |
  sed -E 's/^resource "([^"]+)" "([^"]+)"/\1.\2/' | sort -u)

for e in dev prd; do
  vars="$APP_ROOT/csi-spl-cnf/csi-spl/$e/tf/$STEP.vars.tfvars"
  [[ -f "$vars" ]] || { fail "$e: missing $vars"; continue; }
  project=$(sed -nE 's/^gcp_project *= *"([^"]+)".*/\1/p' "$vars")
  sa_id=$(sed -nE 's/^runtime_sa_account_id *= *"([^"]+)".*/\1/p' "$vars")
  n_auth=$(sed -nE 's/^auth_secret_ids *= *\[(.*)\]/\1/p' "$vars" | tr ',' '\n' | command grep -c '"')
  n_dsn=$(sed -nE 's/^secret_environment_variables *= *\{(.*)\}/\1/p' "$vars" | command grep -oE ':[[:space:]]*"[^"]+"' | sort -u | wc -l)

  out=$(run_importer "$e"); rc=$?
  [[ $rc -eq 0 ]] && pass "$e: importer exit 0" || fail "$e: importer rc=$rc: $out"

  # 1. the address set and its ids
  addrs=$(sed -n 's/^ADDR //p' "$T/calls.log")
  n_inv=0; command grep -qE '^allow_unauthenticated *= *true' "$vars" && n_inv=1
  want=$((4 + n_auth + n_dsn + n_inv))
  got=$(printf '%s\n' "$addrs" | command grep -c .)
  [[ $got -eq $want ]] && pass "$e: $got imports (4 fixed + $n_auth auth slots + $n_dsn accessor + $n_inv invoker)" \
    || fail "$e: $got imports, want $want: $addrs"
  command grep -qF "google_service_account.hub projects/$project/serviceAccounts/$sa_id@$project.iam.gserviceaccount.com" "$T/calls.log" \
    && pass "$e: SA imported as the declared runtime_sa_account_id" || fail "$e: SA import id"
  command grep -E 'terraform import' "$T/calls.log" | command grep -q 'compute@developer' \
    && fail "$e: default compute SA used in an import" || pass "$e: default compute SA never imported"
  command grep -qF "google_storage_bucket_iam_member.hub_files_object_user b/$project-files roles/storage.objectUser serviceAccount:$sa_id@" "$T/calls.log" \
    && pass "$e: files bucket binding id" || fail "$e: files bucket binding id"
  command grep -qE "google_cloud_run_v2_service.hub projects/$project/locations/[a-z0-9-]+/services/" "$T/calls.log" \
    && pass "$e: service id" || fail "$e: service id"
  command grep -E '^terraform import' "$T/calls.log" | command grep -vqF -- "-var-file=" \
    && fail "$e: an import without -var-file" || pass "$e: every import passes -var-file"

  # 2. drift guard, both ways
  covered=$(printf '%s\n' "$addrs" | sed -E 's/\[.*$//' | sort -u)
  extra=$(comm -23 <(printf '%s\n' "$covered") <(printf '%s\n' "$declared"))
  missing=$(comm -13 <(printf '%s\n' "$covered") <(printf '%s\n' "$declared") | command grep -v '^terraform_data' || true)
  [[ -z "$extra" ]] && pass "$e: every imported address is declared in $STEP" || fail "$e: undeclared addresses: $extra"
  [[ -z "$missing" ]] && pass "$e: every $STEP resource is covered" || fail "$e: resources not covered: $missing"

  # 5. import only
  command grep -qE '^terraform (apply|destroy|plan|taint|state (rm|mv|push))' "$T/calls.log" \
    && fail "$e: a mutating/non-import terraform call" || pass "$e: only state list + import"
done

# 3. already in state -> skipped
printf '%s\n' google_cloud_run_v2_service.hub google_service_account.hub >"$T/state.txt"
out=$(run_importer dev STATE_FIXTURE="$T/state.txt")
command grep -qE '^terraform import .* google_cloud_run_v2_service.hub ' "$T/calls.log" \
  && fail "in-state service re-imported" || pass "in-state service skipped"
[[ "$out" == *"SKIP  already in state: google_service_account.hub"* ]] && pass "in-state SA reported SKIP" || fail "SKIP line"
[[ "$out" == *"skipped=2 "* ]] && pass "summary counts skipped=2" || fail "summary: $(echo "$out" | tail -5)"

# 4. failed import is non-fatal
out=$(run_importer dev FAIL_ADDR=google_cloud_run_v2_service.hub); rc=$?
[[ $rc -eq 0 && "$out" == *"failed=1"* && "$out" == *"WARN  could not import google_cloud_run_v2_service.hub"* ]] \
  && pass "failed import non-fatal (exit 0, failed=1)" || fail "failed import: rc=$rc"

# 6. missing tfvars
(cd "$T" && env STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" sh "$IMPORTER" "$T/nope.tfvars" >/dev/null 2>&1)
[[ $? -eq 1 ]] && pass "missing tfvars -> exit 1" || fail "missing tfvars not refused"

# ---- the action -------------------------------------------------------------
cat >"$T/stub/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$DOCKER_LOG"
exit 0
EOF
chmod +x "$T/stub/docker"

run_action() { # env assignments...
  : >"$T/docker.log"
  env DOCKER_LOG="$T/docker.log" PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "'"$PROJ_ROOT"'/src/bash/run/tf-030-import-existing-cloud-run.func.sh"
    do_tf_030_import_existing_cloud_run' 2>&1
}

mkdir -p "$T/home-nokey" "$T/home/.gcp/.csi"
echo '{}' >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# 7.
for bad in "" inf qa; do
  out=$(run_action HOME="$T/home" ENV="$bad" TF_030_WORK="$T/tf-030-x"); rc=$?
  [[ $rc -ne 0 && ! -s "$T/docker.log" ]] && pass "ENV='$bad' refused, no docker" || fail "ENV='$bad': rc=$rc"
done
# 8.
out=$(run_action HOME="$T/home-nokey" ENV=dev TF_030_WORK="$T/tf-030-dev"); rc=$?
[[ $rc -ne 0 && "$out" == *"missing credentials"* && ! -s "$T/docker.log" ]] \
  && pass "no project key -> refused, no docker" || fail "no key: rc=$rc $out"
# 9.
out=$(run_action HOME="$T/home" ENV=dev TF_030_WORK="$T/scratch"); rc=$?
[[ $rc -ne 0 && "$out" == *"refuse to reset"* ]] && pass "work dir guard" || fail "work dir guard: rc=$rc"
# 10.
out=$(run_action HOME="$T/home" ENV=dev TF_030_WORK="$T/tf-030-dev"); rc=$?
[[ $rc -eq 0 ]] && pass "happy path rc 0" || fail "happy path rc=$rc: $out"
[[ $(wc -l <"$T/docker.log") -eq 2 ]] && pass "two docker runs (init, import)" || fail "docker calls: $(cat "$T/docker.log")"
sed -n 1p "$T/docker.log" | command grep -q "init -input=false -backend-config=$STEP.backend-config.tfvars" \
  && pass "init uses the step backend-config" || fail "init args"
sed -n 2p "$T/docker.log" | command grep -q "/tf/tf-030-import-existing-cloud-run.sh $STEP.vars.tfvars" \
  && pass "importer runs with the step tfvars" || fail "importer args"
command grep -c "GOOGLE_APPLICATION_CREDENTIALS=/home/tf/.gcp/.csi/key-csi-spl-dev.json" "$T/docker.log" | command grep -qx 2 \
  && pass "both runs on the project key" || fail "credentials"
command grep -qwE 'apply|destroy' "$T/docker.log" && fail "apply/destroy in a docker call" || pass "no apply/destroy"
[[ -f "$T/tf-030-dev/04-cloud-run-service.tf" && -f "$T/tf-030-dev/$STEP.vars.tfvars" && -f "$T/tf-030-dev/tf-030-import-existing-cloud-run.sh" ]] \
  && pass "work dir holds step + tfvars + importer" || fail "work dir contents"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
