# csi-spl ::: SPL-451, spec 011 T025 / FR-R10. Writes the JSON schema of the
# cnf env files, csi-spl-cnf/schema/env-schema.json, FROM the pydantic models
# under EnvModels/. The models are the one hand-kept source; the JSON schema is
# their export, never edited by hand, so the two cannot drift: --check
# regenerates it in memory and fails when the committed file differs (the cnf
# suite runs that, csi-spl-cnf/src/bash/tests/env-schema.tst.sh).
#
# What the schema holds is what pydantic's own schema() emits: types, required
# keys, enums (Literal), bounds (conint), patterns (constr), additional
# properties refused where a model says Extra.forbid. What it cannot hold are
# the models' root and field validators (the realm rule, a split row summing
# to 100, i18n.default_locale in i18n.locales, the agent_model syntax rules):
# those stay pydantic-only, and the pydantic validator stays the gate before
# tpl-gen. The JSON schema is the second, dependency-light check (jsonschema +
# pyyaml, no pydantic) that ./run -a do_check_env_schema runs on every env.
#
# Which model a document is checked against is chosen inside the schema by
# env.ENV: "lde" = the lde model, any other ENV = the cloud (dev / prd)
# model, no ENV at all = all.env.yaml's model.
#
# Usage (from csi-spl-cnf/src/python/conf-validator, in its poetry env):
#   python -m conf_validator.env_schema_export            # rewrite the file
#   python -m conf_validator.env_schema_export --check    # exit 1 on drift
#   ... [--check] <path>   the same against another file (the tests' red control)
import json
import sys
from pathlib import Path

from pydantic.schema import schema as pydantic_schema

from EnvModels import AllEnv, DevEnv, LdeEnv

SCHEMA_PATH = Path(__file__).resolve().parents[4] / "schema" / "env-schema.json"
DRAFT = "http://json-schema.org/draft-07/schema#"


def _ref(model, model_names):
    return {"$ref": f"#/definitions/{model_names[model]}"}


def build():
    """The schema document, as a dict; the same input always gives the same output."""
    from pydantic.schema import get_flat_models_from_models, get_model_name_map

    models = [AllEnv, DevEnv, LdeEnv]
    names = get_model_name_map(get_flat_models_from_models(models))
    defs = pydantic_schema(models)["definitions"]
    env_is = lambda cond: {  # noqa: E731
        "properties": {"env": {"required": ["ENV"], "properties": {"ENV": cond}}},
        "required": ["env"],
    }
    return {
        "$schema": DRAFT,
        "title": "csi-spl cnf env file",
        "description": (
            "GENERATED from csi-spl-cnf/src/python/conf-validator/EnvModels by "
            "conf_validator.env_schema_export; edit the models, never this file. "
            "env.ENV lde = the lde model, another ENV = the cloud model (dev, prd), "
            "no ENV = all.env.yaml. Checked by: cd csi-spl-iac && ./run -a do_check_env_schema"
        ),
        "type": "object",
        "if": env_is({"const": "lde"}),
        "then": _ref(LdeEnv, names),
        "else": {
            "if": env_is({}),
            "then": _ref(DevEnv, names),
            "else": _ref(AllEnv, names),
        },
        "definitions": defs,
    }


def render():
    return json.dumps(build(), indent=2, sort_keys=True) + "\n"


def main(argv):
    text = render()
    paths = [Path(a) for a in argv if not a.startswith("--")]
    target = paths[0] if paths else SCHEMA_PATH
    if "--check" in argv:
        have = target.read_text() if target.exists() else ""
        if have != text:
            print(
                f"DRIFT: {target} is not what EnvModels/ export. Rewrite it with: "
                "cd csi-spl-cnf/src/python/conf-validator && poetry run python -m "
                "conf_validator.env_schema_export",
                file=sys.stderr,
            )
            return 1
        print(f"IN SYNC: {target} == the export of EnvModels/")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    print(f"WROTE {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
