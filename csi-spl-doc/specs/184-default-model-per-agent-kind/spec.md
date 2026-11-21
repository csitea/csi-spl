# Spec 184: Default Model per Agent Kind

Status: **Draft v0.4** (2026-11-21). Lane `c-358` (`claude`, the backup for
`specs_and_docs`: no agy CLI on this box, agy at quota on the other).
v0.1 `3c8f2f7fd`; v0.2 folds the owner's answers to the form (poll
`ccb3a406`, HUM-10 msg `0d33aa83`): Q1 `bo`, Q2 `bo`, Q3 `liv`, Q4 `rot`,
Q5 `fb`; v0.3 folds the R7 review notes N1 and N2 (a-069, agy PASS on
`9ff267a3b`); v0.4 fills the agy, qwen and codex rows of 3.2 and 7.1.3
(row M0, lane `c-888`). Every change is in section 9.
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
agent starts on its CLI's own default (section 3.1).

## 1. Decided (owner HUM-10, t1 `815215f5`, msg `0d33aa83`, poll `ccb3a406`)

The owner's answers, verbatim:

> Answer 1: A — Both: a model per vendor, plus an optional override per task kind (specs, tests, coding...)
> Answer 2: A — In the config, plus a per-workspace override on the WUI Split page
> Answer 3: B — Read live from each CLI (only grok has a list command today)
> Answer 4: A — New starts, rotations and restarts all take the new model
> Answer 5: A — Restart once on the CLI's own default and log a warning

| Q | answer | what it decides here |
|---|---|---|
| Q1 | **`bo`**: a model per vendor, plus an optional override per vendor per task kind | 7.1.1 `default` and `by_kind`; 7.1.2 steps 3 and 4 |
| Q2 | **`bo`**: cnf default, plus a per-workspace override on the WUI Split page | rows H1 and W1 are in; 7.1.2 step 2; 7.1.5 |
| Q3 | **`liv`**: the list is read live from each CLI | no catalogue in cnf; row A1 is the live read (7.1.6); the launcher checks the model against it (4 step 3); the validator checks syntax only (C1) |
| Q4 | **`rot`**: new starts, rotations and restarts take the setting in force | row L3 re-resolves at every restore; `lifetime/model.txt` is a record, not an input (7.1.4) |
| Q5 | **`fb`**: restart once on the CLI's default, log a WARN | row L4; 4 step 6 |

One point the answers leave open, decided here and open to the review:
**N1**. The hub cannot run a CLI, yet the WUI picker (row W1) needs a list.
The box reads the list live (7.1.6) and reports each reading to the hub,
which keeps only the latest per box and vendor, with its time and the CLI
version. The WUI offers that reading as choices and also takes a typed
model (syntax-checked). The reading is a display, never a gate: the gate is
the live read at spawn (4 step 3).

### 1.1 The form as asked (v0.1, kept as the record)

Each question had 2 to 4 options; the recommendation was first.

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
| agy | 1.5.14 (second box) | `--model` "Model for the current CLI session" (no short form; the help is Go `flag` style, `Usage of agy:`). The help does not give the value form: the agent user's `~/.gemini/antigravity-cli/settings.json` holds `"model": "Gemini 3.8 Flash (High)"`, a display name with spaces and parentheses | `agy models` "List available models" (`agy help models`: flags `-h`, `--help` only). Not run: the help does not say whether it reads a local file or asks the vendor. No model cache file under `~/.gemini/antigravity-cli/` (`settings.json` holds the current model only) |
| qwen | 0.25.1 (second box) | `-m, --model` "Model  [string]"; also `--fallback-model` "Fallback model(s) for capacity errors (429/503/529), repeatable or comma-separated (max 3)" | no list subcommand under `qwen --help` "Commands:". The CLI keeps `~/.qwen/model-registry.json` (`source` `https://models.dev/api.json`, `fetchedAt` 2026-10-13T21:37Z, 301 entries): a public catalogue of every provider, not the models this account may use, so not a list for the live check |
| codex | codex-cli 0.166.0 (second box) | `-m, --model <MODEL>` "Model the agent should use"; and `-c, --config <key=value>`, whose help gives the example `` -c model="o3" `` (the value is parsed as TOML) | `codex debug models` "Render the raw model catalog as JSON"; its flag `--bundled` "Skip refresh and dump only the bundled catalog shipped with this binary" (not run; the help reads that without `--bundled` it refreshes from the vendor). The CLI's own cache `~/.codex/models_cache.json` (`fetched_at` 2026-11-14T11:46Z, `client_version` 0.166.0) lists `gpt-reserve`, `gpt-6-luna`, `gpt-5.6-terra`, `gpt-5.6-luna`, `codex-auto-review` |

The agy, qwen and codex rows were read on a second box, where all three
are in the agent user's `~/.local/bin` (`--version` and `--help` only, with
stdin from `/dev/null`; no model call, no list command run). On the same
box grok is 1.0.92: `grok help models` shows only `--debug`,
`--debug-file`, `-h` and `--leader-socket` ("Use a custom leader socket path
instead of the default `~/.grok/leader.sock`"), so the list goes through
the local grok leader process, and its help does not say whether that asks
the vendor. Whether `grok models` is a free list call stays UNVERIFIED; its
cache there (`fetched_at` 2026-11-21T13:30Z, `grok_version` 1.0.92) lists
the same four models as above.

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
   and the per-kind cells (Q1 `bo`). The hub holds a workspace override
   (7.1.5), shown and set on the WUI Split page (row W1, Q2 `bo`).
2. **Resolve.** `spawn-window.sh` already knows the task kind (3.1); it
   exports it as `SPAWN_TASK_KIND`. `spawn_main` calls
   `spool_agent_model <vendor> <task kind>` (7.1.2): the caller's
   `SPAWN_MODEL` wins, then the workspace override, then the cnf cell,
   then the cnf vendor default, else empty.
3. **Live check (Q3 `liv`).** For a non-empty model the launcher runs
   `spool_agent_models <vendor>` (7.1.6), the CLI's list read at that
   moment. A model the list does not hold is treated as refused (step 6)
   before the start, with the same WARN. A vendor whose list cannot be
   read (exit 4: no list source, or the read failed) skips the check and
   lets the CLI itself decide (step 6). Each reading is reported to the hub
   for the WUI picker (N1).
4. **Words and launch.** `spool_model_args <vendor> <model>` (7.1.3)
   returns what to add: a flag for claude and grok (codex after M0); an env
   assignment for mistral, added to `SPAWN_EXEC_PREFIX`. Empty model:
   nothing, and the launch line stays byte-identical to today.
   `spawn-core.inc.sh:839` appends it after the perm and extra flags. The
   resolved model is recorded in `<spool root>/<id>/lifetime/model.txt`
   (7.1.4).
5. **Restore and rotation (Q4 `rot`).** The resume stub (`:818`) and
   `restore-core.inc.sh:140` re-resolve with `spool_agent_model` from the
   setting in force (task kind from `lifetime/category.json`), run the live
   check of step 3, and add `spool_model_args`. A changed setting is so
   taken at the next rotation or restart; a running session is never
   interrupted.
6. **Refused model (Q5 `fb`).** The start check (`lib/start-check.inc.sh`,
   `spool_start_check` rc 5 = the pane's process ended first) sees the CLI
   quit. The launcher relaunches once without the model (the CLI's own
   default) and logs `WARN model <m> refused by <vendor>, started on the
   CLI default` in the spawn log and the lane journal; `lifetime/model.txt`
   then reads `cli-default`. A second failure is an ordinary failed start.
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
  update `do_spl_cli_update` of spec 102 9.1). With the live read (Q3) a
  CLI update changes the list at the next read; each reading reported to
  the hub carries the CLI version it came from.
- **G8** claude has no list command (3.2): its live list is the aliases its
  installed `--help` names (`fable`, `opus`, `sonnet` on 2.1.323). A full
  model name is not listable, so the live check passes any syntax-valid
  full claude name and leaves it to the CLI (step 6).

## 6. Build order (rows a later lane can take in parallel)

Every row works against the contracts of 7.1, so all rows except L2..L4 and
W1 can start at once (L1, A1, C1, H1, I1, M0 in parallel). Each row lands with its test and its red control
(developer guide 2.12.1).

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| M0 | measure agy, qwen, codex: model setting and list command from `--help` on a box that has each CLI; fill 3.2 and 7.1.3 | this spec | none | the three rows of 3.2 cite a CLI version and a help line | n/a (doc) |
| C1 | cnf `env.box.agent_model` (7.1.1), shipped empty; conf-validator model; tpl-gen render | `csi-spl-cnf/csi-spl/all.env.yaml`, `csi-spl-cnf/src/python/conf-validator/EnvModels/agent_model.py` (new) and its test, `csi-spl-cnf/csi-spl/{dev,prd}.env.json` | none | validator test: a model failing the syntax of 7.1.2 is refused, a cell for an unknown task kind or vendor is refused, an UNVERIFIED vendor with a non-empty model is refused; `do_tpl_gen` then `git diff --exit-code` clean | a test copy with `claude: "a b"` passes the validator -> the test fails |
| L1 | `spool_agent_model`, `spool_model_args` (7.1.2, 7.1.3) | `lib/spool-env.inc.sh`, `tests/test-spool-agent-model.sh` (new) | contract 7.1.1 (fixture cnf) | the resolution order of 7.1.2, case by case; empty in, nothing out; a model with a quote is refused | swap steps 3 and 4 -> a case fails |
| L2 | launch: `SPAWN_TASK_KIND` export, the words at `:839` and `:818`, the mistral env in `SPAWN_EXEC_PREFIX`, chain `_ch_flags`, plan line `model=`, `lifetime/model.txt` | `scripts/spawn-window.sh`, `scripts/spawn-core.inc.sh`, `scripts/spawn-mistral.sh`, `scripts/spawn-chain-core.inc.sh`; tests `tests/test-spawn-dry-run.sh`, `tests/test-spawn-window-dry-run.sh`, `tests/test-spawn-chain.sh` | L1 | with the empty cnf every existing dry-run launch line is byte-identical; with `default.claude: sonnet` the launch and the resume stub each carry `--model 'sonnet'` once | drop the words from `:818` -> the resume-stub case fails |
| L3 | restore and rotation re-resolve the model from the setting in force, with the live check (Q4 `rot`) | `scripts/restore-core.inc.sh`, `scripts/restore-mistral.sh`, `tests/test-agent-identity-restore*.sh` | L1, A1 | a seat spawned with `sonnet`, the cnf then set to `opus`: its restore line carries `--model 'opus'`; with the setting emptied it carries none | a restore that reads `lifetime/model.txt` instead -> the case fails |
| L4 | refused model (Q5 `fb`): relaunch once on the CLI default, WARN in the spawn log and the lane journal, `model.txt` = `cli-default` | `lib/start-check.inc.sh` caller in `scripts/spawn-window.sh`, its test | L2 | a stub CLI that exits on `--model x` is relaunched once without it, the WARN is logged once, a second exit is a failed start (no third launch); a model missing from the live list starts without it at once, same WARN | a stub that does not exit -> no relaunch and no WARN, and the test asserts both |
| A1 | `spool_agent_models VENDOR` (7.1.6), the live read: grok `grok models` (M0 first confirms it makes no paid call; until then the CLI's own cache file), vibe's `[[models]]` names and aliases, claude's `--model` help aliases (G8), M0's answer for agy, qwen, codex; a reading is reported to the hub (`PUT /v1/boxes/{box}/agent-models/{vendor}`, 7.1.5); `do_spl_agent_models_list` prints it by hand | `lib/agent-models.inc.sh` (new; L1 owns `lib/spool-env.inc.sh`, so A1 never edits it), `csi-spl-orc/src/bash/run/spl-agent-models-list.func.sh` (new), `csi-spl-orc/src/bash/tests/spl-agent-models-list.tst.sh` (new) | contract 7.1.6 | stub CLIs and fixture homes give the expected list per vendor; a vendor with no source exits 4; the read never writes the cnf | a model added to the stub's output is missing from the list -> the test fails |
| I1 | the identity map reads `-m` and `VIBE_ACTIVE_MODEL` | `scripts/agent-identity.py`, `tests/test-agent-identity.sh` | none | `grok -m grok-4.6` and a vibe pid with the env both record their model | revert the `-m` read -> the grok case fails |
| H1 | hub: `tenant_agent_model` and `agent_model_reading` (7.1.5), store, the tenant settings field, the reading routes `PUT /v1/boxes/{box}/agent-models/{vendor}` and `GET /v1/tenant/agent-model-readings`, `do_spl_agent_model_show` | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_tenant_agent_model.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/agent_model.go`, the hub handlers and their tests, `csi-spl-orc/src/bash/run/spl-agent-model-show.func.sh` | contract 7.1.5 | on PostgreSQL (`PRE_PUSH_TIER=full`): a workspace reads only its rows (RLS); an unknown vendor or kind, or a model failing the syntax, is refused; a newer reading replaces the older | drop the RLS policy in a test copy -> the cross-workspace read case fails |
| W1 | WUI: a model column on the Split page per vendor and kind; choices = the latest box reading (N1) with its time and CLI version, plus a typed model (syntax-checked); empty = "CLI default"; optionally the model in Agents | `csi-spl-wui/src/components/AgentSplitKinds.vue` (or a new `AgentModels.vue`), `csi-spl-wui/src/utils/tenant-settings.mjs`, a unit test, every locale (agy review last) | H1 | unit test, and e2e on the generated bundle | saving a model with a space -> the test fails |
| D1 | docs: how to set and refresh (operations guide), pointers from specs 115 and 110, this spec's status | `csi-spl-doc/` | the rows it documents | `do_check_fleet_rules_drift` green | n/a (doc) |

## 7. Contracts

### 7.1 Binding contracts for parallel rows

#### 7.1.1 cnf keys (row C1; Q1 `bo`)

```yaml
env:
  box:
    agent_model:
      # vendor -> model; "" = the CLI's own default (nothing added).
      default: { claude: "", agy: "", grok: "", mistral: "", qwen: "", codex: "" }
      # task kind -> vendor -> model; a cell beats default.
      # Keys are the agent_split_by_kind kinds; absent = no override.
      by_kind: {}
```

No catalogue (Q3 `liv`): the validator checks the syntax of 7.1.2, the
kind and vendor names, and that a vendor whose row in 7.1.3 is UNVERIFIED
holds only `""`. Whether the CLI offers the model is checked live at spawn
(7.1.6). The block ships empty: no seat changes until someone sets a value.

#### 7.1.2 Resolver (row L1)

`spool_agent_model VENDOR [TASK_KIND]` prints one model or nothing, exit 0;
exit 2 for an unknown vendor. First non-empty wins:

1. env `SPAWN_MODEL` (a caller's own pick; the placer never sets it);
2. the workspace override for (vendor, kind), then (vendor, `*`), from
   `SPAWN_MODEL_MAP` (the line of `do_spl_agent_model_show`, H1; Q2 `bo`);
3. cnf `by_kind.<kind>.<vendor>` (Q1 `bo`);
4. cnf `default.<vendor>` (Q1 `bo`);
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
| codex | `--model '<m>'` (the long form of `-m`, so the identity map reads it) | after the perm and extra flags | measured (codex-cli 0.166.0 `--help`: `-m, --model <MODEL>`); `-c model="<m>"`, the help's own example, needs TOML quoting, so `--model` is used |
| agy | `--model '<m>'` | after the perm flags | flag measured (1.5.14 `--help`); the value form is open: agy's own settings store a display name (`Gemini 3.8 Flash (High)`), which the syntax of 7.1.2 refuses. Until that is decided, agy stays `""` (UNVERIFIED for the validator, 7.1.1) |
| qwen | `--model '<m>'` (the long form of `-m`) | after the perm flags | measured (0.25.1 `--help`: `-m, --model`) |

#### 7.1.4 Lifetime record (row L2)

`<spool root>/<id>/lifetime/model.txt`: one line, the model the CLI was
started with, or `cli-default` (none set, or Q5 fallback). Written at every
start, restore included. A record for the identity and the logs; never an
input: a restore re-resolves (Q4 `rot`).

#### 7.1.5 Hub tables, routes and show line (row H1; Q2 `bo`)

- `tenant_agent_model(tenant_id, vendor, kind, model, updated_by, updated_at)`,
  primary key `(tenant_id, vendor, kind)`; `kind` is one of the split
  kinds or `*` (the vendor default); `vendor` is the split table's CHECK
  list; RLS as in 0163. Set through the tenant settings PATCH (field
  `agent_models`), read through its GET.
- `agent_model_reading(tenant_id, box, vendor, cli_version, models, read_at)`,
  primary key `(tenant_id, box, vendor)`, `models` a text array; RLS as in
  0163. A box reports each live reading (7.1.6) with
  `PUT /v1/boxes/{box}/agent-models/{vendor}`, body
  `{"cli_version", "models": [...], "read_at"}`, under the box's own
  tenant; a newer `read_at` replaces the row, an older one is ignored
  (answer 200 either way). The WUI reads them with
  `GET /v1/tenant/agent-model-readings` -> `{"readings": [{"box",
  "vendor", "cli_version", "models", "read_at"}]}`. Display only (N1).
- `do_spl_agent_model_show` (`ENV`, `TENANT_ID`) prints one line,
  `SPAWN_MODEL_MAP=<vendor>:<kind>=<model>,...`, the form the resolver reads.

#### 7.1.6 Live list (row A1; Q3 `liv`)

`spool_agent_models VENDOR` prints the models the installed CLI offers,
one per line, read at call time; exit 0 with a list, exit 4 when the vendor
has no list source or the read failed (the caller then skips the check),
exit 2 for an unknown vendor. Never a paid call; never writes the cnf.
Sources: grok `grok models` (M0 confirms it is a free list call; until then
the CLI's own `<agent home>/.grok/models_cache.json`), mistral the
`[[models]]` `name` and `alias` of `<agent home>/.vibe/config.toml`, claude
the aliases its `--help` names for `--model` (a full claude name passes on
syntax alone, G8), agy, qwen and codex per M0. It also prints the CLI
version on stderr as `cli=<version>`, which the hub report carries.

## 8. Not in this spec

A price row for a new model (spec 121, a separate lane); reasoning effort
(grok-token-burn 6/6 measured that it acts on under 1% of grok's tokens);
switching the model of a running session; any paid model call.

## 9. Changes from v0.1

Folds the owner's answers (HUM-10, t1 `815215f5`, msg `0d33aa83`, poll
`ccb3a406`): Q1 `bo`, Q2 `bo`, Q3 `liv`, Q4 `rot`, Q5 `fb`.

- Section 1: the decided table with the answers verbatim; N1 (the WUI
  picker under a live list); the v0.1 form kept as 1.1.
- Section 4: step 3 is the live check; step 5 re-resolves at every restore
  and rotation; step 6 is the fallback only.
- Section 5: G7 reworded for the live list; G8 (claude has no list
  command) added.
- Section 6: C1 checks syntax only; L3 re-resolves (Q4 `rot`); L4 is the
  fallback (Q5 `fb`); A1 is the live read, not a cnf refresh; H1 adds the
  reading table; W1 offers the latest reading plus a typed model; H1 and W1
  no longer depend on an open question.
- Section 7.1: 7.1.1 drops `catalogue`; 7.1.2 and 7.1.5 drop the
  conditions; 7.1.4 is a record, not an input; 7.1.5 adds
  `agent_model_reading`; 7.1.6 (the live list) is new.

### 9.1 Changes from v0.2

Folds the R7 review notes (a-069, agy PASS on `9ff267a3b`), spec text only:

- N1: row A1 owns a new `lib/agent-models.inc.sh`; `lib/spool-env.inc.sh`
  stays row L1's, so the two parallel rows touch no common file.
- N2: the reading routes are named in row H1, row A1 and 7.1.5:
  `PUT /v1/boxes/{box}/agent-models/{vendor}` (a box reports a reading) and
  `GET /v1/tenant/agent-model-readings` (the WUI reads them).

### 9.2 Changes from v0.3

Row M0 (lane `c-888`), sections 3.2 and 7.1.3 only, measured from
`--version` and `--help` on a second box (no model call, no list command
run):

- 3.2: the agy (1.5.14), qwen (0.25.1) and codex (codex-cli 0.166.0) rows
  cite their help lines and their list source: agy `agy models` (not run,
  unknown whether it asks the vendor), qwen none (its models.dev registry
  is not the account's list), codex `codex debug models --bundled`
  (offline by its help) and its `models_cache.json`. The note under the
  table says that `grok models` (1.0.92) goes through the local leader and
  its help does not show a free call: UNVERIFIED.
- 7.1.3: codex `--model '<m>'` (was `-c model='"<m>"'`, unverified), qwen
  `--model '<m>'`, agy `--model '<m>'` with its value form open: agy's
  settings hold a display name with spaces and parentheses, outside the
  syntax of 7.1.2. That contract question goes to the spec's editor.
