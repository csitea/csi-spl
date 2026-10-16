#!/usr/bin/env bash
# The live topic status card topic-status-card.sh (one card per owner issue
# topic, posted once then edited in place; SPL-2089), run here so the orc CI
# job gates it: csi-spl-orc/src/bash/features/spawn-agents/tests/test-topic-status-card.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spawn-agents/tests/test-topic-status-card.sh"
