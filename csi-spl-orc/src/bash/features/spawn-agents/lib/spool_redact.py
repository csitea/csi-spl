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
#
# Order matters: a whole block (a PEM key) goes before the pieces inside it,
# and the shaped tokens go before the generic `name=value` pass. The classes
# after the first eleven are specs/017 FR-SEC-032 (CLE-34988): each one was a
# credential this box holds or handles that passed the pass untouched.
SECRETS = [
    (r"xox[abprs]-[A-Za-z0-9-]{10,}", "slack-token"),
    (r"gh[pousr]_[A-Za-z0-9]{20,}", "github-token"),
    (r"github_pat_[A-Za-z0-9_]{20,}", "github-token"),
    (r"glpat-[A-Za-z0-9_-]{20,}", "gitlab-token"),
    (r"npm_[A-Za-z0-9]{30,}", "npm-token"),
    (r"AKIA[0-9A-Z]{16}", "aws-key-id"),
    (r"AIza[0-9A-Za-z_-]{30,}", "google-api-key"),
    (r"GOCSPX-[A-Za-z0-9_-]{20,}", "google-oauth-secret"),
    (r"ya29\.[A-Za-z0-9_-]{20,}", "google-access-token"),
    (r"1//0[A-Za-z0-9_-]{30,}", "google-refresh-token"),
    (r"sk-[A-Za-z0-9_-]{20,}", "api-key"),
    (r"xai-[A-Za-z0-9]{20,}", "api-key"),
    (r"(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}", "stripe-key"),
    (r"whsec_[A-Za-z0-9]{16,}", "stripe-webhook-secret"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----", "private-key"),
    # A key cut short (`head`, a scrolled pane) has no END line: take the
    # armour header, then every base64 / header line that follows it.
    (r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----(?:\r?\n(?:[A-Za-z0-9+/=]*|[A-Za-z-]+: [^\n]*)(?=\r?\n|\Z))*", "private-key"),
    (r'("private_key"\s*:\s*)"[^"]+"', r'\1"<redacted>"', "private-key"),
    # A spool box / tenant root key file is one raw base64 line: a 64-byte
    # ed25519 private key is 86 characters and "==". (A 32-byte PUBLIC key
    # is 43 + "=", and stays.)
    (r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{86}==(?![A-Za-z0-9+/=])", "ed25519-private-key"),
    (r"(postgres(?:ql)?://[^:\s/]+:)[^@\s]+@", r"\1<redacted>@", "dsn-password"),
    (r"(\b[a-z][a-z0-9+.-]*://[^:\s/@]+:)(?!<redacted>)[^@\s/]+@", r"\1<redacted>@", "url-password"),
    # A signed URL (git-rel's relay, S3/GCS) is a bearer credential until it
    # expires: the signature is what grants the read.
    (r"(?i)((?:X-Goog-Signature|X-Amz-Signature|Signature|sig)=)[A-Za-z0-9%+/=_-]{16,}", r"\1<redacted>", "signed-url"),
    (r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/-]{16,}=*", r"\1<redacted>", "bearer"),
    (r"(?i)(\b(?:set-)?cookie:\s*[^=\s;]+=)[^;\s]{16,}", r"\1<redacted>", "cookie"),
    (r'(?i)("[a-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)"\s*:\s*)"[^"]{6,}"',
     r'\1"<redacted>"', "json-secret"),
    (r"(?i)(password|passwd|pw|secret|token|api[_-]?key|access[_-]?key)(\s*[=:]\s*)['\"]?[^\s'\"]{6,}", r"\1\2<redacted>", "assignment"),
    # A password said in prose, the way a human types one into a terminal:
    # "the password is X", "pw for HUM-1 was X". The value must carry a digit
    # or a symbol, so "the password is incorrect." stays prose. (2026-10-01: a
    # typed password once reached a prd DM through the mirror.)
    (r"(?i)(\b(?:password|passwd|passphrase|passcode|pw|pwd)\b(?:\s+(?:for|of)\s+\S+)?\s+(?:is|was)\s+['\"]?)"
     r"(?=[^\s'\"]*[0-9!@#$%^&*_+=~])[^\s'\"]{6,}", r"\1<redacted>", "typed-password"),
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
