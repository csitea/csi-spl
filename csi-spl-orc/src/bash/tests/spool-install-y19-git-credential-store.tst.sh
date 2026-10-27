#!/usr/bin/env bash
# spool-install step Y19 (SPL-3761): no clear-text git credential store; the feature
# test gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y19-git-credential-store.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y19-git-credential-store.sh"
