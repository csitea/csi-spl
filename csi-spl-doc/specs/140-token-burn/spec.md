# 140: Real-time token burn per agent type and per agent, on the Monitoring page

Status: **Decided / Phased for build** (Owner answers folded; issue SPL-1986).  
Authority: this file for the architecture and technical requirements; [tasks.md](tasks.md) for the phased build tasks.  
Status vocabulary: [README.md](../README.md) §2.3. Docs only: this spec builds nothing ([README.md](../README.md) §2.4).  
Topic: `e8ae0aad-b8fb-4d3c-8377-072eec9cd404` (HUM-10, prd t1, msgs `ebff27ef`, `f2f947d1`, poll `63182298` msg `86ee1e4e`, poll `aa31a0fe` msg `ca189c3a`).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local folder spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, RLS)
- [005 WUI](../005-spool-wui/spec.md) (Nuxt 3 web interface, theme variables, layout)
- [074 operator workspace](../074-operator-workspace/spec.md) (operator tenant, operatorActor, operatorAuth)
- [121 sales channel & usage ledger](../121-sales-channel/spec.md) (usage_events, model_prices, rdb `0171`, pricing formula)
- [122 capacity scale-out](../122-capacity-scale-out/spec.md) (box load, agent split, hardware scaling)
- [123 cost source fleet_tokens](../123-cost-tracking/spec.md) (`spl-cost-tokens-read.func.sh`, daily transcripts extraction)
- [135 work process](../135-work-process/spec.md) (issue workflow, lane integration rules)
- Monitoring section merged proposal: `/var/spool-hub/dispatch/work/monitoring-panel/merged.md` (tabs as paths, Go hub routes, operators-only fleet tabs)

`<BASE_DOMAIN>`, `<tenant>`, `<workspace_id>`, `<human_id>`, `<org>`, `<app>`, and `<env>` are placeholders. No estate value appears as a literal to copy. Per the owner's wording rule, this specification uses the term **workspace** throughout the narrative, requirements, user stories, and acceptance scenarios; the term **tenant** appears strictly when citing existing code identifiers, database columns, shell functions, terraform resources, or API headers.

---

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic e8ae0aad)

The owner established the requirements in prd workspace `t1`, topic `e8ae0aad-b8fb-4d3c-8377-072eec9cd404`, verbatim:

| msg | text |
|---|---|
| `ebff27ef` | "real time token burn in the monitoring page" |
| `f2f947d1` | "we need to have a real time ( almost ) token burn data per agent type and per agent in the monitoring page" |

Owner decisions from poll `63182298` (msg `86ee1e4e-1d33-4c31-bb68-fc4607585321`):
- **Placement: Choice A, in Monitoring version 1**: A third tab beside Agents and Boxes (`/monitoring/tokens`). The spec must fit into the v1 tab shell (`pages/monitoring.vue`, `utils/monitoring-tabs.mjs`) and plan its implementation lanes to start as soon as the shell lands.
- **Content: Choice A**: Tokens per minute per vendor (agent type) and per agent, plus today's total and cost.

Owner decisions from poll `aa31a0fe` (msg `ca189c3a-8763-486e-9fbd-3efde27322d5`):
- **1 Ingestion Protocol: Choice B, Over the agent's existing live connection**: Telemetry pushed over WebSocket via `lane_op fleet_tokens_push` frame on the box's existing persistent live session (`TLane` frame), avoiding separate HTTP client overhead, ad-hoc Bearer token exchange, or opening secondary TCP connections from runner boxes.
- **2 Retention Window: Choice B, Per-minute detail 30 days, daily totals 1 year**: High-resolution 1-minute bucket records are retained for 30 days; nightly aggregated daily rollups (`fleet_token_burn_daily`) are retained for 365 days (1 year) for comprehensive long-term cost auditing.
- **3 Burn Rate Alerts: Choice B, Colour plus a message in a `#fleet-alerts` channel**: Monitoring UI displays visual badges (amber > 30k/min, red > 60k/min); additionally, when an agent sustains > 60k tokens/min across 3 consecutive minutes, the hub generates an automated alert message posted to the `#fleet-alerts` operator channel.

What they bind:
- **B1 (msg ebff27ef & f2f947d1)**: Provide live ("almost real-time") token consumption telemetry on the Monitoring page.
- **B2 (msg f2f947d1)**: Telemetry must be aggregated along two primary dimensions:
  1. **Per agent type (vendor)**: claude, grok, mistral, agy, qwen.
  2. **Per agent (lane)**: specific running and recent agent instances (e.g. `c-001`, `a-204`, `m-183`).
- **B3 (Poll 63182298 Placement A)**: The interface lives as a first-class tab in Monitoring v1 (`/monitoring/tokens`), using the path-based tab model established in `merged.md` D4.
- **B4 (Poll 63182298 Content A)**: Metrics displayed include:
  - Tokens per minute (input, output, cache read/write).
  - Today's cumulative total tokens.
  - Today's cumulative cost, derived from the canonical price table (`model_prices`, spec 121 / rdb `0171`).
- **B5 (Fleet lane gap)**: Today, `store.UsageLedger` and `usage_events` meter only customer-facing workspace channel posts (`csi-spl-api/src/go/spool-hub-api/internal/hub/usage_events.go:41-81`). Autonomous fleet git lanes are entirely unmetered in real time. This spec closes that visibility gap.
- **B6 (Poll aa31a0fe Q1 Choice B)**: Telemetry is transmitted over the box's existing live WebSocket connection using `lane_op fleet_tokens_push` (matching the pattern in `box_stats.go` and `box_beat.go`).
- **B7 (Poll aa31a0fe Q2 Choice B)**: Retention is 30 days for 1-minute raw buckets and 365 days (1 year) for daily rollups (`fleet_token_burn_daily`).
- **B8 (Poll aa31a0fe Q3 Choice B)**: In addition to dashboard amber/red indicators, the hub evaluates rolling 3-minute sustained burn and posts an automated alert message to `#fleet-alerts` when an agent sustains > 60k tokens/min for 3 consecutive minutes.

---

## 1. Near real-time definition and latency budget

### 1.1 Target lag: <= 60 seconds

The owner specified "a real time ( almost ) token burn data" (msg `f2f947d1`). In distributed systems and LLM agent orchestration, "near real-time" is defined as:

> **Lag <= 60 seconds** from the moment an LLM finishes generating an assistant turn on an agent runner box to the moment that token consumption is reflected on the operator's Monitoring dashboard.

### 1.2 Latency breakdown across the pipeline

The 60-second budget is partitioned across four discrete stages:

```
[ LLM Turn Finished ]
        │  (0 - 5 s: Assistant writes message and usage to local transcript)
        ▼
[ Local Box Transcript / Journal ]
        │  (15 - 30 s: Collector cron/sidecar detects delta via byte offsets)
        ▼
[ Box Token Burn Collector ]
        │  (50 - 200 ms: WebSocket frame lane_op fleet_tokens_push over live connection)
        ▼
[ Spool Hub Ingestion & Store ]
        │  (10 - 30 ms: Ingested into PostgreSQL fleet_token_burn_events)
        ▼
[ Monitoring WUI Dashboard ]
        │  (0 - 30 s: Browser tab poll cycle, active tab visibility)
        ▼
[ Operator Screen Updated ]
```

| Stage | Latency | Mechanism | Rationale |
|---|---|---|---|
| **1. CLI write** | 0–5 s | Agent CLI flushes JSONL stream | Claude, Vibe, Grok append usage objects upon turn completion. |
| **2. Box collection** | 15–30 s | Periodic collector tick (`do_spl_token_burn_collect`) | Scans incremental byte offsets across active session files every 30 s. |
| **3. Wire & DB write** | < 0.3 s | WebSocket `lane_op fleet_tokens_push` + batch DB insert | Reuses existing authenticated live connection; no TCP/TLS handshake overhead. |
| **4. WUI polling** | 0–30 s | Active tab visibility timer | `merged.md` D6 specifies 30 s refresh for the active visible tab. |
| **Total End-to-End** | **15–65 s** | Cumulative budget | P90 <= 45 s; P99 <= 60 s. |

### 1.3 Why this target (and why not faster or slower)

1. **Why not sub-second (< 5 s)?**
   - Agent turns themselves take 5–45 seconds of LLM inference time. Sub-second file tailing on dozens of concurrent worktrees causes excessive disk I/O, CPU overhead, and battery/thermal load on box runners.
   - Browser DOM re-renders every second would degrade operator UI responsiveness without delivering actionable intelligence.
2. **Why not 5–15 minutes?**
   - A looping or runaway agent (e.g. an infinite git rebase loop or unconstrained tool call retry cycle) can burn 50,000–100,000 tokens per minute. At 5 minutes, $50–$150 of API credits can be burned before an operator detects the surge.
   - 60-second visibility allows immediate intervention (e.g. killing or pausing a runaway lane) before material financial loss occurs.

---

## 2. Box collector architecture

### 2.1 Overview & execution model

Each box running agent lanes runs a lightweight, incremental telemetry collector:
- **Named action**: `csi-spl-orc/src/bash/run/spl-token-burn-collect.func.sh`, exposing `do_spl_token_burn_collect`.
- **Invocation**: Triggered every 30 seconds via box cron (`cnf/box-crons/box-crons.manifest`) or folded into the running desk sidecar tick.
- **State storage**: Persistent JSON checkpoint file at `/var/csi/csi-spl/token-burn/collector-state.json`.
- **Transmission**: Pushes delta samples via WebSocket frame `lane_op fleet_tokens_push` over the box's existing persistent live connection (`spool fleet-tokens push` or direct live connection framing), avoiding separate HTTP requests or Bearer token negotiation.

### 2.2 Dynamic user home resolution (hygiene rule)

Per repository distribution hygiene rules (`CLAUDE.md`, `csi-spl-orc/src/bash/features/spawn-agents/tests/test-hygiene.sh`), no literal OS usernames, box hostnames or hardcoded `/home/...` paths appear in code or configurations.
- The agent runner user is resolved dynamically:
  ```bash
  agent_user="${SPOOL_AGENT_USER:-$(sed -n 's/^SPOOL_AGENT_USER=//p' /var/spool-hub/box.env 2>/dev/null)}"
  agent_home="$(getent passwd "${agent_user:-$(id -un)}" | cut -d: -f6)"
  ```
- Because transcripts are written mode `0600` owned by the agent user, the collector executes as the box user using `sudo -n -u "$agent_user"`, or as root, guaranteeing read access without exposing session data globally.

### 2.3 Per-vendor transcript sources & parsing

The collector inspects four distinct vendor session formats:

#### 2.3.1 Claude (`claude`)
- **Location**: `<agent_home>/.claude/projects/<slug>/<sid>.jsonl` and `<sid>/subagents/*.jsonl`.
- **Parsing**: Records matching `.type == "assistant"` and containing `.message.usage`.
- **Counts extracted**:
  - `tokens_in`: `.message.usage.input_tokens`
  - `tokens_out`: `.message.usage.output_tokens`
  - `cache_read`: `.message.usage.cache_read_input_tokens`
  - `cache_write`: `.message.usage.cache_creation_input_tokens`
- **Deduplication invariant**: Claude streams assistant responses, writing multiple progressive chunks sharing the identical `.message.id`. The collector records the **MAX** value seen for each token field per `.message.id`, matching the established logic in `spl-cost-tokens-read.func.sh:109-112`. A naive sum would roughly double measured tokens.

#### 2.3.2 Mistral / Vibe (`mistral`)
- **Location**: `<agent_home>/.vibe/logs/session/unified/<sid>/journal/*.jsonl` and compacted `<sid>/chunks/*.json`.
- **Parsing**: OpenAI-compatible usage structures:
  - `tokens_in`: `.usage.prompt_tokens - (.usage.prompt_tokens_details.cached_tokens // 0)`
  - `tokens_out`: `.usage.completion_tokens`
  - `cache_read`: `.usage.prompt_tokens_details.cached_tokens // 0`
  - `cache_write`: `0`
- **Compaction handling**: Vibe periodically compacts completed journals into `chunks/` and updates `CURRENT` (`csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:55-66`). The collector tracks processed chunk hashes and journal file sizes to ensure no turn is lost or double-counted upon compaction.

#### 2.3.3 Grok (`grok`)
- **Location**: `<agent_home>/.grok/sessions/<slug_uri>/updates.jsonl` or `chat_history.jsonl`, cross-referenced with `<agent_home>/.grok/active_sessions.json`.
- **Parsing**: API response blocks containing standard OpenAI completion `usage` objects (`prompt_tokens`, `completion_tokens`).

#### 2.3.4 Antigravity (`agy`)
- **Location**: `<agent_home>/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (and `transcript_full.jsonl`).
- **Telemetry Extraction**: While session state includes binary protobuf files (`.pb`), Antigravity records full conversation transcripts in JSON Lines format under the conversation brain directory.
- **Parsing**: Lines of type `PLANNER_RESPONSE` contain `token_usage` metrics:
  - `tokens_in`: `.token_usage.input_tokens` (prompt tokens, already excluding cache read tokens).
  - `tokens_out`: `.token_usage.output_tokens` (completion tokens).
  - `cache_read`: `.token_usage.cache_read_tokens` (cached prompt tokens).
  - `cache_write`: `0`.
  - `model`: e.g. `gemini-3.8-flash` (or model name extracted from model config/response).
- **Attribution to Agent**:
  1. Prompt seed path: the initial user prompt step (`step_index: 0`) contains `/var/spool-hub/<agent_id>/lifetime/prompt.txt`.
  2. Workspace database: `<agent_home>/.gemini/antigravity-cli/conversation_summaries.db` contains `workspace_uris` matching the worktree pattern `-wt[0-9]*[/-]([A-Za-z]+-[0-9]+)`.
  3. Direct worktree path regex from transcripts.
- **Reporting & Display Invariant**:
  - Running agy lanes with resolved transcripts report `is_metered: true` with measured token counts.
  - Any agy lane without discovered transcript token counts reports `is_metered: false` with `status: "unmetered"` (tokens NEVER rendered as zero).
  - The unmetered vendor control is now `qwen`.

### 2.4 Incremental read state & deduplication

To prevent reading entire multi-megabyte transcripts on every 30-second cycle:
1. **Byte Offset Tracking**: For each active file path, `collector-state.json` stores:
   - `inode`: To detect file recreation or log rotation.
   - `byte_offset`: Last read position. The collector opens the file, `seek`s to `byte_offset`, and processes only appended bytes.
   - `mtime`: Last modified time.
2. **Rotation / Truncation Reset**: If current file size is less than `byte_offset` or `inode` changed, the offset resets to 0.
3. **Sliding Deduplication Cache**: To guarantee idempotency across restarts or overlapping chunk flushes, the collector maintains a bounded LRU / sliding window (TTL: 2 hours) of processed message/turn UUIDs.

### 2.5 Mapping sessions to agent identities

To attribute token usage to specific lanes, the collector resolves session files to agent identifiers via three prioritized mechanisms:
1. **Registry TSV** (`/var/spool-hub/registry.tsv`): Maps `agent_id` <-> `vendor` <-> `pane_id` <-> `worktree_path`.
2. **Project Slug Regex**: Project directory names follow `-wt[0-9]*-([a-z0-9-]+)$` (e.g. `/opt/csi/csi-spl-wt/a-204` -> `a-204`).
3. **Agent Metadata Records**: `/var/spool-hub/agents/<agent_id>.json`.

---

## 3. Wire protocol and database store

### 3.1 Architectural analysis: dedicated fleet table vs usage ledger

| Criterion | Option S1: Overload `usage_events` (rdb `0171`) | Option S2: Dedicated `fleet_token_burn_events` (Recommended) |
|---|---|---|
| **Domain Scope** | Designed for tenant customer billing of channel visitor turns (`tenant_id`, `turn_id`, `channel_id`). | Purpose-built for fleet runner infrastructure telemetry. |
| **Tenant Isolation** | Requires dummy synthetic tenant (e.g. `'system'` or `'operator'`), violating business ledger purity. | Explicitly bound to operator scope via RLS; completely isolated from customer billing. |
| **Unique Constraints** | Enforces `UNIQUE (tenant_id, turn_id, kind) WHERE turn_id IS NOT NULL`. Git lanes have no turn IDs. | Natural composite key: `UNIQUE (box_tag, agent_id, minute_bucket)`. |
| **Immutability & Retention** | `usage_events` is append-only with strict trigger preventing deletes (`rdb 0171:136-145`). High-frequency 1-minute telemetry cannot be pruned. | High-frequency telemetry requires automatic retention pruning (30-day TTL on 1-minute data, 365-day TTL on daily rollups). |
| **Query Performance** | Pollutes billing ledger with hundreds of thousands of runner telemetry rows. | Dedicated time-series table indexed on `(minute_bucket, vendor, agent_id)` ensures sub-50ms dashboard reads. |

**Decision**: Adopt **Option S2**. Fleet runner telemetry must not be conflated with the customer financial ledger.

### 3.2 Schema specification: `fleet_token_burn_events` (rdb migration `0199`)

Built as `0199_fleet_token_burn.sql` (0198 went to `0198_human_rail_order_monitoring.sql` first); what differs from the sketch below is listed in section 3.7.

```sql
-- 0198_fleet_token_burn.sql - near real-time fleet runner token telemetry.
-- Operators-only visibility.

CREATE TABLE fleet_token_burn_events (
    id               bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    box_tag          text          NOT NULL CHECK (box_tag ~ '^[a-z0-9_-]{1,32}$'),
    agent_id         text          NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 100),
    vendor           text          NOT NULL CHECK (vendor IN ('claude', 'mistral', 'grok', 'agy', 'qwen')),
    model            text          NULL CHECK (length(model) BETWEEN 1 AND 200),
    minute_bucket    timestamptz   NOT NULL,
    tokens_in        bigint        NOT NULL DEFAULT 0 CHECK (tokens_in >= 0),
    tokens_out       bigint        NOT NULL DEFAULT 0 CHECK (tokens_out >= 0),
    cache_read       bigint        NOT NULL DEFAULT 0 CHECK (cache_read >= 0),
    cache_write      bigint        NOT NULL DEFAULT 0 CHECK (cache_write >= 0),
    cost_micros      numeric(20,6) NOT NULL DEFAULT 0 CHECK (cost_micros >= 0),
    currency         text          NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
    is_metered       boolean       NOT NULL DEFAULT true,
    created_at       timestamptz   NOT NULL DEFAULT now()
);

-- Natural key preventing duplicate bucket writes
CREATE UNIQUE INDEX idx_fleet_tokens_natural ON fleet_token_burn_events (box_tag, agent_id, minute_bucket);

-- Aggregation indices for dashboard reads
CREATE INDEX idx_fleet_tokens_time_vendor ON fleet_token_burn_events (minute_bucket, vendor);
CREATE INDEX idx_fleet_tokens_time_agent ON fleet_token_burn_events (minute_bucket, agent_id);

-- Row Level Security: operators only
ALTER TABLE fleet_token_burn_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_token_burn_events FORCE ROW LEVEL SECURITY;

CREATE POLICY operator_scope ON fleet_token_burn_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

### 3.3 Price resolution from `model_prices`

At ingestion time, the hub queries `model_prices` (`rdb 0171:74-84`, populated from cnf by `do_spl_model_prices_sync`) to calculate `cost_micros`:
- Unit cost for `llm_tokens_in`, `llm_tokens_out`, `llm_tokens_cache_read`, and `llm_tokens_cache_write` in force at `minute_bucket`.
- Formula:
  $$\text{cost\_micros} = \sum (\text{tokens} \times \frac{\text{micros\_per\_million}}{10^6})$$
- Storing calculated `cost_micros` at write time guarantees that historical burn charts remain immutable even if vendor pricing models change in the future.

### 3.4 Wire protocol: WebSocket lane_op fleet_tokens_push over existing live connection

Telemetry is transmitted over the authenticated live connection between runner boxes and the Spool Hub (the `TLane` WebSocket frame path, matching the architectural pattern established in `internal/hub/box_stats.go:20-25` and `internal/hub/box_beat.go:17-25`).

- **Framing**: `wire.TLane` frame carrying `lane_op: "fleet_tokens_push"`.
- **Identity & Authentication**: The writing `box_tag` is derived directly from the authenticated session context (the box session's peer identity or agent session), never trusted from an arbitrary JSON payload field.
- **Client Invocation**: Triggered from the box collector action via `spool fleet-tokens push --json -` or internal CLI client framing.
- **Push Payload Schema**:
  ```json
  {
    "type": "lane",
    "lane_op": "fleet_tokens_push",
    "samples": [
      {
        "agent_id": "c-001",
        "vendor": "claude",
        "model": "claude-3-5-sonnet-20241022",
        "minute": "2026-10-15T10:40:00Z",
        "tokens_in": 12450,
        "tokens_out": 850,
        "cache_read": 34000,
        "cache_write": 4200,
        "is_metered": true
      },
      {
        "agent_id": "a-204",
        "vendor": "agy",
        "model": null,
        "minute": "2026-10-15T10:40:00Z",
        "tokens_in": 0,
        "tokens_out": 0,
        "cache_read": 0,
        "cache_write": 0,
        "is_metered": false
      }
    ]
  }
  ```
- **Hub Ack Response Frame**:
  ```json
  {
    "type": "ack",
    "lane_op": "fleet_tokens_push",
    "inserted": 2,
    "at": "2026-10-15T10:40:05Z"
  }
  ```
- **Upsert Semantic**: Database write performs `ON CONFLICT (box_tag, agent_id, minute_bucket) DO UPDATE SET tokens_in = EXCLUDED.tokens_in, tokens_out = EXCLUDED.tokens_out, cache_read = EXCLUDED.cache_read, cache_write = EXCLUDED.cache_write, cost_micros = EXCLUDED.cost_micros` ensuring safe idempotent retries across ticks.
- **Error Handling**: Malformed payloads or invalid vendor strings return `wire.TError` with code `bad_frame` / `bad_samples` (status 400) without terminating the persistent WebSocket connection.

### 3.5 Hub read route for Monitoring tab

- **Route**: `GET /v1/operator/fleet-tokens`
- **Parameters**:
  - `window`: `1h` (default), `24h`, `today`
  - `vendor`: `all` (default) or specific vendor filter
- **Response Structure**:
  ```json
  {
    "as_of": "2026-10-15T10:42:00Z",
    "summary": {
      "burn_rate_tokens_per_min": 45200,
      "burn_rate_cost_per_hour": 3.84,
      "today_total_tokens": 18450200,
      "today_total_cost": 42.15,
      "currency": "EUR",
      "active_agents": 18,
      "unmetered_agents": 3
    },
    "by_vendor": [
      {
        "vendor": "claude",
        "active_agents": 12,
        "burn_rate_tokens_per_min": 38100,
        "today_tokens_in": 8200000,
        "today_tokens_out": 640000,
        "today_cache_read": 8900000,
        "today_cache_write": 450000,
        "today_total_tokens": 18190000,
        "today_cost": 40.50,
        "status": "metered"
      },
      {
        "vendor": "agy",
        "active_agents": 3,
        "burn_rate_tokens_per_min": null,
        "today_total_tokens": null,
        "today_cost": null,
        "status": "unmetered"
      }
    ],
    "by_agent": [
      {
        "agent_id": "c-001",
        "vendor": "claude",
        "model": "claude-3-5-sonnet-20241022",
        "box": "sat",
        "burn_rate_tokens_per_min": 4200,
        "today_total_tokens": 1420500,
        "today_cost": 3.12,
        "is_metered": true,
        "last_active": "2026-10-15T10:41:35Z"
      },
      {
        "agent_id": "a-204",
        "vendor": "agy",
        "model": null,
        "box": "sat",
        "burn_rate_tokens_per_min": null,
        "today_total_tokens": null,
        "today_cost": null,
        "is_metered": false,
        "last_active": "2026-10-15T10:40:19Z"
      }
    ],
    "history": [
      {
        "minute": "2026-10-15T10:41:00Z",
        "tokens": 42100,
        "cost": 0.064
      }
    ]
  }
  ```

### 3.6 Data retention policy

To satisfy owner decision 2 = B (poll `aa31a0fe`, msg `ca189c3a`) while preventing unbounded storage growth:
1. **1-minute raw buckets**: Retained for **30 days**. Provides granular high-resolution telemetry for auditing and debugging across the entire previous month.
2. **Daily rollups**: Computed nightly by `do_spl_cost_rollup_daily` and stored in `fleet_token_burn_daily` (retained for **365 days / 1 year**).
3. **Automated purge**: Daily retention sweep job (`sweepFleetTokens`) executes:
   ```sql
   DELETE FROM fleet_token_burn_events WHERE minute_bucket < now() - INTERVAL '30 days';
   DELETE FROM fleet_token_burn_daily WHERE day_bucket < now() - INTERVAL '365 days';
   ```

### 3.7 As built (lane `hub-tokens`, SPL-2036)

Where the hub differs from sections 3.2 to 3.6 and 4.4.2, and why. The code is
`internal/{wire,store,hub}/fleet_tokens*.go` and rdb `0199_fleet_token_burn.sql`.

- **Migration 0199**, two tables: `fleet_token_burn_events` (the minutes) and
  `fleet_token_burn_daily` (the rollups), both operator-scope RLS only.
  Extra columns: `priced` (false when a counted kind had no price row; cost
  is then 0), `updated_at`. CHECKs: `minute_bucket` is on the minute; an
  unmetered row carries zero counts. `currency` defaults to `USD`, the
  currency of every cnf `model_prices` row; costs are never converted.
- **Framing**: the samples ride the lane frame's `lane` field, like every
  other lane op: `{"type":"lane","msg_id":"<uuid>","lane_op":"fleet_tokens_push","lane":{"samples":[...]}}`.
  The ack is a lane frame on the same `msg_id` whose `lane` is
  `{"type":"ack","lane_op":"fleet_tokens_push","inserted":n,"at":"..."}`.
  Refusals are error frames on that `msg_id`: `bad_samples` (400) for a
  missing `agent_id` / `vendor` / `minute`, an unknown field or vendor, a
  minute ahead of the hub's clock by more than 2 min or older than 30 days,
  two samples of one `(agent_id, minute)`; `bad_frame` for another
  `fleet_tokens_*` op or no `msg_id`; `not_operator` (403) for a box outside
  the operator workspace (the rows are the instance's). The connection stays
  open. `is_metered` absent reads true; an unmetered sample (vendor `qwen`, or
  any unmetered lane) must say false.
- **Pricing**: vendor to `model_prices.provider`: claude `anthropic`,
  mistral `mistral`, grok `xai`, agy `google`, qwen `qwen`; a model's `[1m]`-style suffix
  and an 8-digit snapshot date (`claude-haiku-4-5-20251001` prices as
  `claude-haiku-4-5`, SPL-2323) are dropped for the lookup. The price row in
  force at the minute wins. mistral's model is vibe's alias
  (`mistral-large`), priced at Mistral's list price (cnf `model_prices`).
- **Reprice** (SPL-2405): a minute stored while its model had no price row
  stays `priced=false`, cost 0, until it is repriced once:
  `ENV=<env> TOKEN_REPRICE_MODELS=<m1,m2> TOKEN_REPRICE_FROM=<YYYY-MM-DD> ./run -a do_spl_token_burn_reprice`
  (csi-spl-orc; `DRY_RUN=1` by default, rolled back). It runs
  `spool fleet-tokens-reprice`, the same pricer as the push, on the hub DB
  as the env's service account: only metered unpriced rows of the named
  stored models at or after the from are priced, in one transaction that
  re-rolls the daily rows from that day; a priced row is never touched, and
  a re-run prices 0 rows.
- **Read route**: both doors of the fleet load route (the operator
  workspace's admin session, or the operator service account's Bearer id
  token). Burn rates are the mean of the last 5 full minutes; the answer adds
  `fresh_tokens_per_min`, `burn_rate_1m_tokens_per_min`, `priced`,
  `unpriced_agents`, `today_cache_read` and history `fresh`.
- **Rollups**: the hub's retention sweep (`sweepFleetTokens`) rolls whole UTC
  days (yesterday, today, and every day it is about to prune) into
  `fleet_token_burn_daily`, then drops minutes of days older than 30 days and
  rollups older than 365 days. No orc action is needed.
- **Surge measure**: fresh tokens (in + out + cache write), not the total.
  Measured 2026-10-15 on 3 live claude transcripts (10 minutes): the total
  with cache reads was 0.14M to 1.4M tokens/min per lane in normal work, so
  `> 60k` total would alert on every busy lane; fresh tokens were 5k to 93k
  per minute with no 3 consecutive minutes above 60k. The dashboard keeps the
  total as `burn_rate_tokens_per_min` and shows the fresh rate beside it.
- **Alert**: posted as a HUB-0 note, its own topic, in the operator
  workspace's `#fleet-alerts`. A missing channel is logged and never
  created. The cool-off state is per hub process; the alert's `msg_id` is
  fixed per lane and 30-minute slot, so two hub instances never post the
  same slot twice. The body has no "last reported task" (the hub does not
  know it) and gives the cost in the price currency.

### 3.8 Paid items and the effective price (SPL-2342)

Owner, t1 `e8ae0aad` msg `9f549412`: "I should report the paid subscriptions
and you would calculate the price per token". List prices (3.3) stay as they
are; this adds what was really paid. Code: `internal/{store,hub}/fleet_token_paid*.go`,
rdb `0205_fleet_token_paid.sql` (operator-scope RLS, like 0199).

**What is entered.** One row per paid item, by the operator (the operator
workspace's admin or the operator service account) through
`/v1/operator/fleet-tokens/paid` (GET list, POST, PATCH `/{id}`, DELETE
`/{id}`). Never a cnf or code literal, never seeded.

| field | meaning |
|---|---|
| `vendor` | claude, mistral, grok, agy or qwen |
| `kind` | `subscription` or `topup` |
| `plan_label` | free text, e.g. "Max 20x" |
| `quantity` | units bought (default 1; 3 for three seats) |
| `amount` | ONE unit's price; the item paid `amount * quantity` |
| `currency` | USD, or a currency the hub holds an `fx_rates` rate for (rdb 0200) |
| `period_start`, `period_end` | the UTC days paid for, `[start, end)`: the end is the first day NOT paid for |
| `note` | free text, up to 2000 characters |

**How the effective price is computed.**
`GET /v1/operator/fleet-tokens/effective?from=YYYY-MM-DD&to=YYYY-MM-DD`
(`to` excluded; default the last 30 whole UTC days; at most 366 days). It is
a sibling read, not a field of the 3.5 read: that one is polled every few
seconds over minutes; this one spans whole paid periods and the exchange
rates, so it is asked for once.

1. Each item's total, converted to USD at the `fx_rates` rate of its
   `period_start` (else the last rate before it, else the first after it),
   is spread evenly over its days: `amount * quantity / days / rate` a day.
2. For each vendor, the shares of every item day inside `[from, to)` are
   summed: `paid_usd`; `paid_per_day_usd` is that sum over the range's days.
3. The vendor's tokens of the same days (a day still in the minute table is
   read from its minutes, an older one from its rollup) are input + output +
   cache write; cache reads are returned as `cache_read`, never divided in.
4. `effective_usd_per_mtok = paid_usd / tokens * 1e6`, beside
   `list_usd_per_mtok` (the list-price cost of the same days, per million).

Each vendor row has a `status`: `effective`; `list_only` (no paid item in
the range); `not_metered` (paid, but no tokens logged, e.g. agy: only the
daily share shows); `no_fx_rate` (an item's currency has no rate, so no sum).
`items` lists each item's share, days and the rate it used. A day paid for
before metering started still counts its share, so a range starting before
the first metered day reads high.

**Extension point.** The owner's "additional parameters" are deferred.
`fleetPaidDailyUSD` in `store/fleet_token_paid.go` is the one function a
weighting rule (a cap, a discount, an unused remainder) changes.

**From a box.** `ENV=<env> ./run -a do_spl_hub_fleet_paid` (csi-spl-orc)
reads the items (`PAID_CMD=list`) or the effective price (`PAID_CMD=effective
FROM= TO=`) through the hub as the env's project service account; `create`
and `delete` are for test fixtures and are dry runs unless `DRY_RUN=0`.

**In the WUI (SPL-2567).** Monitoring -> Tokens carries a Paid card under
the tables, for the operator admin only (the Tokens tab's gate; a 403 draws
nothing). It lists the items with add, edit and delete: a form with the
fields above, checked as the hub checks them before anything is sent (the
end after the start, an amount above 0, USD or a currency from
`GET /v1/tenant/fx/currencies`), the hub's own refusal text shown as it
comes. Under it, the effective price per 1M tokens per vendor beside the
list price of the same days, read once on open and after each change, never
polled: `not_metered` reads "Not metered" with the daily share, a vendor with
tokens but a list cost of 0 (no price held, grok) reads "not priced", never
$0.00, and cache reads stay their own column. Code:
`csi-spl-wui/src/components/monitoring/token-burn/{PaidItemsCard,PaidItemForm,EffectivePriceTable}.vue`
(their own chunk), `src/utils/monitoring-paid.mjs` (helpers and the mock
hub), the lazy client's `fleetPaid(op, ...)`. Tests:
`tests/unit/monitoring-paid.test.mjs`, the paid round of
`tests/e2e/monitoring-costs.test.mjs`.

### 3.9 Grok burn: named apart, per turn, backfilled (SPL-2461)

Owner HUM-10, t1 efd618b2 (msgs 2439f1b6 "Collect the agent token statistics
for the Grok vendor", 5e9c69c4 "integrate those into the monitoring page
costs tab", c1cf9b0b "establish the process for collecting them on a regular
basis").

**Why grok went missing.** The minute buckets key on `(agent, minute)` in
the collector and `(box_tag, agent_id, minute_bucket)` on the hub, and the
daily rollup on `(day_bucket, box_tag, agent_id)`; the vendor is a column,
not part of the key. A grok session whose cwd named no grok lane (the GC
agent's main checkout, `/opt`, a claude lane's worktree or scratch dir) was
named `unattributed` or `c-NNN`, like claude's rows, so its tokens were
summed into the claude bucket of the same minute and the day's row took
the vendor of the latest minute: on 2026-10-17 prd held 7 grok minute rows
(5 `unattributed`) and no grok daily row. Second, a grok session first seen
with turns that ended before the window took its whole counters as the
baseline, so a lane's new turn after a long idle was never counted.

**Naming** (`TOKEN_BURN_GROK_AWK` in `spl-token-burn-collect.func.sh`, one
awk function for the live tick, the backfill and the daily cost source),
from the url-encoded cwd under `~/.grok/sessions/`:

| cwd | agent_id |
|---|---|
| a `<x>-wt/<id>` worktree (or a claude scratch dir naming `<x>-wt-<id>`), `<id>` a grok id `g-NNN` or legacy `GRK-NNN` | `<id>` |
| the same, `<id>` another vendor's lane (`c-296`) | `c-296 (grok)` |
| no lane id (`/opt`, the main checkout, a home) | `unattributed (cwd <dir>)`, every `/tmp` dir as `/tmp` |

**Per turn.** Each `usage.json` turn carries its own counters, and they sum
to the session's (717 of 717 sessions on one box, 2026-10-18). A session first
seen takes as its baseline the turns that ended before the window; its
newer turns count.

**Backfill, once per box.** `./run -a do_spl_token_burn_grok_backfill`
(csi-spl-orc, `DRY_RUN=1` by default: frames under
`<TOKEN_BURN_STATE_DIR>/backfill`, nothing pushed) reads every
`usage.json` of the agent user's and the box user's homes, one bucket per
agent and UTC minute from the turns' counters, and pushes them with
`DRY_RUN=0` as `fleet_tokens_push` frames of at most 2000 samples. The hub
replaces a bucket on its natural key, so a re-run writes the same rows. The
hub refuses a minute older than 30 days: turns older than
`TOKEN_BURN_BACKFILL_DAYS` (29) are counted and skipped, and the history
before them is not in the hub. A session that moved inside the live window
is the live collector's and is skipped. The next retention sweep rolls the
pushed minutes into `fleet_token_burn_daily`.

**Regular basis.** The every-minute collector cron
(`# csi-spl:box-cron:token-burn`, `token-burn-collect-cron.sh`) is the
collection; no new job. The daily cost source `fleet_tokens`
(`do_spl_cost_tokens_read`, spec 123 4.3) adds each grok lane's turns of the
day from the same homes (`spl_cost_tokens_grok`) and each Antigravity lane's
turns of the day (`spl_cost_tokens_agy`), so Monitoring -> Costs lists grok's
and agy's tokens beside claude's; a grok or agy lane with rows there is no
longer "unmetered".

**No price.** `model_prices` holds no `xai` or `google` row: grok and agy
minutes are stored `priced=false`, cost 0, and the Tokens tab and the Costs
card say "not priced", never a cost of 0. A price row added later is applied with
`do_spl_token_burn_reprice` (3.7).

### 3.10 Each workspace sees its own token costs (SPL-3565)

Owner HUM-10, t1 `f3ed0eed` (#spool-hub-bugs), msg `1bb1f74b`: "each of the
workspaces should be able to distinguish between the token costs of it's own
workspace - all of the roles should be able to check those costs"; msg
`96d69790`: "but the admin of the spoool-hub should be able to see the costs
of the other workspaces as well". Screenshot msg `407b4e7c`: a customer
workspace's Costs tab read "No cost data yet this month" while lanes worked
for it all morning.

**Measured before the build (prd, 2026-10-26 ~14:00Z, n=1 read each).**
Every October `cost_lines` row was an estate row (`tenant_id` NULL; sources
`fleet_tokens.<box>` and `agent_hours.<box>`, counts only, the latest day
10-25: the daily feed has no today). `fleet_token_burn_events` had no
workspace column: the three lanes working for that workspace that day
(c-093, c-425, a-531, one box) had 28.9M, 42.6M and 47.0M tokens at 11.60,
13.89 and 0.00 USD list price (agy unpriced), all operator rows. Their
`fleet_lanes` topic, the one lane-to-workspace mapping (spec 153 3.4 / 3.7):
c-093 named a topic of that workspace, c-425 and a-531 named none.
`costs.read` was biz_owner's and admin's (rdb 0166), so a regular_user got
403; the operator workspace's biz_owner read the whole estate.

**Attribution (write time).** Before the hub stores a push, each sample's
lane is looked up in the operator workspace's lane map (fleet `main`, the
row of that agent at the pushing box); the workspace that holds the lane's
topic (each workspace read in its own scope, the operator's first) is the
minute's `work_tenant` (rdb `0229`, `hub/workspace_tokens.go`). An operator
topic, no topic, no row or an unknown topic leave it NULL: the operator
workspace's own work. A failed lookup never fails the push. The daily
rollup carries the day's latest minute's value. A box never sends the field
(`json:"-"`, the strict decoder refuses it). Rows written before 0229 stay
NULL: no history is rewritten.

**Read.** `GET /v1/tenant/costs` (spec 123 5.1) adds, for a workspace view,
the month's burn of the lanes working for that workspace: one part per
vendor, source `fleet_tokens`, kind `tokens`, units = every token (cache
reads included), `usd_micros` 0 and `list_value_micros` = the burn's list
price (USD rows only), since a subscription's token volume is never a paid
amount (spec 123 Q-4). Days the minutes still hold are read from the
minutes, older days from the rollup, each day once
(`store/workspace_tokens.go`). The operator workspace's own view is its NULL
rows.

**Who sees what.**

| caller | answer |
|---|---|
| any member role of a workspace (rdb 0229 grants `costs.read` to every member role; not demo_user, channel_guest or time_accountant) | `scope: workspace`: its own cost lines plus its own lanes' burn |
| the operator workspace's members other than its admins (e.g. a customer seated there as regular_user, and its biz_owner) | `scope: workspace`: the operator workspace's own rows and burn, never the estate, never another workspace's |
| the operator workspace's `admin` (the spool-hub admin) | `scope: estate` (spec 123), and `workspaces`: every workspace's burn per vendor (tokens, list price, days) |

The estate's own `fleet_tokens.<box>` count rows are unchanged, and the burn
is never added to a paid total (3.1).

Tests (memory and Postgres): `hub/workspace_tokens_test.go`
(TestWorkspaceTokenCosts W1-W6), `hub/cost_read_test.go` (TestCostReadRoles,
TestCostReadEstateScope), `store/workspace_tokens_test.go`,
`rbac/rbac_test.go` (TestCostsReadEveryMemberRole).

---

## 4. The Monitoring page tab (`/monitoring/tokens`)

### 4.1 Route & tab shell integration

Per poll `63182298` (msg `86ee1e4e`) and `merged.md` D4:
- Path: `/monitoring/tokens`
- Rendered within the Monitoring v1 shell (`pages/monitoring.vue`).
- Tab item in `utils/monitoring-tabs.mjs`:
  ```javascript
  {
    id: 'tokens',
    label: 'monitoring.tabs.tokens',
    to: '/monitoring/tokens',
    operatorOnly: true
  }
  ```
- Access control: Guarded by `isOperatorAdmin`. Non-operator members viewing `/monitoring` see only the public tabs (Agents and Boxes); `/monitoring/tokens` returns a 403 or redirects cleanly to `/monitoring/agents`.

### 4.2 Tab user interface components

The page layout consists of three primary visual sections:

```
+------------------------------------------------------------------------------------+
|  [Summary Strip]: 18 Agents Live | 2 Boxes Online | Load 42% | Paused: none        |
+------------------------------------------------------------------------------------+
|  [ Tabs ]:   Agents   |   Boxes   |   [ Tokens (Active) ]                              |
+------------------------------------------------------------------------------------+
|  TOP KPI CARDS                                                                     |
|  ┌─────────────────────┐ ┌─────────────────────┐ ┌───────────────────────────────┐ |
|  │ Fleet Burn Rate     │ │ Today's Total       │ │ Today's Fleet Cost            │ |
|  │ 45.2k tokens/min    │ │ 18.45M tokens       │ │ €42.15                        │ |
|  │ (In: 12k · Out: 2k) │ │ (Cache hit: 48%)    │ │ (15 metered / 3 unmetered)    │ |
|  └─────────────────────┘ └─────────────────────┘ └───────────────────────────────┘ |
+------------------------------------------------------------------------------------+
|  TOKEN BURN BY VENDOR (AGENT TYPE)                                                 |
|  Vendor    Active  Tokens/Min     Today's Tokens   Today's Cost   Status           |
|  Claude        12  38.1k/min      14.2M            €34.10         Metered          |
|  Mistral        3   7.1k/min       4.2M             €8.05         Metered          |
|  Agy            3  —              —                —              [Not Metered] ⚠  |
|  Grok           0  0/min          0                €0.00          Idle             |
|  Qwen           0  0/min          0                €0.00          Idle             |
+------------------------------------------------------------------------------------+
|  TOKEN BURN PER AGENT (LANES)                                 [Filter: All ▼]      |
|  Agent    Vendor   Box  Model          Tokens/Min  Today Tokens Today Cost Status  |
|  c-001    claude   sat  Sonnet 3.5     4,200/min   1.42M        €3.12      Active  |
|  c-198    claude   sat  Sonnet 3.5     3,800/min   890k         €1.95      Active  |
|  m-183    mistral  sat  Codestral      2,100/min   450k         €0.45      Active  |
|  a-204    agy      sat  —              —           —            —          [Not] ⚠ |
+------------------------------------------------------------------------------------+
```

### 4.3 Refresh model & stale data indicator

Conforming strictly to `merged.md` D6 and D7:
1. **Active Tab Only**: Polling occurs strictly every **30 seconds** while `/monitoring/tokens` is the active route AND `document.visibilityState === 'visible'`. Hidden background tabs suspend network calls.
2. **Manual Refresh**: A manual "Refresh" button provides instantaneous re-fetching.
3. **Stale Data Marker**:
   - `lag <= 45 s` (1.5x timer): Normal display.
   - `45 s < lag <= 90 s`: Amber warning dot beside the timestamp ("Updated 48s ago").
   - `lag > 90 s` (3x timer): Red warning badge ("Data stale: hub unreachable or collector paused").
4. **Resilience**: Full empty state (when no lanes are active) and error state with an interactive "Retry" button.

### 4.4 Sustained burn rate alerts & `#fleet-alerts` channel notification

Per owner decision 3 = B (poll `aa31a0fe`, msg `ca189c3a`), the platform implements dual-layer alerting: visual indicators in the Monitoring dashboard and automated proactive alerts to the `#fleet-alerts` operator channel.

#### 4.4.1 Visual threshold highlights in UI
In both the vendor table and the agent lane breakdown table:
- **Normal burn**: `< 30,000 tokens/min` (standard theme typography).
- **Elevated burn**: `30,000` to `60,000 tokens/min` (Amber warning badge).
- **Surge burn**: `> 60,000 tokens/min` (Red alert badge with pulsing warning icon).

#### 4.4.2 Automated Spool Hub alert to `#fleet-alerts`
When an LLM agent enters an infinite loop, recursive rebase cycle, or runaway tool failure, rapid alerting prevents material API cost:
1. **Detection Window**: Upon ingestion of minute samples, the hub tracks rolling token burn per agent over a 3-minute sliding window (`minute_bucket`, `minute_bucket - 1m`, `minute_bucket - 2m`).
2. **Trigger Invariant**: An alert fires if and only if an agent sustains **> 60,000 tokens/min across 3 consecutive minutes**, counting fresh tokens (in + out + cache write; section 3.7).
3. **Destination Channel**: The alert is posted directly into the `#fleet-alerts` channel in the operator workspace as a high-visibility spool message.
4. **Message Format**:
   ```markdown
   :warning: **Fleet Token Surge Alert**: Agent `<agent_id>` (`<vendor>` / `<model>`) on box `<box>` has sustained high token burn (>60k tokens/min) for 3 consecutive minutes:
   - Minute 1: 64,200 tokens/min
   - Minute 2: 71,500 tokens/min
   - Minute 3: 68,900 tokens/min
   Cumulative cost in window: €0.48. Last reported task: `<task_id>`. Immediate operator inspection recommended.
   ```
5. **Throttling & Cool-off**: Once an alert fires for an agent, further alerts for that specific agent are silenced for **30 minutes** unless burn rate drops below 30,000 tokens/min and subsequently surges again.

---

## 5. Privacy and security invariants

To protect codebase integrity and operational secrecy:

- **Invariant P1 (Zero Transcript Content)**: The token telemetry pipeline handles strictly scalar counts and metadata (`box`, `agent_id`, `vendor`, `model`, `tokens_in`, `tokens_out`, `cache_read`, `cache_write`). **Under no circumstances does prompt text, completion text, tool call arguments, or file content leave the local runner box**.
- **Invariant P2 (Strict Operator Isolation)**: Fleet token burn rows stay operator-scope under PostgreSQL RLS, and the per-lane burn (the Tokens tab) is the operator workspace administrators' only. Since 3.10 a workspace's members read one sum per vendor of the lanes working for their own workspace through the hub's cost route, never a lane id, box or another workspace's burn; visitors and guest channels read none.
- **Invariant P3 (Sanitized Logs & Hygiene)**: No raw token totals are written to public logs (matching `spl-cost-tokens-read.func.sh:74-81`). Telemetry endpoints and scripts adhere strictly to distribution hygiene: dynamic user home lookups, no personal email addresses, and org-neutral identifiers.

---

## 6. Build split: independent disjoint lanes

To ensure zero merge collisions with the ongoing Monitoring v1 shell and Agents/Boxes migration (`merged.md` §4), the token burn implementation is partitioned into four independent lanes with completely disjoint file paths:

```
[ Monitoring v1 Shell (ongoing) ]
  pages/monitoring.vue
  utils/monitoring-tabs.mjs
  components/AgentCard.vue
  components/BoxCard.vue
         │
         ▼ (Shell lands; opens third tab slot)
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                TOKEN BURN LANES                                  │
├──────────────────────┬──────────────────────┬──────────────────┬─────────────────┤
│ Lane 1: hub-tokens   │ Lane 2: collector    │ Lane 3: wui-tab  │ Lane 4: e2e     │
│ (rdb / Go API)       │ (orc / bash / cron)  │ (Nuxt / Vue)     │ (test / proof)  │
├──────────────────────┼──────────────────────┼──────────────────┼─────────────────┤
│ 0198_fleet_token.sql │ spl-token-burn-      │ pages/monitoring/│ monitoring-     │
│ internal/hub/        │   collect.func.sh    │   tokens.vue     │   tokens.test   │
│   fleet_tokens.go    │ spl-token-burn-      │ components/      │ live-proof-     │
│ internal/store/      │   collect.tst.sh     │   monitoring/    │   tokens.sh     │
│   fleet_tokens.go    │ box-crons.manifest   │   TokenBurn*.vue │                 │
└──────────────────────┴──────────────────────┴──────────────────┴─────────────────┘
```

| Lane | Domain | File Set (Disjoint) | Dependencies |
|---|---|---|---|
| **Lane 1: `hub-tokens`** | `api` / `rdb` | `csi-spl-rdb/src/sql/postgres/spool-hub/0198_fleet_token_burn.sql`<br>`csi-spl-api/src/go/spool-hub-api/internal/wire/fleet_tokens*.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_tokens*.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/fleet_tokens*.go` | Independent. Implements WebSocket `lane_op fleet_tokens_push` frame handler, 30-day raw / 365-day daily retention pruning sweep, GET route, and 3-minute sustained burn evaluator posting to `#fleet-alerts`. |
| **Lane 2: `collector-tokens`** | `orc` | `csi-spl-orc/src/bash/run/spl-token-burn-collect.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-token-burn-collect.tst.sh`<br>`csi-spl-orc/cnf/box-crons/box-crons.manifest` | Depends on Lane 1 WebSocket frame schema `lane_op fleet_tokens_push`. Pushes samples via box CLI live session. |
| **Lane 3: `wui-tokens`** | `wui` | `csi-spl-wui/src/pages/monitoring/tokens.vue`<br>`csi-spl-wui/src/components/monitoring/token-burn/*`<br>`csi-spl-wui/src/utils/monitoring-tokens.mjs` | Requires Monitoring v1 tab shell to land first. Implements visual badges (amber >30k/min, red >60k/min) and vendor/agent breakdown tables. |
| **Lane 4: `e2e-proof`** | `test` / `proof` | `csi-spl-wui/src/tests/e2e/monitoring-tokens.test.mjs`<br>`csi-spl-orc/src/bash/tests/token-burn-e2e.tst.sh` | Runs after Lanes 1, 2, and 3 land. |

---

## 7. Decided owner choices (poll aa31a0fe, msg ca189c3a)

The owner (HUM-10, t1 topic `e8ae0aad-b8fb-4d3c-8377-072eec9cd404`, msg `ca189c3a-8763-486e-9fbd-3efde27322d5`, poll form `aa31a0fe-fc26-4099-9b16-bc90670c99db`) answered all three questions, selecting **Option B** for each:

### Question Q1. Ingestion protocol from box to hub
- **Decided: Option B — WebSocket `lane_op fleet_tokens_push` over existing live connection**.
  - *Adopted In*: §1.2, §2.1, §3.4, and Tasks T002, T011, T022.
  - *Rationale*: Reuses the authenticated persistent CLI session (`TLane` frame), eliminating ad-hoc HTTP Bearer token negotiation, secondary TLS handshakes, and runner outbound port proliferation.

### Question Q2. Storage & aggregation granularity
- **Decided: Option B — Per-minute detail 30 days, daily totals 1 year (365 days)**.
  - *Adopted In*: §0, §3.1, §3.6, and Tasks T001, T013.
  - *Rationale*: Guarantees a full 30-day operational debugging window with minute-level precision across all runner boxes, with a 1-year audit trail for financial trend analysis.

### Question Q3. Token burn alert notifications
- **Decided: Option B — Visual colour on page plus automated message in `#fleet-alerts` channel**.
  - *Adopted In*: §0, §4.4, §6, and Tasks T014, T031, T032, T033.
  - *Rationale*: Protects against expensive unattended runaway loops by pushing an explicit warning to the operator channel when an agent sustains > 60,000 tokens/min across 3 consecutive minutes, complemented by amber (>30k) and red (>60k) visual styling in the UI.

---

<!-- version: 0.2.3 · updated: 2026-10-17 · last-edit: 2026-10-17T14:40:00Z -->
