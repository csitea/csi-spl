#!/usr/bin/env python3
# csi-spl ::: SPL-451, spec 011 T025 / FR-R10. Checks cnf env yaml files
# against csi-spl-cnf/schema/env-schema.json (the JSON schema exported from
# the pydantic models by conf_validator/env_schema_export.py). It needs only
# jsonschema and pyyaml, never pydantic, so it runs on a box python too.
# Run it through the action: cd csi-spl-iac && ./run -a do_check_env_schema.
#
# Usage: env_schema_check.py <schema.json> <label>=<yaml> [<label>=<yaml> ...]
#   label is what the error lines name (e.g. dev, or the repo-relative file).
#
# Exit codes, the conf-validator's contract:
#   0  every file was checked and is valid
#   1  checked, and at least one file is invalid: one line per bad key,
#      "FAIL <label>: <path.of.the.key>: <what is wrong>"
#   2  NOTHING WAS VALIDATED: no jsonschema / pyyaml, an unreadable schema,
#      a missing yaml, or bad arguments
import json
import sys

EXIT_OK, EXIT_INVALID, EXIT_CANNOT_CHECK = 0, 1, 2
MAX_LINES = 30


def cannot(msg):
    print(f"NOTHING WAS VALIDATED: {msg}", file=sys.stderr)
    return EXIT_CANNOT_CHECK


def key_path(error):
    parts = [str(p) for p in error.absolute_path]
    return ".".join(parts) if parts else "(top level)"


def check_one(validator, yaml, label, path):
    """Prints one line per error; returns the error count, or None if unreadable."""
    try:
        with open(path, "r") as fh:
            doc = yaml.safe_load(fh)
    except OSError as e:
        print(f"NOTHING WAS VALIDATED: {label}: {e}", file=sys.stderr)
        return None
    except yaml.YAMLError as e:
        print(f"FAIL {label}: (yaml): {e}", file=sys.stderr)
        return 1
    errors = sorted(
        validator.iter_errors(doc), key=lambda e: list(map(str, e.absolute_path))
    )
    for e in errors[:MAX_LINES]:
        print(f"FAIL {label}: {key_path(e)}: {e.message[:300]}", file=sys.stderr)
    if len(errors) > MAX_LINES:
        print(f"FAIL {label}: ... {len(errors) - MAX_LINES} more", file=sys.stderr)
    if not errors:
        print(f"PASS {label}: {path}")
    return len(errors)


def main(argv):
    if len(argv) < 2 or any("=" not in a for a in argv[1:]):
        return cannot("usage: env_schema_check.py <schema.json> <label>=<yaml> ...")
    try:
        import jsonschema
        import yaml
    except ImportError as e:
        return cannot(
            f"{e} (the check needs jsonschema and pyyaml: the conf-validator poetry env, or apt-get install python3-jsonschema python3-yaml)"
        )
    try:
        with open(argv[0], "r") as fh:
            schema = json.load(fh)
        cls = jsonschema.validators.validator_for(schema)
        cls.check_schema(schema)
    except (OSError, ValueError, jsonschema.exceptions.SchemaError) as e:
        return cannot(f"schema {argv[0]}: {e}")
    validator = cls(schema)
    bad = unreadable = 0
    for arg in argv[1:]:
        label, path = arg.split("=", 1)
        n = check_one(validator, yaml, label, path)
        if n is None:
            unreadable += 1
        elif n:
            bad += 1
    if unreadable:
        return EXIT_CANNOT_CHECK
    return EXIT_INVALID if bad else EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
