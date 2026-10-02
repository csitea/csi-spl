#!/usr/bin/env bash
# pre-push-tier: slow -- needs terraform (CI workflow 10 iac-suite)
#------------------------------------------------------------------------------
# Purpose: 120-github-general-secrets publishes GCP_KEY_<ORG>_<APP>_<ENV> from
#          the project key file WITHOUT the key entering terraform state or
#          the plan output -- by APPLYING the step (local backend, temp copy) with
#          HOME in a temp dir holding a planted fake key and a stub `gh` on PATH
#          that records its argv and its stdin. Then:
#            - gh got `secret set GCP_KEY_CSI_SPL_DEV --repo <repo>` and the
#              key bytes on STDIN (never in argv)
#            - the state file does not contain the key, only its sha256
#            - an unchanged key is not re-published, a changed key is
#            - a missing key publishes nothing and says so (published=false)
#          Static: no plaintext_value / github provider / Secret Manager
#          mirror / credentials=file() in the step.
#          terraform: $TF_BIN, else the newest $HOME/.local/share/csi-spl/bin/
#          terraform-*, else PATH. Missing terraform is a FAIL unless
#          SPL_TF_ALLOW_SKIP=1 (spec 007 T070).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP="$PROJ_ROOT/src/terraform/120-github-general-secrets"
fails=0

[[ -d "$STEP" ]] || { echo "FAIL: missing $STEP"; exit 1; }

# --- static --------------------------------------------------------------------
grep -hvE '^[[:space:]]*#' "$STEP"/*.tf | grep -qE 'plaintext_value|encrypted_value' && fail "120 sets a secret value through terraform (lands in state)" || pass "120 passes no secret value through terraform"
grep -qE 'google_secret_manager_secret_version|resource "github_' "$STEP"/*.tf && fail "120 mirrors the key into a state-borne resource" || pass "120 has no github_* or Secret Manager version resource"
grep -qE 'credentials[[:space:]]*=[[:space:]]*file\(' "$STEP"/*.tf && fail "120 reads a credentials file in a provider" || pass "120 has no credentials=file()"
for e in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$e/tf/120-github-general-secrets.vars.tfvars"
  grep -qx 'gh_repo = "csitea/csi-spl"' "$v" && pass "$e 120 targets csitea/csi-spl" || fail "$e 120 gh_repo"
done

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
mkdir -p "$T/home/.gcp/.csi" "$T/bin" "$T/run"
cp -r "$STEP/." "$T/run/"
printf 'terraform {\n  backend "local" {}\n}\n' >"$T/run/backend_override.tf"
MARK="STUB-KEY-MATERIAL-$$-$RANDOM"
KEY="$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf '{"type":"service_account","marker":"%s"}\n' "$MARK" >"$KEY"; chmod 600 "$KEY"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$GH_LOG".*.argv 2>/dev/null | wc -l)
echo "$*" >"$GH_LOG.$n.argv"
cat >"$GH_LOG.$n.stdin"
STUB
chmod +x "$T/bin/gh"

tfrun() {  # apply the temp copy as a fresh user with the stub gh
  env HOME="$T/home" PATH="$T/bin:$PATH" GH_LOG="$T/gh" TF_IN_AUTOMATION=1 \
    "$TF" -chdir="$T/run" "$@" -no-color \
    -var=org=csi -var=app=spl -var=env=dev -var=gcp_project=csi-spl-dev -var=gh_repo=csitea/csi-spl
}
env HOME="$T/home" "$TF" -chdir="$T/run" init -input=false -no-color >/dev/null 2>&1 || fail "terraform init (local backend)"

out=$(tfrun apply -auto-approve -input=false 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "apply succeeds with a key present" || fail "apply failed: $out"
[[ "$(cat "$T/gh.0.argv" 2>/dev/null)" == "secret set GCP_KEY_CSI_SPL_DEV --repo csitea/csi-spl" ]] \
  && pass "gh called: secret set GCP_KEY_CSI_SPL_DEV --repo csitea/csi-spl" || fail "gh argv: $(cat "$T/gh.0.argv" 2>/dev/null)"
cmp -s "$T/gh.0.stdin" "$KEY" && pass "the key reached gh on STDIN, byte for byte" || fail "gh stdin != key file"
grep -q "$MARK" "$T/gh.0.argv" && fail "the key appeared in gh argv" || pass "the key never appears in gh argv"
grep -q "$MARK" "$T/run/terraform.tfstate" && fail "the KEY is in terraform state" || pass "the key is not in terraform state"
grep -q "$(sha256sum "$KEY" | cut -d' ' -f1)" "$T/run/terraform.tfstate" && pass "state holds the key's sha256 only" || fail "state lacks the sha256 trigger"
grep -q "$MARK" <<<"$out" && fail "the key appeared in the apply output" || pass "the key never appears in the apply output"

out=$(tfrun apply -auto-approve -input=false 2>&1)
[[ ! -e "$T/gh.1.argv" ]] && pass "an unchanged key is not re-published" || fail "re-published an unchanged key"

printf '{"type":"service_account","marker":"%s-rotated"}\n' "$MARK" >"$KEY"
out=$(tfrun apply -auto-approve -input=false 2>&1)
cmp -s "$T/gh.1.stdin" "$KEY" && pass "a rotated key is re-published" || fail "a rotated key was not re-published"

rm -f "$KEY" "$T"/gh.*
out=$(tfrun apply -auto-approve -input=false 2>&1); rc=$?
[[ $rc -eq 0 && ! -e "$T/gh.0.argv" ]] && pass "a missing key publishes nothing" || fail "missing key: rc=$rc gh=$(ls "$T"/gh.* 2>/dev/null)"
[[ "$(env HOME="$T/home" "$TF" -chdir="$T/run" output -raw published 2>/dev/null)" == false ]] \
  && pass "output published=false when the key is missing" || fail "output published is not false"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
