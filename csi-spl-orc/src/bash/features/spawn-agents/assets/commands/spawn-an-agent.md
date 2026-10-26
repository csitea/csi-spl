---
name: spawn-an-agent
description: >
  Route a piece of work to the right agent launcher and spawn it. Name the
  task kind, then let do_spl_lane_mix pick the per-kind main and backup vendors
  (cnf env.box.agent_split_by_kind). Use when the user says
  "spawn an agent", "give this to an agent", or hands you work that belongs in
  another lane. A leading c-NNN / g-NNN / a-NNN / q-NNN / m-NNN id (or a legacy
  CLE-nn) sends the rest to that agent instead.
---

# /spawn-an-agent — pick the launcher, then spawn

> Generated from qto doc `47fef649-d866-4853-8e3f-93f8326a827c`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

You do not ask which launcher to use. You estimate, route, run the launcher's
spawn steps in this turn, and report which one you picked and why.

<a id="ws-doc-8fd7b748-d600-4ff1-8e64-2eb34b8abfba"></a>
## 1. Message mode

If the first word is an agent id (`c-NNN`, `g-NNN`, `a-NNN`, `q-NNN`, `m-NNN`, or a legacy `CLE-nn`), send
the rest to that agent (section 2 of its launcher command) and stop.

<a id="ws-doc-982ffadd-6615-4caa-82a8-4f378d7ace78"></a>
## 2. Pick the launcher

Name the task kind, estimate difficulty against your own maximum capacity
(0..100) when the work is coding, then let the box's vendor split pick the
launcher:

```bash
cd {{HARNESS_DIR}}/../../../.. && LANE_MIX_KIND=<specs_and_docs|tests|simple_coding|complex_coding|i18n|secret|orchestration> LANE_MIX_DIFFICULTY=<0..100> LANE_MIX_SENSITIVE=<0|1> LANE_MIX_TASK=<task_id> LANE_MIX_BRIEF=<brief file> ./run -a do_spl_lane_mix
```

`LANE_MIX_BRIEF` (or `LANE_MIX_PATHS=<path,...>`) lets the UI rule see the lane: UI work
(a brief or a path naming `csi-spl-wui/`) never goes to mistral, as main or backup, until
`do_spl_vendor_ui_retest` passes (owner 2026-10-16, t1 b61851fb).

Coding never goes to mistral, as main or backup (owner 2026-10-17, t1 b61851fb, msg 91bf8278: "Docs and reviews only, no coding"): every kind but `specs_and_docs` and `i18n`, whatever the row. `do_spl_spawn_enqueue` refuses a `SPAWN_PLACE=mistral:<slug>` of such a kind (`SPAWN_KIND`, else the brief's `Kind:`; a brief with none counts as coding), and the placer launches claude for one queued before. Grok is the backup of those rows only because a backup may not be the main; with grok off, claude takes the lane.

Its last line, `pick=<vendor> launcher=/<vendor>-spawn reason=...`, is the
launcher. The split is cnf `env.box.agent_split_by_kind` (all.env.yaml), which defines the per-kind main and backup vendors:

| the task | main    | backup  |
|----------|---------|---------|
| specs, docs, plans, spec reviews and code reviews: `LANE_MIX_KIND=specs_and_docs` | agy     | claude  |
| writing tests: `LANE_MIX_KIND=tests` | claude  | grok    |
| simple and routine coding: `LANE_MIX_KIND=simple_coding` | claude  | grok    |
| hard coding, architecture, hi-fi work: `LANE_MIX_KIND=complex_coding` | claude  | grok    |
| translation, or the language review of user-facing text in several languages: `LANE_MIX_KIND=i18n` | agy     | claude  |
| personal data or secrets: `LANE_MIX_KIND=secret` or `LANE_MIX_SENSITIVE=1` | claude  | grok    |
| dispatching and orchestrating: `LANE_MIX_KIND=orchestration` | claude  | grok    |

The backup vendor takes over after 2 failed tries of the main on the same task.

<!-- fleet-pin data-rule-vendors: claude grok mistral -->
**Data rule** (owner msgs 803c3b38, 26117740, 474f32a0): Work that carries personal data or secrets (credentials, keys, customer data) goes only to `/claude-spawn`, `/grok-spawn` or `/mistral-spawn`, never to qwen or agy, and a brief for those lanes never names a credential path. The `secret` row of the cnf may name claude, grok or mistral as its main or backup.

<!-- fleet-pin language-rule-final: agy -->
**Language rule**: agy has the final word on multilingual text. Any user-facing text in several languages (blog posts, WUI i18n locale files, help pages) gets an agy review as the LAST step before it ships. With no agy on the box, claude drafts and the text waits for an agy review; it never ships unreviewed.

Multilingual text that carries personal data (`LANE_MIX_KIND=i18n LANE_MIX_SENSITIVE=1`) is `secret`: claude, grok or mistral drafts it, and the pick carries `flag=needs_masked_agy_review`. The drafter runs `I18N_MASK_SRC=<text> I18N_MASK_TERMS=<term list> LANE_MIX_TASK=<task_id> ./run -a do_spl_i18n_mask` (csi-spl-orc; the term list names the people and workspaces, one `name|workspace|other <term>` per line) and the agy brief names only its `agy_review_dir=`, never the original or `map.tsv`; `do_spl_i18n_unmask` puts the reviewed text back.

A vendor whose CLI is not installed or not signed in on this box is skipped.
The backup vendor is tried next, and if it is also unavailable, the work falls to claude (the default and last fallback). An `i18n` task with no agy on the box falls to claude, but the text WAITS for an agy review before it ships.

<a id="ws-doc-54af7b9d-1f14-4959-9aba-4648d6a2ac97"></a>
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

<a id="ws-doc-d67ced65-8c52-46bf-881f-d5994fbb2526"></a>
## 4. Spawn

Follow the chosen launcher command's section 1, in this turn.
