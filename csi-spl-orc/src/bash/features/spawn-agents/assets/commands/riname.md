---
name: riname
description: Rename THIS agent's tmux window to "<ID> <title>", keeping the agent id (and the box tag). Use when the user runs /riname <title> or asks to retitle the current agent window.
---

# /riname — rename your tmux window

> Generated from qto doc `c496ab78-889e-4071-b0a0-547d9fc42786`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Pass your OWN agent id (the `c-NNN` / `g-NNN` / `a-NNN` / `q-NNN`, or a legacy `CLE-nn`, in your
window name, also in `$MCP_BOT_AGENT_ID`). `--agent` survives a sudo hop, which
strips `$TMUX_PANE`; the script validates the target against the live window
list and fails loudly rather than renaming the wrong window.

```bash
bash {{HARNESS_DIR}}/scripts/riname.sh --agent <YOUR-AGENT-ID> "<title>"
```

Window names are load-bearing: `spool-send.sh`, `next-agent-id.sh` and
`tmux-close-window.sh` read them. Keep the title short (2-5 words).
