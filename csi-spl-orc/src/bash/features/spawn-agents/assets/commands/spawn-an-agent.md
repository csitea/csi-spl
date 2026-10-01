---
name: spawn-an-agent
description: >
  Route a piece of work to the right agent launcher and spawn it: estimate the
  task's difficulty against your own maximum capacity, then run /qwen-spawn
  (under 60%, the cheap lane) or /claude-spawn (60% or more, or unsure). Use when
  the user says "spawn an agent", "give this to an agent", or hands you work that
  belongs in another lane. A leading CLE-nn / GRK-nn / AGY-nn / QWN-nn id sends
  the rest to that agent instead.
---

# /spawn-an-agent — pick the launcher, then spawn

You do not ask which launcher to use. You estimate, route, run the launcher's
spawn steps in this turn, and report which one you picked and why.

## 1. Message mode

If the first word is an agent id (`CLE-nn`, `GRK-nn`, `AGY-nn`, `QWN-nn`), send
the rest to that agent (section 2 of its launcher command) and stop.

## 2. Pick the launcher

| your difficulty estimate | launcher |
|---|---|
| under 60% of what you could handle | `/qwen-spawn` |
| 60% or more, or unsure | `/claude-spawn` |

The data rule overrides difficulty: work that carries personal data or secrets
(credentials, keys, customer data) always goes to `/claude-spawn`. An estimate
near the line counts as harder than it looks: use `/claude-spawn`.
`/grok-spawn` and `/agy-spawn` are used only when the user names them.

## 3. Before spawning

- Count the live agents (the launcher's section 1.1); the ceiling is {{AGENT_CEILING}}.
- Read the fleet-wide lane map, `bash {{HARNESS_DIR}}/scripts/lane-map.sh`: every live agent on EVERY
  machine (`<ID>@<box>`, repo, branch, scope, files, topic). `git worktree list`
  sees this machine only. Keep the new scope disjoint; `--check <path,...>` exits 3
  naming the live lane that owns one of those paths. Name in the brief the files
  it must NOT touch.
- Pass the paths it will own as `SPAWN_LANE_FILES=<path,...>` (and its topic as
  `SPAWN_LANE_TOPIC`) to the launcher: the spawn writes them into its lane row.

## 4. Spawn

Follow the chosen launcher command's section 1, in this turn.
