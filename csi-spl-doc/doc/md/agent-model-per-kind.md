# The default model per agent kind: how to set it and refresh it

Spec 184 ([spec](../../specs/184-default-model-per-agent-kind/spec.md)),
issue SPL-6036, epic SPL-2398. The owner's words (HUM-10, t1 topic
`815215f5`, msg `c91190e9`): "add the option of starting the agents for each
specific agent kind with a default model from the list of /models available
from it". The owner's answers (poll `ccb3a406`, msg `0d33aa83`): a model per
vendor plus an optional one per vendor and task kind (Q1), in the cnf plus a
per-workspace override on the WUI (Q2), the list read live from each CLI
(Q3), new starts, rotations and restarts all take the setting in force (Q4),
a refused model starts once more on the CLI's own default with a WARN (Q5).

Measured on `origin/master` `e6e9b2fd8` (2026-11-28). Paths that start with
`lib/`, `scripts/` or `tests/` are under
`csi-spl-orc/src/bash/features/spawn-agents/`.

## 1. Where a model is set

Nothing is set today: the cnf block ships empty, and an empty setting adds
nothing to a launch line, so every agent starts on its CLI's own default
exactly as before spec 184.

### 1.1 The order a launcher reads

`spool_agent_model VENDOR [TASK_KIND]` (`lib/spool-env.inc.sh`) prints one
model or nothing. The first non-empty wins:

1. env `SPAWN_MODEL`, a caller's own pick (the placer never sets it);
2. env `SPAWN_MODEL_MAP`, the workspace override: the line
   `do_spl_agent_model_show` prints, `(vendor, kind)` first, then
   `(vendor, *)`;
3. cnf `env.box.agent_model.by_kind.<kind>.<vendor>`;
4. cnf `env.box.agent_model.default.<vendor>`;
5. nothing: the CLI's own default.

A model must match `^[A-Za-z0-9._:/-]{1,80}$`; anything else is refused
before it reaches a command line. The task kind is the brief's `Kind:` line
(lower case), which `spawn-window.sh` exports as `SPAWN_TASK_KIND` and
records in `<spool root>/<id>/lifetime/category.json`.

### 1.2 The fleet default: the cnf

`csi-spl-cnf/csi-spl/all.env.yaml`, next to `agent_split_by_kind`:

```yaml
env:
  box:
    agent_model:
      default: { claude: "", agy: "", grok: "", mistral: "", qwen: "", codex: "" }
      by_kind: {}
```

To set one, edit the block, for example `default.claude: sonnet` and
`by_kind: { complex_coding: { claude: opus } }`, then re-render and land it
like any cnf change:

1. `cd csi-spl-iac && ENV=dev ./run -a do_tpl_gen`, the same with
   `ENV=prd`; then `git diff` on the rendered
   `csi-spl-cnf/csi-spl/{dev,prd}.env.json` shows only your change.
2. The conf-validator
   (`csi-spl-cnf/src/python/conf-validator/EnvModels/agent_model.py`) refuses
   a model outside the syntax, an unknown vendor or task kind, and any
   non-empty model for agy, qwen or codex (its `UNVERIFIED_VENDORS`).
3. A launcher reads the `all.env.yaml` of the checkout it runs from
   (`SPOOL_AGENT_MODEL_CNF` overrides it), so a landed change takes effect on
   a box once that checkout is on the new master. It needs `yq`: without it
   the cnf is not read, with one WARN, and the agent starts on its CLI
   default.

Which vendors a model reaches: `spool_model_args` (`lib/spool-env.inc.sh`)
adds `--model '<m>'` for claude and grok, and `VIBE_ACTIVE_MODEL='<m>'` in
the `env` prefix for mistral (it beats the `active_model` of the agent's
`~/.vibe/config.toml`, which the install pins from cnf
`env.box.mistral_vibe.model`). For agy, qwen and codex it adds nothing yet,
even when the workspace override names a model. agy's own Gemini-quota
fallback (spec 184 section 10) passes its `--model` separately.

### 1.3 The workspace override: the WUI

Workspace settings -> Vendor split, the card under the split per kind
(`csi-spl-wui/src/components/AgentModels.vue`, for a member with
`tenant.settings`): one row per kind, **Every kind** (`*`) first, one text
cell per vendor. Each cell offers its vendor's newest box reading (section
2.1) and takes a typed model too; a cell outside the syntax is marked and
Save stays off. An emptied cell is dropped and then reads as the cnf. Save
sends `PATCH /v1/tenant/settings {"agent_models": {...}}`; the hub keeps it
in `tenant_agent_model` (rdb `0309_tenant_agent_model.sql`, under RLS).

Read it back as the resolver's line:

`cd csi-spl-orc && ENV=prd TENANT_ID=t1 ./run -a do_spl_agent_model_show`

It prints `SPAWN_MODEL_MAP=claude:*=sonnet,claude:complex_coding=opus`, or
`SPAWN_MODEL_MAP=` when nothing is set.

**Not wired yet:** no launcher or placer reads the hub's rows by itself.
`git grep -n 'SPAWN_MODEL_MAP=' origin/master -- ':!*/tests/*'` names only
the show action, the resolver and docs. A WUI setting reaches a launch only
when the caller exports that line before `spawn-window.sh`. Until a row
wires it, the cnf is the setting that acts.

## 2. Where the list of models comes from, and how to refresh it

There is no catalogue to refresh: the list is read live from each CLI at the
moment it is needed (Q3). `spool_agent_models VENDOR`
(`lib/agent-models.inc.sh`) prints it, the CLI version on stderr as
`cli=<version>`; it makes no paid call and writes nothing.

| vendor | source | exit |
|---|---|---|
| claude | the aliases its `--help` names for `--model` (`fable`, `opus`, `sonnet` on 2.1.323); a full model name is not listable and passes on syntax alone | 0 |
| grok | the CLI's own cache `<agent home>/.grok/models_cache.json` (`grok models` is not run: whether it is a free call is unverified) | 0 |
| mistral | the `[[models]]` `name` and `alias` of `<agent home>/.vibe/config.toml` | 0 |
| agy, qwen, codex | no source | 4 |

Print what this box offers, by hand:

`cd csi-spl-orc && ./run -a do_spl_agent_models_list`

`AGENT_MODELS_VENDOR=grok` limits it to one vendor. A CLI update (spec 142,
spec 102 9.1) changes the list at its next read; for grok the list moves
when grok itself refreshes its cache.

### 2.1 The readings the WUI offers

A box reports a reading to the hub with the `spool` verb
`spool agent-models report --vendor <v> --cli-version <x>` (models on
stdin), on its own upload token; the library wrapper is
`spool_agent_models_report` (`lib/agent-models.inc.sh`). It is off unless
`SPOOL_HUB_URL`, `SPOOL_BOX_ID` and `SPOOL_TENANT` are set (exit 3). The hub
keeps the newest reading per box and vendor (`agent_model_reading`); an
older one answers `stored false`. The WUI reads them with
`GET /v1/tenant/agent-model-readings`. A reading is a display, never a gate.

**Not wired yet:** nothing calls `spool_agent_models_report` on its own
(`git grep -n spool_agent_models_report origin/master -- ':!*/tests/*'
':!csi-spl-doc'` names its definition and comment only), so no box sends
readings and each WUI cell says no box has read its vendor yet. A typed
model still saves.

## 3. What happens at a start

- **New start** (`scripts/spawn-core.inc.sh`): the resolved model's words
  follow the perm and extra flags, the resume stub repeats them, and the
  dry-run plan line `adapter` ends `model=<m|cli-default>`. The chain
  launchers (`scripts/spawn-chain-core.inc.sh`) do the same.
- **Live check** (`scripts/spawn-window.sh`, before the window opens): a
  model the vendor's live list does not hold starts without it. A vendor
  with no list (exit 4) skips the check and lets the CLI decide.
- **Refused at start** (row L4): when the CLI quits at start, the pane is
  respawned once with no setting in force, on the CLI default. A second quit
  is an ordinary failed start. The relaunch covers claude and codex, the
  kinds the start check reads.
- **Restore, rotation, restart** (rows L3 and L5;
  `scripts/restore-core.inc.sh`, `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh`,
  `csi-spl-orc/src/bash/run/spl-lane-restart.func.sh`): each re-resolves the
  model from the setting in force at that moment, with the task kind from
  `lifetime/category.json`, and runs the live check. A running session is
  never interrupted; a changed setting is taken at its next rotation or
  restart.
- **Lane handover, mode B**
  (`csi-spl-orc/src/bash/run/spl-lane-handover.func.sh`, op `spawn`, line
  258: `spawn-window.sh claude <id> <repo> <brief> handover`): a new id, so
  no recorded `category.json` is read. The task kind comes ONLY from the
  first `Kind:` line of the handover brief, which embeds the old lane's
  `lifetime/brief.md` verbatim. When that file is missing on the old box the
  brief has no `Kind:`, and the new seat takes no `by_kind` model, only the
  vendor default.

## 4. What records it

- `<spool root>/<id>/lifetime/model.txt`: the model the CLI started with,
  or `cli-default`. Written at every start, restore included. A record,
  never an input: a restore re-resolves.
- `<spool root>/<id>/lifetime/journal.log` and the spawn log (stderr): one
  `WARN model <m> refused by <vendor>, started on the CLI default (<why>)`
  line per fallback, `<why>` = `not in its live list` or
  `the CLI quit at start`.
- `<spool root>/agents/<id>.json`: the identity map's `model`, read from
  `--model`, grok's `-m` and mistral's `VIBE_ACTIVE_MODEL`.
- A model with no cnf `env.box.model_prices` row stays unpriced (spec 121).

## 5. Tests

`tests/test-spool-agent-model.sh` (the order and the words),
`tests/test-spawn-window-model-fallback.sh` (live check and fallback),
`tests/test-agent-identity-restore-model.sh` (restore),
`csi-spl-orc/src/bash/tests/model-launch.inc.sh` with
`{lane-rotate,peer-restart,lane-restart}.tst.sh` (rotation and restarts),
`csi-spl-orc/src/bash/tests/spl-agent-models-list.tst.sh`,
`csi-spl-orc/src/bash/tests/spl-agent-model-show.tst.sh`,
`csi-spl-cnf/src/python/conf-validator/tests/test_agent_model.py`,
`csi-spl-wui/tests/unit/agent-models.test.mjs` and
`csi-spl-wui/tests/e2e/agent-models.test.mjs`.
