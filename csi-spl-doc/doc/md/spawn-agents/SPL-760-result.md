## Result: SPL-760, spawn-agents comments stop blaming the renderer

**Fixed**: Comments in three spawn-agents scripts that blamed the renderer for the distortion caused by the `-v` split.

### Changes
- **spawn-window.sh**: Corrected comments to reflect the actual cause (the `-v` split, not the renderer).
- **spool-poke-queue.inc.sh**: Corrected comments to reflect the actual cause.
- **spool-strip-resize-proof.sh**: Corrected comments **and** added a SIGWINCH test to verify the Ink-style subject repaints its frame after the strip is split.

### Proof
- **Before/after**: `wc -l` and `git diff --stat` confirm the files changed only as intended.
  - spawn-window.sh: 471 lines, 8 insertions(+), 12 deletions(-)
  - spool-poke-queue.inc.sh: 553 lines, 2 insertions(+), 2 deletions(-)
  - spool-strip-resize-proof.sh: 358 lines, 125 insertions(+), 1 deletion(-)
- **Suite**: The spawn-agents feature suite is green (test-strip-resize.sh, test-spawn-window-dry-run.sh, test-spawn-window-riname.sh, test-spool-poke-queue.sh).
- **SIGWINCH**: The proof script now verifies the Ink-style subject repaints its frame after the strip is split.

### Landing
- **Commit**: [055075996](https://github.com/csitea/csi-spl/commit/0550759966e2b8155b0b6f20c0ecc64a44c62b0b)
- **CI**: Pre-push gate green, landed on master.

Closes: SPL-760
