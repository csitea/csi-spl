#!/usr/bin/env python3
"""Syntax gate for config files: YAML, JSON, TOML. Stdlib + PyYAML only.

Fails on a parse error AND on a duplicate mapping key. Duplicate keys are the
case the usual one-liners miss: yq v4, jq and yaml.safe_load all accept
`a: 1\na: 2` and silently keep the last value.

Usage: config-syntax-check.py <file>...   (exit 0 clean, 1 findings, 2 usage)
Files with other extensions are ignored, so the caller may pass the whole
touched-file list.
"""
import json
import sys
import tomllib

import yaml


class _DupKeyLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    seen = {}
    for key_node, _ in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":  # `<<:` may repeat
            continue
        key = loader.construct_object(key_node, deep=deep)
        try:
            hash(key)
        except TypeError:
            continue
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None,
                "duplicate key %r (first at line %d)" % (key, seen[key] + 1),
                key_node.start_mark)
        seen[key] = key_node.start_mark.line
    loader.flatten_mapping(node)  # resolve `<<:` merges as SafeLoader does
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


_DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def _json_hook(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise ValueError("duplicate key %r" % k)
        seen.add(k)
    return dict(pairs)


def check(path):
    low = path.lower()
    if low.endswith((".yml", ".yaml")):
        with open(path, encoding="utf-8") as fh:
            for _ in yaml.load_all(fh, Loader=_DupKeyLoader):
                pass
    elif low.endswith(".json"):
        with open(path, encoding="utf-8") as fh:
            json.load(fh, object_pairs_hook=_json_hook)
    elif low.endswith(".toml"):
        with open(path, "rb") as fh:
            tomllib.load(fh)  # TOML forbids duplicate keys itself
    else:
        return False
    return True


def main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    bad = checked = 0
    for path in argv:
        try:
            checked += check(path)
        except FileNotFoundError:
            continue  # deleted in the diff
        except Exception as exc:  # noqa: BLE001 - every parse error is a finding
            bad += 1
            checked += 1
            msg = " ".join(str(exc).split())
            print("%s: %s" % (path, msg))
    print("config-syntax-check: %d file(s) checked, %d finding(s)" % (checked, bad),
          file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
