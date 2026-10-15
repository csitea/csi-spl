# 140: Real-time token burn per agent type and per agent, on the Monitoring page

Status: **Ready for review** (Initial specification; issue SPL-1986).  
Authority: this file for the architecture and technical requirements; [tasks.md](tasks.md) for the phased build tasks.  
Status vocabulary: [README.md](../README.md) §2.3. Docs only: this spec builds nothing ([README.md](../README.md) §2.4).  
Topic: `e8ae0aad-b8fb-4d3c-8377-072eec9cd404` (HUM-10, prd t1, msgs `ebff27ef`, `f2f947d1`, poll `63182298` msg `86ee1e4e`).

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
        │  (100 - 300 ms: HTTPS POST or WebSocket frame to Spool Hub API)
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
| **3. Wire & DB write** | < 0.5 s | Hub ingestion route + batch DB insert | Single transaction write and price calculation in PostgreSQL. |
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

#### 2.3.4 Antigravity (`agy`) — the unmetered vendor
- **Location**: `<agent_home>/.gemini/antigravity-cli/*.pb` (binary Protocol Buffer storage).
- **The Gap**: As documented in `do_spl_review_line_check` and `c002-token-burn-spec.md` line 8, agy session state is compiled protobuf and is currently unreadable without proprietary schemas.
- **Reporting & Display Invariant**:
  - Agy lanes are detected from `/var/spool-hub/registry.tsv` and active tmux panes.
  - The collector reports these active lanes with `is_metered: false` and `status: "unmetered"`.
  - The hub stores and the WUI displays a prominent **"Not metered (binary .pb format)"** badge.
  - **Agy token counts and costs are NEVER rendered as zero (`0`)**. Displaying zero would falsely imply free usage; displaying "Not metered" explicitly exposes the telemetry gap.

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
| **Immutability & Retention** | `usage_events` is append-only with strict trigger preventing deletes (`rdb 0171:136-145`). High-frequency 1-minute telemetry cannot be pruned. | High-frequency telemetry requires automatic retention pruning (e.g. 7-day TTL on 1-minute data). |
| **Query Performance** | Pollutes billing ledger with hundreds of thousands of runner telemetry rows. | Dedicated time-series table indexed on `(minute_bucket, vendor, agent_id)` ensures sub-50ms dashboard reads. |

**Decision**: Adopt **Option S2**. Fleet runner telemetry must not be conflated with the customer financial ledger.

### 3.2 Schema specification: `fleet_token_burn_events` (rdb migration `0198`)

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

### 3.4 Wire protocol: HTTP REST batch ingestion

- **Route**: `POST /v1/operator/fleet-tokens`
- **Auth**: Service Account Bearer ID token (`operatorAuth`, verified against `OperatorEmails`) or active operator workspace admin session (`operatorActor`).
- **Payload**:
  ```json
  {
    "box": "sat",
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
- **Upsert Semantic**: Database write performs `ON CONFLICT (box_tag, agent_id, minute_bucket) DO UPDATE SET tokens_in = EXCLUDED.tokens_in, ...` ensuring safe idempotent retries.

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

To prevent unbounded table growth:
1. **1-minute raw buckets**: Retained for **7 days**.
2. **Daily rollups**: Computed nightly by `do_spl_cost_rollup_daily` and stored in `fleet_token_burn_daily` (retained for **90 days**).
3. **Automated purge**: Daily cleanup job executes `DELETE FROM fleet_token_burn_events WHERE minute_bucket < now() - INTERVAL '7 days'`.

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

---

## 5. Privacy and security invariants

To protect codebase integrity and operational secrecy:

- **Invariant P1 (Zero Transcript Content)**: The token telemetry pipeline handles strictly scalar counts and metadata (`box`, `agent_id`, `vendor`, `model`, `tokens_in`, `tokens_out`, `cache_read`, `cache_write`). **Under no circumstances does prompt text, completion text, tool call arguments, or file content leave the local runner box**.
- **Invariant P2 (Strict Operator Isolation)**: Fleet token burn data is restricted exclusively to operator workspace administrators via PostgreSQL RLS. Standard workspace members, visitors, and guest channels cannot query or infer fleet token activity.
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
| **Lane 1: `hub-tokens`** | `api` / `rdb` | `csi-spl-rdb/src/sql/postgres/spool-hub/0198_fleet_token_burn.sql`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_tokens*.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/fleet_tokens*.go` | Independent. Can build and test immediately. |
| **Lane 2: `collector-tokens`** | `orc` | `csi-spl-orc/src/bash/run/spl-token-burn-collect.func.sh`<br>`csi-spl-orc/src/bash/tests/spl-token-burn-collect.tst.sh`<br>`csi-spl-orc/cnf/box-crons/box-crons.manifest` | Depends on Lane 1 ingestion route schema. |
| **Lane 3: `wui-tokens`** | `wui` | `csi-spl-wui/src/pages/monitoring/tokens.vue`<br>`csi-spl-wui/src/components/monitoring/token-burn/*`<br>`csi-spl-wui/src/utils/monitoring-tokens.mjs` | Requires Monitoring v1 tab shell to land first. |
| **Lane 4: `e2e-proof`** | `test` / `proof` | `csi-spl-wui/src/tests/e2e/monitoring-tokens.test.mjs`<br>`csi-spl-orc/src/bash/tests/token-burn-e2e.tst.sh` | Runs after Lanes 1, 2, and 3 land. |

---

## 7. Open questions for the owner (poll format)

These questions represent operational and architectural tradeoffs for the owner's decision:

### Question Q1. Ingestion protocol from box to hub
- **Option A (Recommended)**: HTTP batch POST from the box collector to `POST /v1/operator/fleet-tokens` with Bearer auth.
  - *Rationale*: Decoupled, stateless, standard retry on 5xx, matches existing operator routes.
- **Option B**: WebSocket `lane_op fleet_tokens_push` over the persistent box CLI session.
  - *Rationale*: Reuses open WebSocket, marginally lower handshake overhead.

### Question Q2. Storage & aggregation granularity
- **Option A (Recommended)**: 1-minute buckets retained for 7 days, daily rollups retained for 90 days.
  - *Rationale*: Minimal storage footprint (< 50 MB / month), rapid dashboard queries, sufficient resolution for real-time debugging.
- **Option B**: 1-minute buckets retained for 30 days, daily rollups retained for 365 days.
  - *Rationale*: Extended high-resolution historical auditing at the cost of higher database storage.

### Question Q3. Token burn alert notifications
- **Option A (Recommended)**: Visual highlighting only in the Monitoring tab (amber badge if agent > 30k tokens/min; red badge if > 60k tokens/min).
  - *Rationale*: Unobtrusive, informs without generating notification noise.
- **Option B**: Visual highlighting plus automated alert message posted to `#fleet-alerts` when an agent sustains > 60k tokens/min for more than 3 consecutive minutes.
  - *Rationale*: Proactive notification if operators are not actively viewing the Monitoring dashboard.

---

<!-- version: 0.1.0 · updated: 2026-10-15 · last-edit: 2026-10-15T10:45:00Z -->
