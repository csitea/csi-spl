#!/usr/bin/env python3
"""do_spl_mail_verify_token, the mailbox half: the token of the newest verify
mail (the /verify-email link of a register) to one fresh plus-address of the
relay mailbox, read over IMAP with m3-e2e.py's imap_verify_token. For tools
that cannot speak IMAP (the WUI live proofs) on a hub that answers no
debug_token (dev and prd since SPL-2157).

The address must be new (no earlier mail to it): every mail to it counts.

MAIL_TOKEN_KIND=reset reads the newest /reset-password link instead (SPL-6182,
the native-auth WUI proof); the default is verify.

Env: MAIL_TOKEN_EMAIL, MAIL_TOKEN_FILE (the token is written there, 0600, and
nowhere else), MAIL_TOKEN_KIND, M3_IMAP_USER / M3_IMAP_PASS_FILE / M3_IMAP_HOST /
M3_IMAP_TIMEOUT. Prints one JSON line of evidence (sender, subject, delay,
never the token or the address); exit 0 = token written.
"""

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)


def main():
    email, path = os.environ["MAIL_TOKEN_EMAIL"], os.environ["MAIL_TOKEN_FILE"]
    if not m3.IMAP_USER:
        print(json.dumps({"ok": False, "error": "no M3_IMAP_USER mailbox set"}))
        return 1
    kind = os.environ.get("MAIL_TOKEN_KIND", "verify")
    if kind not in ("verify", "reset"):
        print(json.dumps({"ok": False, "error": "MAIL_TOKEN_KIND is verify or reset"}))
        return 1
    link = m3.RESET_LINK if kind == "reset" else m3.VERIFY_LINK
    token, ev = m3.imap_verify_token(email, set(), link)
    if not token:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "no %s mail within %ds" % (kind, m3.IMAP_TIMEOUT),
                }
            )
        )
        return 1
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    keep = (
        "mail_from",
        "mail_subject",
        "mail_message_id",
        "mail_after_s",
        "link_page_status",
    )
    print(json.dumps(dict({"ok": True}, **{k: ev[k] for k in keep if k in ev})))
    return 0


if __name__ == "__main__":
    sys.exit(main())
