#!/usr/bin/env python3
"""Redact the banned literals of the OSS gate from a text on stdin (spec 044,
do_oss_mirror). Every match of every rule in the rules file (the same file and
the same {{cnf:...}} resolution do_oss_gate uses) becomes "[redacted]". Used
for the commit MESSAGE a public mirror commit carries: the gate proves the
tree, and this keeps the message from naming what the tree may not.

usage: oss-redact.py --rules <banned-literals.tsv> [--cnf-vars <json>] <in >out
Exit 0 always on success; the number of redactions goes to stderr.
"""
import argparse
import importlib.util
import os
import sys


def gate_module():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("oss_gate", os.path.join(here, "oss-gate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", required=True)
    ap.add_argument("--cnf-vars")
    a = ap.parse_args()
    rules = gate_module().load_rules(a.rules, a.cnf_vars)
    text, n = sys.stdin.read(), 0
    for _cls, _label, rx in rules:
        text, k = rx.subn("[redacted]", text)
        n += k
    sys.stdout.write(text)
    print(f"redacted {n}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
