#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4298 -- the revision name 030 sends with the hub's template
#          (030-cloud-run-hub/revision-name), driven offline with terraform
#          console: no provider, no GCP.
#          - nothing changed (live label = hash, live env = cnf env) -> the
#            live name, so a deploy by the 20 pipeline leaves the plan clean
#            (SPL-3997)
#          - env or another input changed -> a fresh <service>-tf-<8 hex>,
#            never the live name (Cloud Run 409s a known name with another
#            configuration), the same on every plan, and back to "clean"
#            once applied
#          CONTROL: master 8ca8fb600's behaviour (the ignored revision always
#          re-sends the live name) fails the "changed" case.
#          terraform: $TF_BIN, else the newest
#          $HOME/.local/share/csi-spl/bin/terraform-*, else terraform on PATH.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
MOD="$PROJ_ROOT/src/terraform/030-cloud-run-hub/revision-name"
[[ -f "$MOD/main.tf" ]] && pass "the module lives at 030-cloud-run-hub/revision-name" || { echo "FAIL: no $MOD/main.tf"; exit 1; }

TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
[[ -n "$TF" && -x "$TF" ]] || { echo "FAIL: no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH)"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# root <dir> <module dir>: a root that forwards every input to the module
root() {
  mkdir -p "$1"; cp -r "$2" "$1/mod"
  cat >"$1/main.tf" <<'TF'
variable "live_revision" { type = string }
variable "live_template_hash" { type = string }
variable "live_env" { type = map(string) }
variable "want_env" { type = map(string) }
variable "template_hash" { type = string }
module "r" {
  source             = "./mod"
  service_name       = "csi-spl-hub-dev"
  template_hash      = var.template_hash
  live_revision      = var.live_revision
  live_template_hash = var.live_template_hash
  live_env           = var.live_env
  want_env           = var.want_env
}
TF
  "$TF" -chdir="$1" init -backend=false -input=false -no-color >"$1.init.log" 2>&1
}
# rev <dir> <live_revision> <live_label> <live_env> <want_env> <hash> -> the
# module's revision, unquoted ("null" for none)
rev() {
  echo 'module.r.revision' | "$TF" -chdir="$1" console -no-color \
    -var "live_revision=$2" -var "live_template_hash=$3" -var "live_env=$4" -var "want_env=$5" -var "template_hash=$6" 2>&1 | tr -d '"'
}

root "$tmp/new" "$MOD" || { echo "FAIL: terraform init"; tail -5 "$tmp/new.init.log"; exit 1; }
A=0123456789abcdef B=fedcba9876543210
E0='{X="1"}' E1='{X="1",Y="2"}'
DEPLOYED=csi-spl-hub-dev-01219-paw

# check <dir> -> number of failed cases (prints a line per case)
check() {
  local d=$1 n=0 got f1 f2 f3
  # 1. SPL-3997: a 20 deploy renamed the revision; terraform's inputs unchanged
  got=$(rev "$d" "$DEPLOYED" "$A" "$E0" "$E0" "$A")
  [[ "$got" == "$DEPLOYED" ]] && pass "unchanged: the live (deployed) name, no revision diff -> $got" || { fail "unchanged: got '$got', want $DEPLOYED"; n=$((n + 1)); }
  # 2. SPL-4298: the 8 env adds (c-664's plan) -> fresh name, not the live one
  f1=$(rev "$d" "$DEPLOYED" "$A" "$E0" "$E1" "$B")
  [[ "$f1" =~ ^csi-spl-hub-dev-tf-[0-9a-f]{8}$ ]] && pass "env + inputs changed: a fresh name -> $f1" || { fail "env + inputs changed: got '$f1', want csi-spl-hub-dev-tf-<8 hex>"; n=$((n + 1)); }
  # 3. env drift only (an out-of-band gcloud --update-env-vars), same inputs
  f2=$(rev "$d" "$DEPLOYED" "$A" "$E1" "$E0" "$A")
  [[ "$f2" =~ ^csi-spl-hub-dev-tf- ]] && pass "env drift only: a fresh name -> $f2" || { fail "env drift only: got '$f2'"; n=$((n + 1)); }
  # 4. another input changed (cpu, limits: the label), env equal
  f3=$(rev "$d" "$DEPLOYED" "$A" "$E0" "$E0" "$B")
  [[ "$f3" =~ ^csi-spl-hub-dev-tf- ]] && pass "label differs: a fresh name -> $f3" || { fail "label differs: got '$f3'"; n=$((n + 1)); }
  # 5. the first apply after this fix: the live template has no label yet
  got=$(rev "$d" "$DEPLOYED" "" "$E0" "$E0" "$A")
  [[ "$got" =~ ^csi-spl-hub-dev-tf- ]] && pass "no label yet: a fresh name -> $got" || { fail "no label yet: got '$got'"; n=$((n + 1)); }
  # 6. a plan is stable: the same inputs give the same fresh name
  got=$(rev "$d" "$DEPLOYED" "$A" "$E0" "$E1" "$B")
  [[ "$got" == "$f1" ]] && pass "stable: a second plan gives the same fresh name" || { fail "unstable: '$got' then '$f1'"; n=$((n + 1)); }
  # 7. after that apply: live name = the fresh one, label = B -> clean
  got=$(rev "$d" "$f1" "$B" "$E1" "$E1" "$B")
  [[ "$got" == "$f1" ]] && pass "after the apply: the plan is clean -> $got" || { fail "after the apply: got '$got', want $f1"; n=$((n + 1)); }
  # 8. A -> B -> A: back to A from another live name gives a new name
  got=$(rev "$d" "$f1" "$B" "$E1" "$E0" "$A")
  [[ "$got" =~ ^csi-spl-hub-dev-tf- && "$got" != "$f1" ]] && pass "revert to earlier inputs: a name Cloud Run does not hold -> $got" || { fail "revert: got '$got'"; n=$((n + 1)); }
  # 9. a service terraform created (server-named, template.revision empty)
  got=$(rev "$d" "" "$A" "$E0" "$E0" "$A")
  [[ "$got" == null || "$got" == "tostring(null)" ]] && pass "unchanged, no live name: null (no diff on \"\")" || { fail "unchanged, no live name: got '$got', want null"; n=$((n + 1)); }
  return "$n"
}

check "$tmp/new"

# CONTROL: master 8ca8fb600 ignored template[0].revision, so the provider sent
# the live (state) name whatever changed. Model it as a module that always
# returns the live name: the "changed" cases must fail.
mkdir -p "$tmp/oldmod"; cp "$MOD/main.tf" "$tmp/oldmod/main.tf"
sed -i 's|^  value       = local.unchanged ? .*|  value       = var.live_revision|' "$tmp/oldmod/main.tf"
grep -q '^  value       = var.live_revision$' "$tmp/oldmod/main.tf" || fail "CONTROL could not plant the old behaviour"
root "$tmp/old" "$tmp/oldmod" || fail "CONTROL terraform init"
saved=$fails
check "$tmp/old" >"$tmp/control.log" 2>&1
fails=$saved
if grep -q '^FAIL: env + inputs changed' "$tmp/control.log"; then
  pass "CONTROL master's behaviour (re-send the live name) fails the changed case"
else
  fail "CONTROL master's behaviour passed the changed case"; sed 's/^/      /' "$tmp/control.log"
fi

[[ $fails -eq 0 ]] && echo "PASS: all revision-name-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
