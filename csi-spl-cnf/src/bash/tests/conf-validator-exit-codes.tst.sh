#!/usr/bin/env bash
# conf-validator exit-code contract.
#
# Why this exists as a PASSING job rather than a comment: the Make target
# renders tfvars only if `poetry run validate <yaml> <env>` exits zero
# (csi-spl-orc/src/make/generate-config-for-step.func.mk). In csi-rel, until
# 2026-08-26 two paths through the validator returned SUCCESS having checked
# nothing — an unknown env (`return`) and a missing file (bare `sys.exit()`) —
# so `ENV=lde`, a typo'd `ENV=`, or a wrong `APP_PATH` sailed through the gate
# and the operator read a green run as a validated config.
#
# The failure mode was a PASS, which is exactly the kind that hides. So the
# contract gets a test, and the test refuses to skip itself: if it cannot reach
# a working interpreter it exits non-zero rather than quietly reporting nothing,
# which would reproduce the bug it exists to prevent.
#
#   0  parsed against the env's model and VALID
#   1  checked and INVALID
#   2  could NOT be checked (unknown env / missing file)
#
# csi-spl: the yaml a cloud env is validated as is its EFFECTIVE config
# (do_spl_merged_cnf: all.env.yaml under <env>.env.yaml + env.dns.fqdn), the
# file the Make target hands the validator; the "valid dev config" case builds
# it. PYTHON defaults to the module's own .venv when it exists
# (`cd csi-spl-cnf/src/python/conf-validator && poetry install`).
#
# Usage:
#   PYTHON=python3 bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh
#
# The interpreter needs the validator's own dependencies (pydantic 1.x, typer,
# rich, pydantic-yaml). In CI the workflow pip-installs them. On a developer box
# the venv only resolves INSIDE the conf-validator image, so run it there:
#
#   docker run --rm -v "$PWD":/opt/csi/csi-spl \
#     -v /opt/csi/csi-spl/csi-spl-cnf/src/python/conf-validator/.venv:/opt/csi/csi-spl/csi-spl-cnf/src/python/conf-validator/.venv:ro \
#     img-conf-validator:latest /bin/bash -c \
#     'cd /opt/csi/csi-spl/csi-spl-cnf/src/python/conf-validator && source .venv/bin/activate \
#      && bash /opt/csi/csi-spl/csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh'
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"
VDIR="${ROOT_DIR}/csi-spl-cnf/src/python/conf-validator"
CNF_DIR="${ROOT_DIR}/csi-spl-cnf/csi-spl"
[[ -x "${VDIR}/.venv/bin/python" ]] && PYTHON="${PYTHON:-${VDIR}/.venv/bin/python}"
PYTHON="${PYTHON:-python3}"

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- the test must not be able to no-op ------------------------------------
if ! "${PYTHON}" -c 'import pydantic, typer, rich, pydantic_yaml' >/dev/null 2>&1; then
  echo "FAIL: '${PYTHON}' cannot import the validator's dependencies (pydantic, typer, rich, pydantic_yaml)."
  echo "      Refusing to report a pass for a self-test that did not run — that is the bug this file guards."
  echo "      See the header for the container recipe, or set PYTHON= to an interpreter that has them."
  exit 2
fi

# Runs the validator exactly as the Make targets do and echoes its exit status.
# stdout/stderr are captured so a case can assert on the operator-facing text.
run_validate() {
  local yaml="$1" env="$2"
  ( cd "${VDIR}" && "${PYTHON}" -m conf_validator.conf_validator "${yaml}" "${env}" ) \
    >"${TMP_DIR}/out" 2>"${TMP_DIR}/err"
  echo $?
}

expect_rc() {
  local want="$1" got="$2" what="$3"
  if [[ "${got}" == "${want}" ]]; then
    ok "${what} → exit ${got}"
  else
    bad "${what} → exit ${got}, want ${want}"
    sed 's/^/      /' "${TMP_DIR}/err" | head -5
  fi
}

# --- 0: a real env with a real model validates ------------------------------
# Anchors the suite: without this a validator that exited non-zero for
# EVERYTHING would satisfy every other case here.
# shellcheck disable=SC1091
source "${ROOT_DIR}/csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh"
do_spl_merged_cnf "${CNF_DIR}" dev "${TMP_DIR}/dev.env.yaml"
expect_rc 0 "$(run_validate "${TMP_DIR}/dev.env.yaml" dev)" "a valid dev config"

# --- 2: an env whose name is not in the enum --------------------------------
# The `ENV=` typo. This is the case that used to exit 0.
expect_rc 2 "$(run_validate "${CNF_DIR}/dev.env.yaml" nonsense)" "an unknown env name"
if grep -qi "NOTHING WAS VALIDATED" "${TMP_DIR}/err"; then
  ok "an unknown env says outright that nothing was validated"
else
  bad "an unknown env must SAY nothing was validated, not just fail quietly"
fi

# --- 2: a real env of this repo that has no model ---------------------------
# lde is a first-class env here (csi-spl-cnf/csi-spl/lde.env.yaml exists and the
# api runs on it) and EnvModels/ has no lde.py, so it cannot be validated. It
# must refuse, not pass. If somebody adds the model, THIS case flips to 0 and
# the line below is what tells them to update it deliberately.
expect_rc 2 "$(run_validate "${CNF_DIR}/lde.env.yaml" lde)" "lde, a real env with no model"

# --- 2: the file is not there -----------------------------------------------
# The wrong-APP_PATH shape: the gate ran, the yaml it named did not exist.
expect_rc 2 "$(run_validate "${CNF_DIR}/does-not-exist.env.yaml" dev)" "a yaml that does not exist"

# --- 1: checked, and genuinely invalid --------------------------------------
# Distinct from 2 on purpose: "this config is wrong" and "I could not look at
# this config" are different operator problems and must not share a code.
printf '{}\n' > "${TMP_DIR}/empty.env.yaml"
expect_rc 1 "$(run_validate "${TMP_DIR}/empty.env.yaml" dev)" "a well-formed yaml that fails the model"

# --- 1: csi-spl's realm rule -------------------------------------------------
# env <env> is GCP project csi-spl-<env>, state bucket csi-spl-<env>-tfstate: a
# config that would point terraform at another project is invalid, not "valid
# with a different project".
yq '.env.gcp.gcp_project = "some-other-project"' "${TMP_DIR}/dev.env.yaml" >"${TMP_DIR}/realm.env.yaml"
expect_rc 1 "$(run_validate "${TMP_DIR}/realm.env.yaml" dev)" "a dev config pointing at another GCP project"

# --- the source keeps the contract ------------------------------------------
# Cheap, but it catches the exact regression: someone "tidying" a refusal back
# into a bare return would otherwise only be caught if this suite still runs.
if grep -q "EXIT_CANNOT_CHECK = 2" "${VDIR}/conf_validator/conf_validator.py"; then
  ok "the exit-code contract is named in the source"
else
  bad "conf_validator.py no longer defines EXIT_CANNOT_CHECK"
fi

echo
echo "Summary: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
