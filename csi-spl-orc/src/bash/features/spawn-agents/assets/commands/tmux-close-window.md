---
name: tmux-close-window
description: Close an agent's tmux window by its agent id, immediately or after the agent exits (--defer). Use when the user runs /tmux-close-window or asks to close an agent window.
---

# /tmux-close-window — close an agent window

> Generated from qto doc `1c9f728b-2ed2-447e-af99-fafac5a9702c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The helper never guesses: with no provable owner it exits 3 and closes nothing,
and a window whose name does not carry the named id is refused (exit 4).

<a id="ws-doc-de719e66-0164-4bfd-a911-e47817675d11"></a>
## 1. Close another agent's window now

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <AGENT-ID>
```

<a id="ws-doc-e202f460-4dae-4cf0-9058-470ab469e4c2"></a>
## 2. Close your OWN window after you exit

Schedule it first, then `/exit`. `--defer` waits for the agent CLI to leave the
pane (at most `--timeout`, default 180 s).

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --defer
```

<a id="ws-doc-f161ba50-4aff-4530-b889-19b00298e4cf"></a>
## 3. See what it would close

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <AGENT-ID> --dry-run
```
