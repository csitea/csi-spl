#!/usr/bin/env python3
"""issue-key-rate.py: the fleet's issue key rate on trunk (owner Q6 A, HUM-10,
t1 5ea2e615 msg 910b14c9; spec 135 section 9: the key is enforced at the
lane's exit, and the rate is measured weekly).

  issue-key-rate.py GIT_DIR REF SINCE

GIT_DIR the checkout to read (read-only)
REF     the trunk ref, e.g. origin/master
SINCE   git's --since value, e.g. "7 days ago"

Counts the non-merge commits on REF since SINCE:
  cite   an issue key in the subject scope ("docs(spec, SPL-12): ...", any
         type) or a "Closes:" trailer: the commit carries a key
  close  the commits the landed-fix rule closes an issue with (commit_keys of
         issue-close-landed.py, the one parser: no second pattern here)
Prints one JSON line: since, ref, commits, cite, close, the two rates in
percent (null for no commits), and the uncited commits per subject type.
"""

import importlib.util
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "icl", os.path.join(_HERE, "issue-close-landed.py")
)
icl = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(icl)


def cites(subject, closes):
    m = icl.SUBJECT.match(subject)
    return bool(
        (m and icl.KEY.search(m.group("scope")))
        or any(icl.KEY.search(v) for v in closes)
    )


def rate(part, whole):
    return round(100.0 * part / whole, 1) if whole else None


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    gdir, ref, since = argv[1:]
    fmt = (
        icl.SEP.join(["%H", "%s", "%(trailers:key=Closes,valueonly,separator=%x2C)"])
        + icl.END
    )
    out = subprocess.run(
        [
            "git",
            "-C",
            gdir,
            "log",
            "--no-merges",
            "--since=" + since,
            "--format=" + fmt,
            ref,
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    n = cite = close = 0
    uncited = {}
    for rec in out.split(icl.END):
        rec = rec.strip("\n")
        if not rec:
            continue
        _sha, subject, closes = (rec.split(icl.SEP) + ["", ""])[:3]
        closes = [c for c in closes.split(",") if c.strip()]
        n += 1
        if icl.commit_keys(subject, closes):
            close += 1
        if cites(subject, closes):
            cite += 1
        else:
            m = icl.SUBJECT.match(subject)
            t = m.group("type") if m else "other"
            uncited[t] = uncited.get(t, 0) + 1
    by_type = dict(sorted(uncited.items(), key=lambda kv: (-kv[1], kv[0])))
    print(
        json.dumps(
            {
                "since": since,
                "ref": ref,
                "commits": n,
                "cite": cite,
                "close": close,
                "cite_pct": rate(cite, n),
                "close_pct": rate(close, n),
                "uncited_by_type": by_type,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
