#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: owner direction 2026-09-19 -- the hub deploy (20) and the lag
#          watch (00) authenticate with the project SA key secret
#          GCP_KEY_CSI_SPL_<ENV> (iac 120) and keep WIF as the alternative.
#          Each workflow: a credentials_json auth step reading that secret,
#          gated on HAS_KEY; a WIF auth step gated on its absence; the plan
#          step sees only a BOOLEAN of the secret; and no secret other than
#          GCP_KEY_CSI_SPL_* is read (github.token is the context, not a secret).
#          CONTROL: a copy with a planted extra secret is reported.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
W="$APP_ROOT/.github/workflows"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# other_secrets <file> -> every secrets.<NAME> / secrets[...] that is not GCP_KEY_CSI_SPL_*
other_secrets() {
  grep -oE 'secrets\.[A-Za-z0-9_]+|secrets\[[^]]*\]' "$1" | grep -vE "GCP_KEY_CSI_SPL_(DEV|PRD|\{0\})" || true
}

for wf in 20_hub-build-deploy.yml 00_deploy-lag-watch.yml; do
  f="$W/$wf"
  [[ -f "$f" ]] || { fail "missing $wf"; continue; }
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && pass "$wf parses" || fail "$wf is not valid yaml"
  grep -qE "credentials_json: \\$\\{\\{ secrets\\[format\\('GCP_KEY_CSI_SPL_\\{0\\}'" "$f" \
    && pass "$wf: key auth (credentials_json from GCP_KEY_CSI_SPL_<ENV>)" || fail "$wf: no credentials_json from GCP_KEY_CSI_SPL_<ENV>"
  grep -qE "if: .*env\\.HAS_KEY == 'true'" "$f" && grep -qE "if: .*env\\.HAS_KEY != 'true'" "$f" \
    && pass "$wf: key step gated on HAS_KEY, WIF step on its absence" || fail "$wf: auth steps are not gated on HAS_KEY"
  grep -q 'workload_identity_provider:' "$f" && pass "$wf: WIF kept as the alternative" || fail "$wf: WIF path removed"
  grep -qE "KEY_DEV: \\$\\{\\{ secrets\\.GCP_KEY_CSI_SPL_DEV != '' \\}\\}" "$f" \
    && pass "$wf: the plan step sees only a boolean of the secret" || fail "$wf: plan step does not read a boolean of the secret"
  o=$(other_secrets "$f")
  [[ -z "$o" ]] && pass "$wf: reads no secret but GCP_KEY_CSI_SPL_<ENV>" || fail "$wf: reads other secrets: $o"
done

# --- control -------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$W/20_hub-build-deploy.yml" "$T/x.yml"
printf '      FOO: ${{ secrets.FOO }}\n' >>"$T/x.yml"
[[ "$(other_secrets "$T/x.yml")" == "secrets.FOO" ]] && pass "control: a planted secrets.FOO is reported" || fail "control: planted secret not reported"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
