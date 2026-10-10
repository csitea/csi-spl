# 121 Sales channel: tasks

Authority for what is built. `spec.md` (v1.2, `4af38a02e`) holds the
behaviour; this file splits its phases 1-3 (section 3) into ordered,
disjoint build lanes, and reserves phases 2b, 4 and 5 as HOLD slots. Each
task names its layer, what it waits on, the files it owns, its tests and the
agent kind. Status vocabulary: `../README.md` item 3 (`[x]` Implemented,
`[~]` Partial / in progress in a live lane, `[ ]` Planned).

Version **v1.0** (2026-10-10, lane c-757, for the dispatch holder c-002,
task dispatch-e001c851).

**Path prefixes:**

- `GO/` is `csi-spl-api/src/go/spool-hub-api/internal/`.
- `RDB/` is `csi-spl-rdb/src/sql/postgres/spool-hub/`.
- `WUI/` is `csi-spl-wui/src/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`, `OT/` is `csi-spl-orc/src/bash/tests/`.

**Rules for every lane:**

- A migration takes the next free prefix AT PUSH TIME
  (`ls csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`), never a number
  written here: `0166` is spec 123's, and spec 119 lane A may take the next
  one too. Old migrations are read, never edited.
- DDL lands and is applied on dev AND prd (`do_spl_db_bootstrap`, the
  owner's go per CLAUDE.md) before any code lane that reads it pushes.
- Store, hub and auth tests run on postgres: `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- No literal host: the hub host comes from cnf `BASE_DOMAIN`.
- Agent kind: claude for auth, RLS, store, payments, keys and anything a
  visitor's request reaches; mistral or grok only for low-risk doc/UI.
- Everything ships behind cnf `env.hub.embed.enabled` (off) until T207.

## Owner changes after v1.2, not yet in spec.md

The v1.3 editor lane folds these into `spec.md`; this file only marks them.

- **Q-N1 changed** (msg e8a817b3, relayed by c-001, msg 8f734e00): the EUR 5
  ceiling for unpaid visitors is now **EUR 5 per visitor chat session**, not
  EUR 5 per day per embed. The last row of the `spec.md` section 6 table
  (and the matching lines of 1.4, 4.3 and 12.4) change with it. **N1b**, an
  embed-wide daily ceiling (recommended EUR 50), is still asked: the cap
  lane T305 is HOLD on N1b.
- **Live feed** (msg 9b62e197): a new phase 2b slot, HOLD on F1/F2 (T2B1).
- **Trained standby agent** (msg 78d59612): the sales agent's knowledge
  ingest is HOLD on G1/G2 (T307).

## Order

T101 (the DDL) lands and is applied on dev and prd before any phase 1 code.
T103 (cnf) needs nothing and may run at once. Then T102 -> T104; after T104,
T105, T106, T106b, T201..T206 are disjoint lanes and run in parallel within
their waits. T207 turns the flag on (dev, then prd with the owner's go).
T208, the csi-web side, is the LAST lane of phase 2.

Phase 3: T301 (its own DDL) may land any time after T101, applied dev and
prd before T302..T304. T306 (the sales agent) needs T104 and T304.

## Lane table

| id | title | phase | waits on | state | agent |
|---|---|---|---|---|---|
| T000 | this file | - | - | done | claude |
| **T101** | **lane A: DDL `embed_visitors`, `embed_customers`, channel-scope RLS + negative tests** | 1 | - | build | claude |
| T102 | store: `inChannel`, visitor and embed rows | 1 | T101 applied dev+prd | done | claude |
| T103 | cnf `env.hub.embed.*` + config reader | 1 | - | done (7b1e4f47e) | claude |
| T104 | hub: visitor token, `channel_guest` role, read/post/erase in its channel | 1 | T102, T103 | build | claude |
| T106 | hub: `#sales` triage line, retention, lead mark, block, export exclusion | 1 | T104 | build | claude |
| T106b | WUI: "Visitors" rail group, lead / block buttons | 1 | T106 | build | mistral or grok |
| T105 | hub: abuse limits, proof-of-work gate, bans, token sweep | 2 | T104 | build | claude |
| T201 | hub serves `/embed/*` with per-customer `frame-ancestors` | 2 | T102, T103 | build | claude |
| T202 | loader.js + iframe chat page | 2 | T201, T104 | build | claude |
| T203 | hub: embed admin API (origins, per-embed JWT key) | 2 | T102 | build | claude |
| T204 | WUI: embed admin page | 2 | T203 | build | mistral or grok |
| T205 | hub: signed-in customer JWT -> one `channel_guest` | 2 | T104, T203 | build | claude |
| T206 | hub: e-mail one-time relink to a new device | 2 | T104 | build | claude |
| T207 | cnf flip `env.hub.embed.enabled` dev, then prd | 2 | T104..T206 | build | claude |
| T208 | csi-web: script tag + CSP, deploy dev then prd | 2 (last) | T207 on each env | build | claude |
| T2B1 | live feed on csitea.net | 2b | owner F1/F2 | HOLD | - |
| T301 | DDL: `usage_events`, `model_prices`, `token_budgets` | 3 | T101 landed | build | claude |
| T302 | metering: `turn_id`, usage report, `unmetered` alert | 3 | T301 applied dev+prd | build | claude |
| T303 | `model_prices` fill action from cnf | 3 | T301 applied dev+prd | build | claude |
| T304 | token budgets: refuse before dispatch, 429, 80 % notice | 3 | T302, T303 | build | claude |
| T305 | unpaid spend cap: EUR 5 per visitor session + embed-wide daily ceiling | 3 | owner N1b; T304, T105 | HOLD | claude |
| T306 | the sales agent: scoped context, small model, handover | 3 | T104, T304 | build | claude |
| T307 | sales agent knowledge ingest (website + Drive), standby mode | 3 | owner G1/G2; T306 | HOLD | - |
| T4xx | workspace sale on metered pricing | 4 | spec 122 pricing gate | HOLD | claude |
| T5xx | fixed-cost slice, second embedding customer | 5 | spec 122 M0 + M3 | HOLD | - |

## Tasks

### Phase 1: visitor channel (spec 3.1, 4)

- [x] T000 **doc** (c-757): this file.
- [ ] T101 **lane A, rdb** (claude; needs nothing). One new migration
  (`spec.md` 4.1, 4.2, 5):
  - `embed_visitors` (tenant_id, embed_id, visitor_id uuid, token_hash,
    channel_id, ip_hash, email NULL, created_at, last_seen_at, expires_at),
    tenant RLS in the 0014/0021 shape with the NULLIF guard;
  - `embed_customers` (tenant_id, embed_id, allowed_origins, the per-embed
    JWT key's PUBLIC part or hash only, enabled), tenant RLS;
  - the `channel_guest` HUM kind and system role (as `demo_user`);
  - the restrictive `app.channel_scope` policy, `USING` and `WITH CHECK`,
    on every table a channel reader reaches, listed by name in the
    migration header (`messages`, `channels`, `channel_humans`, reactions,
    revisions, files, the search signature index).

  Files: `RDB/<next free at push>_embed_channel_scope.sql` (*new*);
  `GO/store/channel_scope_rls_test.go` (*new*). The negative tests set the
  GUC directly as the runtime role `spool_hub_rt`: a scoped session reads
  and writes no other channel, no DM (`channel IS NULL`), no lobby, tasks
  or alerts; an unscoped staff session is unchanged; the catalogue gate
  (`rls_failclosed_test.go`) sees both new tables. Done: green on postgres
  (`PRE_PUSH_TIER=full`), applied on dev and prd.
- [x] T102 **store** (claude; needs T101 applied dev+prd).
  `store.inChannel(tenant, channel)` beside `inTenant` and `asOperator`;
  visitor mint (HUM + membership + channel + `channel_humans` in one
  transaction), lookup by token hash, slide / expire; `embed_customers`
  reads. Files: `GO/store/rls.go`; `GO/store/embed_visitors.go` +
  `_test.go` (*new*); `GO/store/embed_customers.go` + `_test.go` (*new*).
  Done: a visitor request path cannot reach `inTenant` (test).
  Built: `inChannel` refuses "", a default or reserved channel
  (`ErrNoChannel`); `MintEmbedVisitor`, `SlideEmbedVisitor`,
  `ExpireEmbedVisitor` run under it; `EmbedCustomer` and
  `EmbedVisitorByToken` are reviewed operator reads (the URL's embed id,
  the token's hash), `EmbedCustomers` the staff list. Gate:
  `TestEmbedVisitorPathNeverInTenant` walks the store's call graph from
  `embedVisitorPath`. Open for T104: the visitor's `tenant_memberships` row
  is a member row like any other, so member lists must leave out
  `channel_guest`.
- [x] T103 **cnf** (claude; needs nothing). `env.hub.embed.*`: `enabled:
  false`, every limit of `spec.md` section 6 except the spend cap (T305),
  token lifetime 30 d sliding / 180 d cap. Files: the `env.hub.embed` block
  of `csi-spl-cnf/csi-spl/all.env.yaml`; the rendered `dev` / `prd` env
  files; `GO/config/config.go` + `config_test.go`. Done: `ENV=<env> ./run
  -a do_tpl_gen` + `git diff --exit-code` on both envs.
- [ ] T104 **hub visitor API** (claude; needs T102, T103). `POST
  /v1/embed/<embed-id>/visitor`; the bearer token path for a
  `channel_guest` (never a cookie); the `ChannelGuest` system role, kept
  out of `rbac.RoleIDs`; read, post (4 KB text, no file) and delete-own-
  channel (erasure) in its one channel, every call under `inChannel`; 404
  while the flag is off. Files: `GO/hub/embed_visitor.go` + `_test.go`
  (*new*); `GO/rbac/rbac.go` + `rbac_test.go`; `GO/auth/embed_bearer.go` +
  `_test.go` (*new*; the existing auth files are not edited). Done: a
  visitor sees no channel list, people list, docs or search outside its
  channel (one test each); a staff session is unchanged.
- [ ] T106 **hub staff side** (claude; needs T104). One `#sales` triage
  line (a link, never the text) on a new visitor channel and on a first
  post after 24 h quiet; retention sweep (30 days after the last message,
  unless marked a lead); lead mark; owner block (token revoked, channel
  kept); the spec 091 public export excludes `channel_guest` channels, with
  a test. Files: `GO/hub/embed_staff.go` + `_test.go` (*new*);
  `GO/hub/embed_retention.go` + `_test.go` (*new*); the 091 export filter
  (look under `RUN/spl-public-*`; the lane names the file it changed in its
  report). Done: tests green; the export test plants a visitor message and
  finds it absent.
- [ ] T106b **WUI staff side** (mistral or grok; needs T106 on dev). The
  "Visitors" rail group for biz_owner and admin, the lead and block buttons
  in the channel header. Files: `WUI/components/ChannelSidebar.vue`; one new
  `WUI/components/VisitorChannelActions.vue`; its unit test; the i18n keys
  (multilingual text gets the agy review last, the language rule). Done:
  `pnpm run typecheck`, the unit test, `test:e2e` on the generated bundle;
  the initial-JS budget holds (`perf-budget.py`).

### Phase 2: embed (spec 3.2, 5, 6)

- [ ] T105 **hub abuse** (claude; needs T104). The `spec.md` section 6
  limits as `quota_counts` kinds `embed_visitor`, `embed_post`,
  `embed_turn` (refuse before writing); client IP as 017 FR-SEC-006; the
  self-hosted proof-of-work + honeypot on the FIRST post; repeat offenders
  (3 hits / 24 h: challenge every post; 5: 24 h ip_hash ban); bans via
  `demo_bans`; the token expiry sweep (`SweepDemo` pattern). NOT here: the
  spend cap (T305). Files: `GO/hub/embed_abuse.go` + `_test.go` (*new*);
  `GO/hub/embed_pow.go` + `_test.go` (*new*); `GO/hub/embed_sweep.go` +
  `_test.go` (*new*). Done: each 429 / 413 / 503 has a test that also
  proves nothing was written.
- [ ] T201 **hub `/embed/*` route** (claude; needs T102, T103).
  `frame-ancestors <embed_customers.allowed_origins>` on `/embed/*` only;
  every other path keeps `'none'` and `X-Frame-Options: DENY`; the loader
  with `Cross-Origin-Resource-Policy: cross-origin`; no
  `Access-Control-Allow-Origin` for a customer site. Files:
  `GO/hub/embed_serve.go` + `_test.go` (*new*). Done: a test per header;
  an unknown or disabled embed id gets `'none'`;
  `csi-spl-wui/tests/unit/csp-policy.test.mjs` still green (the WUI CSP is
  not touched).
- [ ] T202 **loader + iframe chat page** (claude; needs T201, T104).
  `/embed/v1/loader.js` (launcher button, iframe to
  `/embed/v1/chat?e=<embed-id>`) and the chat page; token in the iframe's
  own `localStorage`, sent as `Authorization: Bearer`; `postMessage` with
  an exact `targetOrigin` and an `event.origin` check, UI events only (open,
  close, unread count). Files: `GO/hub/embedassets/` (*new dir*: loader.js,
  the chat page, their test). Done: a test that no message text crosses
  `postMessage`; the Safari third-party storage lifetime measured (n
  stated) and reported before any token lifetime is promised (`spec.md`
  4.1).
- [ ] T203 **hub embed admin API** (claude; needs T102). The workspace
  owner sets `allowed_origins` and makes the per-embed JWT key; the private
  part is shown once and never stored, logged or committed. Files:
  `GO/hub/embed_admin.go` + `_test.go` (*new*). Done: owner-only (a member
  gets 403); the private key is in no response after the first.
- [ ] T204 **WUI embed admin page** (mistral or grok; needs T203 on dev).
  Files: `WUI/pages/embed/` (*new*), its unit test, i18n keys (agy review
  last). Done: as T106b.
- [ ] T205 **signed-in customer** (claude; needs T104, T203). The
  customer's 5-minute JWT (`sub`, `aud` = embed id), verified with the
  per-embed key; (embed, sub) -> one `channel_guest`. Files:
  `GO/hub/embed_jwt.go` + `_test.go` (*new*). Done: expired, wrong `aud`,
  wrong key, replayed: each refused (one test each).
- [ ] T206 **e-mail relink** (claude; needs T104). Optional e-mail after
  the first answer, its purpose shown; a 15-minute single-use link binds a
  new token to the same visitor. Files: `GO/hub/embed_relink.go` +
  `_test.go` (*new*); one new mail template under `GO/invitemail/`. Done:
  a reused or expired link is refused; the e-mail is visible to the
  workspace owner only.
- [ ] T207 **flag on** (claude; needs T104..T206 on trunk and deployed).
  `env.hub.embed.enabled: true` for dev, then prd with the owner's go; the
  `csitea` workspace's `embed_customers` row (origin csitea.net) through
  T203's API, not SQL. Files: `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` and
  their rendered files. Done: `do_tpl_gen` + `git diff --exit-code`; the
  loader answers on dev, then prd.
- [ ] T208 **csi-web side, LAST lane of phase 2** (claude; needs T207 on
  dev for the dev deploy, on prd for the prd deploy). In the separate repo
  `/opt/csi/csi-web`, `csi-web-wui/src` only: the one script tag on
  csitea.net and its CSP (`script-src` for the loader, `frame-src` for the
  hub host, from that repo's cnf, never a literal). No change in this repo.
  Gate, that repo's own (`gh api
  repos/csitea/csi-web/contents/csi-web-utl/src/bash/run` lists
  `check-pre-push-lint.func.sh` and `run-wui-tests.func.sh`): from
  `csi-web-utl`, `./run -a do_check_pre_push_lint`, then `./run -a
  do_run_wui_tests` (the-bot; tests 101-103 stay green), and the hygiene
  rules of that repo's CLAUDE.md. Deploy `ENV=dev` then `ENV=prd` `./run -a
  do_gcp_deploy_wui` from `csi-web-utl` with `APP_PATH=/opt/csi/csi-web
  ORG=csi APP=web CON_WUI=con-csi-web-wui`. The repo is not on every box
  (`ls /opt/csi/csi-web` -> absent on the box that wrote this file): spawn
  the lane where it is checked out. Done: the pop-up opens a visitor
  channel from csitea.net on dev, then prd.

### Phase 2b: live feed (owner msg 9b62e197, not in spec 121 v1.2)

- [ ] T2B1 **HOLD on F1/F2.** The owner, verbatim: "The way I envision it is
  that, directly on the site, we will have a live feed from some movement
  which happens on the school hub. When one clicks there, there will be this
  time slot for anyone to ask a question on anything, both on this idea and
  on this board." ("school hub" = Spool Hub.) F1: what the feed shows (A,
  recommended: one owner-chosen public channel; B: agent activity titles;
  C: all). F2: a click opens the visitor chat. Asked by c-002:
  https://spool-hub.ai/m/43c43312-c96e-426f-b276-c4d3719a9066. Not designed
  here: the v1.3 editor folds the answers, then this slot is split into
  lanes.

### Phase 3: agent answers and metering (spec 3.3, 4.3, 7)

- [ ] T301 **rdb, metering DDL** (claude; needs T101 landed, so the two
  migrations do not race for one number). `usage_events` (append-only,
  tenant RLS, the kinds of `spec.md` 7 plus `unmetered`), `model_prices`
  (provider, model, kind, micros per million, valid_from), `token_budgets`
  (per workspace, optionally per channel or visitor). Files: `RDB/<next free
  at push>_usage_events.sql` (*new*); `GO/store/usage_rls_test.go` (*new*).
  `0166_cost_lines.sql` (spec 123) is read, never edited: spec 123's
  rollup reads `usage_events` later. Done: green on postgres, applied dev
  and prd.
- [ ] T302 **metering** (claude; needs T301 applied). A `turn_id` on every
  hub-dispatched turn; the seat reports `{turn_id, provider, model,
  tokens_in, tokens_out, cache_read, cache_write}` from the model's own
  usage record on the result envelope; the hub writes the rows with
  `unit_cost_micros` copied at write time; a turn with no report is written
  `unmetered` and alerts. Files: `GO/wire/wire.go` + `wire_test.go` (the
  envelope fields); `GO/hub/usage_events.go` + `_test.go` (*new*);
  `GO/store/usage_events.go` + `_test.go` (*new*); the box side, one new
  `GO/spool/usage_report.go` + `_test.go`. Done: a turn without a report is
  never read as zero (test).
- [ ] T303 **model prices** (claude; needs T301 applied). Named action
  `do_spl_model_prices_sync`: fills `model_prices` from cnf; a price change
  is a new row. Files: `RUN/spl-model-prices-sync.func.sh` +
  `OT/spl-model-prices-sync.tst.sh` (*new*); the `model_prices` block of
  `csi-spl-cnf/csi-spl/all.env.yaml` (T103 owns the `env.hub.embed` block
  of the same file: disjoint blocks, rebase). Done: dry run by default;
  re-running writes nothing new.
- [ ] T304 **token budgets** (claude; needs T302, T303). Check before a
  turn is dispatched (refuse before the work is built), 429 `token_quota`,
  one notice to the workspace owner at 80 %; hard stop by default. Files:
  `GO/hub/token_budget.go` + `_test.go` (*new*); `GO/store/token_budget.go`
  + `_test.go` (*new*). Done: a refused turn writes no usage row and starts
  no seat.
- [ ] T305 **unpaid spend cap, HOLD on N1b** (claude). The owner moved Q-N1
  to EUR 5 per visitor chat session (msg e8a817b3); N1b, the embed-wide
  daily ceiling (recommended EUR 50), is still asked. When answered: both
  caps in cnf, 429, the owner alerted on a hit. Files when built:
  `GO/hub/embed_spend_cap.go` + `_test.go` (*new*) and its cnf keys.
- [ ] T306 **the sales agent** (claude; needs T104, T304). One dedicated
  agent per selling workspace reads its visitor channels and no other
  agent does (Q-V2 = A); it answers first and hands over to the owner when
  unsure (Q-V1 = A); its context is the visitor channel's text plus the
  owner-written "sales facts" doc, nothing else; it runs on a pay-per-token
  API key (Q-M3 = A) with the cheapest model that does the job and declines
  anything outside what Csitea sells (41925444). The key is minted out of
  band and never named in a brief, a log or git. Files:
  `GO/hub/sales_agent.go` + `_test.go` (*new*); `GO/hub/sales_context.go`
  + `_test.go` (*new*). Done: the test that a visitor channel's context
  holds no other channel's message ids; an out-of-scope question is
  declined (a fixed transcript). The "sales facts" text is the owner's, not
  a lane's.
- [ ] T307 **knowledge ingest, HOLD on G1/G2.** The owner (msg 78d59612),
  verbatim: "And we should have one trained agent which has been fed all of
  the information from our website and also from our Google Drive for our
  business, to be able to stand by and start answering. This one agent
  should always be on standby." G1: Drive scope (A, recommended: one public
  folder; B: whole Drive). G2: standby (A, recommended: hub on-demand small
  API model; B: an always-running seat). Asked by c-002:
  https://spool-hub.ai/m/001d47d4-693a-4c24-a73c-d81b846f3657. Not
  designed here; G2 = B would change T306's run model.

### Phase 4: workspace sale on metered pricing (spec 3.4, 8, 9): HOLD

- [ ] T4xx **HOLD on spec 122's pricing gate** (`pricingReady(month)`,
  spec 122 section 9). It holds only when all of these measurements exist:
  - **M0**: an `estate_cost_months` row with `source=billing_export` for a
    closed month (needs `do_gcp_billing_export_setup`, the owner, once);
  - **M2** (one workspace) and **M3** (the knee, `W_max`): rows with
    n >= 5, newer than the last shape hash;
  - **M4** (the token gap): a row at most 35 days old, or the +20 % launch
    buffer flagged as the owner's estimate.

  Plus spec 122 build lane 4 (the gate itself). Split into lanes only then:
  the `metered` plan kind in the buy-a-tenant checkout, `price_plans`
  (`margin_pct` = 29), card top-up drawn down by `token_budgets`, 409
  `pricing_not_ready`, the `/services` catalogue (section 9).

### Phase 5: fixed-cost slice (spec 3.5): HOLD

- [ ] T5xx **HOLD on spec 122 M0 and M3** (slice = the month's fixed cost /
  `W_max`), and on a second embedding customer.

### Later (L1)

The paid private channel (`spec.md` section 10): not in v1, no lane.
