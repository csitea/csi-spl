# Spec 177: The Reporter Agent Role, Iterative Qto Checklist, `reporting` Task Kind, and Daily Per-Member Task Notes

Version **0.2.0** (2026-11-15). Authored by lane `a-940` (`antigravity`).
Placement slug: `c002-s177-reporter-role-spec`.
Epic: **SPL-2129**. Issue: **SPL-5533** (status `wip`). Kind: **specs_and_docs**.
Discussion / Topic: `8319e41b-d408-4ffa-af53-12fa1db2d6e7` (`t1` `#reports`) and `dfe850d9` (`csitea` `#spool-hub`).
Nearest prior spec on `origin/master` (`f13d23295`): `csi-spl-doc/specs/166-orchestrator-daily-rhythm` (`176-full-offline-ai-stack` was the highest spec directory; `177-reporter-role` verified free).

> **Note on `csi-spl-doc/specs/README.md`**: On `origin/master`, `csi-spl-doc/specs/README.md` is a Qto-exported repo document (`59cba1d3-fb50-4045-82ff-13f5c140566f` in `csi-spl-doc/doc/md/qto-docs.tsv:265`) stopping at spec `099`. Hand-editing a Qto-mapped Markdown file fails `QTO_DRIFT_LIVE=1` (`csi-spl-orc/src/bash/run/check-qto-doc-drift.func.sh`) and is overwritten by `do_spl_doctree_export_md`, while `prd` Qto writes are barred in this spec-only lane. Following specs `100..176`, `csi-spl-doc/specs/README.md` is left untouched.

---

## 0. Owner Words and Decisions (Verbatim from Lane Brief)

> **Source verification note**: Sections `0.1`, `0.2`, and `0.3` reproduce the verbatim owner quotes and poll `f85b65de` outcomes supplied in the dispatcher's lane brief (`SPL-5533`); under the fleet data rule this `agy` spec lane does not read `prd` directly.

### 0.1 `HUM-10` in `prd` `t1` `#reports`, topic `8319e41b-d408-4ffa-af53-12fa1db2d6e7` (2026-11-14)

- `21:45:20Z` — *"Let's start the creation of a new role for an agent, which should be called Reporter."*
- `21:46:04Z` — *"The reporter should have a checklist with several items which he will use to go through, so that he should be able to report hourly and on every half hour."*
- `21:46:47Z` — *"Each reporter should be instantiated by a cron job with a predefined prompt based on the checklist, which we will iterate with each reporter after each report."*
- `21:47:44Z` — *"The way it should work is that there should be a separate reporter checklist document in the QTO, which we will update each time after a new reporter has done his duties. Now we prompt him to update the checklist. Then this reporter will make sure that the next reporter who will start will start with the prompt based on the checklist for the specific period (because the checklist might be a little bit different for each round hour and for each half hour)."*
- `21:48:28Z` — *"The reporter should report me for lanes which are stuck, for everything which is worth reporting for the overall operation of the Spool Hub system."*
- `21:48:52Z` — *"And just provide me the links for the discussion and stuff so that I will jump from his report to the correct discussion or issue or whatever objects, lanes, and so on and so forth. Then I will come back to the report and go through the next item."*
- `21:49:44Z` — *"The reporter should be spawned with the basic reporter prompt and not by the orchestrator, to avoid cases in which the orchestrator might be stuck. The reporter should be the one who actually prompts me to unstuck the orchestrator."*
- `21:50:12Z` — *"Based on all of those unstructured thoughts and prompts, create the initial checklist for the reporter."*
- `21:50:45Z` — *"It should report what is \"hot\" in the system so that I could know to go check, via the links, the specific things which might require my input."*
- `21:51:15Z` — *"And all of these should be done on a priority basis. Now that we have the priority attribute, establish the attribute linking end-to-end. The report should contain the items top to bottom based on their priority order."*
- `21:51:55Z` — *"We should establish a new type of task which is called reporting, and in the settings as well, create a new discussion for that in this channel. The preferred order should be: 1. AGY 2. Claude 3. Grok 4. Codex 5. Mistral"*

### 0.2 `HUM-10` Poll Decisions in `t1` `#reports`, poll `f85b65de` (2026-11-14)

- **D1 (`21:55:55Z`) — Report threading**: **A new topic per report in `t1` `#reports`** (never replies inside a single running thread).
- **D2 (`21:56:09Z`) — Fleet placement**: **One Reporter for the whole fleet, its cron on the `sat` box**.

### 0.3 `HUM-10` in `prd` `csitea` `#spool-hub`, topic `dfe850d9` (Spec 170 day-tasks topic, 2026-11-14)

- `21:59:52Z` — *"This should be done in the form of notes"*
- `22:02:11Z` — *"That is on daily basis the reporter role of agent should check the calendar and issues of a person and compile a task list - aka the notes for each member of the workspace"*
- `22:03:15Z` — *"And each note will contain links to the events in calendar or the issue and use the same prio order"*

---

## 1. The Role: Fleet Reporter on `sat`

### 1.1 Architecture and Independence from Orchestrator / Dispatcher

The **Reporter** is an ephemeral, cron-started fleet observer role — never a standing multi-hour tmux seat and never a lane spawned or supervised by `c-001` (orchestrator) or `c-002`/`c-003` (dispatchers).

1. **One fleet Reporter on `sat` (Decided D2)**:
   - Configured under a **new** top-level `env.reporter` block in `csi-spl-cnf/csi-spl/all.env.yaml` (`0` hits for `reporter` in `csi-spl-cnf` on `origin/master` today; full schema and `conf-validator` model in Section 1.4, owned by build row `B2`).
   - Registered as **new** box-cron row `reporter` (`0,30 * * * *`) in `csi-spl-orc/cnf/box-crons/box-crons.manifest`, invoking `src/bash/scripts/reporter-cron.sh` (`as: desk`, owned by build row `B6`).
   - On any machine whose `$SPOOL_BOX_TAG` does not match `env.reporter.box` (unless `REPORTER_FORCE=1`), or when `env.reporter.enabled` is `false`, `do_spl_reporter` logs `OK reporter: disabled or configured for <box>, skipping` and exits `0`.
2. **Zero orchestrator / dispatcher dependency (Owner `21:49:44Z`)**:
   - `reporter-cron.sh` invokes `REPORTER_CMD=start DRY_RUN=0 ./run -a do_spl_reporter` directly from the `sat` box user's crontab (`$SPOOL_BOX_USER`, resolved via `spool_env_resolve` / per-env `env.box.box_owner_user` in `prd.env.yaml:255`).
   - It never writes a `fleet_asks` spawn request, never waits on `do_spl_spawn_place`, never consults `c-001`, and posts directly to `t1` `#reports` via `do_spl_desk_post` using its own seated desk identity on `sat`, bypassing `c-002`/`c-003`.
3. **Standing vendor-matched desk identities (`SPL_RPT_AGENTS`, new in row `B6`)**:
   - In Spool's ID grammar (`csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go:64`), the first letter of an agent ID (`a-`, `c-`, `g-`, `o-`, `m-`) declares its vendor in the WUI, and `do_spl_desk_doctree` (`csi-spl-orc/src/bash/run/spl-desk-doctree.func.sh:97`, `SPL-2078`) requires `AGENT_ID == DESK_AGENT` on `DRY_RUN=0` writes.
   - Five standing Reporter desk IDs — one per vendor in the `reporting` ladder (`agy`, `claude`, `grok`, `codex`, `mistral`), allocated once via `next-agent-id.sh` — are declared in `csi-spl-orc/lib/bash/funcs/spl-desk-agents.func.sh` (`SPL_RPT_AGENT_AGY`, `SPL_RPT_AGENT_CLAUDE`, `SPL_RPT_AGENT_GROK`, `SPL_RPT_AGENT_CODEX`, `SPL_RPT_AGENT_MISTRAL`) and appended to `SPL_DESK_AGENT_IDS` so `agent-id-reap.sh` never reaps them between half-hour rounds.
   - Each of the five IDs is seated once on `sat`'s desk (`do_spl_desk_up`, Section 8.2 operator cutover) and added to `t1` `#reports` and `#alerts`. When a round runs under `agy`, it runs and posts as `SPL_RPT_AGENT_AGY`; if `agy` is unavailable and `claude` takes the round, it runs and posts as `SPL_RPT_AGENT_CLAUDE` (100% vendor-truthful attribution in WUI).

### 1.2 Round Cadence (`:00` and `:30`), Base Prompt, User/Permissions, and Self-Exit

Modelled on `gc-session.sh` / `do_spl_gc` (`csi-spl-orc/src/bash/features/gc/gc-session.sh:20-50`, `csi-spl-orc/src/bash/run/spl-gc.func.sh`):

1. **Slot detection**:
   - Minutes `00..14` select variant **`full`** (`:00` full-hour checklist); minutes `30..44` select variant **`half`** (`:30` half-hour delta checklist). Manual runs accept `REPORTER_SLOT=full|half`.
   - Round ID: `<YYYYMMDDTHHMMZ>-reporter-sat` (UTC).
2. **Overlap & stale-window guard**:
   - `REPORTER_CMD=start` acquires non-blocking `flock` on `$SPOOL_ROOT/dispatch/reporter/start.lock` and checks `$SPOOL_ROOT/dispatch/reporter/run` (`<start_epoch> <pane_id> <vendor> <round_id>`).
   - If window `reporter@sat` is still alive and `age < REPORTER_MAX_AGE` (default `1500 s` = `25 min`), the starter logs `SKIP <round_id> alive (<age>s)` and exits `0`.
   - If `age >= REPORTER_MAX_AGE`, the starter logs `END-STALE`, kills the hung `reporter@sat` window, records `prev_stale=<old_round_id>` in `$SPOOL_ROOT/dispatch/reporter/prev-stale`, and starts the new round so the stale-Reporter incident is reported at `P2` in the new `#reports` post.
3. **Box-user `facts.json` pre-gather, OS user hop, and CLI autonomy flags**:
   - Before starting any AI CLI, `REPORTER_CMD=start` runs as `$SPOOL_BOX_USER` (`spool_env_resolve` / per-env `env.box.box_owner_user`):
     1. Exports the current Qto checklist into `$SPOOL_ROOT/dispatch/reporter/rounds/<round_id>/checklist-active.md` (Section 2.2), and
     2. Runs `do_spl_reporter_gather` (build row `B4`) into `$ROUND_DIR/facts.json`, which executes all hub/DB/GCP read actions as `$SPOOL_BOX_USER`, **drops human/customer message bodies across every workspace**, and strips all credential/key paths (Section 7.1).
   - `reporter-session.sh` then launches one interactive CLI session inside tmux window `reporter@sat` as the agent OS user **`$SPOOL_AGENT_USER`** (`spool_env_resolve` / per-env `env.box.box_agent_user` in `prd.env.yaml:256`, invoked through `spool_agent_exec` in `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:671`; literal OS usernames are omitted in tracked docs per `.github/workflows/10_ci-quality.yml` `distribution-hygiene`), after marking the workdir trusted via `trust-workdir.sh --settle "$workdir" "$SPOOL_AGENT_USER" "$vendor"`, with `SPOOL_CLI_ENV` (`DISABLE_AUTOUPDATER='1'`) and `SPOOL_AGENT_ID=<SPL_RPT_AGENT_of_vendor>`.
   - Autonomy / permission flags come strictly from `spool_claude_perm_flags "$vendor"` (`spool-env.inc.sh:693`), never hand-rolled:
     - `agy`: `--dangerously-skip-permissions --prompt-interactive`
     - `claude`: `--name 'reporter@sat' --dangerously-skip-permissions`
     - `grok`: `--dangerously-skip-permissions --permission-mode bypassPermissions`
     - `codex`: `--dangerously-bypass-approvals-and-sandbox`
     - `mistral`: `--auto-approve`
   - The fixed base prompt (`csi-spl-orc/src/bash/features/reporter/reporter-prompt.md`) points the session to `checklist-active.md` and `facts.json` and requires all post/Qto/done actions to run through `sudo -u "$SPOOL_BOX_USER" env SPOOL_ROOT="$SPOOL_ROOT" DRY_RUN=0 REPORTER_CMD=<post|checklist-update|daily-notes|done> ./run -a do_spl_reporter`.
4. **How it exits after a round (no `ACCEPTED` wait)**:
   - Unlike dispatched task lanes (`30-exit-after-accepted.md`), the Reporter has no spawner and no `ACCEPTED` sender; `30-exit-after-accepted.md` applies only to task lanes.
   - At the end of its round, the Reporter runs `REPORTER_CMD=done DRY_RUN=0 ./run -a do_spl_reporter`, which verifies:
     1. `post.receipt` exists for `<round_id>` (a new topic was posted in `t1` `#reports`), and
     2. `checklist.receipt` exists for `<round_id>` (the Qto checklist iteration check/edit ran, or logged `hub-unreachable` fallback),
     then writes `DONE <round_id>` to `reporter.log` and schedules `kill-window -t "$REPORTER_PANE"` (`2 s` defer). `reporter-session.sh` has **no** trailing `exec bash` (matching `gc-session.sh:6`), so exiting the CLI closes the window cleanly and leaves zero idle sessions behind.

### 1.3 When the Reporter Cannot Start (Who Learns, and How)

Failure to start on `sat` is handled deterministically in two new layers, backed by the fleet's existing box/cron liveness monitors:

1. **Layer 1 — Automatic step-down across the 5-vendor `reporting` ladder**:
   - `REPORTER_CMD=start` reads the operator workspace's `reporting` vendor order (`1. agy -> 2. claude -> 3. grok -> 4. codex -> 5. mistral`, Section 5).
   - Before opening a window for vendor `V`, it checks:
     - `spool fleet-load get`: skips `V` if listed in `agent_kinds_off` or live `agent_kinds_paused`;
     - `spool_vendor_clis` & `auth_marker`: skips `V` if its CLI binary or login file is absent on `sat`.
   - After opening `reporter@sat` for `V`, it watches the pane for `REPORTER_START_CHECK_S` (`20 s`) via `spool_start_check` (`csi-spl-orc/src/bash/features/spawn-agents/lib/start-check.inc.sh`). If `V` stops on a `usage limit`, `grok weekly limit`, `auth`, or `trust prompt` screen, `REPORTER_CMD=start` kills that pane, logs `FALLBACK <round_id> <V> -> <next>: <dialog>`, and tries the next vendor in the ladder. Any fallback is surfaced as a `P3` note in that round's `#reports` post.
2. **Layer 2 — All 5 AI vendors fail on `sat` (pure-bash fallback post)**:
   - If all 5 vendors are off/paused/unauthenticated/limit-blocked (or `tmux` cannot open a pane), `REPORTER_CMD=start` runs `REPORTER_CMD=fallback-post` directly in bash as `$SPOOL_BOX_USER` (no LLM):
     - Uses `facts.json` from `do_spl_reporter_gather` to render a deterministic markdown summary table of hot `P1..P3` items.
     - Posts a `[P1] Reporter agent failed to start (<round_id>)` topic in `t1` `#reports` via `do_spl_desk_post` (as `SPL_RPT_AGENT_CLAUDE`) naming every vendor tried and its exact failure reason, followed by the raw deterministic table.
     - Posts a one-line alert in `t1` `#alerts` (deduplicated once per hour per failure signature) **and** sends a spool `blocker` note to `orchestrator` and the current dispatch lease holder.
     - **Who learns**: **HUM-10 (the owner)** immediately in `t1` `#reports` and `#alerts`, plus the **orchestrator** and **dispatch holder** via spool inbox.
3. **Existing `sat` host / cron outage detection (already on `origin/master`; optional `#reports` silence snitch in Section 9.2 `Q5`)**:
   - If the `sat` box itself goes offline or its `cron` daemon stops, existing fleet monitors (`rel-box-beat` -> `GET /v1/operator/boxes` and `do_cron_heartbeat_snitch` in `csi-spl-utl`) already raise `#alerts` / `alert-issue` filings. Whether to **also** add a cross-box `#reports` topic-age check (`> 75 min` silence) on a second box is left to the owner in **Section 9.2, Open Question `Q5`** (not built unless chosen).

### 1.4 New `env.reporter` Configuration Block and `conf-validator` Schema (Owned by Row `B2`)

None of `env.reporter.*` exists on `origin/master` today (`git grep -n reporter origin/master -- csi-spl-cnf` -> `0` hits). Build row `B2` introduces all **new** `env.reporter` keys in one place, modelled directly on `env.rhythm` (`csi-spl-cnf/src/python/conf-validator/EnvModels/all.py:36-56`, `test_rhythm.py`):

1. **New YAML block in `csi-spl-cnf/csi-spl/all.env.yaml`** (deep-merged into `dev.env.json` and `prd.env.json` via `ENV=dev ./run -a do_tpl_gen` and `ENV=prd ./run -a do_tpl_gen`; per-env `checklist_doc_id` and `enabled: true` overridden in `dev.env.yaml` / `prd.env.yaml` at Section 8.2 activation):
   ```yaml
   # NEW (Spec 177 row B2): fleet Reporter schedule, target channel, Qto doc, and offline vendor order
   reporter:
     enabled: false
     box: sat
     tenant: t1
     channel: reports
     checklist_doc_id: ""
     vendor_order:
       - agy
       - claude
       - grok
       - codex
       - mistral
     daily_notes_hour_utc: 5
   ```
2. **New Pydantic `Reporter(BaseModel)` in `csi-spl-cnf/src/python/conf-validator/EnvModels/all.py` and `EnvModels/cloud.py`**:
   - Validates `enabled: bool = False`, `box: str = "sat"` (non-empty), `tenant: str = "t1"`, `channel: str = "reports"`, `checklist_doc_id: str = ""` (empty or valid UUIDv4 when `enabled` is `True`), `vendor_order: List[Literal["agy", "claude", "grok", "codex", "mistral"]]` (non-empty, distinct items), and `daily_notes_hour_utc: conint(ge=0, le=23) = 5`.
   - Attached as `reporter: Reporter = Reporter()` on both `EnvModels/all.py:Env` and `EnvModels/cloud.py:Env` (used by `EnvModels/dev.py` and `EnvModels/prd.py`), tested in `csi-spl-cnf/src/python/conf-validator/tests/test_reporter_cnf.py`.

---

## 2. The Checklist as a Qto Document

### 2.1 Document Location, Structure, and Access Control

- **Location**: One workspace Qto document in `prd` workspace **`t1`** (`SPOOL_DOCTREE_FS=workspace`, the default of `spool doctree`), titled **`Reporter Checklist`**, its UUID stored in the **new** cnf key `env.reporter.checklist_doc_id` in `csi-spl-cnf/csi-spl/prd.env.yaml` (and `dev.env.yaml` for `dev`).
- **Single document, two slot variants + shared sections** (matching `csi-spl-doc/specs/177-reporter-role/checklist.md`):
  - `1. Shared Rules for Every Round` (applies to both `:00` and `:30`)
  - `2. Full-Hour Checklist (:00 UTC)` (including `2.9 Daily Per-Member Task-List Notes`)
  - `3. Half-Hour Checklist (:30 UTC)`
  - `4. Priority Mapping Quick Reference (P1 Highest -> P5 Lowest)`
  - `5. Iteration Notes (Updated by Each Reporter at End of Round)`
- **Who may edit it**:
  - **HUM-10 (the owner) and `t1` workspace admins/members**: Directly in the WUI (`Workspace Docs` / `/workspace/docs` Qto outline editor) at any time; human edits take immediate effect on the very next `:00` or `:30` round because cron exports fresh from Qto before starting each Reporter.
  - **The active Reporter agent (`SPL_RPT_AGENTS` on `sat`)**: At the end of its round via `REPORTER_CMD=checklist-update` -> `do_spl_desk_doctree` (`DOCTREE_ARGS="edit <doc_uuid> <item_uuid> ..."`, optimistic concurrency via item `rev` returning `412` on conflict).
  - **Orchestrator / dispatcher role seats (`c-001..c-003`)**: Only when relaying an explicit owner instruction in topic `8319e41b` / `#reports`. Lane agents (`004..999`) never edit the live Qto checklist.

### 2.2 How Cron Builds the Prompt from the Current Variant

Before opening the `reporter@sat` window, `REPORTER_CMD=start` (running as `$SPOOL_BOX_USER`) executes:

1. **Live Qto export**:
   ```bash
   ENV=prd TENANT_ID=t1 DESK_AGENT="$RPT_AGENT" \
     DOCTREE_ARGS="export $CHECKLIST_DOC_UUID --out $ROUND_DIR/checklist-full.md" \
     ./run -a do_spl_desk_doctree
   ```
   and `DOCTREE_ARGS="read $CHECKLIST_DOC_UUID"` -> `$ROUND_DIR/checklist-tree.json` (capturing item UUIDs and `rev` numbers so `REPORTER_CMD=checklist-update` knows exact item IDs for end-of-round updates).
2. **Cache + offline fallback**:
   - On a clean export (non-empty, contains headings `## 1.`, `## 2.`, `## 3.`, `## 4.`, `## 5.`), atomically copies `checklist-full.md` to `$SPOOL_ROOT/dispatch/reporter/checklist.last-good.md`.
   - If `checklist_doc_id` is unset or the hub is unreachable / returns `5xx`, `REPORTER_CMD=start` falls back to `checklist.last-good.md`, else to repo-tracked `csi-spl-doc/specs/177-reporter-role/checklist.md`, and sets `CHECKLIST_SOURCE=cache|repo-fallback` so the Reporter's header notes that live Qto was unreachable.
3. **Slot-specific prompt assembly and vendor data boundary**:
   - A deterministic slicer extracts:
     - On **`:00` (`full`)**: Sections `1`, `2` (`2.1..2.8`, plus `2.9` only when current UTC hour == `env.reporter.daily_notes_hour_utc`), `4`, and `5` -> `$ROUND_DIR/checklist-active.md`.
     - On **`:30` (`half`)**: Sections `1`, `3`, `4`, and `5` -> `$ROUND_DIR/checklist-active.md`.
   - **Vendor-aware execution rule in `reporter-prompt.md` (Data Rule, Section 7.1)**:
     - On **`agy` and `codex` rounds**, the Reporter session works **strictly from `facts.json` and `checklist-active.md`** (pre-built by `$SPOOL_BOX_USER` `do_spl_reporter_gather` with **zero** human message bodies from any workspace and **zero** GCP/DB credentials) and calls only `REPORTER_CMD=post|checklist-update|daily-notes|done`. Per the fleet data-rule prompt policy (matching normal fleet practice where `$SPOOL_AGENT_USER` holds `sudo -u "$SPOOL_BOX_USER"`), `reporter-prompt.md` and `checklist.md` forbid running `do_spl_unanswered_sweep`, `do_gcp_list_alert_incidents`, `psql`, or `gcloud` from an `agy` or `codex` session.
     - Optional live drill-down reads beyond `facts.json` (e.g. reading `do_spl_unanswered_sweep` non-`spool_enc` excerpts to summarize a stuck thread) are permitted **only when the active round vendor is `claude`, `grok`, or `mistral`**.

### 2.3 How the Reporter Updates the Qto Document at the End of Its Round

To fulfil the owner's iterative loop (`21:46:47Z`, `21:47:44Z`) without risking accidental truncation or prompt-injection corruption of the checklist:

1. After posting the `#reports` topic, the Reporter runs `REPORTER_CMD=checklist-update`:
   - If nothing in the checklist needed refinement this round, `REPORTER_CMD=checklist-update --noop "<round_id>: no checklist change"` stamps `checklist.receipt` without creating noisy Qto revision churn.
   - When the round uncovered a new check nuance, threshold tweak, action flag, or recurring false positive, the Reporter edits Section `5` (`Iteration Notes`, capped at the newest 10 bullets) and/or appends/refines a check bullet in Section `2` or `3` via `do_spl_desk_doctree` (`edit <doc_uuid> <item_uuid> --field body --file ...`).
2. **Structural guardrails enforced by `REPORTER_CMD=checklist-update`**:
   - `delete <doc_uuid>` (whole-doc delete) and deleting top-level headings `1..5` or mandatory check subsections `2.1..2.9` are **refused** (`exit 4`) in the wrapper.
   - Any candidate edit is scanned before upload so no secret pattern, OS username, or workspace message excerpt can ever be written into the `t1` Qto checklist.
   - On HTTP `412` (`stale rev` — e.g. the owner edited the Qto doc in WUI while the Reporter was running), the wrapper re-reads `doctree read <doc_uuid>`, preserves the human edit unconditionally, appends the Reporter's note only under Section `5`, and retries once.

---

## 3. Initial Checklist (`checklist.md`) and Action Audit on `origin/master`

The complete ready-to-import initial Qto document lives in [`checklist.md`](checklist.md). Every required operational check was audited against `origin/master` (`f13d23295`):

| # | Check Category | Slot(s) | Verified Existing Action / Route on `origin/master` | Gap Marked `"no action yet"` (Built in Section 8) |
|---|---|---|---|---|
| **1** | **Stuck / silent orchestrator or dispatch lease** (+ owner unstick prompt) | `:00`, `:30` | `LEASE_CMD=show ./run -a do_spl_dispatch_lease` (`spl-dispatch-lease.func.sh`); `ENV=prd ./run -a do_spl_dispatch_check` (`spl-dispatch-check.func.sh`); `ASKS_FORMAT=json ./run -a do_spl_asks_open` (`spl-asks-open.func.sh`) | Cross-box orch/dispatch health roll-up JSON from `sat`: **`no action yet`** (`B4`) |
| **2a** | **Stuck lanes** (silent commit / msg / heartbeat `>= 15 min`) | `:00`, `:30` | `lane-map.sh` / `do_spl_lane_map` (`GET /v1/operator/fleet-lanes`); `GC_CMD=scan ./run -a do_spl_gc` (local box `sat`) | Fleet-wide silent-lane age & last-commit/msg JSON across all boxes from `sat`: **`no action yet`** (`B4`) |
| **2b** | **Failed launches / DOA windows** | `:00`, `:30` | Local `start-check.inc.sh` & `$SPOOL_ROOT/dispatch/wd` S2 verdicts | Cross-box failed-launch counter since last round: **`no action yet`** (`B4`) |
| **2c** | **Queued asks not placed** | `:00`, `:30` | `SPAWN_QUEUE_FORMAT=json ./run -a do_spl_spawn_queue` (`spl-spawn-queue.func.sh`); `./run -a do_spl_spawn_share` (`spl-spawn-share.func.sh`); `fleet-stopped-alarm-cron.sh` | None (`do_spl_spawn_queue` already emits `priority`, `wait_s`, `.place.wait`) |
| **3** | **Owner questions waiting** (blockers & unanswered polls) | `:00`, `:30` | `do_spl_issue_needs_owner` / `spl_owner_digest_render` (`spl-owner-digest-post.func.sh`) | Unanswered ```` ```poll ```` & open channel `kind=blocker` query with `msg:<uuid>` + topic prio: **`no action yet`** (`B4`) |
| **4** | **Unanswered human posts** | `:00`, `:30` | `ENV=prd DELIVER=0 ./run -a do_spl_unanswered_sweep` (`spl-unanswered-sweep.func.sh`, run inside `$SPOOL_BOX_USER` `do_spl_reporter_gather` with all message bodies stripped for `facts.json`; direct drill-down `claude`/`grok`/`mistral` only); store `UnansweredPosts` (`store/fallback_postgres.go:114-130`) | Exposing `topic_priorities.priority` + body-free JSON mode on `do_spl_unanswered_sweep`: **`no action yet`** (`B3`, `B4`) |
| **5** | **CI red on `master`** (& stuck / at-risk jobs) | `:00` (`CI_GATE_RUNS=20`), `:30` (`CI_GATE_RUNS=10`) | `cd csi-spl-iac && CI_GATE_RUNS=20 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`; `do_check_ci_gate_stuck`; `do_report_ci_red_note` | None |
| **6** | **Deploy lag `dev` / `prd`** (& deploy failures / release-note lag) | `:00` (`dev`+`prd`), `:30` (`prd`) | `ENV=dev ./run -a do_check_deploy_lag`; `ENV=prd ./run -a do_check_deploy_lag`; `do_spl_deploy_failure_poll`; `do_spl_release_notes_lag_alarm` | None |
| **7** | **Vendor quota / weekly limits / auth markers** | `:00`, `:30` (pauses) | `spool fleet-load get` (`GET /v1/operator/fleet-load`: `agent_kinds_off`, `agent_kinds_paused`); `DRY_RUN=1 ./run -a do_spl_weekly_limit_alert` (local box); `agent-login-check-cron.sh` | Single cross-box live weekly-% summary for unpaused vendors on non-`sat` boxes: **`no action yet`** (`B4` reads `fleet-load` + `#alerts` weekly-limit posts) |
| **8** | **Box health** (disk blocks `>=85%`/`>=92%`, inodes `>=80%`/`>=90%`, reliability crons, `#alerts`, GCP incidents) | `:00`, `:30` (crit) | `DRY_RUN=1 ./run -a do_check_disk_headroom`; `csi-spl-utl` `do_systemd_unit_health`, `do_tmux_health_guard`, `do_gh_runner_health`, `do_external_api_health`, `do_cron_heartbeat_snitch`; `csi-spl-iac` `do_gcp_list_alert_incidents` (run inside `$SPOOL_BOX_USER` `do_spl_reporter_gather` only); `spool topics --channel alerts`; `do_spl_alert_issue_tick` | Cross-box disk mount-% on hub box heartbeat (`GET /v1/operator/boxes`): **`no action yet`** (non-`sat` crossings surface via `#alerts` / `alert-issue`) |
| **9** | **Daily per-member task-list notes** | Daily `:00` slot | `day-tasks.mjs` (`82822fc4b`); `0225_personal_notes.sql`, `0254_note_priority.sql`, `Note*.vue` | Hub + orc daily per-member `personal.notes` compiler/writer: **`no action yet`** (`B7`, `B8`) |

---

## 4. The Report: Format, End-to-End Priority Linking, and Deep Links

### 4.1 Where `priority` Lives Today on `origin/master` (`f13d23295`)

Empirical audit of `git grep -n priority origin/master -- csi-spl-rdb csi-spl-api`:

| Entity | Storage / Code Home on `origin/master` | Scale & Default | Existing Sync / Propagation |
|---|---|---|---|
| **Discussion / Topic** | `topic_priorities` (`csi-spl-rdb/src/sql/postgres/spool-hub/0214_topic_priorities.sql`, PK `(tenant_id, task_id)`, `CHECK (priority BETWEEN 1 AND 5)`); `store/topic_priority.go`, `hub/topic_priority.go`; owner prio-word auto-`1` in `hub/owner_prio_word.go` (`SPL-5524`) | `1..5` (`1` highest); unset reads as **`3`** (`store.TopicPriorityDefault`, `SPL-4367`) | Bidirectional last-change-wins with linked open issues (`hub/topic_priority_follow.go`, `hub/topic_priority_spread.go` `SPL-5223`, and 5-min cron `do_spl_topic_prio_sync` in `spl-topic-prio-sync.func.sh`, `SPL-4813`). |
| **Issue** | `issues.priority` (`0047_issues.sql`, `0054`, `0055`), `issues.priority_set_at` (`0273_issue_priority_set_at.sql:17`) | `1..5`; create inherits highest set linked-topic priority, else `1` (`bug`/`alert`), `2` (`refactor`), else **`5`** (`hub/issue_prio_default.go`) | Linked to discussions in `issue_discussions` (`0194_issue_discussions.sql:39`); priority synced last-change-wins using `issues.priority_set_at` (`0273`) vs `topic_priorities.set_at` (`0214`). |
| **Spawn Ask (`fleet_asks`)** | `fleet_asks.discussion` (`0241_fleet_ask_discussion.sql`), `store/fleet_ask.go` (`askPositions`) | Ranked by discussion's `topic_priorities.priority` (`1..5`, unset = **`3`**), then class (`urgent` -> `1`), then `enqueued_at` | Exposed in `do_spl_spawn_queue` (`PRIO` column). |
| **Active Lane (`fleet_lanes`)** | Computed dynamically in `hub/fleet_lanes_view.go:351` (`lanePrio`) — no column on `fleet_lanes` | `min(priority)` (`1..5`) across open/linked `laneIssues` (`issue_discussions` on lane's topic + `lane.IssueKey`); `0` (dash) when lane has no issue | Shown in `Monitoring -> Lanes` (`monitoring/lanes/index.vue`, `SPL-4727`), **but misses topic priority when a lane has a topic with `topic_priorities` and no issue yet!** |
| **Unanswered Human Post** | `store/fallback_postgres.go:114-130` (`UnansweredPosts`) joins `topic_priorities` | Orders by `coalesce(tp.priority, $5)` at line `130` (`TopicPriorityDefault = 3`), then `m.received_at` | `spl-unanswered-sweep.func.sh` SQL does **not** yet project `topic_priorities.priority` in its output. |
| **Personal Note** | `personal.notes.priority` (`0254_note_priority.sql`) | `1..5`, default **`5`**; `NotePriorityChooser.vue` | Set per note by member (and by daily-notes compiler in Section 6). |
| **Message (`messages`)** | `0001_hub_core.sql`..`0278_note_to_self.sql` — **no `priority` column** | None on row | Must inherit from enclosing `task_id` (`topic_priorities`) + linked issues. |
| **Calendar Event (`calendar_events`)** | `0125_calendar.sql`, `0247_calendar_event_links.sql` (`topic_id`, `issue_keys`) — **no `priority` column** | None on row | Must derive from linked `issue_keys` and `topic_id` (Section 4.2). |

### 4.2 End-to-End Priority Linking Specification (`P1..P5`)

To satisfy *"Now that we have the priority attribute, establish the attribute linking end-to-end. The report should contain the items top to bottom based on their priority order"* (`21:51:15Z`):

1. **Lane priority fallback to topic priority (`hub/fleet_lanes_view.go`, row `B3`)**:
   - Today `lanePrio` returns `0` whenever a lane has no linked issue, even if its `topic` has `topic_priorities.priority = 1` (e.g. an owner `"urgent"` topic before an issue is filed).
   - `lanePrio` is extended to `min` over: (a) linked `laneIssues` priorities (`1..5`), and (b) the lane topic's explicit `topic_priorities.priority` (`1..5`), remaining `0` (displayed as `-`, ranked at default `3` in Reporter sorting) only when neither is set.
2. **Unanswered sweep & poll/blocker reader priority projection (rows `B3` / `B4`)**:
   - `do_spl_unanswered_sweep` (`spl-unanswered-sweep.func.sh`) `LEFT JOIN`s `topic_priorities tp ON tp.tenant_id = m.tenant_id AND tp.task_id = m.task_id` and emits `priority = COALESCE(tp.priority, 3)`, sorting `priority ASC, oldest_unanswered_at ASC`.
   - Open owner polls/blockers compute `priority = min(linked_issue_priorities, COALESCE(tp.priority, 2_if_blocker_else_3))`.
3. **Calendar event effective priority (shared by Reporter & Section 6 daily notes, row `B7`)**:
   - For any `calendar_events` row (or deadline item):
     - Deadline item (`source = "issue"`): the issue's `issues.priority` (`1..5`).
     - Event (`source = "event"`): `min` over (a) `issues.priority` of open/linked `calendar_events.issue_keys` (`0247`), and (b) explicit `topic_priorities.priority` of `calendar_events.topic_id` (`0125`). If neither is set: `2` for `kind IN ('release', 'deploy', 'freeze')`, else **`3`** (`TopicPriorityDefault`).
4. **System / infrastructure check mapping onto `P1..P5`** (thresholds aligned with `check-disk-headroom.func.sh` and `tmp-scratch-sweep.func.sh`):
   - If `do_spl_alert_issue_tick` or an operator already filed an open `SPL-<n>` issue for the alert/CI-red/lag, the item inherits `issues.priority` (created at `1` for `bug`/`alert`).
   - Otherwise:
     - **`P1`**: Dead/stale dispatch or orch lease (`> 180 s`), `master` CI gate/deploy workflow red, `prd` deploy `lagging`, disk blocks `>= 92%` (`DISK_HEADROOM_CRIT_PCT`) or inodes `>= 90%` (`SCRATCH_INODE_MIN_FREE_PCT=10`), dead box heartbeat / tmux down, open `prd` GCP incident, or primary `secret`/`orchestration` vendor blocked with no backup.
     - **`P2`**: `dev` deploy `lagging`, open human `blocker` / unacked orch ask `> 15 min`, dispatcher unread backlog `> 20`, vendor newly paused/off or weekly quota `>= 95%`, disk blocks `85%..91%` (`DISK_HEADROOM_BLOCK_PCT=85`) or inodes `80%..89%` (`DISK_HEADROOM_INODE_PCT=80`), stale previous Reporter killed.
     - **`P3`**: Silent/stuck lane (`>= 15 min`) on an unset-prio topic, unanswered human post on an unset-prio topic, spawn queue wait `>= 20 min` on an unset-prio topic, CI timeout-headroom `AT RISK` (`> 75%`), release-note lag, weekly quota `85%..94%`, Reporter vendor step-down notice.
     - **`P4`**: Lower-priority (`priority = 4`) issues/topics/lanes, routine daily-notes completion summary.
     - **`P5`**: `priority = 5` backlog items (included only when stuck/hot, never as filler).
5. **Deterministic report sort key**:
   - `(priority ASC [1..5], hot_requires_owner DESC, age_seconds DESC, key ASC)`.

### 4.3 Report Post Structure and Clickable Deep Links (`t1` `#reports`)

- **Channel & Threading (Decided D1)**: New level-1 topic per round in `t1` `#reports` via `do_spl_desk_post` (`DESK_CHANNEL=reports`, `DESK_KIND=blocker` **only** when a `P1` orchestrator/lease unstick poll requires owner action, else `DESK_KIND=note`).
- **Formatting rules** (`csi-spl-doc/doc/help/how-to-post.md`):
  - Plain GitHub-flavoured Markdown, **never** wrapped in ```` ```md ```` fences.
  - Every clock time in **UTC** (`2026-11-15T06:00Z` or `06:00 UTC`, rule 4).
  - At most **one** ```` ```poll ```` fence in the entire post (checked by `spl_desk_poll_check`, rule 7/10), reserved for unsticking a dead/silent orchestrator or lease when present.
- **Canonical clickable deep links** (Owner `21:48:52Z`, verified against `csi-spl-wui/src/pages/**` and `how-to-post.md` rule 17):
  - **Same-workspace (`t1`) discussion**: `topic:<full-task-uuid>` (or `[<title>](https://<t1-host>/t/<full-task-uuid>)`)
  - **Other-workspace discussion**: `[<ws>: #<channel>](https://<ws-host>/t/<full-task-uuid>)` (metadata label only — never customer message text)
  - **Specific message / poll / blocker**: `msg:<full-msg-uuid>` in `t1`, or `[post](https://<ws-host>/m/<full-msg-uuid>)` across workspaces
  - **Issue**: bare `SPL-<n>` in `t1` (auto-linked by `issue-key-links.mjs` to `/issues?issue=SPL-<n>`), or `[<KEY>](https://<ws-host>/issues?issue=<KEY>)` for non-`t1` workspaces
  - **Active lane**: `[<id>@<box>](https://<t1-host>/monitoring/lanes?lane=<id>%40<box>)` (`monitoring/lanes/index.vue:35`, `SPL-4206`)
  - **Box / Fleet load**: `[boxes](https://<t1-host>/monitoring/boxes)` / `[fleet load](https://<t1-host>/tenant-settings/fleet-load)`
  - **Calendar event**: `[<title>, <YYYY-MM-DD>](https://<ws-host>/calendar?d=<YYYY-MM-DD>&event=<full-event-id>)` (`event:` is never used — `how-to-post.md` line 195).

**Illustrative report skeleton**:

```markdown
**Fleet Report — 2026-11-15 06:00 UTC** (`full` round · `a-NNN@sat` · checklist rev 14)

### Hot — Requires Attention (P1 -> P5)
1. **[P1 · Lease / Orch]** Dispatch lease on `c-002@sat` stale **6m 12s** (`> 180s`); 3 open asks unacked **21m** — topic:8319e41b-d408-4ffa-af53-12fa1db2d6e7 · [lanes](https://<t1-host>/monitoring/lanes)
2. **[P1 · CI `master`]** `10_ci-quality.yml` job `api-pg` red on `f13d23295` (**18m** ago) — SPL-5560 · [run](https://github.com/csitea/csi-spl/actions/runs/123456789)
3. **[P2 · Stuck Lane]** [c-910@<box>](https://<t1-host>/monitoring/lanes?lane=c-910%40<box>) silent **24m** (no commit/msg) — SPL-5541 · topic:48d75e5f-9700-4000-8000-000000000000
4. **[P3 · Unanswered]** `csitea` `#spool-hub` human post (`HUM-10`) waiting **19m** — [post](https://<csitea-host>/m/<msg-uuid>) · [topic](https://<csitea-host>/t/<task-uuid>)

**Verified green**: `prd` & `dev` deploy lag (`0` unserved), vendor quotas (all 5 on, max `68%`), disk/inodes (`<= 61%`), `#alerts` (`0` new), daily member notes (`2` workspaces, `9` notes updated at 06:00 UTC).
```

*(When item 1 is a stuck orchestrator/lease, the single ```` ```poll ```` unstick block follows immediately below the list.)*

---

## 5. The Task Kind `reporting` and Settings UI

### 5.1 Owner Requirement and Two-Layer Settings Fit

Owner (`21:51:55Z`):
> *"We should establish a new type of task which is called reporting, and in the settings as well, create a new discussion for that in this channel. The preferred order should be: 1. AGY 2. Claude 3. Grok 4. Codex 5. Mistral"*

*(Per brief §2.5, this spec defines `reporting` end to end; the dispatcher opens its dedicated discussion in `t1` `#reports`.)*

On `origin/master`, task-kind vendor routing has **two** coupled surfaces in code and WUI:

1. **Vendor Split per Task Kind** (`env.box.agent_split_by_kind` in `all.env.yaml`, `tenant_agent_split_kind` in `rdb 0163/0178/0262`, `store/agent_split_kind.go`, `do_spl_lane_mix`, WUI `/tenant-settings/split` -> `AgentSplitKinds.vue`):
   - Picks the **primary** vendor (`weights` summing to `100`, strict unique `main`, and `backup != main`).
2. **Agent Takeover / Preference Ladder per Task Kind** (`tenants.settings` keys `takeover.<kind>.order` and `takeover.<kind>.max_failures`, `store/takeover_ladder.go`, `hub/takeover_ladder.go`, WUI `/tenant-settings/takeover` -> `takeover.vue`):
   - Stores an **ordered list of distinct vendors** (`1..N`) and `max_failures`, with up/down reorder buttons, add/remove vendor controls, Save, and Reset to defaults.

Adding **new** task kind `reporting` to **both** surfaces satisfies both `env.box.agent_split_by_kind.reporting` and the 5-vendor ordered preference `1. agy -> 2. claude -> 3. grok -> 4. codex -> 5. mistral` in Settings:

- **New row in `env.box.agent_split_by_kind`** (`csi-spl-cnf/csi-spl/all.env.yaml`, `DefaultSplitKinds()` in `store/agent_split_kind.go`, `DEFAULT_SPLIT_KINDS` in `csi-spl-wui/src/utils/tenant-settings.mjs`):
  ```yaml
  reporting: { agy: 100, backup: claude }
  ```
  - Why `agy: 100, backup: claude`: The owner specified a strict **preference order** (`1. AGY 2. Claude 3. Grok 4. Codex 5. Mistral`), not a round-robin percentage split. With `agy: 100, backup: claude`, `agy` is always picked #1 whenever healthy and available (never nudged aside by `do_spl_lane_mix`'s deficit window), while `claude` is #2 in `SplitKind` and the full 5-vendor chain lives in the ladder below. Workspace admins can still adjust weights in `/tenant-settings/split` if desired.
- **New row in `DefaultTakeoverLadder` & new cnf key `env.reporter.vendor_order`** (`store/takeover_ladder.go`, `csi-spl-wui/src/utils/takeover-ladder.mjs`, `all.env.yaml`):
  ```go
  {Kind: "reporting", Order: []string{"agy", "claude", "grok", "codex", "mistral"}, MaxFailures: 1}
  ```
  - Editable per workspace in **Workspace Settings -> Agent takeover** (`/tenant-settings/takeover`, `csi-spl-wui/src/pages/tenant-settings/takeover.vue`) using the existing up/down/add/remove controls.
  - Read at runtime by `REPORTER_CMD=start` (for operator workspace `t1`, falling back to **new** cnf key `env.reporter.vendor_order: [agy, claude, grok, codex, mistral]` in `all.env.yaml` if the hub is unreachable) and by `do_spl_lane_mix` when `LANE_MIX_KIND=reporting`.

### 5.2 Coordination with In-Flight `SPL-5454` (`codex` in Settings)

Empirical check on `origin/master` (`f13d23295`) vs fleet lane map:
- On `origin/master` today, `codex` (`o-NNN`) is already in `agentid.go` and `0238_cursor_codex_kinds.sql` (`fleet_agent_kinds_off`), while `store.AgentKinds` (`store/fleet_load.go:44`), `tenant_agent_split_kind_vendor_check` (`0163`), `agent_split.py`, `AGENT_SPLIT_KINDS`, and `TAKEOVER_VENDORS` still list 5 vendors (`claude, grok, agy, qwen, mistral`).
- Live lane **`SPL-5454`** (`c-688@sat`, in review on `c-688-c002-feat-codex-in-every-ai-client-setting-9130912f`) is **already** adding `codex` to `store.AgentKinds`, `tenant_agent_split_kind_vendor_check`, `agent_split.py`, `do_spl_lane_mix`, `split.vue` / `AgentSplitKinds.vue`, `takeover-ladder.mjs`, and all 19 locale files.
- **Collision-free rule**: Build row **`B1`** of Spec 177 (`reporting` task kind) **waits for and rebases onto `SPL-5454`** on `origin/master` rather than re-implementing `codex` vendor plumbing in parallel.

### 5.3 Exact Schema, Config, Backend, Orchestrator, and WUI Rules for `reporting`

1. **RDB migration** (`<NNNN>_agent_split_kind_reporting.sql`, claimed via `DRY_RUN=0 ./run -a do_rdb_migration_next` at build time, row `B1`):
   - Widens `tenant_agent_split_kind_kind_check` (`0178_agent_split_kind_orchestration.sql`) to include `'reporting'`:
     ```sql
     CHECK (kind IN ('specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret', 'orchestration', 'reporting'))
     ```
   - `tenant_agent_split_kind_secret_vendors` stays restricted to `('secret', 'orchestration')` — `reporting` is **not** a secret-class kind (`agy` and `codex` are allowed under the `facts.json` boundary in Section 7.1); if a lane sets `LANE_MIX_SENSITIVE=1`, `_spl_lane_mix_kind` upgrades it to `secret` as it already does for every other kind (`spl-lane-mix.func.sh:157-158`).
2. **Mistral non-coding classification (`owner msg 91bf8278` + owner `21:51:55Z`, row `B2`)**:
   - Under the owner's Mistral rule (Mistral handles documentation and reviews only, never repository code changes), a Reporter round writes only WUI `#reports` markdown summaries and Qto checklist notes — zero git commits and zero code edits. `reporting` therefore explicitly counts as **non-coding**, matching the owner's explicit placement of Mistral at `#5` in the `reporting` ladder:
     - `agent_split.py`: `KINDS` adds `"reporting"`, while `CODING_KINDS` and `MISTRAL_NO_CODE_KINDS` do **not** include `"reporting"`, allowing Mistral in `reporting`.
     - `spl-lane-mix.func.sh`: `LANE_MIX_MISTRAL_KINDS=(specs_and_docs i18n reporting)` and `_spl_lane_mix_kind` accepts `reporting` (plus alias `report -> reporting`).
3. **Fleet rules drift pins (`check-fleet-rules-drift.func.sh`, row `B2`)**:
   - Update `_frd_per_kind_main` (`csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh:197-205`) and the per-kind tables in `20-spawn-an-agent.md` and `spawn-an-agent.md` with `reporting` (`main = agy`, `backup = claude`).
4. **Go API & WUI Settings (rows `B1` & `B5`)**:
   - `store/agent_split_kind.go`: append `"reporting"` to `SplitTaskKinds` (`:30`) and `DefaultSplitKinds()`.
   - `store/takeover_ladder.go`: append `"reporting"` to `TakeoverTaskKinds` (`:25`) and `{Kind: "reporting", Order: []string{"agy", "claude", "grok", "codex", "mistral"}, MaxFailures: 1}` to `DefaultTakeoverLadder()` (`:56`).
   - `csi-spl-wui/src/utils/tenant-settings.mjs` (`SPLIT_TASK_KINDS`, `DEFAULT_SPLIT_KINDS`), `csi-spl-wui/src/utils/takeover-ladder.mjs` (`TAKEOVER_KINDS`, `DEFAULT_TAKEOVER`), and i18n key `tenant_settings.split_kind_reporting` (`"Reporting"` across all 19 locale files in `csi-spl-wui/i18n/locales/*.json`, authored/reviewed by an `agy` seat).

---

## 6. Daily Per-Member Task-List Notes and Relation to Spec 170

### 6.1 Owner Requirement (`csitea` `#spool-hub` topic `dfe850d9`)

- `21:59:52Z`: *"This should be done in the form of notes"*
- `22:02:11Z`: *"That is on daily basis the reporter role of agent should check the calendar and issues of a person and compile a task list - aka the notes for each member of the workspace"*
- `22:03:15Z`: *"And each note will contain links to the events in calendar or the issue and use the same prio order"*

### 6.2 How Daily Notes Fit Spec 155 (`personal.notes`, `Note*.vue`) and Spec 119 RLS

Verified in `csi-spl-rdb/src/sql/postgres/spool-hub/0225_personal_notes.sql` and `0254_note_priority.sql`:

1. **Personal-realm isolation (`0225_personal_notes.sql:81-88`)**:
   - `personal.notes`, `personal.note_items`, and `personal.note_links` enforce `FORCE ROW LEVEL SECURITY` with policy `person_scope`: rows are visible/writable **only** when `app.person_id = person_id`, `app.tenant_id` is empty, and `app.rls_scope` is **not** `'operator'`.
   - Furthermore, under Spec 155 D1, **one person sees one `personal.notes` list across every workspace they belong to**, while `personal.note_links.workspace_id` tags which workspace each linked event or issue belongs to.
   - Under the fleet Data Rule (`Section 7.1`), an `agy` or `codex` CLI session must never receive private calendar titles or customer workspace issue titles in its prompt, and no agent ever reads a human's existing `personal.notes`.
2. **Write-only hub compiler triggered on the morning `:00` round (`POST /v1/operator/reporter/daily-notes`, rows `B7` & `B8`)**:
   - Once per day (on the `:00` full-hour round matching **new** cnf key `env.reporter.daily_notes_hour_utc`), `do_spl_reporter_daily_notes` (`csi-spl-orc/src/bash/run/spl-reporter-daily-notes.func.sh`, running as `$SPOOL_BOX_USER`) calls `spl_hub_operator_call POST /v1/operator/reporter/daily-notes "$body"` (`csi-spl-orc/lib/bash/funcs/spl-hub-operator.func.sh:33`, authenticated by the `prd` project SA token).
   - Inside Go (`internal/hub/reporter_daily_notes.go` + `internal/store/reporter_daily_notes.go`), the hub:
     1. Enumerates active human members (`HUM-<n>`, excluding probe/demo/disabled accounts and skipping members whose `humans.day_tasks_reminder = 'off'` in `0252_humans_day_tasks_reminder.sql:26-30`; `NULL` and `'on'` are included) across enabled non-test workspaces, resolving each member's timezone from their per-workspace membership override `tenant_memberships.settings->>'time_zone'` (`0078_membership_settings.sql:30`, `internal/auth/handler.go:1420`, fallback `env.rhythm.timezone` / `UTC` — `humans` has no `timezone` column) and local calendar day `YYYY-MM-DD`.
     2. Reads, per workspace the person belongs to:
        - **Calendar events overlapping that person's local day** where the person is `owner_id` (`0247_calendar_event_links.sql`), `creator_id` (`0125_calendar.sql:31`), named in `calendar_events.mentions` (`0125_calendar.sql:29`), or has a human invitation row in table `calendar_guests` (`0139_calendar_full_edit.sql:54`, `guest_type = 'human' AND guest_id = person_id AND response <> 'no'`), respecting `audience = 'private'` strictly for that person alone and expanding `rrule` occurrences via `calrecur`.
        - **Open task issues assigned to that `HUM-<n>`** (`assignee = person_id`, `status NOT IN ('done', 'diss')`, `type NOT IN ('epic', 'feature')` — the exact `isTask` rule of Spec 170 `day-tasks.mjs`), taking: (i) overdue deadlines (`deadline < dayStart`), (ii) due-today deadlines (`dayStart <= deadline < dayEnd`), and (iii) open assigned issues with no deadline (ordered after dated items within the same priority).
     3. Computes each item's effective `priority` (`1..5`, Section 4.2) and sorts **top-to-bottom** by:
        `(priority ASC [1..5], bucket ASC [0=overdue, 1=timed_event_today, 2=due_today_or_all_day, 3=open_assigned_no_date], starts_or_due_at ASC, key ASC)`.
     4. Writes **one** consolidated daily Note per person per local date inside `inPerson(ctx, personID, ...)` (so a person in 3 workspaces gets **one** clean daily task list across their workspaces, never 3 duplicate notes, and re-running on the same date is idempotent via a nullable `daily_date date` column + `(person_id, daily_date)` partial unique index on `personal.notes`, migration `<NNNN>_personal_notes_daily_date.sql`):
        - `title`: `"Tasks — YYYY-MM-DD"` (localized in the member's `preferred_locale` if set, else English).
        - `priority`: `min(item.priority)` across all items in the note (`1..5`, default `5` if none; renders in `NotePriorityChooser.vue`).
        - `personal.note_items`: one checklist line (`done = false`, `position` `1000, 2000, ...` in `P1..P5` order) per event or issue, e.g. `[P1 · Overdue] SPL-5512 — Fix hub token refresh (csitea)` or `[P2 · 10:00] Architecture sync — 2026-11-15 (t1)` (`<= 500` chars). If the note for `(person_id, daily_date)` already exists, existing `done = true` ticks are preserved while new events/issues are inserted in priority order.
        - `personal.note_links`: one typed link chip per item (`0225_personal_notes.sql:58-70`), rendered by `NoteCard.vue` / `NoteEditor.vue`:
          - Calendar event -> `kind = 'event'`, `workspace_id = <tenant_id>`, `ref = <event_uuid>`, `day = <YYYY-MM-DD>` (satisfies `CONSTRAINT note_links_event_day`), `label = "<title> (<HH:MM>)"`.
          - Issue -> `kind = 'issue'`, `workspace_id = <tenant_id>`, `ref = <ISSUE-KEY>`, `day = NULL`, `label = "<ISSUE-KEY>: <title>"`.
        - When a member has **zero** events and **zero** open assigned task issues today, **no empty note is created** (`0` clutter).
     5. Returns **counts only** (`{date, workspaces_scanned, members_checked, notes_created, notes_updated, empty_skipped}`) to `do_spl_reporter_daily_notes` — zero private titles or personal data leave the hub.

### 6.3 Exact Relationship to Spec 170 (`170-day-tasks-reminder`)

Verified on `origin/master` (`f13d23295`):

| Spec 170 Row | Status on `origin/master` | Relation to Spec 177 Daily Per-Member Notes |
|---|---|---|
| **B0** (`6231710ad`) | **Landed** (`0252_humans_day_tasks_reminder.sql:24-30`: `day_tasks_seen_on date NULL`, `day_tasks_reminder text NULL CHECK (... IN ('on','off'))`; `PUT /v1/me/settings`) | **Kept & reused**: `humans.day_tasks_reminder` (`NULL` or `'on'` = enabled, `'off'` = disabled) serves as each member's opt-out switch for receiving automated daily task notes. |
| **B1** (`82822fc4b`) | **Landed** (`csi-spl-wui/src/utils/day-tasks.mjs` + `tests/unit/day-tasks.test.mjs`) | **Reused directly as the rule contract**: `isTask` (`type NOT IN ('epic', 'feature')`, `status NOT IN ('done', 'diss')`), `dayBounds(dateStr, timeZone)` (explicit zone, no `Date.parse`), and `overdue` (`deadline < dayStart` above today's rows) are mirrored 1-for-1 in Go (`internal/daytasks`) with parity fixtures against `day-tasks.test.mjs`. |
| **B2** (Desktop Calendar To-do view, `CalendarTodoView.vue`, `?k=todo`) | **Not built** (`0` hits for `CalendarTodoView` in `csi-spl-wui`) | **Candidate to replace / drop** (`HUM-10` `21:59:52Z`: *"This should be done in the form of notes"* in Spec 170's own topic `dfe850d9`). Left as explicit owner confirmation in **Section 9.2, Q1**. |
| **B3** (Phone Calendar To-do view) | **Not built** | **Candidate to replace / drop** — `notes.vue` + `Note*.vue` already render responsive checklists, priority badges, and typed `event`/`issue` deep links on phone and desktop (Spec 155 B6–B10). **Section 9.2, Q1**. |
| **B5** (`day_tasks_seen_on` morning pop-up card in `calendar.vue`) | **Not built** | **Candidate to replace (or retarget to open `/notes?note=<id>`)** — **Section 9.2, Q1**. |

---

## 7. Security, Data Rule, and Hygiene Invariants

1. **Fleet Data Rule (`agy` #1 and `codex` #4 in `reporting` — Strict `facts.json` Boundary)**:
   - Under the fleet data rule (`store/agent_split_kind.go:36-39`, `Spec 161 §5.1`), `agy` and `codex` never hold secrets, credentials, GCP service-account keys, or customer/personal data from any workspace.
   - Because `spl-unanswered-sweep.func.sh:540` (`left(l.body, 400)`) and `unanswered-sweep-classify.py:223` (`body[:120]`) currently include message excerpts for workspaces where `spool_enc` is not set, and `do_gcp_list_alert_incidents` (`gcp-list-alert-incidents.func.sh:33,80`) reads `$HOME/.gcp/.csi/key-csi-spl-<env>.json`, **no `agy` or `codex` Reporter session ever invokes those actions directly**.
   - Instead (matching normal fleet practice, where `$SPOOL_AGENT_USER` has `sudo -u "$SPOOL_BOX_USER"`, so enforcement is the prompt/checklist rule + pre-built `facts.json` + narrow `REPORTER_CMD` verbs):
     1. `do_spl_reporter_gather` (row `B4`) runs as `$SPOOL_BOX_USER` before `reporter-session.sh` starts. It executes `do_spl_unanswered_sweep` in metadata-only mode (`SWEEP_FORMAT=metadata-json`, added in `B3`), **dropping human/customer message bodies (`body`, `excerpt`, `text`) from EVERY workspace** (`spool_enc` and non-`spool_enc` alike) and retaining only IDs, timestamps, channel slugs, `HUM-<n>` sender IDs, ages, and `1..5` priorities in `facts.json`.
     2. `do_gcp_list_alert_incidents` also runs inside `$SPOOL_BOX_USER` `do_spl_reporter_gather` before the session starts, writing only `{env, policy_name, resource_label, open_count, first_open_utc, last_violating_utc, peak_value}` into `facts.json` (zero SA key paths, zero `client_email`, zero OAuth tokens).
     3. Daily per-member `personal.notes` compilation runs inside the Go hub (`POST /v1/operator/reporter/daily-notes`), returning aggregate counts only.
     4. On `agy` and `codex` rounds, `reporter-prompt.md` and `checklist.md` require the session to read **only** `facts.json` and `checklist-active.md` and call only `REPORTER_CMD=post|checklist-update|daily-notes|done`; live drill-down commands that inspect non-`spool_enc` topic text or GCP incidents are restricted to **`claude`, `grok`, and `mistral` rounds only**.
2. **Distribution Hygiene (`do_check_dist_hygiene`)**:
   - Zero literal machine tags outside `sat` config (`env.reporter.box` supplies the box tag), zero literal OS usernames (`spool_env_resolve` / per-env `env.box.box_owner_user` and `env.box.box_agent_user`), zero personal names, and all domain links built dynamically from `env.dns.fqdn` / workspace host records.
3. **Deterministic Code vs Agent Judgment**:
   - Cron scheduling, vendor step-down, Qto export/guardrails, `facts.json` collection, priority sorting, link formatting, and daily `personal.notes` assembly are deterministic code; the Reporter LLM session correlates multi-signal events (e.g. linking a CI red to a stuck lane and an unacked ask), writes crisp human summaries, and records concise checklist refinements in Section 5 of the Qto doc.

---

## 8. Implementation Plan: Small Disjoint Build Rows (`B1..B9`) and Operator Cutover

### 8.1 Build Rows (`B1..B9`, Zero Overlapping Files Across Rows)

Every row below is one single-concern task with **strictly disjoint file ownership** (`0` files appear in more than one row):

| Row | Depends On | Task Kind | Scope & Exact Disjoint Files | Tests & Red Control |
|---|---|---|---|---|
| **B1** | `SPL-5454` (`codex` in settings) | `complex_coding` | **RDB migration & Go store/hub `reporting` task kind**:<br>• `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_agent_split_kind_reporting.sql`<br>• `csi-spl-api/src/go/spool-hub-api/internal/store/{agent_split_kind.go,takeover_ladder.go}`<br>• `csi-spl-api/src/go/spool-hub-api/internal/store/{agent_split_kind_test.go,takeover_ladder_test.go}` | `PRE_PUSH_TIER=full`: Go store/hub tests (Memory + Postgres migration test).<br>**Red control**: omit `'reporting'` from `tenant_agent_split_kind_kind_check` -> Postgres migration & `PATCH` `reporting` test fail. |
| **B2** | `B1` | `simple_coding` | **New `env.reporter` cnf schema + `reporting` in `conf-validator`, `do_spl_lane_mix`, & fleet-rules-drift** *(sole owner of `csi-spl-cnf`)*:<br>• `csi-spl-cnf/src/python/conf-validator/EnvModels/{agent_split.py,all.py,cloud.py}` + `tests/{test_agent_split_by_kind.py,test_reporter_cnf.py}`<br>• `csi-spl-cnf/csi-spl/all.env.yaml` (+ `do_tpl_gen` rendered `{dev,prd}.env.json`)<br>• `csi-spl-orc/src/bash/run/{spl-lane-mix.func.sh,check-fleet-rules-drift.func.sh}` + `tests/{spl-lane-mix.tst.sh,check-fleet-rules-drift.tst.sh}`<br>• `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md` + `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/spawn-an-agent.md` | `python3 -m unittest discover` in `conf-validator`, `ENV=dev ./run -a do_tpl_gen && ENV=prd ./run -a do_tpl_gen && git diff --exit-code`, `spl-lane-mix.tst.sh`, `check-fleet-rules-drift.tst.sh`.<br>**Red control**: set `daily_notes_hour_utc: 24` or omit `reporting` from `20-spawn-an-agent.md` -> `test_reporter_cnf.py` and `check-fleet-rules-drift.tst.sh` fail. |
| **B3** | — (parallel) | `simple_coding` | **End-to-end priority linking & body-free JSON mode on lanes and unanswered sweep**:<br>• `csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_lanes_view.go` + `fleet_lanes_view_test.go` (`lanePrio` falls back to explicit `topic_priorities.priority` when lane has no issue)<br>• `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` + `tests/unanswered-sweep-pg.tst.sh` (join `topic_priorities.priority`, sort `priority ASC, age DESC`, add `SWEEP_FORMAT=metadata-json` dropping all `body` text across every workspace) | `go test ./internal/hub/...` (Postgres) + `bash csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh`.<br>**Red control**: plant a non-`spool_enc` human post body `"SECRET-CUSTOMER-LINE"` under `SWEEP_FORMAT=metadata-json` or revert `lanePrio` topic fallback -> redaction assertion and `P1` issue-less lane test fail. |
| **B4** | `B3` | `complex_coding` | **Box-user `do_spl_reporter_gather` (`facts.json`) & hub poll/blocker status endpoint**:<br>• `csi-spl-api/src/go/spool-hub-api/internal/hub/reporter_status.go` + `reporter_status_test.go` (`GET /v1/operator/reporter/status`: unanswered ```` ```poll ```` & open channel `kind=blocker` metadata with `msg_id` + topic prio, no message bodies)<br>• `csi-spl-orc/src/bash/run/spl-reporter-gather.func.sh` + `tests/spl-reporter-gather.tst.sh` (runs as `$SPOOL_BOX_USER`, calls `spl_hub_operator_call GET /v1/operator/reporter/status`, `SWEEP_FORMAT=metadata-json do_spl_unanswered_sweep`, `do_gcp_list_alert_incidents`, lease/lanes/queue/CI/deploy-lag/quotas/disk; writes body-free, key-free `facts.json` sorted `P1..P5` with WUI deep links) | `PRE_PUSH_TIER=full`: `go test ./internal/hub/...` + `spl-reporter-gather.tst.sh`.<br>**Red control**: inject a synthetic SA key path, `client_email`, or customer message excerpt into mock upstream output -> `facts.json` leak-guard test fails when scrubber is bypassed. |
| **B5** | `B1` | `i18n` | **WUI Settings for `reporting` (`/tenant-settings/split` & `/tenant-settings/takeover`)**:<br>• `csi-spl-wui/src/utils/{tenant-settings.mjs,takeover-ladder.mjs}`<br>• `csi-spl-wui/i18n/locales/*.json` (19 locale files: `tenant_settings.split_kind_reporting`)<br>• `csi-spl-wui/tests/unit/{tenant-settings.test.mjs,takeover-ladder.test.mjs}` + `tests/e2e/tenant-settings.test.mjs`<br>• `csi-spl-doc/doc/md/takeover-ladder.md` | `pnpm run typecheck`, `pnpm run test:unit`, e2e `tenant-settings.test.mjs` verifying `reporting` default order `['agy','claude','grok','codex','mistral']` renders, reorders, saves, and resets.<br>**Red control**: drop `reporting` from `TAKEOVER_KINDS` -> Go-parity unit test turns red. |
| **B6** | `B2`, `B4` | `complex_coding` | **Standing Reporter desk IDs, session launcher, Qto checklist export/update guardrails, fallback poster, & `sat` cron**:<br>• `csi-spl-orc/lib/bash/funcs/spl-desk-agents.func.sh` (`SPL_RPT_AGENT_*` in `SPL_DESK_AGENT_IDS`)<br>• `csi-spl-orc/src/bash/features/reporter/{reporter-session.sh,reporter-prompt.md}`<br>• `csi-spl-orc/src/bash/run/spl-reporter.func.sh` (`start`, `post`, `checklist-export`, `checklist-update`, `fallback-post`, `done`; invokes `do_spl_reporter_daily_notes` if defined on the configured `:00` hour)<br>• `csi-spl-orc/src/bash/scripts/reporter-cron.sh` + `csi-spl-orc/cnf/box-crons/box-crons.manifest`<br>• `csi-spl-orc/src/bash/tests/spl-reporter.tst.sh` | `spl-reporter.tst.sh`, `install-box-crons.tst.sh`, `desk-agent-ids.tst.sh`. Covers `:00` vs `:30` Qto slicing, `412` conflict retry, section-delete refusal, `spool_claude_perm_flags` per vendor, 5-vendor step-down, all-5-down pure-bash fallback post, and `enabled: false` / non-`sat` skip.<br>**Red control**: simulate all 5 CLIs down with fallback disabled -> test fails because `#reports` receives no failure post. |
| **B7** | — (parallel) | `complex_coding` | **Hub daily per-member task-list Notes compiler (`personal.notes` + Spec 170 `day-tasks` parity)**:<br>• `csi-spl-rdb/src/sql/postgres/spool-hub/<NNNN>_personal_notes_daily_date.sql` (nullable `daily_date date` + partial unique `(person_id, daily_date) WHERE daily_date IS NOT NULL AND archived_at IS NULL`)<br>• `csi-spl-api/src/go/spool-hub-api/internal/daytasks/{daytasks.go,daytasks_test.go}` (Go port of `day-tasks.mjs` `82822fc4b`)<br>• `csi-spl-api/src/go/spool-hub-api/internal/store/reporter_daily_notes.go` + `internal/hub/{reporter_daily_notes.go,reporter_daily_notes_test.go}` (`POST /v1/operator/reporter/daily-notes`, writes via `inPerson`, honors `day_tasks_reminder != 'off'` and `tenant_memberships.settings->>'time_zone'`, returns counts only) | `PRE_PUSH_TIER=full`: Postgres RLS & idempotency tests (`inPerson` isolation, `operator` scope reads `0` rows from `personal.notes`, `calendar_guests` + `mentions` inclusion, `note_links_event_day` satisfied, `P1..P5` ordering, re-run preserves `done=true` items, `day_tasks_reminder='off'` & zero-task members skipped).<br>**Red control**: attempt write under `app.rls_scope='operator'` instead of `inPerson` -> Postgres RLS rejects write. |
| **B8** | `B6`, `B7` | `simple_coding` | **Morning `:00` daily-notes orchestrator action (`do_spl_reporter_daily_notes`)**:<br>• `csi-spl-orc/src/bash/run/spl-reporter-daily-notes.func.sh` (calls `spl_hub_operator_call POST /v1/operator/reporter/daily-notes`, enforces once-per-UTC-date stamp under `$SPOOL_ROOT/dispatch/reporter/daily-notes.last`, formats `P4` ok / `P2` failure summary line)<br>• `csi-spl-orc/src/bash/tests/spl-reporter-daily-notes.tst.sh` | `spl-reporter-daily-notes.tst.sh` verifying once-per-day execution on `env.reporter.daily_notes_hour_utc`, skip on `:30` and already-ran dates, and zero personal data in logs/output.<br>**Red control**: remove daily stamp check -> second `:00` run triggers duplicate hub POST (caught by test). |
| **B9** | `B6` (and owner poll `Q1`) | `specs_and_docs` | **Documentation & Spec 170 status reconciliation** *(pure repo docs — zero `prd` or `cnf` mutations)*:<br>• `csi-spl-doc/doc/md/reporter-agent.md` (operator/architecture reference for the Reporter role)<br>• `csi-spl-doc/specs/170-day-tasks-reminder/spec.md` (status note recording which Spec 170 rows Daily Notes supersede per owner answer to `Q1`) | `cd csi-spl-iac && ./run -a do_check_dist_hygiene`, `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`, `do_check_qto_doc_drift`.<br>**Red control**: broken relative path or banned literal -> `do_check_fleet_rules_drift` / `do_check_dist_hygiene` fails. |

### 8.2 Post-Deploy Operator / Dispatcher Cutover (Not an `agy` Docs Lane — Requires Owner GO)

Per `CLAUDE.md` and seed `DEPLOY-GATE (e)`, no task lane runs `do_spl_desk_up` or mutates `prd` Qto directly. Once `B1..B8` are green and deployed on `dev` and `prd`, activation is executed by the `claude` dispatch/orchestrator role seat with the owner's explicit GO:

1. Seat the five `SPL_RPT_AGENT_*` identities on `sat` (`do_spl_desk_up` on `dev`, then `prd`) and add them to `t1` `#reports` and `#alerts`.
2. Import `csi-spl-doc/specs/177-reporter-role/checklist.md` into workspace `t1` Qto (`do_spl_doctree_import_md`, first on `dev`, then `prd`) to mint the live **Reporter Checklist** document UUID.
3. Land a small config commit setting `env.reporter.checklist_doc_id` and `env.reporter.enabled: true` in `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` (+ `do_tpl_gen`) and verify one dry-run (`REPORTER_CMD=start DRY_RUN=1 ./run -a do_spl_reporter`) on `sat`.

---

## 9. Decided Items and Open Questions for the Owner

### 9.1 Already Decided (Recorded as Final — Do Not Re-Ask)

1. **Report threading** (poll `f85b65de`, `21:55:55Z`): **One new topic per report in `t1` `#reports`**.
2. **Fleet topology** (poll `f85b65de`, `21:56:09Z`): **One Reporter for the whole fleet, its cron on the `sat` box**.
3. **Task kind & vendor order** (`21:51:55Z`): New task kind **`reporting`** (non-coding), preferred order **`1. AGY, 2. Claude, 3. Grok, 4. Codex, 5. Mistral`**, configurable in Settings (dispatcher opens its own discussion in `t1` `#reports`).

### 9.2 Open Questions (For the Dispatcher to Ask as a Poll)

1. **Q1 — Spec 170 (`170-day-tasks-reminder`) unbuilt rows (`B2` desktop Calendar To-do tab, `B3` phone Calendar To-do view, `B5` morning pop-up card)**:
   - **(A, Recommended)** Daily per-member Notes (Section 6) **replace all three** unbuilt Spec 170 UI rows (`B2`, `B3`, `B5`); keep landed `B0` (`humans.day_tasks_reminder` `'on'`/`'off'`/`NULL` as per-member opt-out) and `B1` (`day-tasks.mjs` shared filter logic).
   - **(B)** Replace `B5` (morning pop-up card) with Daily Notes, **still build `B2` + `B3`** (live Calendar To-do tab alongside Notes).
   - **(C)** Keep all of Spec 170 (`B2`, `B3`, `B5`) alongside Daily Notes.
2. **Q2 — Previous day's automated Daily Task Note in `personal.notes`**:
   - **(A, Recommended)** **Auto-archive** the previous day's Reporter-generated `"Tasks — YYYY-MM-DD"` note when writing today's new one (open unfinished issues/overdue items carry forward automatically into today's note, keeping the active Notes view clean while archived history remains searchable).
   - **(B)** **Keep unarchived** in the active Notes list until the member archives or deletes it manually.
3. **Q3 — Quiet half-hour (`:30`) rounds when zero hot items changed since `:00`**:
   - **(A, Recommended)** Still post a **1-line heartbeat topic** in `t1` `#reports` every `:00` and `:30` (`All green — 0 hot items; N lanes active, CI/prd current`) so silence always means the Reporter itself is broken.
   - **(B)** Post full/heartbeat every `:00`, and **skip `:30`** when zero `P1..P3` items are hot or changed since `:00`.
4. **Q4 — Daily Per-Member Notes schedule and workspace scope**:
   - **(A, Recommended)** Run once daily at **`05:00 UTC`** (`07:00 EET` / `08:00 EEST`) across **all active non-test workspaces** (`t1`, `csitea`, customer workspaces — honoring each member's `humans.day_tasks_reminder != 'off'` setting).
   - **(B)** Run hourly at `:00` and generate each member's note when their per-workspace membership `tenant_memberships.settings->>'time_zone'` (fallback `env.rhythm.timezone`) reaches **`07:00` local time**.
   - **(C)** Start on **`t1` and `csitea` only** first, then widen to all workspaces after one week.
5. **Q5 — Cross-box `#reports` silence alarm if `sat` goes dark**:
   - **(A, Recommended)** Rely on the **existing** `rel-box-beat` and `do_cron_heartbeat_snitch` box/cron health alarms on `origin/master` (build nothing extra).
   - **(B)** Add a lightweight 15-min check on a non-`sat` box that posts one `[P1]` alert to `t1` `#alerts` whenever `t1` `#reports` has no new Reporter topic for `> 75 min`.

<!-- version: 0.2.0 · updated: 2026-11-15 · last-edit: 2026-11-15T04:55:00Z -->
