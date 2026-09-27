#!/usr/bin/env python3
"""The file-level classes of do_oss_gate (spec 044 T003/T004, FR-OS-002/003/006).

Scans an EXPORTED tree (never a git checkout) and appends one TSV row per hit
to the report: class, path, line, label. The label names the RULE that fired,
never the text it matched -- the report is a distribution channel too, so a
secret or a banned literal must not travel in it.

  oss-gate.py scan    --dir D --rules R --assets A --report OUT
  oss-gate.py deps    --report OUT [--node-modules NM] [--go-list F]
  oss-gate.py summary --report OUT --classes c1,c2,...

Exit: scan/deps 0 when they ran (hits or not), 2 when a class could not be
measured -- a class that proved nothing is never reported as clean.
summary: 0 when every class counts 0, 1 otherwise.
"""
import argparse
import fnmatch
import json
import os
import re
import sys

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".svg", ".ico", ".webp", ".tiff", ".avif"}
# Never in the public tree, whatever the allow-list says (T004): the AI-tool
# instruction files, git metadata, cnf values, terraform state/vars, keys.
FORBIDDEN = [
    ("CLAUDE.md", "ai-tool instructions"), ("AGENTS.md", "ai-tool instructions"),
    ("GEMINI.md", "ai-tool instructions"), (".git", "git metadata (history)"),
    ("*.tfvars", "rendered tfvars"), ("*.tfstate", "terraform state"),
    ("*.tfstate.backup", "terraform state"), ("*.env.yaml", "cnf env file"),
    ("*.env.json", "cnf env file"), ("key-*.json", "service-account key file"),
    ("*.pem", "key material"), ("*.p12", "key material"), ("*.key", "key material"),
]
SKIP_DIRS = {"node_modules", ".git"}
# The outbound licence is AGPL-3.0 (SPL-62). A dependency licence must be one
# an AGPL-3.0 work may include; anything else -- or none -- is a hit.
ALLOWED_LICENCES = {
    "MIT", "MIT-0", "ISC", "0BSD", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0",
    "BlueOak-1.0.0", "CC0-1.0", "CC-BY-4.0", "CC-BY-3.0", "Unlicense", "Zlib",
    "Python-2.0", "MPL-2.0", "LGPL-2.1-or-later", "LGPL-3.0-only",
    "LGPL-3.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later", "AGPL-3.0-only",
    "AGPL-3.0-or-later", "WTFPL", "Artistic-2.0",
}


def walk(root):
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            p = os.path.join(d, f)
            yield os.path.relpath(p, root), p


def is_text(path):
    try:
        with open(path, "rb") as fh:
            return b"\0" not in fh.read(8192)
    except OSError:
        return False


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def load_rules(path):
    rules = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                sys.exit(f"FATAL {path}:{n}: want class<TAB>label<TAB>regex")
            cls, label, rx = parts
            rules.append((cls, label, re.compile(rx)))
    if not rules:
        sys.exit(f"FATAL {path}: no rules -- the literal classes would prove nothing")
    return rules


def load_globs(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [l.strip() for l in fh if l.strip() and not l.lstrip().startswith("#")]


def row(out, cls, path, line, label):
    out.write(f"{cls}\t{path}\t{line}\t{label}\n")


def scan(a):
    rules = load_rules(a.rules)
    assets = load_globs(a.assets)
    with open(a.report, "a", encoding="utf-8") as out:
        for d, dirs, files in os.walk(a.dir):
            dirs[:] = sorted(x for x in dirs if x != "node_modules")
            for name in dirs + sorted(files):
                rel = os.path.relpath(os.path.join(d, name), a.dir)
                for pat, label in FORBIDDEN:
                    if fnmatch.fnmatch(name, pat):
                        row(out, "forbidden-file", rel, 0, label)
                        break
            dirs[:] = [x for x in dirs if x != ".git"]
        for rel, p in walk(a.dir):
            ext = os.path.splitext(rel)[1].lower()
            if ext in IMAGE_EXT and not any(fnmatch.fnmatch(rel, g) for g in assets):
                row(out, "image-unlicensed", rel, 0, ext.lstrip("."))
            if not is_text(p):
                continue
            with open(p, encoding="utf-8", errors="replace") as fh:
                for n, text in enumerate(fh, 1):
                    for cls, label, rx in rules:
                        if rx.search(text):
                            row(out, cls, rel, n, label)
        licence(a.dir, out)
        ci_runner(a.dir, out)
    return 0


def ci_runner(root, out):
    """FR-OS-005: no workflow of the public repo runs on a self-hosted runner."""
    wf = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(wf):
        return
    for f in sorted(os.listdir(wf)):
        p = os.path.join(wf, f)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            for n, text in enumerate(fh, 1):
                code = text.split("#", 1)[0]
                if re.search(r"runs-on\s*:.*self-hosted|^\s*-\s*['\"]?self-hosted", code):
                    row(out, "ci-runner", os.path.relpath(p, root), n, "self-hosted runner in a public workflow")


def licence(root, out):
    lic = os.path.join(root, "LICENSE")
    body = read(lic) if os.path.isfile(lic) else ""
    if "GNU AFFERO GENERAL PUBLIC LICENSE" not in body or "Version 3" not in body:
        row(out, "licence", "LICENSE", 0, "root LICENSE missing or not AGPL-3.0")
    if not any(os.path.isfile(os.path.join(root, f)) for f in
               ("THIRD-PARTY-NOTICES.md", "THIRD-PARTY-NOTICES", "NOTICE")):
        row(out, "licence", "THIRD-PARTY-NOTICES.md", 0, "third-party notices missing")
    for rel, p in walk(root):
        base = os.path.basename(rel)
        if base == "package.json":
            try:
                if not json.loads(read(p)).get("license"):
                    row(out, "licence", rel, 1, "package.json has no license field")
            except ValueError:
                row(out, "licence", rel, 1, "package.json unreadable")
        elif base == "go.mod":
            d = os.path.dirname(p)
            if not any(f.endswith(".go") and "SPDX-License-Identifier:" in read(os.path.join(d, f))
                       for f in os.listdir(d)):
                row(out, "licence", rel, 1, "Go module root has no SPDX-License-Identifier")


def spdx_ok(expr):
    e = (expr or "").replace("(", " ").replace(")", " ").strip()
    if not e:
        return False
    if " OR " in e:
        return any(spdx_ok(x) for x in e.split(" OR "))
    return all(x.strip() in ALLOWED_LICENCES for x in e.split(" AND "))


def classify_text(t):
    if "GNU AFFERO GENERAL PUBLIC LICENSE" in t:
        return "AGPL-3.0-only"
    if "GNU LESSER GENERAL PUBLIC LICENSE" in t:
        return "LGPL-3.0-only" if "Version 3" in t else "LGPL-2.1-or-later"
    if "GNU GENERAL PUBLIC LICENSE" in t:
        return "GPL-3.0-only" if "Version 3" in t else "GPL-2.0-only"
    if "Business Source License" in t or "Server Side Public License" in t:
        return "non-free"
    if "Apache License" in t and "Version 2.0" in t:
        return "Apache-2.0"
    if "Mozilla Public License" in t and "2.0" in t:
        return "MPL-2.0"
    if "Permission is hereby granted, free of charge" in t:
        return "MIT"
    if "Redistribution and use in source and binary forms" in t:
        return "BSD-3-Clause" if re.search(r"Neither the name|names of (its|the|any) contributors", t) else "BSD-2-Clause"
    if re.search(r"Permission to use, copy, modify, and(/or)? distribute", t):
        return "ISC"
    return ""


def go_licence(moddir):
    names = [f for f in os.listdir(moddir) if re.match(r"(?i)^(licen[cs]e|copying)", f)] \
        if os.path.isdir(moddir) else []
    ids = sorted({classify_text(read(os.path.join(moddir, f))) for f in names} - {""})
    return " AND ".join(ids) if ids else "UNKNOWN"


def npm_packages(nm_root):
    """(name, package.json path) of every package in a pnpm node_modules/.pnpm store."""
    store = os.path.join(nm_root, ".pnpm")
    for entry in sorted(os.listdir(store)):
        nm = os.path.join(store, entry, "node_modules")
        if not os.path.isdir(nm):
            continue
        for cand in os.listdir(nm):
            subs = [cand] if not cand.startswith("@") else \
                [f"{cand}/{s}" for s in os.listdir(os.path.join(nm, cand))]
            for name in subs:
                # the store entry is <name with / as +>@<version>[_peers]
                if not entry.startswith(name.replace("/", "+") + "@"):
                    continue
                pj = os.path.join(nm, name, "package.json")
                if not os.path.islink(os.path.join(nm, name)) and os.path.isfile(pj):
                    yield name, pj


def deps(a):
    counted = 0
    with open(a.report, "a", encoding="utf-8") as out:
        if a.go_list:
            for line in open(a.go_list, encoding="utf-8"):
                parts = line.split()
                if len(parts) != 3:
                    continue
                path, ver, moddir = parts
                counted += 1
                lic = go_licence(moddir)
                if not spdx_ok(lic):
                    row(out, "dep-licence", f"go:{path}@{ver}", 0, lic)
        if a.node_modules:
            if not os.path.isdir(os.path.join(a.node_modules, ".pnpm")):
                print(f"FATAL no .pnpm store under {a.node_modules}: npm licences not measured", file=sys.stderr)
                return 2
            for name, pj in npm_packages(a.node_modules):
                try:
                    d = json.loads(read(pj))
                except ValueError:
                    d = {}
                lic = d.get("license")
                if isinstance(lic, dict):
                    lic = lic.get("type")
                if not lic and isinstance(d.get("licenses"), list):
                    lic = " OR ".join(x.get("type", "") for x in d["licenses"] if isinstance(x, dict))
                counted += 1
                if not spdx_ok(lic):
                    row(out, "dep-licence", f"npm:{name}@{d.get('version', '?')}", 0, lic or "UNKNOWN")
    print(f"dep-licence: {counted} package(s) measured")
    if counted == 0:
        print("FATAL 0 dependencies measured -- the dep-licence class proved nothing", file=sys.stderr)
        return 2
    return 0


def summary(a):
    counts = {c: 0 for c in a.classes.split(",") if c}
    total = 0
    with open(a.report, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            cls = line.split("\t", 1)[0]
            counts[cls] = counts.get(cls, 0) + 1
            total += 1
    for c in sorted(counts):
        print(f"{c}\t{counts[c]}")
    print(f"TOTAL\t{total}")
    return 0 if total == 0 else 1


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("scan")
    s.add_argument("--dir", required=True)
    s.add_argument("--rules", required=True)
    s.add_argument("--assets")
    s.add_argument("--report", required=True)
    d = sp.add_parser("deps")
    d.add_argument("--report", required=True)
    d.add_argument("--node-modules")
    d.add_argument("--go-list")
    m = sp.add_parser("summary")
    m.add_argument("--report", required=True)
    m.add_argument("--classes", default="")
    a = ap.parse_args()
    return {"scan": scan, "deps": deps, "summary": summary}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
