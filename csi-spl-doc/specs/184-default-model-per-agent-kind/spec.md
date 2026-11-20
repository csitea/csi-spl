# Spec 184: Default Model per Agent Kind

Status: **Draft v0.1** (2026-11-20). Lane `c-358` (`claude`, the backup for
`specs_and_docs`: no agy CLI on this box, agy at quota on the other).
Epic: **SPL-2398**. Issue: **SPL-6036**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:815215f5-2d1b-47df-b465-b4ea0ee5d991` (`t1`).
Builds on: [115 vendor split by task kind](../115-vendor-split-by-task-kind/spec.md)
(the task kinds and the per-kind table), [127 workspace vendor keys](../127-workspace-vendor-keys/spec.md)
(the workspace settings pages), [142 binaries management](../142-binaries-management/spec.md)
(pinned CLI versions), [161 Cursor and Codex](../161-cursor-codex-vendors/spec.md)
(the codex launcher) and [110 Mistral vendor](../110-mistral-vendor/spec.md)
(vibe's `active_model`).

Line references were measured on `origin/master` `dd7a2795a`. CLI help was
read with `--help` only, on this box (no paid call, and no list command that
may reach a vendor). Nothing here is built.

## 0. The owner's words (HUM-10, t1 #spool-hub-biz, topic `815215f5`, msg `c91190e9`, verbatim)

> "add the option of starting the agents for each specific agent kind with a
> default model from the list of /models available from it"

What it asks: a setting that picks, per agent kind, the model a new agent
starts with, chosen from the models that kind's CLI offers. Today every
agent starts on its CLI's own default (section 3.1). What "agent kind" means
and where the setting lives are the owner's to decide (section 1).

## 1. Open questions (one form)

Each question has 2 to 4 options; the recommendation is first. Every part of
sections 4 to 7 that depends on an answer names it.

**Q1. What is an "agent kind" here?**

| key | option |
|---|---|
| `bo` | **(recommended)** Both: a default model per vendor (claude, agy, grok, mistral, qwen, codex), and an optional override per vendor per task kind of spec 115 (specs_and_docs, tests, simple_coding, ...). Most cells stay empty and fall back to the vendor's default. |
| `ven` | The vendor only: one default model per CLI. |
| `tk` | The task kind only: one model per task kind, whatever vendor the split picks (needs a model name every vendor accepts; no two vendors share one). |

**Q2. Where is it set?**

| key | option |
|---|---|
| `bo` | **(recommended)** Both: the cnf holds the fleet default; a workspace overrides it on the WUI Split page (Workspace settings -> Split), next to the split per kind. |
| `cnf` | cnf only (`csi-spl-cnf/csi-spl/all.env.yaml`), changed by a commit. |
| `wui` | The WUI page only, per workspace, stored in the hub. |

**Q3. Where does the list of models come from?**

| key | option |
|---|---|
| `cnf` | **(recommended)** A catalogue in cnf, one list per vendor, refreshed by a named action that reads what each CLI exposes without a paid call and records the CLI version it read. A setting outside the list is refused by the conf-validator. |
| `liv` | Read live from each CLI's `/models` (or equivalent) at every setting change. Measured: only grok has a list command (section 3.2); claude's `/model` is interactive only. |

**Q4. What happens to agents already running?**

| key | option |
|---|---|
| `rot` | **(recommended)** New starts, and also rotations and restarts (resume): a resumed seat starts with the setting in force at that moment. A running session is never interrupted. |
| `new` | Only new starts. A rotation or restart resumes on the model its seat was spawned with (recorded at spawn). |

**Q5. A configured model the CLI refuses at start (retired, not in the account's plan)?**

| key | option |
|---|---|
| `fb` | **(recommended)** Start again once without the model (the CLI's default), one WARN line in the spawn log and the lane journal. |
| `ref` | Refuse the spawn; the placer counts it as a failed try (spec 115 section 6) and the backup vendor takes the lane. |

## 2. Terms

- **vendor**: the CLI an agent runs: `claude`, `agy`, `grok`, `mistral`,
  `qwen`, `codex` (`SPAWN_KIND`, `spawn-core.inc.sh:32`).
- **task kind**: a spec 115 kind, read from the brief's `Kind:` line
  (`spawn-window.sh:598`).
- **model**: the id or alias the vendor's CLI accepts for its model setting.
- **empty**: no setting; the launcher adds nothing and the CLI uses its own
  default, exactly as today.

## 3. What exists today (measured)

Paths below are under `csi-spl-orc/src/bash/features/spawn-agents/` unless
they start with a top-level `csi-spl-*` directory.

### 3.1 The launchers pass no model

- Every interactive spawn goes through one function, `spawn_launch_session`
  (`scripts/spawn-core.inc.sh:812`). The launch line is
  `<bin> <name flag> <perm flags> <extra flags> <prompt>` (`:839`); the
  resume stub repeats the perm and extra flags (`:818`).
- The perm flags come from `spool_claude_perm_flags`
  (`lib/spool-env.inc.sh:703-711`), one case per vendor. Extra flags are set
  by two adapters only: mistral `--max-price N` (`scripts/spawn-mistral.sh:97`)
  and codex `-c analytics.enabled=false -c check_for_update_on_startup=false`
  (`scripts/spawn-codex.sh:60`).
- The restore path builds its own line the same way
  (`scripts/restore-core.inc.sh:140-142`); the chain launchers too
  (`scripts/spawn-chain-core.inc.sh:21-24`).
- No model flag anywhere:
  `git grep -nE -- '--model' origin/master -- 'csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-*.sh' 'csi-spl-orc/src/bash/features/spawn-agents/scripts/restore-*.sh' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`
  -> 0 lines (the 6 hits of `-m ` in those files are all `setfacl -m`).
- The adapters (`scripts/spawn-{claude,agy,grok,qwen,mistral,codex}.sh`)
  set only the `SPAWN_*` contract of `scripts/spawn-core.inc.sh:30-58`;
  none has a model variable.
- The task kind is known at spawn: `sw_category` reads the brief's `Kind:`
  and writes `<spool root>/<id>/lifetime/category.json`
  `{"work_kind", "category_path"}` (`scripts/spawn-window.sh:595-609`). The
  launcher itself is `spawn-$KIND.sh` (`scripts/spawn-window.sh:173`), which
  is not handed the task kind today.

### 3.2 Each CLI's model setting and list (this box)

| vendor | CLI on this box | model setting (`--help`) | list of models |
|---|---|---|---|
| claude | 2.1.323 | `--model <model>`: "an alias for the latest model (e.g. 'fable', 'opus', or 'sonnet') or a model's full name" | no list subcommand under `claude --help` "Commands:"; `/model` is interactive |
| grok | 1.0.89 | `-m, --model <MODEL>` "Model ID to use" | `grok models` "List available models and exit" (not run: it may call the vendor). The CLI's own cache `<agent home>/.grok/models_cache.json` (`fetched_at` 2026-11-20T11:30Z, `grok_version` 1.0.89) lists `grok-4.7`, `grok-4.7-build-fast`, `grok-4.6`, `grok-4.5` |
| mistral | vibe 2.26.0 | no model flag; `--agent NAME` picks a tool profile, not a model. "`VIBE_*` Override any config field (e.g. `VIBE_ACTIVE_MODEL=local`)" | the `[[models]]` entries (`name`, `alias`) of `<agent home>/.vibe/config.toml` |
| agy | absent | UNVERIFIED (row M0) | UNVERIFIED |
| qwen | absent | UNVERIFIED (row M0) | UNVERIFIED |
| codex | absent | UNVERIFIED; the adapter already passes `-c key=value` overrides (`scripts/spawn-codex.sh:60`); I believe, unchecked, that `-c model="<m>"` and `-m <m>` both work (row M0) | UNVERIFIED |

"Absent": neither in the agent user's `~/.local/bin` nor on `PATH` on this
box.

### 3.3 Where a model is pinned today

- **mistral only**: cnf `env.box.mistral_vibe.model: mistral-vibe-cli-latest`
  (`csi-spl-cnf/csi-spl/all.env.yaml:1480`). `do_install_mistral_vibe`
  hands it to `spool-install/install.sh`
  (`csi-spl-orc/src/bash/run/install-mistral-vibe.func.sh:35`), which writes
  `active_model` into `~/.vibe/config.toml` **only when it has none**
  (`csi-spl-orc/src/bash/features/spool-install/install.sh:339-340,470-478`).
  On this box the agent user's `config.toml` reads
  `active_model = "mistral-large"`: a hand-set value beats the cnf, so the
  cnf does not say what runs.
- **grok**: nothing; every seat runs the CLI default
  (`csi-spl-doc/doc/md/grok-token-burn/06-lighter-model.md` section 1:
  289 of 292 sessions on `grok-4.7`, measured 2026-10-20).
- **prices**: cnf `env.box.model_prices` (`all.env.yaml:1865`) prices the
  model names the collector reports (claude-opus-5-5, claude-sonnet-5-5,
  claude-haiku-4-5, mistral-large, gemini-3.8-flash, gemini-4-argon). A
  model chosen here with no row stays unpriced.

### 3.4 The per-kind split and the WUI

- cnf `env.box.agent_split_by_kind` (`all.env.yaml:1461-1468`), validated by
  `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_split.py`, rendered
  into `csi-spl-cnf/csi-spl/{dev,prd}.env.json`.
- Hub: `tenant_agent_split_kind`
  (`csi-spl-rdb/src/sql/postgres/spool-hub/0163_tenant_agent_split_kind.sql`,
  amended by 0178, 0262 and 0283) under RLS; store
  `csi-spl-api/src/go/spool-hub-api/internal/store/agent_split_kind.go`;
  `do_spl_agent_split_show --kind <k>` prints it.
- WUI: Workspace settings -> Split
  (`csi-spl-wui/src/pages/tenant-settings/split.vue`, component
  `csi-spl-wui/src/components/AgentSplitKinds.vue`) edits the split per
  kind; Agent keys (`agent-keys.vue`, spec 127 section 8); Agents
  (`agents.vue`) shows the seats and the caps read-only. No page shows or
  sets a model.

### 3.5 Where a running agent's model is visible

- The identity map records `"model": flag(argv, "--model")`
  (`scripts/agent-identity.py:542`, field list `:93`) into
  `<spool root>/agents/<ID>.json`. It reads only the long `--model`: grok's
  `-m` and vibe's `VIBE_ACTIVE_MODEL` would read as null.
- The dry-run plan line `adapter` (`scripts/spawn-core.inc.sh:699`) names
  the bin and the flags, no model.

## 4. The flow end to end

1. **Setting.** cnf `env.box.agent_model` (7.1.1) holds the vendor default
   and the per-kind cells (Q1). With Q2 `bo` or `wui` the hub holds a
   workspace override (7.1.5), shown and set on the WUI Split page (row W1).
2. **Resolve.** `spawn-window.sh` already knows the task kind (3.1); it
   exports it as `SPAWN_TASK_KIND`. `spawn_main` calls
   `spool_agent_model <vendor> <task kind>` (7.1.2): the caller's
   `SPAWN_MODEL` wins, then the workspace override (Q2), then the cnf cell,
   then the cnf vendor default, else empty.
3. **Words.** `spool_model_args <vendor> <model>` (7.1.3) returns what to
   add: a flag for claude and grok (codex after M0); an env assignment for
   mistral, added to `SPAWN_EXEC_PREFIX`. Empty model: nothing, and the
   launch line stays byte-identical to today.
4. **Launch.** `spawn-core.inc.sh:839` appends the flag after the perm and
   extra flags; the resume stub `:818` appends it too (Q4). The resolved
   model goes to `<spool root>/<id>/lifetime/model.txt` (7.1.4).
5. **Restore and rotation.** `restore-core.inc.sh:140` adds
   `spool_model_args`: under Q4 `rot` it re-resolves from the setting in
   force (task kind from `lifetime/category.json`); under Q4 `new` it reads
   `lifetime/model.txt`.
6. **Refused model.** The start check (`lib/start-check.inc.sh`,
   `spool_start_check` rc 5 = the pane's process ended first) sees the CLI
   quit. Q5 `fb`: relaunch once without the model and log
   `WARN model <m> refused by <vendor>`. Q5 `ref`: exit non-zero; the placer
   counts a failed try.
7. **Visible.** The plan line `adapter` gains `model=<m|cli-default>`; the
   identity record reads `--model`, `-m` and `VIBE_ACTIVE_MODEL` (row I1);
   the WUI Agents page may show the identity's model (row W1, optional).

## 5. Reused, and the gaps

Reused: the one launch function and its resume stub; the brief's `Kind:`
parse and `category.json`; the cnf + conf-validator + tpl-gen path of
`agent_split_by_kind`; the hub per-kind table pattern (RLS, store, show
action) and the Split page; the identity map's `model` field.

Gaps:

- **G1** No cnf key and no resolver for a model.
- **G2** The adapter is not handed the task kind.
- **G3** No list of models: claude has no list command; grok's list may
  call the vendor (its cache file does not); vibe's sits in a per-user
  config; agy, qwen and codex are unmeasured (M0).
- **G4** The mistral cnf model is not what runs (3.3): a hand-set
  `active_model` beats it. `VIBE_ACTIVE_MODEL` at launch sets it per seat.
- **G5** The identity map misses `-m` and env-set models.
- **G6** A model with no `model_prices` row is unpriced (spec 121): the
  validator warns; the price row is a separate lane.
- **G7** The list depends on the CLI version (spec 142, and the controlled
  update `do_spl_cli_update` of spec 102 9.1): the catalogue records the
  version it was read from, and a CLI update re-runs the refresh.

## 6. Build order (rows a later lane can take in parallel)

Every row works against the contracts of 7.1, so all rows except L2..L4 and
W1 can start at once. Each row lands with its test and its red control
(developer guide 2.12.1).

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| M0 | measure agy, qwen, codex: model setting and list command from `--help` on a box that has each CLI; fill 3.2 and 7.1.3 | this spec | none | the three rows of 3.2 cite a CLI version and a help line | n/a (doc) |
| C1 | cnf `env.box.agent_model` (7.1.1), shipped empty; conf-validator model; tpl-gen render | `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_model.py` (new) and its test, `csi-spl-cnf/csi-spl/{dev,prd}.env.json` | none | validator test: a model outside the vendor's catalogue is refused, a cell for an unknown task kind is refused, an UNVERIFIED vendor with a non-empty model is refused; `do_tpl_gen` then `git diff --exit-code` clean | a test copy with `claude: nosuchmodel` passes the validator -> the test fails |
| L1 | `spool_agent_model`, `spool_model_args` (7.1.2, 7.1.3) | `lib/spool-env.inc.sh`, `tests/test-spool-agent-model.sh` (new) | contract 7.1.1 (fixture cnf) | the resolution order of 7.1.2, case by case; empty in, nothing out; a model with a quote is refused | swap steps 3 and 4 -> a case fails |
| L2 | launch: `SPAWN_TASK_KIND` export, the words at `:839` and `:818`, the mistral env in `SPAWN_EXEC_PREFIX`, chain `_ch_flags`, plan line `model=`, `lifetime/model.txt` | `scripts/spawn-window.sh`, `scripts/spawn-core.inc.sh`, `scripts/spawn-mistral.sh`, `scripts/spawn-chain-core.inc.sh`; tests `tests/test-spawn-dry-run.sh`, `tests/test-spawn-window-dry-run.sh`, `tests/test-spawn-chain.sh` | L1 | with the empty cnf every existing dry-run launch line is byte-identical; with `default.claude: sonnet` the launch and the resume stub each carry `--model 'sonnet'` once | drop the words from `:818` -> the resume-stub case fails |
| L3 | restore adds the model (Q4 `rot` or `new`) | `scripts/restore-core.inc.sh`, `scripts/restore-mistral.sh`, `tests/test-agent-identity-restore*.sh` | L1; Q4 | a restore of a seat spawned with a model carries it (Q4 `new`) or the current setting (Q4 `rot`) | restore without the call -> the case fails |
| L4 | refused model (Q5) | `lib/start-check.inc.sh` caller in `scripts/spawn-window.sh`, its test | L2; Q5 | a stub CLI that exits on `--model x` is relaunched once without it and the WARN is logged (Q5 `fb`), or the spawn exits non-zero (`ref`) | a stub that does not exit -> no relaunch, and the test asserts none |
| A1 | `do_spl_agent_models_refresh`: reads each CLI's list with no paid call and no vendor call (grok's cache file, vibe's `[[models]]`, claude's `--model` help aliases plus the anthropic `model_prices` names, M0's answer for the rest), prints the catalogue diff; `DRY_RUN=1` by default; `DRY_RUN=0` rewrites `agent_model.catalogue` | `csi-spl-orc/src/bash/run/spl-agent-models-refresh.func.sh` (new), `csi-spl-orc/src/bash/tests/spl-agent-models-refresh.tst.sh` (new) | contract 7.1.1; Q3 `cnf` | fixture homes give the expected catalogue and CLI versions | a model added to the fixture cache file is missing from the output -> the test fails |
| I1 | the identity map reads `-m` and `VIBE_ACTIVE_MODEL` | `scripts/agent-identity.py`, `tests/test-agent-identity.sh` | none | `grok -m grok-4.6` and a vibe pid with the env both record their model | revert the `-m` read -> the grok case fails |
| H1 | hub: `tenant_agent_model` (7.1.5), store, the tenant settings field, `do_spl_agent_model_show` | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_tenant_agent_model.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/agent_model.go`, the hub handler and its test, `csi-spl-orc/src/bash/run/spl-agent-model-show.func.sh` | Q2 `bo` or `wui`; contract 7.1.5 | on PostgreSQL (`PRE_PUSH_TIER=full`): a workspace reads only its rows (RLS); an unknown vendor or kind is refused | drop the RLS policy in a test copy -> the cross-workspace read case fails |
| W1 | WUI: a model column on the Split page per vendor and kind, the catalogue as the choices, empty = "CLI default"; optionally the model in Agents | `csi-spl-wui/src/components/AgentSplitKinds.vue` (or a new `AgentModels.vue`), `csi-spl-wui/src/utils/tenant-settings.mjs`, a unit test, every locale (agy review last) | H1; Q2 `bo` or `wui` | unit test, and e2e on the generated bundle | saving a value outside the catalogue -> the test fails |
| D1 | docs: how to set and refresh (operations guide), pointers from specs 115 and 110, this spec's status | `csi-spl-doc/` | the rows it documents | `do_check_fleet_rules_drift` green | n/a (doc) |

## 7. Contracts

### 7.1 Binding contracts for parallel rows

#### 7.1.1 cnf keys (row C1; Q1, Q3)

```yaml
env:
  box:
    agent_model:
      # vendor -> model; "" = the CLI's own default (nothing added). Q1 ven/bo.
      default: { claude: "", agy: "", grok: "", mistral: "", qwen: "", codex: "" }
      # task kind -> vendor -> model; a cell beats default. Q1 bo/tk.
      # Keys are the agent_split_by_kind kinds; absent = no override.
      by_kind: {}
      # Q3 cnf: vendor -> {cli: <version read>, read_at: <ISO-8601 UTC>, models: [ids/aliases]}
      catalogue: {}
```

Every non-empty model must be in `catalogue.<vendor>.models` (validator,
row C1). A vendor whose row in 7.1.3 is UNVERIFIED may hold only `""`. The
block ships empty: no seat changes until someone sets a value. Under Q3
`liv` the `catalogue` key is not added and the validator checks the model
syntax only.

#### 7.1.2 Resolver (row L1)

`spool_agent_model VENDOR [TASK_KIND]` prints one model or nothing, exit 0;
exit 2 for an unknown vendor. First non-empty wins:

1. env `SPAWN_MODEL` (a caller's own pick; the placer never sets it);
2. the workspace override for (vendor, kind), then (vendor, `*`), from
   `SPAWN_MODEL_MAP` (the line of `do_spl_agent_model_show`, H1; only Q2
   `bo` or `wui`);
3. cnf `by_kind.<kind>.<vendor>` (Q1 `bo` or `tk`);
4. cnf `default.<vendor>` (Q1 `bo` or `ven`);
5. empty.

A model must match `^[A-Za-z0-9._:/-]{1,80}$`; anything else is refused
(exit 3) before it reaches a command line.

Env: `SPAWN_TASK_KIND` (the brief's `Kind:`, lower case, exported by
`spawn-window.sh`), `SPAWN_MODEL`, `SPAWN_MODEL_MAP`.

#### 7.1.3 Words per vendor (row L1; M0 fills the UNVERIFIED rows)

`spool_model_args VENDOR MODEL` prints the words to add; nothing for an
empty model:

| vendor | words | where | status |
|---|---|---|---|
| claude | `--model '<m>'` | after the perm flags | measured (2.1.323 `--help`) |
| grok | `--model '<m>'` (the long form, so the identity map reads it) | after the perm flags | measured (1.0.89 `--help`) |
| mistral | `VIBE_ACTIVE_MODEL='<m>'` | appended to `SPAWN_EXEC_PREFIX` (the `env ...` prefix, `scripts/spawn-mistral.sh:63`) | measured (vibe 2.26.0 `--help`: `VIBE_*` overrides any config field); `<m>` must be a `[[models]]` name or alias |
| codex | `-c model='"<m>"'` | in `SPAWN_EXTRA_FLAGS` | UNVERIFIED (M0) |
| agy | none until M0 | n/a | UNVERIFIED (M0) |
| qwen | none until M0 | n/a | UNVERIFIED (M0) |

#### 7.1.4 Lifetime record (row L2)

`<spool root>/<id>/lifetime/model.txt`: one line, the resolved model or
`cli-default`. Written at spawn; read by the restore under Q4 `new`.

#### 7.1.5 Hub table and show line (row H1; only with Q2 `bo` or `wui`)

`tenant_agent_model(tenant_id, vendor, kind, model, updated_by, updated_at)`,
primary key `(tenant_id, vendor, kind)`; `kind` is one of the split kinds or
`*` (the vendor default); `vendor` is the split table's CHECK list; RLS as
in 0163. `do_spl_agent_model_show` (`ENV`, `TENANT_ID`) prints one line,
`SPAWN_MODEL_MAP=<vendor>:<kind>=<model>,...`, the form the resolver reads.

## 8. Not in this spec

A price row for a new model (spec 121, a separate lane); reasoning effort
(grok-token-burn 6/6 measured that it acts on under 1% of grok's tokens);
switching the model of a running session; any paid model call.
