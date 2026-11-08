#!/usr/bin/env python3
"""The customer list's completeness check (spec 091 5.5, SPL-5124).

Run by do_spl_public_dataset_customer_check. --rows holds `host|<h>` and
`key|<PREFIX>` lines read from the customer channels. Anything the gate's own
pattern does not match and customer_ignore does not name is uncovered. Prints
counts only; the values go to --out (a new file, mode 600) when it is given.
Exit 0 = whole, 1 = uncovered entries, 2 = a bad list.
"""

import argparse
import importlib.util
import os
import re
import sys

HOST = re.compile(r"^[a-z0-9-]+(?:\.[a-z0-9-]+)+$")


def gate_module():
    path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "public-dataset-gate.py"
    )
    spec = importlib.util.spec_from_file_location("public_dataset_gate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().split("\n")


def uncovered(rows, cover, ignore):
    """-> sorted unique (kind, value) that neither pattern matches."""
    out = set()
    for row in rows:
        kind, _, v = row.partition("|")
        if kind == "host":
            v = v.rstrip(".,;")
            if not HOST.match(v):  # a template or a typo, not an address
                continue
            probe = v
        elif kind == "key":
            probe = v + "-1"
        else:
            continue
        if not (cover.search(probe) or (ignore and ignore.search(probe))):
            out.add((kind, v))
    return sorted(out)


def main():
    p = argparse.ArgumentParser(description="customer list completeness (SPL-5124)")
    for k in ("rows", "customer-list", "ignore-list"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--out", default="")
    a = p.parse_args()
    gate = gate_module()
    cover, bad = gate.customer_regex(read(a.customer_list))
    ignore, bad_i = gate.customer_regex(read(a.ignore_list))
    if cover is None or bad or bad_i:
        print("FATAL the customer list or customer_ignore is empty or malformed")
        return 2
    new = uncovered(read(a.rows), cover, ignore)
    hosts = sum(1 for k, _ in new if k == "host")
    if a.out:
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.writelines("%s:%s\n" % kv for kv in new)
    if new:
        print(
            "FAIL customer list: %d host(s), %d key prefix(es) on neither list: classify them in the private overlay"
            % (hosts, len(new) - hosts)
        )
        return 1
    print("OK customer list: every host and key prefix of the channels is classified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
