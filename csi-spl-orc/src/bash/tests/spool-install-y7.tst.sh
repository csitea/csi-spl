#!/usr/bin/env bash
# The installer's tmux-cleanup step (specs/069 Y7), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y7-tmux-links.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y7-tmux-links.sh"
