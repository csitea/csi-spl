#!/usr/bin/env python3
"""spool_redact.py - the ONE redaction pass for text that leaves this box
through a desk: the terminal mirror and the session backfill
(specs/036-spool-terminal-mirror).

Every mirror post and every exported transcript goes through redact() first.
The list is deliberately greedy: a false positive costs a word in a DM, a
false negative costs a credential on a hub row.

As a module:  from spool_redact import redact  ->  (text, {kind: count})
As a filter:  spool_redact.py < in > out       (the counts go to stderr)
"""
import json
import re
import sys

# (pattern, replacement[, label]). A replacement that is a bare word becomes
# <redacted:word> and is its own label; one carrying a backreference or a
# quote is used as is and names its label.
SECRETS = [
    (r"xox[abprs]-[A-Za-z0-9-]{10,}", "slack-token"),
    (r"gh[pousr]_[A-Za-z0-9]{20,}", "github-token"),
    (r"github_pat_[A-Za-z0-9_]{20,}", "github-token"),
    (r"AKIA[0-9A-Z]{16}", "aws-key-id"),
    (r"AIza[0-9A-Za-z_-]{30,}", "google-api-key"),
    (r"sk-[A-Za-z0-9_-]{20,}", "api-key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", "private-key"),
    (r'("private_key"\s*:\s*)"[^"]+"', r'\1"<redacted>"', "private-key"),
    (r"(postgres(?:ql)?://[^:\s/]+:)[^@\s]+@", r"\1<redacted>@", "dsn-password"),
    (r"(?i)(password|passwd|pw|secret|token|api[_-]?key)(\s*[=:]\s*)['\"]?[^\s'\"]{6,}", r"\1\2<redacted>", "assignment"),
    (r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", "jwt"),
]
_COMPILED = [(re.compile(t[0]), t[1], t[2] if len(t) > 2 else t[1]) for t in SECRETS]


def redact(text):
    """-> (redacted text, {kind: count}). Never raises on odd input."""
    s = text if isinstance(text, str) else str(text or "")
    counts = {}
    for pat, rep, label in _COMPILED:
        repl = rep if ("\\" in rep or rep.startswith('"')) else f"<redacted:{rep}>"
        s, n = pat.subn(repl, s)
        if n:
            counts[label] = counts.get(label, 0) + n
    return s, counts


def main():
    out, counts = redact(sys.stdin.read())
    sys.stdout.write(out)
    print(json.dumps({"redactions": counts}, sort_keys=True), file=sys.stderr)


if __name__ == "__main__":
    main()
