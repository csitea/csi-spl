#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every terraform run goes through do_tf_init (ported from csi-rel
#          unchanged), and do_tf_init points GOOGLE_APPLICATION_CREDENTIALS at
#          the project IaC SA key ~/.gcp/.<org>/key-<gcp_project>.json that
#          do_gcp_002 mints -- never at the caller's gcloud ADC.
#          1. the real do_tf_init, run against the committed dev/prd env.json,
#             exports the key path of THAT env's project and copies the step
#             and src/terraform/modules into bin/<org>/<app>/<env>/.
#          2. CONTROL: with that key file ABSENT and a user ADC present in
#             $HOME, a real `terraform init` of the gcs backend REFUSES and
#             names the missing key file: GOOGLE_APPLICATION_CREDENTIALS is
#             read before any network call and there is no fall back to the
#             ADC. Needs terraform ($TF_BIN, $HOME/.local/share/csi-spl/bin/
#             terraform-*, or PATH); without it this part FAILS (it would
#             otherwise prove nothing), unless SPL_TF_ALLOW_SKIP=1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/iac/src"
cp -r "$PROJ_ROOT/src/terraform" "$T/iac/src/"
# tfswitch is the container's; here it only has to succeed.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/tfswitch"; chmod +x "$T/bin/tfswitch"

for env in dev prd; do
  proj=$(jq -r '.env.gcp.gcp_project' "$APP_ROOT/csi-spl-cnf/csi-spl/$env.env.json")
  out=$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" HOME="$T/home" \
      SRC_ROOT="$PROJ_ROOT" PROJ_PATH="$T/iac" APP_PATH="$APP_ROOT" BASE_PATH=/ ORG_PATH=/ \
      ORG=csi APP=csi-spl ENV="$env" STEP=000-gcp-remote-bucket bash -c '
    set -u
    do_log() { :; }
    quit_on() { :; }
    for f in "$SRC_ROOT"/lib/bash/funcs/{require-var,export-json-section-vars}.func.sh \
             "$SRC_ROOT"/src/bash/run/{export-json-section-vars-as-tf-vars,tf-init}.func.sh; do source "$f"; done
    do_tf_init >/dev/null 2>&1
    echo "GAC=$GOOGLE_APPLICATION_CREDENTIALS"
    echo "APP=$APP"
    echo "RUN=$tf_run_path"
    ls "$tf_run_path"/*.tf >/dev/null 2>&1 && echo STEP_COPIED
    [[ -f "$tf_run_path/../modules/README.md" ]] && echo MODULES_COPIED
  ' 2>&1)
  want="$T/home/.gcp/.csi/key-$proj.json"
  if grep -qx "GAC=$want" <<<"$out"; then
    pass "$env: GOOGLE_APPLICATION_CREDENTIALS = ~/.gcp/.csi/key-$proj.json"
  else
    fail "$env: GOOGLE_APPLICATION_CREDENTIALS, want $want, got: $(grep '^GAC=' <<<"$out" || tail -3 <<<"$out")"
  fi
  grep -qx 'APP=spl' <<<"$out" && pass "$env: APP csi-spl normalised to spl" || fail "$env: APP not normalised: $(grep '^APP=' <<<"$out")"
  if grep -qx STEP_COPIED <<<"$out" && grep -qx MODULES_COPIED <<<"$out" \
     && grep -qx "RUN=$T/iac/bin/csi/spl/$env/000-gcp-remote-bucket" <<<"$out"; then
    pass "$env: step + modules copied to bin/csi/spl/$env/000-gcp-remote-bucket"
  else
    fail "$env: run dir: $(grep -E '^RUN=|COPIED' <<<"$out" | tr '\n' ' ')"
  fi
done

# --- 2. CONTROL: no key file -> terraform refuses, no ADC fall back -----------
TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ -n "$TF" && -x "$TF" ]]; then
  mkdir -p "$T/ctl/run" "$T/ctl/home/.config/gcloud"
  printf '%s\n' 'terraform {' '  backend "gcs" {}' '}' >"$T/ctl/run/main.tf"
  # a user ADC the provider WOULD find if it fell back to the well-known file
  printf '%s\n' '{"type":"authorized_user","client_id":"x","client_secret":"x","refresh_token":"x"}' \
    >"$T/ctl/home/.config/gcloud/application_default_credentials.json"
  missing="$T/ctl/home/.gcp/.csi/key-csi-spl-dev.json"
  out=$(env -i PATH=/usr/bin:/bin HOME="$T/ctl/home" \
      GOOGLE_APPLICATION_CREDENTIALS="$missing" TF_IN_AUTOMATION=1 \
      timeout 120 "$TF" -chdir="$T/ctl/run" init -input=false -no-color \
      -backend-config="bucket=csi-spl-dev-tfstate" -backend-config="prefix=terraform/ctl" 2>&1)
  rc=$?
  if [[ $rc -ne 0 && "$out" == *"$missing"* ]]; then
    pass "control: no key file -> terraform init refuses (rc=$rc) and names the missing key"
  else
    fail "control: no key file: rc=$rc, output: $(tail -5 <<<"$out")"
  fi
elif [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then
  echo "SKIP: control needs terraform"
else
  fail "control needs terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH), or SPL_TF_ALLOW_SKIP=1"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
