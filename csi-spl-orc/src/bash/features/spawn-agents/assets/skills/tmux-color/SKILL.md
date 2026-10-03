---
name: tmux-color
description: Set the colour of this agent's own tmux window in the status bar (blue, red, green, yellow, orange, purple, cyan, pink, white, reset). Use when the user runs /tmux-color <colour>, or asks to colour, tint or mark the current tmux window.
---

# /tmux-color — colour this agent's tmux window

Sets the status-bar colour of the window this agent runs in. The work is done
by spawn-agents' `tmux-window-color.sh`. It keeps the colour in the window
option `@window-colour`, targets a pane or window id and never a window index,
and reaches the box owner's tmux server on its own.

## Usage

```
/tmux-color blue
/tmux-color reset
```

Colours: `blue` (default, active work), `red` (blocked, error), `green` (done,
healthy), `yellow` (waiting, needs attention), `orange` (warning), `purple`
(special, tooling), `cyan` (info), `pink` (personal), `white` (neutral),
`reset` (back to the theme). `--list` prints them.

## Run

Pass **your own agent id** (the `c-NNN` / `g-NNN` / `a-NNN` / `q-NNN`, or a
legacy `CLE-NN`, that titles your window). It survives a `sudo` hop that would strip `$TMUX_PANE`:

```bash
bash {{HARNESS_DIR}}/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
```

## After it runs

- Exit 0: say `tmux window set to <colour>`.
- Exit 1: an unknown colour or a usage error. Show the `--list` output.
- Exit 2: no target, the target is gone, or no tmux server. Say so; do not guess
  another window.
