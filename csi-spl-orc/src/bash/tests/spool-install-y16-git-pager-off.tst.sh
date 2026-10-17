#!/usr/bin/env bash
# spool-install step Y16 (SPL-2432): an agent's git never pages; the feature test
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y16-git-pager-off.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y16-git-pager-off.sh"
