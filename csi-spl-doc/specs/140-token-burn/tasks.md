# Tasks: Spec 140 — Real-time token burn per agent type and per agent, on the Monitoring page

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet).  
Status: **Ready to build** (Spec complete, SPL-1986).  
Authority: [spec.md](spec.md) for requirements; this file for task status, acceptance gates, and red controls.  
Docs only: this task list defines the work; implementation lanes execute it ([README.md](../README.md) §2.4).

---

## 0. Inventory & baseline

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T001** | **Planned** | `rdb` | `hub-tokens` | **Database schema migration: `fleet_token_burn_events`** (§3.2). Forward-only migration `0198_fleet_token_burn.sql` creating table `fleet_token_burn_events` with natural key `(box_tag, agent_id, minute_bucket)`, composite aggregation indices, and operator-only RLS (`app.rls_scope = 'operator'`).<br>• *Gate*: `psql` applies migration cleanly on PostgreSQL 16; RLS test verifies non-operator role receives 0 rows.<br>• *Red Control*: Querying table without setting `app.rls_scope = 'operator'` returns permission denied or 0 rows; duplicate insert on `(box_tag, agent_id, minute_bucket)` raises unique violation without `ON CONFLICT`. |
| **T002** | **Planned** | `api` | `hub-tokens` | **Wire data contracts & domain models** (§3.4, §3.5). Define Go structs in `internal/wire` (`FleetTokenSample`, `FleetTokensPushFrame`, `FleetTokensAckFrame`, `FleetTokenSummaryResponse`, `VendorTokenBurn`, `AgentTokenBurn`) and store interfaces in `internal/store/fleet_tokens.go`.<br>• *Gate*: `go test ./internal/wire` passes schema serialization/deserialization tests.<br>• *Red Control*: Unmarshaling JSON payload with missing required fields (`minute`, `agent_id`, `vendor`) fails strict validation. |

---

## 1. Phase 1: Hub Ingestion & Read API (`hub-tokens`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T010** | **Planned** | `api` | `hub-tokens` | **Store implementation: Memory & PostgreSQL backends** (§3.1, §3.2). Implement `FleetTokenStore` interface in `internal/store/fleet_tokens.go` (`RecordSamples`, `QuerySummary`, `QueryByVendor`, `QueryByAgent`, `PruneOldBuckets`). Price each sample against `model_prices` table at ingestion time using active rate at `minute_bucket`.<br>• *Gate*: `TestFleetTokenStoreUpsert` and `TestFleetTokenStorePricing` pass under both Memory and PostgreSQL.<br>• *Red Control*: A sample with non-existent model price fails with `ErrNoPrice` or marks row `cost_micros = 0`; re-inserting same minute bucket updates counts rather than creating duplicate row. |
| **T011** | **Planned** | `api` | `hub-tokens` | **Hub WebSocket ingestion handler: `lane_op fleet_tokens_push`** (§3.4). Handle incoming `TLane` frames with `lane_op: "fleet_tokens_push"` over the box CLI / runner authenticated live connection. Resolves `box_tag` from the authenticated session context, parses samples, prices tokens against `model_prices`, and upserts rows into `fleet_token_burn_events` in a single transaction (owner decision 1 = B).<br>• *Gate*: `TestFleetTokensPushOp` verifies valid WebSocket frame ingests samples and returns ack frame with inserted count.<br>• *Red Control*: Frame with invalid `lane_op` or unauthenticated session context returns `bad_frame` error; malformed sample payload returns `bad_samples` without dropping the WebSocket connection. |
| **T012** | **Planned** | `api` | `hub-tokens` | **Hub read route: `GET /v1/operator/fleet-tokens`** (§3.5). Provide aggregated token metrics over requested time window (`1h`, `24h`, `today`): fleet burn rate (tokens/min, cost/hr), vendor breakdown, agent lane breakdown, and minute-by-minute time series.<br>• *Gate*: `TestFleetTokensReadRoute` verifies accurate sum of tokens and costs across multiple active agents.<br>• *Red Control*: Read request from standard workspace session without `app.rls_scope = 'operator'` returns HTTP 403; agy agent reports `is_metered: false` with null token sums. |
| **T013** | **Planned** | `api` | `hub-tokens` | **Telemetry retention pruning in maintenance sweep** (§3.6). Implement `PruneOldBuckets` running during daily maintenance, removing raw 1-minute buckets older than 30 days while preserving 365-day daily rollups (owner decision 2 = B).<br>• *Gate*: Test with simulated 31-day-old rows verifies rows older than 30 days are deleted while newer rows remain; daily rollups older than 365 days are pruned.<br>• *Red Control*: Without the prune job, query verifies table row count continuously accumulates beyond 30-day boundary. |
| **T014** | **Planned** | `api` | `hub-tokens` | **Sustained burn rate evaluator & `#fleet-alerts` publisher** (§4.4). Implement rolling 3-minute sustained burn evaluation upon sample insertion. If an agent sustains > 60,000 tokens/min across 3 consecutive minutes, format and post an automated high-visibility spool alert message to `#fleet-alerts` with a 30-minute cool-off throttle (owner decision 3 = B).<br>• *Gate*: `TestFleetTokenSurgeAlert` fires alert to `#fleet-alerts` when agent exceeds 60k/min for 3 consecutive minutes; verifies 30-minute cool-off prevents duplicate alerts.<br>• *Red Control*: Agent burning 65k/min for only 2 minutes before dropping does not trigger alert; alert omitted if burn rate stays below 60k/min. |

---

## 2. Phase 2: Box Telemetry Collector (`collector-tokens`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T020** | **Implemented** | `orc` | `collector-tokens` | **Incremental transcript parser for Claude, Vibe, and Grok** (§2.3). Bash/Python parser reading Claude `.jsonl` (taking MAX token usage per `message.id`), Vibe session journals and compacted `chunks/`, and Grok session updates. Extracts `tokens_in`, `tokens_out`, `cache_read`, `cache_write`, and model name without extracting any prompt or completion text.<br>• *Gate*: Unit test `spl-token-burn-parse.tst.sh` parses sample transcripts of all 3 vendors and produces exact token counts.<br>• *Red Control*: Streaming Claude chunks parsed naively without deduplicating `message.id` doubles token count; fixture verifies MAX deduplication produces exact expected count. |
| **T021** | **Implemented** | `orc` | `collector-tokens` | **Agy unmetered detection & agent identity mapping** (§2.3.4, §2.5). Cross-reference active tmux panes, `/var/spool-hub/registry.tsv`, and project slugs (`-wt[0-9]*-<id>`). Detect running Agravity (agy) lanes and mark them `is_metered: false` and `vendor: agy`.<br>• *Gate*: Test with mock running agy session emits telemetry sample with `is_metered: false` and `tokens_in: 0`.<br>• *Red Control*: An agy session reported as metered with 0 tokens fails assertion requiring `is_metered: false`. |
| **T022** | **Implemented** | `orc` | `collector-tokens` | **Persistent offset tracker & named action `do_spl_token_burn_collect`** (§2.1, §2.4). Implement `csi-spl-orc/src/bash/run/spl-token-burn-collect.func.sh` with persistent `/var/csi/csi-spl/token-burn/collector-state.json`. Reads incremental byte offsets, detects inode rotations, batches delta samples, and pushes via WebSocket frame `lane_op fleet_tokens_push` using box CLI (`spool fleet-tokens push`) over the live session (owner decision 1 = B).<br>• *Gate*: `spl-token-burn-collect.tst.sh` verifies appending 500 bytes to transcript on second run transmits only the 500 new bytes.<br>• *Red Control*: Truncating transcript file or changing inode resets offset to 0 instead of reading past EOF. |
| **T023** | **Planned** | `orc` | `collector-tokens` | **Box cron registration** (§2.1). Register `do_spl_token_burn_collect` in `cnf/box-crons/box-crons.manifest` to execute every 30 seconds on runner boxes.<br>• *Gate*: `spl-box-crons.tst.sh` validates manifest entry syntax and execution schedule.<br>• *Red Control*: Removing cron entry prevents collector action from running automatically. |

### 2.1 As built (`collector-tokens`, SPL-2037)

Where the build differs from spec section 2, and why:

- **Claude** uses the spec 123 parse, not a second one: `spl_cost_tokens_jq_def`
  in `spl-cost-tokens-read.func.sh` is the jq def both the daily reader and the
  collector run (MAX per `message.id`). The daily file of 2026-10-14 on sat's
  transcripts is byte-identical before and after the refactor (sha256
  `ef43849e…`, 334 lines).
- **Mistral (vibe)** is read from the session's cumulative `tokenUsage` counters
  (`payload.delta[].state.session`, in the journal), not from per-call `usage`
  objects: every call's usage is written twice there (`result.usage` and
  `command.result.usage`), and a counter delta loses or doubles nothing when
  vibe compacts a journal into `chunks/`. Input is `inputTokens -
  cachedInputTokens`. The model is the `[[models]]` name of `config.toml`'s
  `active_model` alias.
- **Grok** is read from each session's `usage.json` (cumulative session
  counters, rewritten whole at each turn's end), not `updates.jsonl`: so grok
  burn shows when a turn ends, not while it runs.
- **A session first seen** counts from 0 when it began inside the 60-minute
  window, else its counters are the baseline (no history counted as burn).
  The first tick on a box starts every transcript at its end.
- **State** is TSV files in `/var/csi/csi-spl/token-burn/` (`files.tsv`
  offsets and inodes, `ids.tsv` the 2-hour per-id MAX, `sessions.tsv`,
  `buckets.tsv`), not one `collector-state.json`: awk reads and writes them
  in the tick's one pass, jq would cost a process per file.
- **Finding the transcripts** costs more than reading them: a listing of every
  transcript dir is ~2700 stats (~0.4 s on sat at load 15-25). So a tick stats
  only the files it tracks (changed in the last 3 h) and lists only the dirs
  whose mtime moved since the last tick; every dir is listed every 5 min. A new
  file in a dir whose mtime does not move (a subagent file in an existing
  `subagents/`) is read up to 5 min late, never lost.
- **Buckets** hold the full totals of each agent's minute for the last 60
  minutes; a changed bucket stays queued until a push is acked, and is sent
  whole (the hub replaces on `(box_tag, agent_id, minute_bucket)`).
- **Push**: `spool fleet-tokens push --json -` is not on master yet (hub lane
  `hub-tokens`): until it is, every push fails and buckets stay queued for 60
  minutes. The hub settings come from `push.env`, written hourly by
  `do_spl_token_burn_push_env`.
- **Cron** (T023): `src/bash/scripts/token-burn-collect-cron.sh` runs 2 ticks a
  minute, 30 s apart, sourcing the two func files directly: `./run`'s start
  alone measured ~0.8 s on sat (n=3), more than a tick's budget.

---

## 3. Phase 3: Monitoring UI Tab (`wui-tokens`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T030** | **Planned** | `wui` | `wui-tokens` | **Tab routing & operator navigation integration** (§4.1). Register Tokens tab in `utils/monitoring-tabs.mjs` (`id: 'tokens'`, `to: '/monitoring/tokens'`, `operatorOnly: true`) and create route page `pages/monitoring/tokens.vue`.<br>• *Gate*: WUI navigation unit test verifies Tokens tab appears beside Agents and Boxes for operator admins and is hidden for non-operator members.<br>• *Red Control*: Non-operator user attempting to access `/monitoring/tokens` is redirected to `/monitoring/agents` or shown 403 state. |
| **T031** | **Planned** | `wui` | `wui-tokens` | **Top KPI cards component: `MonitoringTokensSummary.vue`** (§4.2). Display fleet burn rate (tokens/min, cost/hr), today's total tokens (with cache hit percentage), today's total cost in EUR, and metered vs unmetered lane counts.<br>• *Gate*: Component test renders formatted values (e.g. `45.2k tokens/min`, `€42.15`).<br>• *Red Control*: Negative token count or missing summary properties renders fallback dash (`—`) rather than `NaN` or unformatted zero. |
| **T032** | **Planned** | `wui` | `wui-tokens` | **Vendor breakdown table component: `VendorBurnTable.vue`** (§4.2, §4.4). Display breakdown by agent type (Claude, Mistral, Grok, Agravity, Qwen) with active lane count, current tokens/min with visual alert thresholds (amber >30k/min, red >60k/min), today's tokens, today's cost, and status badge.<br>• *Gate*: Component test verifies Agravity row displays prominent `[Not Metered]` badge with explanatory tooltip.<br>• *Red Control*: Agy row displaying numerical `0 tokens` or `€0.00` fails test assertion requiring unmetered badge. |
| **T033** | **Planned** | `wui` | `wui-tokens` | **Agent lanes breakdown table component: `AgentBurnTable.vue`** (§4.2, §4.4). Display detailed lane table with Agent ID, Vendor, Box tag, Model, 1m/5m tokens/min with visual surge highlighting (amber >30k/min, red >60k/min), today's tokens, today's cost, status (`Active`, `Idle`, `Not Metered`), and last active timestamp.<br>• *Gate*: Table test verifies sorting by burn rate descending and filtering by vendor.<br>• *Red Control*: Clicking sort on tokens/min column correctly re-orders rows by rate rather than string alphabetical order. |
| **T034** | **Planned** | `wui` | `wui-tokens` | **Auto-refresh, visibility polling & stale data indicator** (§4.3). Implement 30-second polling using active visibility guard (`document.visibilityState === 'visible'`). Render amber stale marker after 45 s (1.5x) and red warning badge after 90 s (3x). Provide manual Refresh button with loading spinner.<br>• *Gate*: Timer test verifies backgrounded tab suspends polling; timer advance past 45s displays amber indicator.<br>• *Red Control*: When API response is delayed > 90 s, UI fails if red stale warning badge is not displayed. |

---

## 4. Phase 4: Verification & Live Proof (`test` / `proof`)

| ID | Status | Area | Lane | Summary, Gate & Red Control |
|---|---|---|---|---|
| **T040** | **Planned** | `test` | `e2e-proof` | **End-to-end integration test harness** (§6). Synthetic multi-agent test generating transcripts for Claude, Vibe, and Grok alongside an active Agy lane. Invokes `do_spl_token_burn_collect`, verifies database rows in `fleet_token_burn_events`, tests WebSocket push ack, and tests API output at `GET /v1/operator/fleet-tokens`.<br>• *Gate*: `bash csi-spl-orc/src/bash/tests/token-burn-e2e.tst.sh` passes end-to-end with 0 failures.<br>• *Red Control*: Corrupting JSONL token count or disabling collector causes end-to-end test to fail with missing telemetry assertion. |
| **T041** | **Planned** | `proof` | `e2e-proof` | **Live production proof across runner boxes** (§6). Deploy collector across runner boxes; verify live agent lanes (such as active Claude and Agy lanes) appear in the `/monitoring/tokens` dashboard with accurate real-time burn rates and "Not metered" agy rows.<br>• *Gate*: Operator verifies live data matches actual runner session activity within 60-second lag window.<br>• *Red Control*: Manual termination of collector causes dashboard to display red stale-data badge within 90 seconds. |

---

## 5. Parallel Lane Groups (Disjoint File Sets)

To enable concurrent execution without git merge collisions, tasks are partitioned into four disjoint lane groups:

| Lane Group | Task IDs | Target File Paths | Concurrent With |
|---|---|---|---|
| **`hub-tokens`** | `T001`, `T002`, `T010`, `T011`, `T012`, `T013`, `T014` | `csi-spl-rdb/src/sql/postgres/spool-hub/0198_fleet_token_burn.sql`<br>`csi-spl-api/src/go/spool-hub-api/internal/wire/fleet_tokens*.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/fleet_tokens*.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_tokens*.go` | Can build immediately; independent of UI. |
| **`collector-tokens`** | `T020`, `T021`, `T022`, `T023` | `csi-spl-orc/src/bash/run/spl-token-burn-collect.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-token-burn-collect.tst.sh`<br>`csi-spl-orc/cnf/box-crons/box-crons.manifest` | Can build in parallel with `hub-tokens` using wire contract mock. |
| **`wui-tokens`** | `T030`, `T031`, `T032`, `T033`, `T034` | `csi-spl-wui/src/pages/monitoring/tokens.vue`<br>`csi-spl-wui/src/components/monitoring/token-burn/*`<br>`csi-spl-wui/src/utils/monitoring-tokens.mjs` | Starts as soon as Monitoring v1 shell lands (`pages/monitoring.vue`). |
| **`e2e-proof`** | `T040`, `T041` | `csi-spl-orc/src/bash/tests/token-burn-e2e.tst.sh`<br>`csi-spl-wui/src/tests/e2e/monitoring-tokens.test.mjs` | Executes after `hub-tokens`, `collector-tokens`, and `wui-tokens` land. |

---

<!-- version: 0.3.0 · updated: 2026-10-15 · last-edit: 2026-10-15T18:40:00Z -->
