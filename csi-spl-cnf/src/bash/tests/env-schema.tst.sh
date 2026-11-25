#!/usr/bin/env bash
# SPL-451, spec 011 T025 / FR-R10: the JSON schema of the cnf env files,
# csi-spl-cnf/schema/env-schema.json, and its action do_check_env_schema.
#
#   1. the committed schema IS the export of the pydantic models (no drift),
#      and a hand-edited copy is caught (red control);
#   2. the live all / dev / prd / lde configs pass the action;
#   3. a broken fixture is refused, exit 1, naming the path of the bad key
#      (red controls on all.env.yaml, dev.env.yaml and lde.env.yaml);
#   4. "could not check" is exit 2, never a pass;
#   5. pydantic and the schema give the SAME verdict on the structural
#      fixtures (null included where a model takes None), and the known
#      differences are pinned so a change to either one is seen: the root
#      validators (realm rule) are pydantic-only, and the schema refuses what
#      pydantic would coerce (an int or a bool for a str).
#
# Needs the conf-validator's poetry env (pydantic 1.x + jsonschema): CI's
# cnf-suite, or `cd csi-spl-cnf/src/python/conf-validator && poetry install`.
# Refuses to report a pass when it cannot run (exit 2).
#
# Usage: bash csi-spl-cnf/src/bash/tests/env-schema.tst.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"
VDIR="${ROOT_DIR}/csi-spl-cnf/src/python/conf-validator"
CNF_DIR="${ROOT_DIR}/csi-spl-cnf/csi-spl"
SCHEMA="${ROOT_DIR}/csi-spl-cnf/schema/env-schema.json"
[[ -x "${VDIR}/.venv/bin/python" ]] && PYTHON="${PYTHON:-${VDIR}/.venv/bin/python}"
PYTHON="${PYTHON:-python3}"

pass=0
fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! "${PYTHON}" -c 'import pydantic, pydantic_yaml, jsonschema, yaml' >/dev/null 2>&1; then
  echo "FAIL: '${PYTHON}' cannot import pydantic, pydantic_yaml, jsonschema and yaml."
  echo "      Refusing to report a pass for a self-test that did not run. See the header."
  exit 2
fi

# The action, as an operator runs it; prints its exit code, keeps its output.
run_action() {  # [VAR=value ...]
  ( cd "${ROOT_DIR}/csi-spl-iac" && env PYTHON="${PYTHON}" "$@" ./run -a do_check_env_schema ) \
    >"${TMP_DIR}/out" 2>&1
  echo $?
}
expect_rc() {  # <want> <got> <what>
  if [[ "$2" == "$1" ]]; then ok "$3 -> exit $2"; else bad "$3 -> exit $2, want $1"; sed 's/^/      /' "${TMP_DIR}/out" | tail -n 8; fi
}
expect_line() {  # <fixed text> <what>
  if grep -qF -- "$1" "${TMP_DIR}/out"; then ok "$2"; else bad "$2: no line '$1'"; fi
}

# --- 1. no drift between the models and the committed schema ----------------
( cd "${VDIR}" && "${PYTHON}" -m conf_validator.env_schema_export --check ) >"${TMP_DIR}/out" 2>&1
expect_rc 0 $? "the committed env-schema.json is the export of EnvModels/"
jq '.definitions.Gcp.required -= ["gcp_region"]' "${SCHEMA}" >"${TMP_DIR}/edited.json"
( cd "${VDIR}" && "${PYTHON}" -m conf_validator.env_schema_export --check "${TMP_DIR}/edited.json" ) >"${TMP_DIR}/out" 2>&1
expect_rc 1 $? "red control: a hand-edited schema is DRIFT"
expect_line "DRIFT:" "the drift says DRIFT"

# --- 2. the live configs pass ----------------------------------------------
expect_rc 0 "$(run_action)" "live all, dev, prd and lde"
for f in all.env.yaml 'dev.env.yaml(+all)' 'prd.env.yaml(+all)' 'lde.env.yaml(+all)'; do
  expect_line "PASS ${f}:" "checked ${f}"
done

# --- 3. red controls: a broken fixture is refused with the key's path --------
fixture() {  # <file> <yq expr>: a copy of the cnf dir with one file broken
  rm -rf "${TMP_DIR}/cnf" && cp -r "${CNF_DIR}" "${TMP_DIR}/cnf"
  yq -i "$2" "${TMP_DIR}/cnf/$1"
}
fixture dev.env.yaml '.env.gcp.gcp_region = 5'
expect_rc 1 "$(run_action CNF_DIR="${TMP_DIR}/cnf" ENVS=dev)" "red control: dev gcp_region is a number"
expect_line "FAIL dev.env.yaml(+all): env.gcp.gcp_region: 5 is not of type 'string'" "dev: the line names env.gcp.gcp_region"

fixture all.env.yaml '.env.box.agent_split_by_kind.tests.claude = "lots"'
expect_rc 1 "$(run_action CNF_DIR="${TMP_DIR}/cnf" ENVS=all)" "red control: all, a split weight that is text"
expect_line "FAIL all.env.yaml: env.box.agent_split_by_kind.tests.claude:" "all: the line names the weight's path"

fixture lde.env.yaml '.env.ORG = ["csi"]'
expect_rc 1 "$(run_action CNF_DIR="${TMP_DIR}/cnf" ENVS=lde)" "red control: lde ORG is a list"
expect_line "FAIL lde.env.yaml(+all): env.ORG:" "lde: the line names env.ORG"

fixture all.env.yaml '.env.cloud.provider = "azure"'
expect_rc 1 "$(run_action CNF_DIR="${TMP_DIR}/cnf" ENVS="all dev")" "red control: cloud.provider outside its enum"
expect_line "FAIL dev.env.yaml(+all): env.cloud.provider:" "the merged dev inherits the bad all.env.yaml key"

# --- 4. could not check = exit 2 --------------------------------------------
expect_rc 2 "$(run_action ENV_SCHEMA="${TMP_DIR}/no-such.json" ENVS=all)" "no schema file"
expect_rc 2 "$(run_action ENVS=stg)" "an env with no yaml"
cp "${VDIR}/env_schema_check.py" "${TMP_DIR}/check.py"
CHECK="${TMP_DIR}/check.py" "${PYTHON}" -I -c '
import builtins, os, runpy, sys
real = builtins.__import__
def no_js(name, *a, **k):
    if name == "jsonschema":
        raise ImportError("No module named jsonschema")
    return real(name, *a, **k)
builtins.__import__ = no_js
sys.argv = ["check", "schema.json", "x=y.yaml"]
runpy.run_path(os.environ["CHECK"], run_name="__main__")' >"${TMP_DIR}/out" 2>&1
expect_rc 2 "$?" "an interpreter without jsonschema"
expect_line "NOTHING WAS VALIDATED" "it says nothing was validated"

# --- 5. pydantic and the schema agree ---------------------------------------
# shellcheck disable=SC1091
source "${ROOT_DIR}/csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh"
do_spl_merged_cnf "${CNF_DIR}" dev "${TMP_DIR}/dev.yaml"
verdicts() {  # <yq expr> -> "pydantic=<rc> schema=<rc>" for the merged dev
  yq "$1" "${TMP_DIR}/dev.yaml" >"${TMP_DIR}/case.yaml"
  ( cd "${VDIR}" && "${PYTHON}" -m conf_validator.conf_validator "${TMP_DIR}/case.yaml" dev ) >/dev/null 2>&1
  local p=$?
  "${PYTHON}" -I "${VDIR}/env_schema_check.py" "${SCHEMA}" "case=${TMP_DIR}/case.yaml" >/dev/null 2>&1
  echo "pydantic=${p} schema=$?"
}
agree() {  # <want> <yq expr> <what>
  local got; got="$(verdicts "$2")"
  if [[ "${got}" == "$1" ]]; then ok "agree: $3 (${got})"; else bad "agree: $3: ${got}, want $1"; fi
}
agree "pydantic=0 schema=0" '.'                                              "the live dev config"
agree "pydantic=1 schema=1" 'del(.env.gcp.state_bucket)'                     "a required key missing"
agree "pydantic=1 schema=1" '.env.cloud.provider = "azure"'                  "a value outside a Literal"
agree "pydantic=1 schema=1" '.env.box.agent_split_by_kind.tests.claude = 101' "a weight over its conint bound"
agree "pydantic=1 schema=1" '.env.box.agent_split_by_kind.tests.zz = 0'      "an extra key where the model forbids it"
agree "pydantic=1 schema=1" '.env.box.agent_model.default = {"claude": 7}'   "a model that is not a string"
# null where pydantic takes None (Optional[X]): pydantic's schema() drops it,
# the export puts it back (R7 c-160 B2)
agree "pydantic=0 schema=0" '.env.box.agent_model = null'                    "null for an Optional model (agent_model: ~)"
agree "pydantic=0 schema=0" '.env.box.agent_split_by_kind = null'            "null for an Optional dict"
agree "pydantic=0 schema=0" '.env.steps."030-x" = null'                      "a step with no settings (a bare 030-x:)"
# the known differences, pinned on purpose (see conf_validator/env_schema_export.py)
agree "pydantic=1 schema=0" '.env.gcp.state_bucket = "another-tfstate"'      "KNOWN: the realm rule is pydantic-only"
agree "pydantic=0 schema=1" '.env.gcp.gcp_region = 5'                        "KNOWN: the schema refuses an int pydantic coerces to str"
agree "pydantic=0 schema=1" '.env.gcp.gcp_region = true'                     "KNOWN: the schema refuses a bool pydantic coerces to str"
agree "pydantic=1 schema=1" '.env.gcp.gcp_region = null'                     "null where the model takes no None"

echo
echo "Summary: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
