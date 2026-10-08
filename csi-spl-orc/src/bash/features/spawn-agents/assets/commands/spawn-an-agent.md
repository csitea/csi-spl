---
name: spawn-an-agent
description: >
  Route a piece of work to the right agent launcher and spawn it. Name the
  task kind, then let do_spl_lane_mix pick from the box's vendor split
  (cnf env.box.agent_split): spec work and multilingual text to /agy-spawn, secrets and the most
  complex coding to /claude-spawn, everything else to the larger of the grok
  and mistral shares (/grok-spawn or /mistral-spawn). An omitted kind and an
  omitted difficulty are that default, not claude. Use when the user says
  "spawn an agent", "give this to an agent", or hands you work that belongs in
  another lane. A leading c-NNN / g-NNN / a-NNN / q-NNN / m-NNN id (or a legacy
  CLE-nn) sends the rest to that agent instead.
---

# /spawn-an-agent — pick the launcher, then spawn

You do not ask which launcher to use. You estimate, route, run the launcher's
spawn steps in this turn, and report which one you picked and why.

## 1. Message mode

If the first word is an agent id (`c-NNN`, `g-NNN`, `a-NNN`, `q-NNN`, `m-NNN`, or a legacy `CLE-nn`), send
the rest to that agent (section 2 of its launcher command) and stop.

## 2. Pick the launcher

Name the task kind, estimate difficulty against your own maximum capacity
(0..100) when the work is coding, then let the box's vendor split pick the
launcher:

```bash
cd {{HARNESS_DIR}}/../../../.. && LANE_MIX_KIND=<spec|i18n|secret|hard|> LANE_MIX_DIFFICULTY=<0..100> LANE_MIX_SENSITIVE=<0|1> ./run -a do_spl_lane_mix
```

Its last line, `pick=<vendor> launcher=/<vendor>-spawn reason=...`, is the
launcher. The split is cnf `env.box.agent_split` (all.env.yaml: claude,
grok, agy, qwen and mistral, each +/- 5 over the box's last 20 spawns), an
approximate ratio, never a quota. Mistral takes grok's share (spec 110 D1):
`grok: 55` becomes `mistral: 55, grok: 0`.

| the task | goes to |
|---|---|
| spec writing or spec review: `LANE_MIX_KIND=spec` | agy |
| translation, or the language review of user-facing text in several languages (blog posts, WUI i18n locale files, help pages): `LANE_MIX_KIND=i18n` | agy, whatever the shares: agy has the final word on multilingual text (owner, 2026-10-08) |
| personal data or secrets (credentials, keys, customer data): `LANE_MIX_KIND=secret` or `LANE_MIX_SENSITIVE=1` | claude; mistral may take it too (spec 110 D2), but only when you pick `/mistral-spawn` by hand. Never qwen |
| the most complex coding: `LANE_MIX_KIND=hard`, or difficulty 60 or more | claude |
| everything else, tests included: kind unset or `default`, difficulty omitted | the larger share of grok and mistral (mistral once the share has moved) |
| under 60%, kind unset: easy, mechanical, well specified | the vendor furthest below its share by more than the tolerance; inside the band, the largest non-claude share |

A vendor whose CLI is not installed or not signed in on this box is skipped
and its share goes to claude (a spec with no agy there goes to claude).
mistral is the exception (spec 110 D4): a box without `~/.vibe/.env` passes
its pick down the chain mistral -> agy -> claude. An `i18n` task with no agy
there falls to claude (spec 110 D4: the next vendor in the chain): claude
drafts, and the text WAITS for an agy review before it ships (ask the
orchestrator for an agy lane on another box). It never ships flagged as
unreviewed: the owner gave agy the final word. An estimate near the line
counts as harder than it looks. Omitting the difficulty is the default, not
a hard task. A user who names a launcher wins over the pick.

## 3. Before spawning

- Count the live agents (the launcher's section 1.1); the ceiling is {{AGENT_CEILING}}.
- Read the fleet-wide lane map, `bash {{HARNESS_DIR}}/scripts/lane-map.sh`: every live agent on EVERY
  machine (`<ID>@<box>`, repo, branch, scope, files, topic). `git worktree list`
  sees this machine only. Keep the new scope disjoint; `--check <path,...>` exits 3
  naming the live lane that owns one of those paths. Name in the brief the files
  it must NOT touch.
- Pass the paths it will own as `SPAWN_LANE_FILES=<path,...>` (and its topic as
  `SPAWN_LANE_TOPIC`) to the launcher: the spawn writes them into its lane row.
- Where it starts: a new lane goes where the fleet load target puts it
  (`./run -a do_spl_box_pick`: the first box in the hub's fill order below its
  high mark, load5 / cpus, default band 50..75 %). `pick=hold` means every box
  is full: the launcher exits 10 and spawns nothing, so queue the lane and say
  so. With no pick (hub down) it falls back to the box with the fewest busy
  agents (the lane map's `BOX` header lines). `SPAWN_BOX=local` or
  `SPAWN_BOX=<box>` pins it. The band and order are the hub's instance setting;
  only the operator workspace's admin changes them (`PATCH /v1/operator/fleet-load`).

## 4. Spawn

Follow the chosen launcher command's section 1, in this turn.
