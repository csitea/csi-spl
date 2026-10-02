#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_tf_mirror (the CI iac-suite's /opt/tf layout on a runner
#          that lacks it) writes a terraformrc serving the steps' google
#          providers from a filesystem mirror, downloads only when an init
#          against that mirror does not resolve, and fails loudly otherwise --
#          offline, against a stubbed terraform that logs its argv.
#   1. no TF_MIRROR_ROOT -> refused, nothing written (no default)
#   2. fresh: one `providers mirror` for the runner's platform, the probe asks
#      for the steps' constraint, terraformrc = mirror path + include/exclude
#   3. re-run: no download (idempotent)
#   CONTROL: a mirror that still does not resolve after the download FAILS.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# the steps: two google, one google-beta, each "~> 6.0"
mkdir -p "$T/proj/src/terraform/"{010-a,020-b}
for d in 010-a 020-b; do
  printf 'terraform {\n  required_providers {\n    google = {\n      source  = "hashicorp/google"\n      version = "~> 6.0"\n    }\n  }\n}\n' >"$T/proj/src/terraform/$d/01-providers.tf"
done
printf 'terraform {\n  required_providers {\n    google-beta = {\n      source  = "hashicorp/google-beta"\n      version = "~> 6.0"\n    }\n  }\n}\n' >>"$T/proj/src/terraform/020-b/01-providers.tf"

# terraform stub: init resolves iff every provider the probe names sits in the
# mirror that TF_CLI_CONFIG_FILE points at; `providers mirror` fills the target
# unless STUB_MIRROR_EMPTY=1
mkdir -p "$T/stub"
cat >"$T/stub/terraform" <<'STUB'
#!/usr/bin/env bash
echo "terraform $*" >>"$TF_LOG"
[[ "$1" == version ]] && { printf 'Terraform v1.9.8\non linux_amd64\n'; exit 0; }
dir=${1#-chdir=}; shift
names=$(sed -n 's/^ *source *= *"hashicorp\/\([^"]*\)".*/\1/p' "$dir/main.tf")
case "$1" in
  init)
    m=$(sed -n 's/^ *path *= *"\([^"]*\)".*/\1/p' "$TF_CLI_CONFIG_FILE")
    for n in $names; do [[ -d "$m/registry.terraform.io/hashicorp/$n" ]] || { echo "no $n in $m"; exit 1; }; done ;;
  providers)
    cp "$dir/main.tf" "$PROBE_COPY"
    [[ "${STUB_MIRROR_EMPTY:-0}" == 1 ]] && { mkdir -p "${@: -1}"; exit 0; }
    for n in $names; do mkdir -p "${@: -1}/registry.terraform.io/hashicorp/$n/6.50.0"; done ;;
esac
STUB
chmod +x "$T/stub/terraform"

# run_setup [VAR=value ...] -> rc; output in $T/out
run_setup() {
  env PATH="$T/stub:$PATH" TF_LOG="$T/tf.log" PROBE_COPY="$T/probe.tf" PROJ_PATH="$T/proj" "$@" bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-tf-mirror.func.sh"
    do_setup_tf_mirror' >"$T/out" 2>&1
}
R="$T/cache/csi-spl-tf"
mirrors() { grep -c 'providers mirror' "$T/tf.log" 2>/dev/null || true; }

# --- 1. no root ------------------------------------------------------------------
run_setup; rc=$?
[[ $rc -ne 0 && ! -e "$T/cache" ]] && grep -q 'TF_MIRROR_ROOT must be set' "$T/out" \
  && pass "no TF_MIRROR_ROOT: refused, nothing written" || fail "no TF_MIRROR_ROOT: rc=$rc $(cat "$T/out")"

# --- 2. fresh --------------------------------------------------------------------
run_setup TF_MIRROR_ROOT="$R"; rc=$?
[[ $rc -eq 0 ]] && pass "fresh setup exits 0" || fail "fresh setup rc=$rc $(cat "$T/out")"
[[ "$(mirrors)" -eq 1 ]] && grep -q 'providers mirror -platform=linux_amd64 ' "$T/tf.log" \
  && pass "one providers mirror, for the runner's platform" || fail "providers mirror calls: $(grep providers "$T/tf.log")"
[[ -d "$R/mirror/registry.terraform.io/hashicorp/google" && -d "$R/mirror/registry.terraform.io/hashicorp/google-beta" ]] \
  && pass "the mirror holds google and google-beta" || fail "mirror: $(find "$R/mirror" -maxdepth 3)"
[[ ! -e "$R/mirror.new" ]] && pass "no download dir left behind" || fail "$R/mirror.new left behind"
[[ "$(grep -c 'version = "~> 6.0"' "$T/probe.tf" 2>/dev/null)" -eq 2 ]] \
  && pass "the probe asks for the steps' constraint, once per provider" || fail "probe: $(cat "$T/probe.tf" 2>/dev/null)"
inc='["registry.terraform.io/hashicorp/google", "registry.terraform.io/hashicorp/google-beta"]'
grep -qxF "    path    = \"$R/mirror\"" "$R/terraformrc" && grep -qxF "    include = $inc" "$R/terraformrc" \
  && grep -qxF "    exclude = $inc" "$R/terraformrc" \
  && pass "terraformrc: filesystem mirror for both, the rest direct" || fail "terraformrc: $(cat "$R/terraformrc")"

# --- 3. re-run -------------------------------------------------------------------
run_setup TF_MIRROR_ROOT="$R"; rc=$?
[[ $rc -eq 0 && "$(mirrors)" -eq 1 ]] && grep -q 'already serves' "$T/out" \
  && pass "re-run: no second download" || fail "re-run rc=$rc mirrors=$(mirrors) $(cat "$T/out")"

# --- CONTROL: a download that does not make the mirror resolve fails -------------
run_setup TF_MIRROR_ROOT="$T/cache/other" STUB_MIRROR_EMPTY=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'still does not serve' "$T/out" \
  && pass "CONTROL: a mirror that does not resolve after the download FAILS (rc=$rc)" \
  || fail "CONTROL: an unresolved mirror passed (rc=$rc) $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
