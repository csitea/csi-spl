"""spool_desk_root.py - desk-root.inc.sh for the python desk readers
(spool-mirror.py, agent-mirror-check.py): one copy of the call.
"""

import os
import subprocess


def desk_root(home):
    """The cloud state root of this box's desks under desk-root.inc.sh (spec
    069 row B4): the desk user's, else HOME's. "" when it cannot tell."""
    lib = os.path.join(os.path.dirname(os.path.realpath(__file__)), "desk-root.inc.sh")
    try:
        r = subprocess.run(
            ["bash", lib, home], capture_output=True, text=True, timeout=20
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""
