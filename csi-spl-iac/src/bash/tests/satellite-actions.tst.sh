#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the satellite's box actions (spec 057), offline, in a throwaway HOME
#          with a throwaway cnf (no GCP, no ssh, no network):
#   1. do_satellite_ssh_keygen mints the pair at the cnf path (private 0600,
#      public = the cnf .pub), is idempotent, and REFUSES a lone half.
#   2. do_satellite_ssh_config writes ONE marked `Host satellite` block with
#      the IAP ProxyCommand, keeps the rest of ~/.ssh/config, and a re-run
#      replaces the block instead of appending a second one.
#   3. do_satellite_creds_push is a DRY RUN by default and never prints a
#      credential's content (CONTROL: the planted marker inside the key file
#      appears nowhere in its output).
#   4. satellite-iap-proxy.sh refuses without the SA key and pins --account;
#      satellite-box-setup.sh parses and only formats a BLANK disk (blkid
#      guard before mkfs).
#   5. destroy + recreate path (owner 2026-10-01): make do-tf-plan-destroy and
#      do-deprovision pass the billing id, do_tf_plan_destroy plans -destroy
#      only, and do_satellite_verify runs as the csi-spl-all SA ONLY (drops
#      ACCOUNT / GCP_ACCOUNT, refuses another identity, --account on every
#      gcloud) and prints one PASS/FAIL per check.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_PATH=$(cd "$TEST_DIR/../../.." && pwd)
export PROJ_PATH
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export SATELLITE_CNF_FILE="$T/prd.env.yaml"
cat >"$SATELLITE_CNF_FILE" <<'EOF'
env:
  steps:
    060-gcp-vm-satellite:
      gcp_project: test-proj
      vm_name: test-satellite
      gcp_zone: europe-north1-a
      os_user: debian
      ssh_public_key_file: ~/.ssh/.t/debian@test-satellite.pub
    120-github-general-secrets:
      gh_repo: example/repo
EOF
do_log() { echo "$*"; }
# shellcheck disable=SC1091
source "$PROJ_PATH/lib/bash/funcs/satellite.func.sh"
for f in satellite-ssh-keygen satellite-ssh-config satellite-creds-push; do
  # shellcheck disable=SC1090
  source "$PROJ_PATH/src/bash/run/$f.func.sh"
done

# --- 1. keygen ---------------------------------------------------------------------
key="$HOME/.ssh/.t/debian@test-satellite"
( do_satellite_ssh_keygen ) >/dev/null 2>&1
[[ -f "$key" && -f "$key.pub" && "$(stat -c %a "$key")" == 600 ]] \
  && pass "keygen mints the pair at the cnf path, private 0600" || fail "keygen did not mint $key (+.pub, 0600)"
sum=$(sha256sum "$key" | cut -d' ' -f1)
( do_satellite_ssh_keygen ) >/dev/null 2>&1
[[ "$(sha256sum "$key" | cut -d' ' -f1)" == "$sum" ]] && pass "keygen is idempotent (the pair is kept)" || fail "keygen re-minted an existing pair"
mv "$key.pub" "$T/pub.bak"
if ( do_satellite_ssh_keygen ) >/dev/null 2>&1; then fail "keygen accepted a lone private half"; else pass "keygen refuses a lone half"; fi
mv "$T/pub.bak" "$key.pub"

# --- 2. ssh config -----------------------------------------------------------------
printf 'Host other\n  HostName other.example\n' >"$HOME/.ssh/config"
( do_satellite_ssh_config ) >/dev/null 2>&1
( do_satellite_ssh_config ) >/dev/null 2>&1
c="$HOME/.ssh/config"
n=$(grep -c '^Host satellite test-satellite$' "$c")
[[ "$n" == 1 ]] && pass "one Host satellite block after two runs" || fail "Host satellite block count is $n"
grep -q '^Host other$' "$c" && pass "the rest of ~/.ssh/config is kept" || fail "do_satellite_ssh_config dropped another Host"
grep -qE "^  ProxyCommand bash .*/satellite-iap-proxy.sh test-proj europe-north1-a %h %p$" "$c" \
  && pass "ProxyCommand goes through the IAP proxy as the project" || fail "no IAP ProxyCommand in the block"
grep -qx "  IdentityFile $key" "$c" && pass "the block names the minted private key" || fail "IdentityFile is not $key"

# --- 3. creds push: dry run, no content ---------------------------------------------
mkdir -p "$HOME/.gcp/.csi" "$HOME/.github"
for e in dev prd; do echo '{"client_email":"t@example.com","note":"PLANTED-SECRET-MARKER"}' >"$HOME/.gcp/.csi/key-csi-spl-$e.json"; done
echo PLANTED-SECRET-MARKER >"$HOME/.github/token"
out=$( ( do_satellite_creds_push ) 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would copy' <<<"$out" && pass "creds push is a dry run by default" || fail "creds push default is not a dry run (rc=$rc)"
grep -q PLANTED-SECRET-MARKER <<<"$out" && fail "creds push printed a credential's content" || pass "CONTROL: no credential content in the output"

# --- 4. scripts -------------------------------------------------------------------------
px="$PROJ_PATH/src/bash/scripts/satellite-iap-proxy.sh"
if SATELLITE_SA_KEY="$T/none.json" bash "$px" p z i 22 >/dev/null 2>&1; then fail "the proxy ran without an SA key"; else pass "the proxy refuses without the SA key"; fi
grep -qE 'start-iap-tunnel .*' "$px" && grep -q -- '--account="\$account"' "$px" && pass "the proxy pins --account" || fail "the proxy does not pin --account"
bs="$PROJ_PATH/src/bash/scripts/satellite-box-setup.sh"
bash -n "$bs" && pass "satellite-box-setup.sh parses" || fail "satellite-box-setup.sh does not parse"
awk '/blkid "\$DATA_DEVICE"/ { g = NR } /mkfs\.ext4/ { m = NR } END { exit !(g && m && g < m) }' "$bs" \
  && pass "mkfs only after the blkid blank-disk guard" || fail "mkfs is not guarded by blkid"

# --- 5. destroy / recreate / verify ---------------------------------------------------
mk="$PROJ_PATH/../csi-spl-orc/src/make/tf-tasks.func.mk"
for tgt in do-tf-plan-destroy do-deprovision; do
  awk -v t="$tgt:" '$1 == t { on = 1; next } on && /^\.PHONY/ { on = 0 } on' "$mk" | grep -q 'TF_VAR_billing_account_id="$${GCP_BILLING_ACCOUNT_ID:-}"' \
    && pass "make $tgt passes GCP_BILLING_ACCOUNT_ID" || fail "make $tgt does not pass GCP_BILLING_ACCOUNT_ID"
done
pd="$PROJ_PATH/src/bash/run/tf-plan-destroy.func.sh"
grep -q 'plan -destroy' "$pd" && ! grep -qE 'terraform[^|]* (apply|destroy)( |$)' "$pd" \
  && pass "do_tf_plan_destroy only plans" || fail "do_tf_plan_destroy can change state"
v="$PROJ_PATH/src/bash/run/satellite-verify.func.sh"
grep -q 'unset ACCOUNT GCP_ACCOUNT' "$v" && grep -q 'refusing' "$v" && ! grep -q 'bootstrap_account\|gcp_account_owner_email' "$v" \
  && pass "verify runs as the csi-spl-all SA only" || fail "verify can run as another identity"
n_g=$(grep -cE 'gcloud (compute|billing|storage) ' "$v"); n_a=$(grep -E 'gcloud ' "$v" | grep -v 'command -v gcloud' | grep -cv -- '"\$acct"')
[[ "$n_g" -ge 4 && "$n_a" == 0 ]] && pass "every gcloud call in verify carries --account ($n_g)" || fail "a gcloud call in verify lacks \$acct ($n_a of them)"
grep -q 'prevent_destroy' "$PROJ_PATH/src/terraform/060-gcp-vm-satellite/03-vm.tf" | grep -q true \
  && fail "060 still blocks the owner's destroy drill" || pass "060 has no prevent_destroy (owner-gated destroy drill)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
