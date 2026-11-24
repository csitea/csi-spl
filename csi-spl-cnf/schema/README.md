# csi-spl-cnf/schema: the JSON schema of the env files

`env-schema.json` is the JSON schema (draft-07) of the cnf env files
`csi-spl-cnf/csi-spl/{all,dev,prd,lde}.env.yaml` (SPL-451, spec 011 T025,
FR-R10). It stands next to the pydantic conf-validator
(`csi-spl-cnf/src/python/conf-validator`), which stays the gate before
tpl-gen; it does not replace it (owner, HUM-10, t1 topic 80e54ed8, poll
45c1cf30).

## 1. One source: the schema is generated from the pydantic models

The pydantic models under `conf-validator/EnvModels/` are the only hand-kept
description of the config. `env-schema.json` is their export, written by
`conf_validator/env_schema_export.py` (pydantic's own `schema()`), so the two
cannot drift apart unseen:

- change a model, then rewrite the schema in the same commit:
  `cd csi-spl-cnf/src/python/conf-validator && poetry run python -m conf_validator.env_schema_export`
- `--check` regenerates it in memory and exits 1 (`DRIFT:`) when the
  committed file differs; the cnf suite runs it.

Never edit `env-schema.json` by hand.

## 2. Which model a file is checked against

The schema picks the model by `env.ENV`:

| `env.ENV` | model | file checked |
|---|---|---|
| `lde` | `EnvModels/lde.py` | the EFFECTIVE lde config |
| any other value (`dev`, `prd`) | `EnvModels/cloud.py` | the EFFECTIVE dev / prd config |
| absent | `EnvModels/all.py` | `all.env.yaml` as it is |

The EFFECTIVE config is `all.env.yaml` deep-merged under `<env>.env.yaml`
plus the derived keys (`do_spl_merged_cnf`), the file tpl-gen renders from;
a raw `<env>.env.yaml` alone is not a complete config.

## 3. The check: `do_check_env_schema`

`cd csi-spl-iac && ./run -a do_check_env_schema` checks all four files. It
needs only `jsonschema` and `pyyaml` (the conf-validator poetry env, or
`python3-jsonschema python3-yaml`), never pydantic. A bad key fails with one
line naming its path:

`FAIL dev.env.yaml(+all): env.gcp.gcp_region: 5 is not of type 'string'`

Exit codes, the conf-validator's contract: `0` valid, `1` a file is invalid,
`2` NOTHING WAS VALIDATED (no `jsonschema`, no schema, a missing env file).
Options: `ENVS` (default `all dev prd lde`), `CNF_DIR`, `ENV_SCHEMA`,
`PYTHON`.

## 4. Where pydantic and the schema differ, on purpose

`csi-spl-cnf/src/bash/tests/env-schema.tst.sh` (CI `cnf-suite`) runs the
same fixtures through both and pins their verdicts. They agree on the
structure: a missing required key, a value outside a `Literal`, a number
outside a `conint` bound, an extra key where a model forbids extras, a wrong
type. Two differences are known and pinned, so a change to either is seen:

- the models' validators (the realm rule, a split row summing to 100 with one
  main, `i18n.default_locale` in `i18n.locales`, the `agent_model` syntax
  rules) are pydantic-only: JSON schema cannot express them;
- pydantic coerces (`gcp_region: 5` becomes `"5"`); the schema refuses it.

## 5. Tests

`bash csi-spl-cnf/src/bash/tests/env-schema.tst.sh`: no drift (and its red
control, a hand-edited copy), the live files pass, broken fixtures of
`all.env.yaml`, `dev.env.yaml` and `lde.env.yaml` are refused naming the bad
key, "could not check" is exit 2, and the pydantic / schema agreement above.
