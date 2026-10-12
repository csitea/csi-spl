#!/usr/bin/env python3
"""The qas CI-proof rule (owner, t1 0f2ed820 msg e768eb42: "Yes, passing
could be counted as approved"): which qas issues a passing CI browser proof
accepts. Reads only: the issue list document and local git.

usage: qas-ci-accept.py LIST_JSON GIT_DIR REF PROOF_SHA ORG_APP

Prints one TSV row per issue in status qas:
  <key> TAB move TAB <test file> TAB <newest commit of the key>
  <key> TAB keep TAB <reason>

UI-only: the issue is a plain issue (an epic or a feature closes with its
children), at least one commit on REF names its key in its subject scope
("feat(wui, SPL-992): ..."), every path those
commits touch is under <org-app>-wui/, <org-app>-doc/ or .github/ (docs and
CI config ship nothing to a user), at least one under <org-app>-wui/.

Linked to its proof: a CI browser test, <org-app>-wui/tests/e2e/*.test.mjs
in PROOF_SHA's tree and not in tests/e2e/ci-skip.txt, either named in the
issue description by a line "ci-proof: <file>.test.mjs" or naming the key
itself. Every commit of the key must be in PROOF_SHA, so the passing run
tested the code the issue shipped.
"""

import json
import re
import subprocess
import sys


def git(gdir, *args):
    r = subprocess.run(["git", "-C", gdir, *args], capture_output=True, text=True)
    return r.returncode, r.stdout


def key_regex(key):
    return "(^|[^A-Za-z0-9-])" + re.escape(key) + "([^0-9]|$)"


SCOPE = re.compile(r"^[a-z]+\(([^)]*)\)!?:")


def in_scope(line, key):
    """'<sha> feat(wui, SPL-992): ...' -> True: the key is in the subject's
    scope. A key only quoted in the text (a test fixture, a cross reference)
    does not make the commit that issue's work."""
    m = SCOPE.match(line.split(" ", 1)[1] if " " in line else "")
    return bool(m) and key in [s.strip() for s in m.group(1).split(",")]


def issues_of(path):
    doc = json.load(open(path, encoding="utf-8"))
    res = doc.get("result") if isinstance(doc, dict) else None
    res = res if isinstance(res, dict) else {}
    out = [i for i in res.get("issues") or [] if isinstance(i, dict) and i.get("key")]
    return [i for i in out if (i.get("status") or "") == "qas"]


def ci_skipped(gdir, sha, e2e):
    rc, out = git(gdir, "show", "%s:%s/ci-skip.txt" % (sha, e2e))
    if rc != 0:
        return set()
    names = set()
    for line in out.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line.split()[0])
    return names


def ui_only(gdir, ref, proof, key, org_app):
    """-> (commits newest first, reason): no reason = UI-only and in the proof."""
    rc, out = git(gdir, "log", ref, "-E", "--grep=" + key_regex(key), "--format=%H %s")
    commits = [
        l.split(" ", 1)[0] for l in out.splitlines() if rc == 0 and in_scope(l, key)
    ]
    if not commits:
        return commits, "no commit on %s names %s in its subject scope" % (ref, key)
    wui, ui = org_app + "-wui/", False
    neutral = (org_app + "-doc/", ".github/")
    for c in commits:
        _, files = git(gdir, "show", "--format=", "--name-only", c)
        for f in files.split():
            if f.startswith(wui):
                ui = True
            elif not f.startswith(neutral):
                return commits, "not UI-only: %s touches %s" % (c[:9], f)
    if not ui:
        return commits, "not UI-only: no commit of %s touches %s" % (key, wui)
    for c in commits:
        if git(gdir, "merge-base", "--is-ancestor", c, proof)[0] != 0:
            return commits, "commit %s is newer than the proof run's sha %s" % (
                c[:9],
                proof[:9],
            )
    return commits, ""


def touched(gdir, commits):
    out = set()
    for c in commits:
        out.update(git(gdir, "show", "--format=", "--name-only", c)[1].split())
    return out


def proof_test(gdir, proof, issue, org_app, commits):
    """-> (test file, reason). Of the tests naming the key, one the key's own
    commits touched comes first."""
    e2e = org_app + "-wui/tests/e2e"
    skip = ci_skipped(gdir, proof, e2e)
    m = re.search(
        r"(?mi)^\s*ci-proof:\s*(\S+\.test\.mjs)\s*$", issue.get("description") or ""
    )
    if m:
        name = m.group(1).rsplit("/", 1)[-1]
        path = e2e + "/" + name
        if git(gdir, "cat-file", "-e", "%s:%s" % (proof, path))[0] != 0:
            return "", "ci-proof %s is not in the proof run's tree %s" % (
                name,
                proof[:9],
            )
        if name in skip:
            return "", "ci-proof %s is in ci-skip.txt: CI does not run it" % name
        return path, ""
    rc, out = git(
        gdir, "grep", "-lE", key_regex(issue["key"]), proof, "--", e2e + "/*.test.mjs"
    )
    files = (
        sorted({l.split(":", 1)[1] for l in out.splitlines() if ":" in l})
        if rc == 0
        else []
    )
    files = [f for f in files if f.rsplit("/", 1)[-1] not in skip]
    own = touched(gdir, commits)
    files.sort(key=lambda f: (f not in own, f))
    if not files:
        return (
            "",
            "no CI browser test (tests/e2e/*.test.mjs) names %s and no ci-proof: line"
            % issue["key"],
        )
    return files[0], ""


def main(argv):
    if len(argv) != 6:
        sys.stderr.write(__doc__)
        return 2
    path, gdir, ref, proof, org_app = argv[1:]
    for i in issues_of(path):
        key = i["key"]
        kind = i.get("kind") or "issue"
        if kind != "issue":
            print(
                "%s\tkeep\t%s: closes with its children, never on a proof" % (key, kind)
            )
            continue
        commits, why = ui_only(gdir, ref, proof, key, org_app)
        if not why:
            test, why = proof_test(gdir, proof, i, org_app, commits)
        if why:
            print("%s\tkeep\t%s" % (key, why))
            continue
        print("%s\tmove\t%s\t%s" % (key, test, commits[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
