#!/usr/bin/env bash
# The directive feature (specs/069 Y5: /signed-prompt), run here so the orc CI
# job gates it: csi-spl-orc/src/bash/features/directive/tests/test-directive.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/directive/tests/test-directive.sh"
