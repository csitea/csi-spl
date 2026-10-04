#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: `make do-setup-tpl-gen` needs no GITHUB_TOKEN (spec 072 A14).
#          1. nothing tpl-gen or conf-validator builds or runs reads GITHUB_TOKEN
#             (their Dockerfiles and docker-init scripts)
#          2. `make -n do-setup-tpl-gen` with GITHUB_TOKEN unset exits 0 and
#             renders no GITHUB_TOKEN demand
#          3. it hands compose an inert placeholder, so the compose file's
#             `GITHUB_TOKEN:?` interpolation cannot refuse
#          4. a missing tpl-gen clone with no TPL_GEN_REPO_URL is refused up
#             front (rc 1, names TPL_GEN_REPO_URL), not after the readiness wait
#          5. the readiness probes use the overridable container names
#          CONTROL: do-setup-tf-runner (step 120's gh secret set needs the real
#          token) still renders the demand, so check 2 can see one.
#          Static, needs make only; no container is started.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cd "$ORC" || exit 1
hits=$(grep -l GITHUB_TOKEN src/docker/tpl-gen/Dockerfile src/docker/conf-validator/Dockerfile \
  src/bash/scripts/docker-init-tpl-gen.sh src/bash/scripts/docker-init-conf-validator.sh 2>/dev/null)
[[ -z "$hits" ]] && pass "no tpl-gen/conf-validator Dockerfile or init script reads GITHUB_TOKEN" \
  || fail "reads GITHUB_TOKEN, the placeholder would break it: $hits"

out=$(env -u GITHUB_TOKEN make --no-print-directory -n do-setup-tpl-gen 2>&1); rc=$?
if (( rc == 0 )) && ! grep -q 'GITHUB_TOKEN.* is not set, do set it' <<<"$out"; then
  pass "make -n do-setup-tpl-gen with GITHUB_TOKEN unset: rc 0, no demand"
else
  fail "make -n do-setup-tpl-gen with GITHUB_TOKEN unset (rc $rc): $(grep -m1 -i 'not set\|error' <<<"$out")"
fi
grep -qF 'export GITHUB_TOKEN="${GITHUB_TOKEN:-' <<<"$out" \
  && pass "an unset GITHUB_TOKEN reaches compose as a placeholder" \
  || fail "no GITHUB_TOKEN placeholder before the compose calls"
grep -qE 'docker exec con-\$\(ORG\)-\$\(APP\)-(tpl-gen|conf-validator)' src/make/setup-tpl-gen.func.mk \
  && fail "a readiness probe hard-codes con-\$(ORG)-\$(APP)" \
  || pass "readiness probes use CON_TPL_GEN / CON_CONF_VALIDATOR"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
out=$(env -u GITHUB_TOKEN -u TPL_GEN_REPO_URL make --no-print-directory TPG_PROJ_PATH="$T/none" \
  --eval 'do-create-network: ; @true' do-setup-tpl-gen 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'set TPL_GEN_REPO_URL' <<<"$out" && ! grep -q 'compose' <<<"$out"; then
  pass "no clone, no TPL_GEN_REPO_URL: refused before any compose call"
else
  fail "no clone, no TPL_GEN_REPO_URL (rc $rc): $(tail -1 <<<"$out")"
fi

# CONTROL: a target that does demand the token must render the demand
out=$(env -u GITHUB_TOKEN make --no-print-directory -n do-setup-tf-runner 2>&1)
grep -q 'GITHUB_TOKEN.* is not set, do set it' <<<"$out" \
  && pass "control: do-setup-tf-runner still renders the GITHUB_TOKEN demand" \
  || fail "control: do-setup-tf-runner renders no demand (check 2 is blind)"

echo "fails=$fails"
exit $(( fails > 0 ))
