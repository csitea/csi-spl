---
name: spawn-an-agent
description: >
  Route a piece of work to the right agent launcher and spawn it: estimate the
  task's difficulty against your own maximum capacity, then run the launcher
  do_spl_lane_mix picks from the box's vendor split (cnf env.box.agent_split):
  /claude-spawn for hard, unsure or secret-bearing work, easy work to the vendor
  under its share (grok by default). Use when
  the user says "spawn an agent", "give this to an agent", or hands you work that
  belongs in another lane. A leading c-NNN / g-NNN / a-NNN / q-NNN id (or a legacy CLE-nn) sends
  the rest to that agent instead.
---

# /spawn-an-agent — pick the launcher, then spawn

You do not ask which launcher to use. You estimate, route, run the launcher's
spawn steps in this turn, and report which one you picked and why.

## 1. Message mode

If the first word is an agent id (`c-NNN`, `g-NNN`, `a-NNN`, `q-NNN`, or a legacy `CLE-nn`), send
the rest to that agent (section 2 of its launcher command) and stop.

## 2. Pick the launcher

Estimate the task's difficulty against your own maximum capacity (0..100),
then let the box's vendor split pick the launcher:

```bash
cd {{HARNESS_DIR}}/../../../.. && LANE_MIX_DIFFICULTY=<0..100> LANE_MIX_SENSITIVE=<0|1> ./run -a do_spl_lane_mix
```

Its last line, `pick=<vendor> launcher=/<vendor>-spawn reason=...`, is the
launcher. The split is cnf `env.box.agent_split` (all.env.yaml: claude 40,
grok 50, agy 10, each +/- 5 over the box's last 20 spawns), an approximate
ratio, never a quota:

| the task | goes to |
|---|---|
| personal data or secrets (credentials, keys, customer data): `LANE_MIX_SENSITIVE=1` | claude, always |
| 60% or more, or unsure (omit `LANE_MIX_DIFFICULTY`) | claude |
| under 60%: easy, mechanical, well specified | the vendor furthest below its share by more than the tolerance; inside the band, grok |

A vendor whose CLI is not installed or not signed in on this box is skipped
and its share goes to claude. An estimate near the line counts as harder than
it looks. A user who names a launcher wins over the pick.

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
