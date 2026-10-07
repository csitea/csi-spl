#!/usr/bin/env bash
# The agent-teardown helper tmux-close-window.sh (--defer, the agy and the
# --rebirth closers, the lifetime markers), run here so the orc CI job gates
# it: csi-spl-orc/src/bash/features/spawn-agents/tests/test-tmux-close-window.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spawn-agents/tests/test-tmux-close-window.sh"
