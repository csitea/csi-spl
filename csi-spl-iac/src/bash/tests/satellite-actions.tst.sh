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

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
