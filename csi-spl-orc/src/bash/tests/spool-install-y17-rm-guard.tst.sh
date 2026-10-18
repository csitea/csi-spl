#!/usr/bin/env bash
# The rm-guard suite (spool-install Y17, SPL-2474), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y17-rm-guard.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y17-rm-guard.sh"
