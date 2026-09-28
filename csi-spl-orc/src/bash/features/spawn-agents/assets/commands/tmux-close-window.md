---
name: tmux-close-window
description: Close an agent's tmux window by its agent id, immediately or after the agent exits (--defer). Use when the user runs /tmux-close-window or asks to close an agent window.
---

# /tmux-close-window — close an agent window

The helper never guesses: with no provable owner it exits 3 and closes nothing,
and a window whose name does not carry the named id is refused (exit 4).

## 1. Close another agent's window now

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <AGENT-ID>
```

## 2. Close your OWN window after you exit

Schedule it first, then `/exit`. `--defer` waits for the agent CLI to leave the
pane (at most `--timeout`, default 180 s).

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <YOUR-AGENT-ID> --defer
```

## 3. See what it would close

```bash
bash {{HARNESS_DIR}}/scripts/tmux-close-window.sh --agent <AGENT-ID> --dry-run
```
