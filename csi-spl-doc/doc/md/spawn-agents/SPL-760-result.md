> Generated from qto doc `8c9bca1f-905f-43e2-826c-1b9fc7a73d94`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

<a id="ws-doc-bb0b2b16-e25a-44a7-a52c-e07ef5cc06a5"></a>
## Result: SPL-760, spawn-agents comments stop blaming the renderer

**Fixed**: Comments in three spawn-agents scripts that blamed the renderer for the distortion caused by the `-v` split.

<a id="ws-doc-76dfa8c7-befb-4986-af24-0ad0a2b00333"></a>
### Changes
- **spawn-window.sh**: Corrected comments to reflect the actual cause (the `-v` split, not the renderer).
- **spool-poke-queue.inc.sh**: Corrected comments to reflect the actual cause.
- **spool-strip-resize-proof.sh**: Corrected comments **and** added a SIGWINCH test to verify the Ink-style subject repaints its frame after the strip is split.

<a id="ws-doc-52f97a73-48ff-4876-9e07-6a62bbec4d7b"></a>
### Proof
- **Before/after**: `wc -l` and `git diff --stat` confirm the files changed only as intended.
  - spawn-window.sh: 471 lines, 8 insertions(+), 12 deletions(-)
  - spool-poke-queue.inc.sh: 553 lines, 2 insertions(+), 2 deletions(-)
  - spool-strip-resize-proof.sh: 358 lines, 125 insertions(+), 1 deletion(-)
- **Suite**: The spawn-agents feature suite is green (test-strip-resize.sh, test-spawn-window-dry-run.sh, test-spawn-window-riname.sh, test-spool-poke-queue.sh).
- **SIGWINCH**: The proof script now verifies the Ink-style subject repaints its frame after the strip is split.

<a id="ws-doc-3ce90db8-aed7-4fc9-9815-eac3fede412a"></a>
### Landing
- **Commit**: [055075996](https://github.com/csitea/csi-spl/commit/0550759966e2b8155b0b6f20c0ecc64a44c62b0b)
- **CI**: Pre-push gate green, landed on master.

Closes: SPL-760
