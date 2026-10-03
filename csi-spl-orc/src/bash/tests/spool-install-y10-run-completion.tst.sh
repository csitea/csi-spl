#!/usr/bin/env bash
# The ./run completion suite (spec 069 Y10), run here so the orc CI job gates
# it: csi-spl-orc/src/bash/features/spool-install/tests/test-y10-run-completion.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y10-run-completion.sh"
