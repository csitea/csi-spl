#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the wine-box actions, offline, in a throwaway HOME (no GCP):
#   1. do_spl_wine_box_ssh_keygen mints the pair at the cnf path, is
#      idempotent, and refuses a lone half.
#   2. do_spl_wine_box_stop defaults to DRY_RUN and, with DRY_RUN=0, calls
#      gcloud with --account. do_spl_wine_box_start is the same verb flipped.
#   3. do_spl_wine_box_ansible_sync refuses without DEST, copies the four
#      paths, leaves a README in place, and prints the csi-spl sha.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
export PROJ_PATH="$PROJ_ROOT"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
unset DRY_RUN DEST ACCOUNT GCP_ACCOUNT
export WINE_BOX_CNF_FILE="$T/dev.env.yaml"
cat >"$WINE_BOX_CNF_FILE" <<'EOF'
env:
  steps:
    061-gcp-vm-wine-box:
      gcp_project: test-proj
      vm_name: test-wine-box
      gcp_zone: europe-west2-a
      ssh_public_key_file: ~/.ssh/.t/debian@test-wine-box.pub
EOF
do_log() { echo "$*"; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@test-proj.iam.gserviceaccount.com; export GCP_ACCOUNT; }
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gcloud.log"
EOF
chmod +x "$T/bin/gcloud"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/wine-box.func.sh"
# shellcheck disable=SC1091
source "$PROJ_ROOT/src/bash/run/wine-box-ssh-keygen.func.sh"
# shellcheck disable=SC1091
source "$PROJ_ROOT/src/bash/run/wine-box-stop.func.sh"
# shellcheck disable=SC1091
source "$PROJ_ROOT/src/bash/run/wine-box-ansible-sync.func.sh"

key="$HOME/.ssh/.t/debian@test-wine-box"
( do_spl_wine_box_ssh_keygen ) >/dev/null 2>&1
[[ -f "$key" && -f "$key.pub" && "$(stat -c %a "$key")" == 600 ]] \
  && pass "keygen mints the pair at the cnf path, private 0600" || fail "keygen did not mint $key"
sum=$(sha256sum "$key" | cut -d' ' -f1)
( do_spl_wine_box_ssh_keygen ) >/dev/null 2>&1
[[ "$(sha256sum "$key" | cut -d' ' -f1)" == "$sum" ]] && pass "keygen is idempotent" || fail "keygen re-minted an existing pair"
mv "$key.pub" "$T/pub.bak"
if ( do_spl_wine_box_ssh_keygen ) >/dev/null 2>&1; then fail "keygen accepted a lone private half"; else pass "keygen refuses a lone half"; fi
mv "$T/pub.bak" "$key.pub"

rm -f "$T/gcloud.log"
( do_spl_wine_box_stop ) >/dev/null 2>&1
[[ ! -s "$T/gcloud.log" ]] && pass "stop defaults to DRY_RUN (no gcloud)" || fail "stop called gcloud without DRY_RUN=0"
out=$(DRY_RUN=0 do_spl_wine_box_stop)
grep -q -- '--account=sa@test-proj.iam.gserviceaccount.com' "$T/gcloud.log" \
  && grep -q 'instances stop test-wine-box' "$T/gcloud.log" \
  && grep -q -- '--zone=europe-west2-a' "$T/gcloud.log" \
  && pass "stop with DRY_RUN=0 pins --account" || fail "stop did not pin --account: $(cat "$T/gcloud.log" 2>/dev/null)"
grep -q 'do-tf-plan-destroy' <<<"$out" && pass "stop names the destroy plan" || fail "stop did not name destroy"
rm -f "$T/gcloud.log"
( DRY_RUN=0 do_spl_wine_box_start ) >/dev/null
grep -q 'instances start test-wine-box' "$T/gcloud.log" && pass "start is the same call with start" || fail "start did not call instances start"

if ( DEST= do_spl_wine_box_ansible_sync ) >/dev/null 2>&1; then fail "sync ran without DEST"; else pass "sync refuses without DEST"; fi
dest="$T/dest"
mkdir -p "$dest"
printf 'keep-me\n' >"$dest/README.en.md"
( DEST="$dest" do_spl_wine_box_ansible_sync ) >/dev/null
[[ ! -f "$dest/box-playbook.yaml" ]] && pass "sync defaults to DRY_RUN" || fail "sync copied on the default DRY_RUN"
pin=$(DEST="$dest" DRY_RUN=0 do_spl_wine_box_ansible_sync)
[[ -f "$dest/box-playbook.yaml" && -f "$dest/inventory.example.ini" && -f "$dest/vars.example.yml" \
  && -f "$dest/roles/08_vnc/tasks/main.yml" ]] \
  && pass "sync copies the playbook, the examples and the roles" || fail "sync did not copy the tree"
[[ "$(cat "$dest/README.en.md")" == "keep-me" ]] && pass "sync leaves a README in place" || fail "sync removed the README"
sha=$(git -C "$PROJ_ROOT" rev-parse HEAD)
grep -q "PIN csi-spl ${sha}" <<<"$pin" && pass "sync prints the csi-spl sha" || fail "sync did not print PIN csi-spl ${sha}"
! grep -q -- '--delete' "$PROJ_ROOT/src/bash/run/wine-box-ansible-sync.func.sh" \
  && pass "sync has no --delete" || fail "sync uses --delete"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
