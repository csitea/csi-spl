# Spec 191: Google A2UI evaluation for spool-hub (responsiveness, latency, architecture)

Status: **v0.1** (2026-11-24, review draft). Evaluation only: no code, workflow, or cnf change.
Epic: **SPL-2402**. Issue: **SPL-6357** (label `answer`). Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:341b0f94-d55c-4302-982a-d62ffbc24b3f` (`t1` `#refactoring`), task `dispatch-341b0f94`.
Baseline tree: `origin/master` `48bc8bb6a800a6c032f80d98c5522311a7e0155e` (2026-11-24T08:35:29Z); live served prd WUI `3.6.6` (`48bc8bb6`), hub `3.6.5` (`76471cb9`, `topic_heads: on`).
Related: [027 spool performance](../027-spool-performance/spec.md), [030 wire fast path](../030-spool-wire-fastpath/spec.md), [066 perceived-performance metrics](../066-perceived-performance-metrics/spec.md), [099 topic head](../099-topic-head/spec.md), [109 desktop UI refactor](../109-desktop-ui-refactor/spec.md), [178 Nuxt 4 migration](../178-nuxt4-migration/spec.md), [how-to-post.md](../../doc/help/how-to-post.md).

Numbering: highest spec folder on `origin/master` `48bc8bb6a` is `190-qto-doc-media` (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -n 5`); no remote branch claims `191` (`git branch -r | grep -iE '191|a2ui'` -> empty).

## Owner question (HUM-10, t1 `341b0f94`, 2026-11-24, msg `6be856d5`)

> "evaluate can we improve the responsiveness and the latency , as well as the overall architecture of the spool-hub by taking into use the a2ui from google"

---

## 1. What A2UI is (primary sources only, read 2026-11-24)

All facts below were fetched directly from A2UI's primary sources on **2026-11-24** via `curl` against GitHub, npm, `a2ui.org`, and the Google Developers Blog. Where a URL redirected or returned 404, that is stated explicitly.

### 1.1 What A2UI standardises

A2UI (**Agent-to-User Interface**) is an open-source protocol and SDK suite created by Google that lets an AI agent describe interactive UI as **declarative JSON data** rather than executable code, which the host application renders with its own native UI components from a pre-approved **catalog** (`https://github.com/a2ui-project/a2ui/blob/main/README.md`, read 2026-11-24; `https://developers.googleblog.com/a2ui-10-build-delightful-fast-reliable-agentic-experiences/`, published 2026-11-11, read 2026-11-24).

The v1.0 wire specification (`https://github.com/a2ui-project/a2ui/blob/main/specification/v1_0/docs/a2ui_protocol.md`, read 2026-11-24; also published at `https://a2ui.org/specification/v1.0-a2ui/`, HTTP 200 verified 2026-11-24) standardises:

1. **Separated UI tree and reactive data model** — components are sent as a flat list referencing child IDs and bound to a per-surface JSON data model via JSON Pointer paths (`@path`), enabling incremental/progressive updates without replacing whole subtrees.
2. **Agent-to-renderer wire envelopes** (`agent_to_renderer.json`, `"version": "1.0"`):
   - `createSurface` — allocates a UI surface (`surfaceId`, optional `catalogId`, optional `sendDataModel`; in v1.0, initial `components` and `dataModel` may be inlined in one message for single-shot UI creation; v1.0 forbids `theme` properties on `createSurface`, deferring visual styling entirely to the host framework).
   - `updateComponents` — adds or updates component definitions on a surface.
   - `updateDataModel` — inserts or replaces data at JSON Pointer paths.
   - `deleteSurface` — tears down a surface.
   - Bidirectional typed function RPCs added in v1.0 (`callRendererFunction`, `callAgentFunction`, `rendererFunctionResponse`, `agentFunctionResponse`), validated against catalog definitions and caller/user-activation rules.
3. **Renderer-to-agent events** (`renderer_to_agent.json`): user interactions dispatch structured `action` events (event name + resolved context) or surface data-model sync metadata (`a2uiRendererDataModel`) back to the agent (`https://github.com/a2ui-project/a2ui/blob/main/docs/site/src/content/docs/concepts/messages.mdx`, read 2026-11-24).
4. **Catalog capability boundary** — the client declares supported catalogs; the agent may compose only registered components and functions. Basic Catalog v1 (`https://github.com/a2ui-project/a2ui/blob/main/catalogs/basic/v1/catalog.json`, read 2026-11-24) defines **18 components** (`AudioPlayer`, `Button`, `Card`, `CheckBox`, `ChoicePicker`, `Column`, `DateTimeInput`, `Divider`, `Icon`, `Image`, `List`, `Modal`, `Row`, `Slider`, `Tabs`, `Text`, `TextField`, `Video`) and **14 local functions** (`and`, `email`, `formatCurrency`, `formatDate`, `formatNumber`, `formatString`, `length`, `not`, `numeric`, `openUrl`, `or`, `pluralize`, `regex`, `required`).

### 1.2 Transport

A2UI is **explicitly transport-agnostic**. The v1.0 protocol specification (`a2ui_protocol.md`, section "Transport Interaction Patterns", read 2026-11-24) states that A2UI JSON/JSONL messages "can be transported over both request-response channels (such as HTTP POST or polling) and bidirectional streaming channels (such as WebSockets, gRPC, or Server-Sent Events)." Official transport mappings and packages exist for **A2A** (`specification/v1_0/extensions/a2a/docs/a2ui_extension_specification.md`, Python `a2ui-a2a`), **MCP** (`@a2ui/catalog-mcp`), and **Google ADK** (`a2ui-adk`) (`README.md`, `concepts/messages.mdx`, read 2026-11-24). A2UI does not define a network transport, session/auth layer, persistence layer, or pub/sub broker.

Note on URL reachability: `https://a2ui.org/concepts/transports/` returned an empty redirect shell (5 non-markup lines) and `docs/concepts/transports.md` returned 404 on GitHub; transport documentation lives in `specification/v1_0/docs/a2ui_protocol.md` and `docs/site/src/content/docs/concepts/messages.mdx`, both fetched cleanly on 2026-11-24.

### 1.3 Renderers and SDKs as they exist on 2026-11-24

Primary sources: `https://a2ui.org/concepts/sdks/` (note: `https://a2ui.org/reference/renderers/` redirects here), `https://github.com/a2ui-project/a2ui/blob/main/README.md`, `https://github.com/a2ui-project/a2ui/blob/main/docs/site/src/content/docs/ecosystem/renderers.mdx`, and npm registry metadata (`https://registry.npmjs.org/<pkg>`, all read 2026-11-24).

| Layer | Framework / Language | Official package(s) | Protocol versions | Latest published version & date (npm / GitHub) | Notes for spool-hub |
|---|---|---|---|---|---|
| Web Core SDK | TypeScript | `@a2ui/web_core` | v0.8, v0.9.1, v1.0 | `0.16.1` (`2026-11-23T18:36:58Z`) | Unpacked 11.29 MB; 173 non-test `.js` files = **1,377.9 KB raw / 386.3 KB gzip** (unminified ESM across v0.8/v0.9/v1.0); depends on `lit`, `zod`, `zod-to-json-schema`, `@preact/signals-core`, `@lit/context`, `validate-color`. |
| Web Renderer | React | `@a2ui/react` | v0.8, v0.9.1, v1.0 | `0.16.1` (`2026-11-23T18:35:08Z`) | Depends on `@a2ui/web_core`, `@a2ui/markdown-it`, `zod`, `markdown-it`. |
| Web Renderer | Lit (Web Components) | `@a2ui/lit` | v0.8, v0.9.1, v1.0 | `0.16.0` (`2026-11-23T17:48:11Z`) | 50 non-test `.js` files = **242.4 KB raw / 74.2 KB gzip** (mostly `0.8/` legacy + Shadow DOM Lit elements); depends on `@a2ui/web_core`, `lit`, `zod`, `@lit-labs/signals`, `signal-utils`. |
| Web Renderer | Angular | `@a2ui/angular` | v0.8, v0.9.1, v1.0 | `0.16.0` (`2026-11-23T18:33:35Z`) | Depends on `@a2ui/web_core`, `zod`, `tslib`. |
| Web Renderer | **Vue / Nuxt** | **None** (`@a2ui/vue` -> HTTP 404 on npm; absent from `typescript/renderers/`) | — | — | **Spool-hub WUI is Vue 3 + Nuxt.** Only community projects exist: `shawnwang15/a2ui-vue` (targets `v0.8`, `v0.9.x`, not `v1.0`) and `vercel-labs/json-render` (own schema + A2UI adapter). |
| Mobile / Native | Flutter | `a2ui_flutter` | v0.9.1, v1.0 | pub.dev (source `dart/a2ui_flutter`) | Not applicable to spool-hub WUI. |
| Mobile / Native | SwiftUI | `A2UISwiftUI`, `BasicCatalogSwiftUI` | v0.9.1, v1.0 | `v0.12.0+swift` (`2026-11-23T19:24:48Z`) | Apple platforms only. |
| Mobile / Native | Jetpack Compose | `androidx.a2ui.compose`, `material3-a2ui` | v0.9.1 only | Google Maven | v1.0 not yet listed in official SDK table. |
| Agent SDK | TypeScript, Python, Dart | `@a2ui/agent`, `a2ui-agent-sdk`, `a2ui_agent` | v0.8/v0.9.1/v1.0 | `@a2ui/agent` `0.2.1` (`2026-11-23T18:33:28Z`); `a2ui-agent-sdk` `0.12.1` (`2026-11-23T18:48:43Z`) | **No official Go Core or Agent SDK.** Spool-hub's hub and CLI are Go; community Go libs (`satorunooshie/a2ui-go`, `tmc/a2ui`, `charmbracelet/a2tea`, `muncus/a2term`) target `v0.9.x`, not `v1.0`. |

### 1.4 Maturity, licence, and release cadence

- **Repository**: `https://github.com/a2ui-project/a2ui` (`https://github.com/google/A2UI` redirects here via GitHub API, verified 2026-11-24). Created `2025-09-24T23:14:02Z`, last push `2026-11-24T02:19:24Z`, 18,454 stars (GitHub API, read 2026-11-24).
- **Licence**: **Apache-2.0** (`https://github.com/a2ui-project/a2ui/blob/main/LICENSE`, read 2026-11-24). Compatible with spool-hub (`csi-spl-wui` is `AGPL-3.0-only`).
- **Specification version & age**: Protocol **v1.0** ("Status: Current", stable; `https://github.com/a2ui-project/a2ui/blob/main/specification/versions.json` and `specification/v1_0/README.md`, read 2026-11-24). Initial public announcement: **2025-12-15** (`https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/`, read 2026-11-24). v1.0 announcement: **2026-11-11** — **13 days before this evaluation** (`https://developers.googleblog.com/a2ui-10-build-delightful-fast-reliable-agentic-experiences/`, read 2026-11-24).
- **SDK maturity**: Actively shipping weekly (latest GitHub releases `cli-v0.5.0`, `v0.12.0+swift`, `python/a2ui-core/v0.7.1`, `python/a2ui-agent-sdk/v0.12.1`, and npm `0.16.0`/`0.16.1` all published **2026-11-23**), but **every official client/agent SDK is still pre-1.0 (`0.x`)**, and protocol v1.1 requirements are already being collected (`README.md` Roadmap).

---

## 2. Where spool-hub is today (measured)

Every number below cites its empirical source, tree/build, and sample count `n`.

### 2.1 Real-user field metrics on prd (spec 066 `wui_perf_samples`)

Read-only query against `csi-spl-prd-pg` (`cd csi-spl-orc && ENV=prd SQL="..." ./run -a do_spl_db_query`, `BEGIN TRANSACTION READ ONLY`), **7-day window `2026-11-17` .. `2026-11-24`**, `outcome = 'ok'`, `tenant_id <> 'e2e'` (real users, excluding probe workspace). Served prd builds at query time: WUI `3.6.6` (`48bc8bb6`), hub `3.6.5` (`76471cb9`, `topic_heads: on`). Spec 066 ranks work by **p75** with `n >= 100` (p95 omitted under `n = 50`).

| Metric (spec 066) | Device | View / cache | n | p50 (ms) | **p75 (ms)** | p95 (ms) | Notes |
|---|---|---|---:|---:|---:|---:|---|
| `load_messages` | desktop | cold | 986 | 2,931 | **6,735** | 262,237 | p95 reflects background tabs opened before focus (spec 109 §7.3). |
| `load_messages` | phone | cold | 124 | 3,930 | **6,650** | 127,857 | Same cold boot + mobile CPU/4G cost. |
| `load_messages` | phone | warm | 63 | 3,202 | **4,849** | 29,046 | Under n=100, still multi-second warm load on phones. |
| `load_messages` | desktop | warm | 342 | 914 | **3,828** | 9,986 | Warm JS parse/hydration + session/view waterfall. |
| `reconnect_live` | desktop | — | 39 | 1,150 | **2,951** | — | Socket reconnect + full `channel.catchUp()` re-read. |
| `reconnect_live` | phone | — | 70 | 1,366 | **1,876** | 6,834 | Mobile wake reconnect. |
| `switch_view` | desktop | channel | 578 | 494 | **754** | 1,133 | Click channel -> first message painted. |
| `switch_view` | desktop | topic | 106 | 424 | **688** | 1,336 | Click topic -> first message painted. |
| `switch_view` | phone | channel | 228 | 496 | **682** | 2,513 | Mobile stack channel switch. |
| `switch_view` | phone | topic | 138 | 390 | **513** | 797 | Mobile stack topic open. |
| `send_ack` | desktop | — | 1,184 | 279 | **465** | 1,930 | Submit -> hub ack (`data-pending` cleared); optimistic row shows sooner. |
| `send_ack` | phone | — | 108 | 216 | **454** | 4,466 | Mobile submit -> hub ack. |
| `inp` | desktop | — | 12,517 | 56 | **80** | 128 | Well inside the 200 ms Good INP threshold. |
| `scroll_jank` | desktop | — | 8,465 | 34 | **58** | 142 | Longest frame gap in scroll burst. |
| `inp` | phone | — | 718 | 32 | **48** | 81 | Interactive input is already fast on phones. |
| `type_next_paint` | desktop | — | 9,098 | 24 | **46** | 120 | Keydown -> next paint in composer. |
| `scroll_jank` | phone | — | 4,599 | 30 | **40** | 60 | Smooth scrolling on phones. |
| `type_next_paint` | phone | — | 233 | 17 | **23** | 44 | Sub-25 ms typing on phones. |

**Unmeasured in prd RUM (verified `n = 0`)**: `load_rail` and `deliver_visible` have **0 rows** in prd `wui_perf_samples` over the last 30 days (read-only query on `2026-11-24`, any outcome, `tenant_id <> 'e2e'`). For `load_rail`, lab measurements stand in:
- Spec 066 §12.5 (dev warm cache, tree `92a368fc`, `n = 15/arm`, RUM on): desktop `d1440` rail median **537 ms** (Flow 753 ms, TBT 167 ms); phone `m390` CPU 4x rail median **3,067 ms** (Flow 4,579 ms, TBT 2,499 ms); cold `/lobby` first message **496 ms** desktop / **5,425 ms** phone slow-4G.
- Spec 109 §7.2 (prd `e2e` lab after-round, WUI `6.1.1` `00be0cba` / `6.1.3` `cf5afc58`, hub `6.1.2` `456687a4` `topic_heads: on`, `n = 10`, desktop `d1440`): `/lobby` first message warm **743 ms** (p95 1,830), cold **945 ms** (p95 2,459), `ws open after nav` **954 ms** (CPU 4x: 2,819 ms), click topic -> message **114 ms** (CPU 4x: 343 ms), send confirmed **192 ms** (CPU 4x: 336 ms), same-route rail tab switch **20–25 ms** (route-changing Topics click **412 ms**).

### 2.2 Where the time goes across the stack

| Layer | Measured numbers | Source, tree/build, n | What dominates |
|---|---|---|---|
| **Nuxt bundle & WUI boot** | `ci_initial_gzip_kb` = **151.9 KB** vs **155.0 KB** ceiling (**3.1 KB headroom**; entry chunk ~94.3 KB gzip after SPL-6342 moved `live-ws.mjs` out). `ci_home_gzip_kb` = **352.1 KB** ceiling (85–86 preloaded chunks on `/index.html`). Cold `/lobby` = **343 requests / 951.6 KB** on the wire. Mock first screen (no hub): **~6 JS/CSS import waves**, 99 non-prefetch requests before rail; phone CPU 4x rail **1,733 ms**, TBT **963 ms** (Vue runtime 650 ms, native compile/layout 564 ms, entry chunk 311 ms, i18n 108 ms). Largest lazy chunks: `markdown-it` + `entities` + `linkify-it` **49.0 KB gzip**, default layout **38.7 KB gzip**, `@headlessui/vue` + `@tanstack/virtual-core` **16.6 KB gzip**. | `specs/027-spool-performance/contracts/perf-budgets.json` (trunk `f7b35176e`, `2026-11-24`, `n=2`); `specs/109-desktop-ui-refactor/spec.md` §7.2 (`00be0cba`, `n=10`); `doc/md/perf-audit-round3-2026-10-02.md` §3.2–3.4 (`7155116a`, `n=10` mock / `n=3` CPU profile / `n=1` bundle). | **First-load JS parse/compile, multi-wave chunk waterfall, and Vue hydration** dominate `load_messages` (cold and warm) and phone CPU TBT. |
| **Hub API (Cloud Run + Cloud SQL)** | Cloud Run `csi-spl-hub-prd` (`1` vCPU, `512Mi`, `min_instances: 1`, `max_instances: 2`, Cloud SQL `db-custom-1-3840` REGIONAL, `topic_heads: on`). Live prd server latency (8-min snapshot `2026-11-24T08:40:34..08:48:31Z`, revision `csi-spl-hub-prd-02000-ril`, `2,000` log entries, 0 5xx): `GET /v1/view/channels` **122.7 / 252.8 ms** (p50/p95, `n=26`, 1.2 KB); `GET /v1/view/flow` **96.4 / 492.3 ms** (`n=17`, 0.7 KB); `GET /v1/view/topics` **48.0 / 124.5 ms** (`n=32`, 1.8 KB); `GET /v1/view/issues` **42.0 / 66.0 ms** (`n=31`, 4.3 KB); `GET /v1/view/topics/{id}` **16.1 / 101.0 ms** (`n=30`, 1.1 KB); `GET /v1/view/roster` **13.2 / 39.5 ms** (`n=25`, 5.9 KB); `GET /v1/pins` **4.0 / 7.2 ms** (`n=448`). First-screen API JSON total: **~5.8 KB gzip** across 11 DB round trips (~47 ms local PG16; hub CPU 1–3 ms/route). | `do_spl_hub_route_latency` (`ENV=prd`, `2026-11-24`, `n=2,000` entries); `csi-spl-cnf/csi-spl/{all,prd}.env.yaml`; `doc/md/db-payload-audit-round2-2026-10-02.md` (`e6f862c3`, `n=3x5`). | Hub + DB is **~1–5%** of cold first-load wall time and **~20–25%** of `switch_view` p50. Already small payloads (~1–6 KB p50), gzipped, ETag-validated, and backed by `topic_heads`. |
| **Sidecar & spool wire** | Interactive legs are **already WebSockets** (`/v1/wui/ws` browser, `/v1/ws` box sidecar) pushing full message bodies (no polling). Local file mailbox write: **0.062 ms** (`n>26k`). Full in-process protocol (canonicalise + Ed25519 sign/verify + JSON encode/decode): **~0.26 ms** (`n>10k`). Warm sidecar submit (`FP-2`): **125.0 ms p50 / 160.4 ms p95** quiet box (`n=12`; 231.5 / 401.2 ms loaded, `n=20`) vs cold CLI dial **619.5 / 681.4 ms** (`n=12`). In the `2026-11-24` prd 8-min log, `GET /v1/ws` still logged `n=1,068` upgrades with p50 **38.4 ms** / p95 **246.9 ms** (short-lived CLI dials alongside warm sidecars); `GET /v1/wui/ws` logged `n=13` long-lived browser sockets (p50 26.6 s, max 299.2 s). | `specs/030-spool-wire-fastpath/spec.md` §0 & §0.5 (hub `0.1.17` `39a5a25a` `n=20`, hub `0.1.19` `2e4c1ce` `n=12`); `do_spl_hub_route_latency` (`2026-11-24`). | Protocol serialization is negligible (0.26 ms). Remaining wire costs are network RTT (~62 ms), cold CLI WS dials when bypassing the sidecar, and full-page `channel.catchUp()` on WUI reconnect. |

---

## 3. Fit, per bottleneck

A2UI is a **declarative UI-description schema** for agent outputs, not a transport optimiser, bundle trimmer, or database cache. Mapping it against each measured spool-hub bottleneck shows where it helps and where it cannot:

| Measured bottleneck (section 2) | Effect of A2UI | Concrete mechanism |
|---|---|---|
| **`load_messages` cold / warm** (prd p75 6.7 s / 3.8 s desktop; 6.6 s / 4.8 s phone) & **Nuxt bundle** (`151.9 / 155.0 KB` gzip, 3.1 KB headroom) | **Adds** (or **untouched** if strictly lazy-loaded) | A2UI does not shorten Nuxt's boot, auth probe, 86-chunk `/` preload, or Vue hydration. Putting `@a2ui/web_core` (1,378 KB raw / 386 KB gzip non-test ESM; pulls `zod`, `lit`, `@preact/signals-core`) or `@a2ui/lit` (242 KB raw / 74 KB gzip) in the initial chunk immediately breaks the 155 KB gate. Even behind a dynamic `import()` triggered only by an A2UI message, it adds a lazy download + parse wave on first card render. |
| **`switch_view` channel / topic** (prd p75 688–754 ms desktop; 513–682 ms phone) | **Untouched** (risk: **adds**) | Today's wait is `GET /v1/view/topics[/{id}]` (16–48 ms server + RTT) plus Vue route/feed render. A2UI cannot make view reads faster; mounting A2UI surfaces, JSON Pointer resolution, or Shadow DOM custom elements inside feed rows adds render work during topic open. |
| **`send_ack`** (prd p75 454–465 ms) & **`reconnect_live`** (prd p75 1,876–2,951 ms) | **Untouched** | A2UI rides on top of an existing transport. It does not shorten browser <-> Cloud Run RTT, Postgres insert + `LISTEN/NOTIFY` cross-instance fanout, or `channel.catchUp()` full-page re-reads after wake. |
| **Hub API on Cloud Run** (`GET /v1/view/*` 13–123 ms p50) & **sidecar / spool wire** (125 ms p50 warm submit, 0.26 ms JSON/sign) | **Untouched** (slightly **adds** payload bytes) | A2UI JSON is substantially larger than markdown or a `poll` block: the v1.0 contact form example in `a2ui_protocol.md` is ~2.8 KB of JSON versus ~120 B for a `poll` fence. Messages still stay under `msg.MaxBodyBytes = 64 KiB` (`internal/msg/msg.go:42`), and `internal/msg` strictly rejects unknown top-level JSON keys unless the wire schema is bumped (spec 020). |
| **Interactive responsiveness** (`inp` p75 48–80 ms, `type_next_paint` p75 23–46 ms, `scroll_jank` p75 40–58 ms) | **Untouched** (risk: **adds** jank) | Frame responsiveness is already green on desktop and phone. Mounting Lit Shadow DOM elements or Zod schema validators synchronously inside scrolled feed cards risks regressing `scroll_jank` and `inp` unless carefully windowed and deferred. |
| **Multi-turn human <-> agent interaction latency** (turns required to collect structured input beyond radio/checkbox choices) | **Removes / moves** (the **only** real gain) | Today `how-to-post.md` §7 (`utils/poll.mjs`, `PollForm.vue`) already covers single-click Go buttons, radio choices, and multi-question checkbox forms with zero external deps and plain-text degradation. A2UI adds value only when an agent needs **rich structured input** that `poll` cannot express (validated `TextField`, `DateTimeInput`, `Slider`, multi-step or live-updating status/approval cards) without bespoke Vue components per workflow, or progressive streaming of UI while an LLM is still generating. |

### Architectural frictions specific to spool-hub

1. **Framework mismatch (Vue/Nuxt vs React/Lit/Angular)**: Spool-hub's WUI is Vue 3 + Nuxt (`csi-spl-wui/package.json`), currently migrating from Nuxt 3 to Nuxt 4 (`SPL-5070`, spec 178). A2UI has **no official Vue renderer**. Wrapping `@a2ui/lit` inside Vue introduces Shadow DOM styling isolation (breaking spool-hub's CSS tokens, font-size scale, and focus-ring gates: `font-size.test.mjs`, `focus-tokens.test.mjs`) and Vue `isCustomElement` compiler config.
2. **Backend & fleet mismatch (Go + multi-vendor CLI/MCP vs Python/TS Agent SDK)**: Spool-hub's hub and CLI are Go (`csi-spl-api`), and fleet agents are multi-vendor CLI/MCP harnesses posting plain-text `body` strings via `spool send` / `spool_send` over one strict v:1/v:2 JSON envelope (`developer-guide.md` §2.11.1). There is no official Go A2UI SDK, and fleet agents do not run a shared Python/TS A2UI server.
3. **Strict CSP and zero-remote-media policy**: Deployed Firebase Hosting CSP forbids `'unsafe-inline'` in `script-src`/`style-src` and restricts `img-src` to `'self' data:` (`nuxt.config.ts:127-160`, `utils/markdown.mjs:26-28`). A2UI's Basic Catalog includes `Image`, `Video`, `AudioPlayer`, and `openUrl`, which would violate spool-hub's no-remote-fetch rule unless excluded from a custom spool catalog.
4. **19-locale i18n ratchets**: Spool-hub enforces zero raw UI text (`i18n-no-raw-text.test.mjs`), 19-locale key parity (`i18n-parity.test.mjs`), and falling untranslated baselines (`i18n-untranslated.test.mjs`). Catalog chrome (Submit/Cancel buttons, validation errors) must be translated across all 19 locales; agent-authored labels inside messages bypass locale files just as message prose and `poll` text already do.

---

## 4. Architecture options (3 options)

| Dimension | Option A: No change (keep Nuxt + markdown + `poll`, fix measured bottlenecks) | Option B: Bounded A2UI island inside topic messages (lazy Vue adapter, custom spool catalog, alongside `poll`) | Option C: Wider architectural move (A2UI as primary WUI / streaming layer or React/Lit renderer swap + hub A2UI streaming) |
|---|---|---|---|
| **Scope** | Do not adopt A2UI now. Finish Nuxt 4 (`SPL-5070`), keep `poll` for choices/Go, and spend perf rounds on measured top-p75 waits (`load_messages`, `reconnect_live` delta catch-up, `switch_view`, short-lived `/v1/ws` dials). | **After `SPL-5070` lands**, add an optional fenced ` ```a2ui ` block in `msg.Body` (wire v:1/v:2 unchanged, mirroring ` ```poll ` and ` ```md `). Dynamic `import()` loads a small spool-native Vue 3 adapter (~6–8 catalog components: `Card`, `Column`, `Row`, `Text`, `TextField`, `ChoicePicker`, `CheckBox`, `DateTimeInput`, `Button`; no `Image`/`Video`/`AudioPlayer`, no Lit/Shadow DOM, no Zod in initial chunk). Actions post deterministic plain-text replies in the topic (like `Poll: <msg_id>`) so every CLI/MCP agent parses them; send-time fence validator in `csi-spl-orc` (like `spl_desk_poll_check`). | Replace or wrap core WUI screens with A2UI surfaces (or move the WUI off Vue/Nuxt to React/Lit to use an official `@a2ui/*` renderer) and add hub-side A2UI streaming/RPC (`callAgentFunction` / `callRendererFunction`) over `/v1/wui/ws` and `/v1/ws`. |
| **Cost** | **0 engineering effort** for A2UI; 0 KB bundle growth; 0 new dependencies. | **Medium (3–5 weeks)** after Nuxt 4: Vue v1.0 subset renderer + schema validator, spool catalog components, CSP/XSS/a11y unit + Chrome e2e tests, 19-locale chrome keys + `do_spl_lang_review_gct`, `csi-spl-orc` send validator, and agent prompt/skill. | **Very high (multi-month rewrite)** across `csi-spl-wui`, `csi-spl-api`, `csi-spl-orc`, 19-locale i18n, e2e suite, and all box harnesses. |
| **Risk** | Low: multi-field structured agent inputs (free-text fields, dates, sliders) stay either "Chat about this" prose replies or bespoke Vue cards (e.g., `MarketingDraftHandover.vue`). | Medium: spool-hub owns a custom Vue adapter against a 13-day-old v1.0 spec (with v1.1 on roadmap); `@a2ui/web_core` (0.16.x) is too heavy to import whole and requires either tree-shaking proof or a minimal v1.0 subset parser; LLM JSON errors need send-time refusal + code-block fallback. | Very high: **worsens** measured latency by adding agent/schema indirection to deterministic views; locks onto pre-1.0 (`0.16.x`) SDKs with no Go backend SDK; huge maintenance and regression surface. |
| **What it breaks** | **Nothing.** Nuxt 4 (`SPL-5070`), 19-locale i18n gates, `poll` grammar, `v:1`/`v:2` wire, and CSP all stay intact. | **Does not break** Nuxt 4 (sequenced after `SPL-5070`), `poll` (coexists; `poll` stays default for simple choices/Go), `v:1`/`v:2` strict message parser, or CSP (external media excluded). Adds new i18n keys for catalog chrome across all 19 locales. | **Breaks** `SPL-5070` (invalidates active Nuxt 4 migration), 19-locale i18n ratchets (`i18n-no-raw-text`, `i18n-parity`, `i18n-untranslated`), `poll` grammar and `spl_desk_poll_check`, `ci_initial_gzip_kb` 155 KB gate, strict `internal/msg` envelope, and deterministic Chrome e2e tests. |
| **Measurable success criterion** | `ci_initial_gzip_kb <= 155.0 KB`; `SPL-5070` lands green; next perf round cuts prd `wui_perf_samples` top p75s (`load_messages` warm desktop `3,828 -> <= 2,000 ms`, `switch_view` desktop channel `754 -> <= 400 ms`, `reconnect_live` desktop `2,951 -> <= 1,500 ms`, `n >= 100` each). | `ci_initial_gzip_kb` delta = **0.0 KB**; lazy A2UI chunk `<= 25 KB` gzip; `<= 3%` median delta on spec 066 metrics for non-A2UI views (`n >= 15/arm`); `>= 90%` first-attempt schema-valid A2UI payloads by fleet agents (`n >= 20`) and `>= 50%` fewer human-agent turns on multi-field tasks (`n >= 10`). | Must beat prd baselines (`load_messages` warm p50 914 ms, `switch_view` channel p50 494 ms, `send_ack` p50 279 ms, `inp` p75 80 ms, `ci_initial_gzip_kb <= 155 KB`) with all e2e/i18n gates green — empirically unachievable for deterministic chat/issue chrome. |

---

## 5. Recommendation and experiment

### 5.1 Recommendation

Choose **Option A now (do not adopt Google A2UI for latency, responsiveness, or core spool-hub architecture)**, and revisit **Option B** only after the Nuxt 4 migration (`SPL-5070`) lands if real workspace traffic shows repeated multi-field agent forms that the existing `poll` grammar cannot express. Measured prd data proves that spool-hub's real waits are first-load JS/hydration (`load_messages` cold p75 6.7 s, warm p75 3.8 s desktop), WebSocket reconnect catch-up (`reconnect_live` p75 1.9–3.0 s), and view switching (`switch_view` p75 513–754 ms), while interactive responsiveness is already fast (`inp` p75 48–80 ms, `type_next_paint` p75 23–46 ms) and the hub/wire layer is already WebSocket-pushed and sub-130 ms p50; A2UI is a declarative agent-to-UI payload format (not a transport or bundle optimiser), lacks an official Vue/Nuxt renderer and Go SDK as of 2026-11-24, ships only `0.x` client packages (`@a2ui/web_core` 0.16.1 is 386 KB gzip non-test before tree-shaking against spool-hub's 3.1 KB initial-JS headroom), and cannot shorten any of today's measured waits.

### 5.2 Experiment to prove or refute this recommendation (red/green, n)

Run on a throwaway branch **after `SPL-5070` (Nuxt 4) lands**, with zero prd mutations, in two falsifiable gates:

1. **Gate 1 — Cost & latency A/B (tests whether Option B is overhead-free; refutes any claim that A2UI improves load/switch latency)**:
   - Build a minimal Option B prototype: a dynamic-import Vue 3 renderer for a 6-component spool catalog (`Card`, `Column`, `Text`, `TextField`, `ChoicePicker`, `Button`) triggered only when `mayHaveA2ui(body)` matches a ` ```a2ui ` fence, tested against baseline `origin/master`.
   - Measure `perf-budget.py bundle` (`n = 2` builds per arm) and interleaved A/B on `serve-hosting-h2.mjs` (`d1440` and `m390-4g`, `n = 15` per arm, matching spec 066 §5) for `load_messages`, `switch_view` (plain topic vs A2UI topic vs equivalent `poll` topic), `TBT`, plus hostile-input security controls (raw `<script>`, unknown component type, `javascript:` URL, external `Image` URL).
   - **RED (refutes A2UI adoption / blocks Option B)**: initial JS gzip increases by `> 0.5 KB` (or crosses `155.0 KB`), OR the lazy A2UI chunk exceeds `25 KB` gzip, OR any non-A2UI median regresses by `> 3%`, OR rendering an A2UI card adds `> 50 ms` to `switch_view` p75 versus an equivalent `poll` card, OR any hostile-input control executes/fetches.
   - **GREEN (clears only the cost/safety bar)**: initial JS delta `<= 0.5 KB`, lazy chunk `<= 25 KB` gzip, all non-A2UI medians within `<= 3%` (`n = 15/arm`), A2UI vs `poll` `switch_view` delta `<= 50 ms`, and 100% of hostile-input controls inert.

2. **Gate 2 — Demand & agent reliability test (decides Option A vs Option B)**:
   - Audit 30 days of workspace discussions for multi-field agent-to-human requests that forced "Chat about this" or prose follow-ups because `poll` lacked text/date/numeric fields (`n_asks`), and run `n = 20` trial prompts across active fleet agent vendors generating ` ```a2ui ` v1.0 payloads validated against the spool catalog schema.
   - **GREEN (refutes Option A and justifies building Option B)**: `n_asks >= 10` real non-`poll` multi-field asks per 30 days **AND** fleet agents emit schema-valid A2UI on first attempt in `>= 18 / 20` trials (`>= 90%`) **AND** human-to-agent round trips drop by `>= 50%` (median `>= 3` turns -> `1` submit across `n = 10` end-to-end tasks).
   - **RED (confirms Option A)**: `n_asks < 10` per 30 days, OR first-attempt agent validity `< 90%` (`< 18/20`), OR `< 50%` reduction in human turns.

<!-- version: 0.1.0 · updated: 2026-11-24 · last-edit: 2026-11-24T08:50:39Z -->
