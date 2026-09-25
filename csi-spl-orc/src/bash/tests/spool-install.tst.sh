#!/usr/bin/env bash
# The installer's hermetic suite (specs/037), run here so the orc CI job gates
# it: csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-install.sh"
