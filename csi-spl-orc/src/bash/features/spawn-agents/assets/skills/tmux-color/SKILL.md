---
name: tmux-color
description: Set the colour of this agent's own tmux window in the status bar (blue, red, green, yellow, orange, purple, cyan, pink, white, reset). Use when the user runs /tmux-color <colour>, or asks to colour, tint or mark the current tmux window.
---

# /tmux-color — colour this agent's tmux window

> Generated from qto doc `20a5cdff-4b0e-4df2-91ed-7248d0b8a62c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Sets the status-bar colour of the window this agent runs in. The work is done
by spawn-agents' `tmux-window-color.sh`. It keeps the colour in the window
option `@window-colour`, targets a pane or window id and never a window index,
and reaches the box owner's tmux server on its own.

<a id="ws-doc-b1623045-098c-4fb7-9c68-d0a10b7a0951"></a>
## Usage

```
/tmux-color blue
/tmux-color reset
```

Colours: `blue` (default, active work), `red` (blocked, error), `green` (done,
healthy), `yellow` (waiting, needs attention), `orange` (warning), `purple`
(special, tooling), `cyan` (info), `pink` (personal), `white` (neutral),
`reset` (back to the theme). `--list` prints them.

<a id="ws-doc-2b096755-34ce-4418-abb4-20d5cf366498"></a>
## Run

Pass **your own agent id** (the `c-NNN` / `g-NNN` / `a-NNN` / `q-NNN`, or a
legacy `CLE-NN`, that titles your window). It survives a `sudo` hop that would strip `$TMUX_PANE`:

```bash
bash {{HARNESS_DIR}}/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
```

<a id="ws-doc-943e4261-d73a-4118-97a9-889908aaff5b"></a>
## After it runs

- Exit 0: say `tmux window set to <colour>`.
- Exit 1: an unknown colour or a usage error. Show the `--list` output.
- Exit 2: no target, the target is gone, or no tmux server. Say so; do not guess
  another window.
