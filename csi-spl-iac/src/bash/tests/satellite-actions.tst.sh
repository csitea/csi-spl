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
#   2b. after a recreate the stale host key is dropped and the guest's
#      published host keys are pinned (stub gcloud), and with none published
#      the stale entry is still gone (the first connect accepts the new key).
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
# offline stand-ins: the SA pin and a gcloud that serves guest-attribute host keys
do_gcp_pin_account() { GCP_ACCOUNT=sa@test-proj.iam.gserviceaccount.com; }
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *get-guest-attributes*--account=* && -n "${STUB_HOSTKEYS:-}" ]] && printf '%b\n' "$STUB_HOSTKEYS"
exit 0
STUB
chmod +x "$T/bin/gcloud"; export PATH="$T/bin:$PATH"
# shellcheck disable=SC1091
source "$PROJ_PATH/lib/bash/funcs/satellite.func.sh"
for f in satellite-ssh-keygen satellite-ssh-config satellite-creds-push satellite-install-tools satellite-replicate-ai-user satellite-verify; do
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
kh="$HOME/.ssh/known_hosts.satellite"
printf 'test-satellite ssh-ed25519 AAAAOLDSTALEKEY\nother.example ssh-ed25519 AAAAKEEP\n' >"$kh"
export STUB_HOSTKEYS='ssh-ed25519\tAAAANEWKEY1\necdsa-sha2-nistp256\tAAAANEWKEY2'
( do_satellite_ssh_config ) >/dev/null 2>&1
( do_satellite_ssh_config ) >/dev/null 2>&1
c="$HOME/.ssh/config"
n=$(grep -c '^Host satellite test-satellite$' "$c")
[[ "$n" == 1 ]] && pass "one Host satellite block after two runs" || fail "Host satellite block count is $n"
grep -q '^Host other$' "$c" && pass "the rest of ~/.ssh/config is kept" || fail "do_satellite_ssh_config dropped another Host"
grep -qE "^  ProxyCommand bash .*/satellite-iap-proxy.sh test-proj europe-north1-a %h %p$" "$c" \
  && pass "ProxyCommand goes through the IAP proxy as the project" || fail "no IAP ProxyCommand in the block"
grep -qx "  IdentityFile $key" "$c" && pass "the block names the minted private key" || fail "IdentityFile is not $key"

grep -q AAAAOLDSTALEKEY "$kh" && fail "the stale host key of a recreated VM is kept" || pass "the stale host key is dropped"
grep -qx 'test-satellite ssh-ed25519 AAAANEWKEY1' "$kh" && grep -qx 'test-satellite ecdsa-sha2-nistp256 AAAANEWKEY2' "$kh" \
  && pass "the guest's published host keys are pinned" || fail "the published host keys are not pinned"
grep -q AAAAKEEP "$kh" && pass "other hosts' keys are kept" || fail "another host's key was removed"
printf 'test-satellite ssh-ed25519 AAAAOLDSTALEKEY\n' >"$kh"; STUB_HOSTKEYS='' 
( STUB_HOSTKEYS='' do_satellite_ssh_config ) >/dev/null 2>&1
[[ ! -s "$kh" ]] && pass "no published keys: the stale entry is still gone (accept-new on first connect)" || fail "no published keys: a stale entry survives"
grep -q 'enable-guest-attributes\s*=\s*"TRUE"' "$PROJ_PATH/src/terraform/060-gcp-vm-satellite/03-vm.tf" \
  && pass "060 lets the guest publish its host keys" || fail "060 does not enable guest attributes"

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

# --- 6. the replica ------------------------------------------------------------------
if ( SATELLITE_TOOLS='pnpm bogus' do_satellite_install_tools ) >/dev/null 2>&1; then fail "install_tools accepted an unknown part"; else pass "install_tools refuses an unknown part"; fi
mkdir -p "$HOME/.claude/skills/s1" "$HOME/.claude/projects/-opt-x/memory"
echo '{"model":"m","statusLine":{"command":"'"$HOME"'/.claude/statusline-title.sh"}}' >"$HOME/.claude/settings.json"
echo PLANTED-SECRET-MARKER >"$HOME/.claude/.credentials.json"
out=$( ( DRY_RUN=1 do_satellite_replicate_ai_user ) 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && grep -q 'would copy ~/.claude/settings.json' <<<"$out" && grep -q 'would copy ~/.claude/projects/-opt-x/memory' <<<"$out" \
  && pass "replicate DRY_RUN lists the settings and the memory" || fail "replicate DRY_RUN plan is wrong (rc=$rc)"
grep -q 'credentials\|PLANTED-SECRET-MARKER' <<<"$out" && fail "replicate would copy a credential" || pass "CONTROL: replicate never lists .credentials.json"
grep -q -- "--exclude='.credentials.json'" "$PROJ_PATH/src/bash/run/satellite-replicate-ai-user.func.sh" \
  && pass "replicate's tar excludes .credentials.json" || fail "replicate's tar does not exclude .credentials.json"
vm="$T/vmhome"; mkdir -p "$vm/.claude"
echo '{"hooks":{"Stop":[1]},"model":"old","theme":"light"}' >"$vm/.claude/settings.json"
( cd "$HOME" && tar -czf - .claude/settings.json .claude/skills ) \
  | BOXHOME="$HOME" HOME="$vm" PERSIST=".x" GIT_NAME="FirstName LastName" GIT_EMAIL="a@example.com" \
    bash "$PROJ_PATH/src/bash/scripts/satellite-replicate-ai-user.sh" >"$T/repl.out" 2>&1
st="$vm/.claude/settings.json"
[[ "$(jq -c .hooks "$st")" == '{"Stop":[1]}' && "$(jq -r .model "$st")" == m && "$(jq -r .theme "$st")" == light ]] \
  && pass "settings merge: box keys win, the VM's hooks and keys stay" || fail "settings merge wrong: $(cat "$st")"
jq -r .statusLine.command "$st" | grep -q "^$vm/.claude/statusline-title.sh$" && pass "the box home path is rewritten to the VM's" || fail "the box home path is not rewritten"
[[ "$(HOME="$vm" git config --global user.email)" == a@example.com ]] && pass "the git identity is set" || fail "the git identity is not set"
grep -q '^REPL home FAIL' "$T/repl.out" && grep -q '^REPLICA fails=' "$T/repl.out" && pass "no data disk: home is a FAIL verdict, the other parts still run" || fail "replica verdicts: $(cat "$T/repl.out")"
o=$(echo NOT-A-TAR | HOME="$vm" BOXHOME=/nonexistent PARTS=home PERSIST=".x" bash "$PROJ_PATH/src/bash/scripts/satellite-replicate-ai-user.sh" 2>&1)
grep -q 'REPL copy FAIL' <<<"$o" && fail "PARTS=home read stdin" || pass "PARTS=home reads no stdin"
grep -qE '^REPL (claude|tmux|git|gh) ' <<<"$o" && fail "PARTS=home ran another part" || pass "PARTS=home runs the home part only"
grep -q 'PARTS=home' "$PROJ_PATH/src/bash/run/satellite-home-persist.func.sh" && ! grep -q 'tar ' "$PROJ_PATH/src/bash/run/satellite-home-persist.func.sh" \
  && pass "do_satellite_home_persist sends no box file" || fail "do_satellite_home_persist may copy box files"
grep -q 'claude auth status --json .*jq -r .loggedIn' "$PROJ_PATH/src/bash/run/satellite-verify.func.sh" \
  && pass "verify reads only claude's loggedIn flag" || fail "verify does not check the claude login (loggedIn)"
nv=$(bash -c "$(_satellite_versions_script)" 2>/dev/null | grep -c '^ver ')
nr=$(grep -cv '^#' "$PROJ_PATH/cnf/satellite-replica.tsv")
[[ "$nv" == "$nr" && "$nr" -gt 20 ]] && pass "verify's version script: one ver line per manifest row ($nr)" || fail "verify's version script: $nv ver lines for $nr rows"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
