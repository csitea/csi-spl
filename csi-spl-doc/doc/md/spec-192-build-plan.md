# Spec 192 build round - plan v0.1 (8 rows, 5 batches)

Epic: SPL-2398  
Spec: csi-spl-doc/specs/192-agent-login-from-wui (v0.3)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6472  
Topic: 4781ca4e-f43b-43f0-a86d-0dc37ea19d0a  
Discussion: 4781ca4e-f43b-43f0-a86d-0dc37ea19d0a (t1; the dispatch holder owns it; the planner reports on task `dispatch-4781ca4e`)

Owner HUM-10, by pointer:

- t1 `4781ca4e`, form `90488e20` answer **A** (`msg 32f8e23a`, 2026-11-25 07:56Z):
  "Plan it as a build round now: a planner orders L1-L8, a cross-vendor review
  signs it, the rows are queued".
- Earlier answers built into spec 192 v0.3 (`a16d9b6a4`, SPL-6374): poll
  `2728652b` (`msg 4379dd90`): Q-1 **A** (`admin` and `biz_owner`), Q-2 **B**
  (sign in once, then copy box-to-box over the ssh peer path; per-box sign-in
  where no peer reaches), Q-3 **B** (operator workspace on now for every wired
  kind; customer workspaces keep the per-vendor gate), Q-4 **B** (restart every
  seat of that kind on the box at once after Switch account), Q-5 **B**
  (mistral and qwen stay on Agent keys; AI vendors shows state and links
  there). Not asked again here.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) R1-R16, sections 1-3 and 5.
  The rulebook wins over this plan.

**What this round is.** Spec 192 section 12 names L0 plus eight build rows,
L1-L8. L0 (spec 181 B11, SPL-6345) is already on `origin/master`: this plan
builds directly on L0 and does not re-plan it. The eight rows L1-L8 fit within
rulebook 1.1's hard cap of 10 rows. This plan re-measures each row's sites on
one sha, orders L1-L8 into five batches of disjoint files (R1, at most two rows
live in any batch), assigns each row's kind (with `Kind: secret` for login
files, tokens, and box-to-box copy), author vendor, cross-vendor R7 reviewer,
red control, and test column (R2), and proposes one brief per row. It writes no
code and edits no spec file.

**Status: v0.1, draft for cross-vendor review and dispatch holder GO.** Planner:
a-486 (`agy`, main for `specs_and_docs`). Cross-vendor reviewer: one `claude`
seat (the holder places it; `mistral` sits on no review seat and `grok` is off
fleet-wide). Nothing lands on master until the panel signs PASS and the
dispatch holder gives GO.

**One sha.** Every read is on **`f2cb19298`**
(`f2cb192985464f4ef0023195235ca49196b8d531`, `origin/master` at
2026-11-25T08:25Z, after a fresh fetch), with `git show` / `git grep`, n=1 per
command. `git merge-base --is-ancestor a16d9b6a4 f2cb19298` -> rc 0 (spec 192
v0.3 is on trunk with no newer edit to `csi-spl-doc/specs/192-agent-login-from-wui/`).
L0 is on trunk: `git merge-base --is-ancestor <c> f2cb19298` -> rc 0 for all
three SPL-6345 commits (`61869b56f` api, `a51a7f1da` orc, `50dbdaa6d` wui).
Lane map, queue, and vendor mix are live state and carry their own time.

No credential path, token, login input, personal name, OS user name, box
shorthand, or customer name appears in this plan or in any proposed row brief.

## 1. Baseline

### 1.1 Nothing of spec 192 is built

- `git grep -n 'vendor_logins\|vendor-logins' f2cb19298 -- csi-spl-api csi-spl-rdb csi-spl-wui/src csi-spl-orc | wc -l`
  -> **0**.
- **rdb head.** `git ls-tree --name-only f2cb19298 csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`
  -> `0323_fleet_ask_queue_order.sql`; `git ls-remote origin 'refs/rdb-claims/*'`
  -> highest claim `0323`. Rows L1, L2, and L5 each claim their own migration
  number at work time with `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`
  (developer guide 2.8.3); today that is `0324` or later.
- **Box relay switch not yet in cnf.** `git grep -n 'signin_relay_kinds' f2cb19298 -- csi-spl-cnf/`
  -> **0** lines (`spl-ws-signin-relay.func.sh:65` reads `spl_box_ws_cnf signin_relay_kinds`,
  which answers empty today). `example.env.yaml:188` carries
  `SPOOL_HUB_SIGNIN_RELAY_KINDS: ""`.
- **Sidecar command not yet wired in `do_spl_desk_up`.**
  `git grep -n 'SPOOL_SIGNIN_RELAY_CMD' f2cb19298 -- csi-spl-orc/` -> **0**
  lines (owner Q2, section 2.4).

### 1.2 What L0 (spec 181 B11, SPL-6345) already built on `f2cb19298`

Spec 192 builds on these three landed commits and does not re-plan them:

| layer | commit | what is on `f2cb19298` | what spec 192 extends |
|---|---|---|---|
| api (`61869b56f`) | 20 files | `POST /v1/signin-relay`, `GET /v1/signin-relay/{relay}`, `POST /v1/signin-relay/{relay}/input`, `DELETE /v1/signin-relay/{relay}` (`hub/signin_relay.go:211-219`); in-memory 10-min `signinRelays` map (`:58,:107`); age-sealed input to `pins.box_x25519` (`:347-358,:473-490`); `SPOOL_HUB_SIGNIN_RELAY_KINDS` (`config/config.go:323`, `hub/server.go:333`); `wire.SigninRelayLane` / `SigninRelayOutLane` (`wire/signin_relay.go:49-69`); `hubclient/signin_relay_frame.go` dedup + serial run; `cmd/spool/signin_relay.go` `SPOOL_SIGNIN_RELAY_CMD` stdin-only runner; `TestSigninRelayNeverStoresInput` Postgres base-table walk (`hub/signin_relay_test.go:287,:474`) | L1 switches auth to `vendor_logins.manage` + unconfirmed-manager refusal, splits the switch per workspace (operator vs customer), and widens box selection from `dedicatedBoxes` to all enrolled pins; L2 adds `/v1/vendor-logins*` fan-out, audit + label tables, box facts, offline/new-box catch-up, and extends `wire` + `cmd/spool/signin_relay.go` ops (`out`, `renew`, `status`, `copy`) and report fields |
| orc (`a51a7f1da`) | 2 files | `do_spl_ws_signin_relay` (`spl-ws-signin-relay.func.sh:33-143`): ops `start|input|end`, `claude` only (`:45`), `tmux load-buffer -` stdin paste (`:121-123`), `SIGNIN_RELAY state=<s> [url=<u>] [reason=<r>]` report (`:53-58`), `ws-signin-relay.tst.sh` | L3 widens OS-user binding to every enrolled box (operator agent user for operator workspace; `<W>`'s own user elsewhere, refusing cross-workspace writes), adds `out`/`renew`/`status` + box fact output + seams for L4/L5/L8, and sets `env.box.signin_relay_kinds`; L4 wires `grok` and `agy` or reports `no_relay`; L8 adds workspace-scoped box-to-box copy |
| wui (`50dbdaa6d`) | 27 files | `SigninRelayPanel.vue`, `utils/signin-relay.mjs`, `agent-keys.vue:36` embedding the panel, `spool-client-lazy.mjs:2509` `signinRelay`, `agent-keys.test.mjs`, `signin-relay.test.mjs`, 19 locales + GCT report | L6 adds the **AI vendors** Settings section (`ai-vendors`), adds `ai-vendors` to `MOCK_GATED`, moves subscription sign-ins from Agent keys (replacing the inline panel with a link), adds full multi-box/fan-out/confirm/audit/label UI + 19 locales + GCT check + e2e |

### 1.3 Sites, re-measured on `f2cb19298`

`api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `cmd:` =
`csi-spl-api/src/go/spool-hub-api/cmd/spool/`, `rdb:` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `orc:` = `csi-spl-orc/`, `wui:` =
`csi-spl-wui/src/`.

| site | what lives there on `f2cb19298` | used by |
|---|---|---|
| `api:rbac/rbac.go` | `VendorKeysManage` `:89`, `Permissions` `:191-241` (`:240`), `Defaults` `BizOwner` `:271-275`, `Admin` `:278-281` | L1 |
| `rdb:0232_vendor_keys_manage.sql` | template for inserting a permission and granting to `biz_owner` + `admin` (`:33-37`); `HUM-[0-9]+` actor CHECK (`:41`) | L1, L2 |
| `rdb:0174_workspace_vendor_keys.sql` | template for tenant audit table, RLS (`tenant_scope` + `operator_scope`), append-only trigger (`:74-125`) | L2 |
| `rdb:0235_pins_box_x25519.sql` | `pins.box_x25519` recipient column (`:22-23`) | L1, L2 |
| `rdb:0149_fleet_agent_kinds_off.sql` | `tenants.fleet_agent_kinds_paused jsonb` (`:34-35`) | L5 |
| `api:store/humans_rbac_test.go` | `TestRBACSeedMatchesDefaults` `:170` (enforces rdb seed == `rbac.Defaults`) | L1 |
| `api:store/rls_test.go` | `TestRLSCoversEveryTenantTable` `:103` (every new tenant table must carry RLS) | L2, L5 |
| `api:store/vendor_keys.go` | `VendorKeyKinds` `:22`, `VendorKeyManagerConfirmed` interface `:73`, Memory `:158`, Postgres `:261` | L1 |
| `api:store/box_facts.go` | `BoxFactsMaxBytes` `:20`, `BoxFactSheet` `:23`, `BoxFacts` interface `:31` | L2 |
| `api:store/fleet_load.go` | `KindPause` `:61-65`, `MaxKindPause` `:68`, `mergePauses` `:239-260`, `checkAgentKinds` `:310-328`, `FleetLoadTarget` `:331-337`, Postgres `:416-458` | L5 |
| `api:config/config.go` | `SigninRelayKinds` `:323`, `OperatorTenant` `:471`, `OperatorWorkspace()` `:756-761` | L1 |
| `api:wire/signin_relay.go` | `TSigninRelay` `:17`, `TSigninRelayOut` `:21`, `FeatureSigninRelay` `:25`, ops `:28-32`, states `:35-44`, `SigninRelayLane` `:49-54`, `SigninRelayOutLane` `:65-69` | L2 |
| `api:wire/wire.go` | `BoxHost` `:994-1000` (box hello fact sheet) | L2 |
| `api:hub/server.go` | `OperatorTenant` `:241`, `SigninRelayKinds` `:333`, `relays signinRelays` `:396` | L1, L2 |
| `api:hub/operator_workspaces.go` | `operatorTenant(ctx)` `:58` | L1, L5 |
| `api:hub/keys.go`, `api:store/humans.go` | `humanIDRe = ^HUM-[0-9]+$` (`hub/keys.go:37`, `store/humans.go:101`) | L2 |
| `api:hub/vendor_keys.go` | `routeVendorKeys` `:69-83` (`routeSigninRelay` `:80`), `vendorKeyActor` `:108-133` (unconfirmed-manager check `:122-131`), `vendorKeyActAs` `:137-147` | L1, L2 |
| `api:hub/signin_relay.go` | `routeSigninRelay` `:211-219`, `signinRelayActor` `:223-238`, `signinRelayKindOn` `:242-253`, `signinRelayBox` `:297-320`, `dedicatedBoxes` `:323-344`, `deskRecipient` `:347-358`, `sendSigninRelay` `:509-521`, `onSigninRelayOut` `:537-565`, `checkSigninOut` `:570-587` | L1, L2 |
| `api:hub/signin_relay_test.go` | `TestSigninRelaySwitchOff` `:190`, `TestSigninRelayRefusals` `:224`, `TestSigninRelayNeverStoresInput` `:287` (Postgres base-table walk `:474-500`) | L1, L2 |
| `api:hub/box_facts.go` | `boxFacts` `:55-61`, `keepHostFacts` `:114-133`, `cleanHost` `:178-192`, `cleanFact` `:318-329` | L2 |
| `api:hub/ws.go` | `onBoxAnswer` `:197-198`, `keepHostFacts` `:253`, `sendSigninRelay` `:266` | L2 |
| `api:hub/fleet_load.go` | `routeFleetLoad` `:73-77`, `onFleetLoadLane` `:381-408`, `fleetLoadInForce` `:413-432`, `fleetLoadPause` `:440-476` | L5 |
| `api:hub/openapi.json` & `openapi_routes_test.go` | `TestOpenAPIRoutes` `:314` (every new route in L2 must be in `openapi.json`) | L2 |
| `cmd:hub.go`, `cmd:signin_relay.go` | `SigninRelayKinds` pass-through `hub.go:451`, `startSigninRelay` `hub.go:1393`, `cmdSigninRelayer.Run` `signin_relay.go:83-111` (currently allows `start|input|end` only), `parseRelayReport` `:138-162` | L1, L2 |
| `cmd:fleet_load.go` | `cmdFleetLoad` `:34-57` (`fleet-load get`, `fleet-load pause`) | L5 |
| `orc:lib/bash/funcs/spl-box-workspace.func.sh` | `spl_box_ws_cnf` `:31`, `spl_box_ws_claim` `:55`, `spl_box_ws_user` `:67`, `spl_box_ws_guard` `:80` | L3, L8 |
| `orc:src/bash/run/spl-ws-claude-signin.func.sh` | `SPL_WCS_SUBDIR`/`SPL_WCS_SOCKET` `:38`, `spl_wcs_caller_ok` `:58-67` (refuses `SPOOL_AGENT_USER` `:60`), `spl_wcs_runtime` `:71-81`, `spl_wcs_login_argv` `:104-107`, `spl_wcs_in` `:109-129`, `spl_wcs_out` `:131-146` | L3 |
| `orc:src/bash/run/spl-ws-signin-relay.func.sh` | `do_spl_ws_signin_relay` `:33-50`, `spl_wsr_report` `:53-58`, `spl_wsr_switch_on` `:62-70`, `spl_wsr_start` `:88-105`, `spl_wsr_input` `:111-132`, `spl_wsr_end` `:134-143` | L3, L4 |
| `orc:src/bash/run/spl-desk-up.func.sh` | `hub-run` sidecar launch `:389-431` (does not set `SPOOL_SIGNIN_RELAY_CMD` yet; owner Q2) | L3 |
| `orc:src/bash/scripts/agent-login-cred.sh` | `lc_user` `:43-51`, slot 1/2 setup `:58-65`, `lc_stat` `:70-78`, `lc_put` `:80-96`, `lc_acct` `:105-109`, `lc_acctput` `:113-126`, `lc_probe` `:128-141`, dispatch `:143-152` | L8 |
| `orc:src/bash/run/spl-agent-login-check.func.sh` | `_lc_cred_at` `:264-270`, `_lc_peer_list` `:274-277`, `_lc_peers` `:281-289`, `_lc_peer_one` `:297-319`, `_lc_repair` `:372-403` | L5, L8 |
| `orc:src/bash/run/spl-agent-identity-restore.func.sh` | `_ai_grok_why` `:335-350` (grok sign-in check `:344`), seat restore entry point | L4, L5 |
| `orc:lib/bash/funcs/spl-box-quota.func.sh` | `spl_box_quota_parse` `:68-93` (claude `:72`, grok `:85`), `spl_box_quota_cache_read` `:202` | L3 |
| `orc:src/bash/features/spawn-agents/lib/spool-env.inc.sh` | `spool_agy_auth_marker` `:556` | L3, L4, L8 |
| `orc:src/bash/features/watchdog/situations/lib.inc.sh` | agy quota banner comment `:53-55` | L3 |
| `orc:src/bash/run/spl-lane-mix.func.sh` & `spl-gc.func.sh` | `agent_kinds_paused` reads (`spl-lane-mix.func.sh:506-536`, `spl-gc.func.sh:272-277`) | L5 |
| `csi-spl-cnf/csi-spl/all.env.yaml` | `claude_login_pool` `:1317-1320`, `claude_self_signin_tenants` `:1457`, `agent_split` `:1491-1530`, `agent_split_by_kind` `:1567-1574` | L3, L4 |
| `wui:utils/tenant-settings-nav.ts` | `TENANT_SETTINGS_SECTIONS` `:28-40` (`split` `:31`, `agent-keys` `:32`), `MOCK_GATED` `:51`, `tenantSettingsSections` `:58-67`, `filterByPerm` `:69-72` | L6 |
| `wui:pages/tenant-settings/agent-keys.vue` | inline `SigninRelayPanel` `:36` | L6 |
| `wui:components/SigninRelayPanel.vue` & `wui:utils/signin-relay.mjs` | B11 relay panel & mock (`SIGNIN_RELAY_KINDS` `:17`, `signinSafeUrl` `:34`, `mockSigninRelay` `:82`) | L6 |
| `wui:utils/spool-client.mjs` & `spool-client-lazy.mjs` | `vendorKeys` / `signinRelay` dispatch (`spool-client.mjs:101-102`, `spool-client-lazy.mjs:2478-2521,2637-2638`) | L6 |
| `wui:utils/fleet-load.mjs` | `fleetPauseList` `:153-162`, `normalizeFleetLoad` `:202` (must stay backward-compatible during L5 rollout) | L5 (read-only guard) |
| `csi-spl-wui/i18n/locales/` | 19 locale JSON files (`ls-tree \| wc -l` -> 19) | L6 |
| `csi-spl-wui/tests/unit/help-settings-coverage.test.mjs` & `help-sync.test.mjs` | fails if any `TENANT_SETTINGS_SECTIONS` id is missing from `csi-spl-doc/doc/help/user-settings.md` (`:77-80`), or if `wui:public/help-md/` drifts from `csi-spl-doc/doc/help/` (`help-sync.test.mjs:20-22`) | L6, L7 |
| `csi-spl-doc/doc/help/user-settings.md` | **Vendor split** `:324-330`, **Agent keys** `:331-341` (copied to `wui:public/help-md/user-settings.md` by `sync-help.mjs`) | L6 (stub), L7 (full) |
| `csi-spl-doc/specs/159-byo-ai-keys/spec.md`, `132-fleet-login-selfheal-3-boxes/spec.md`, `060-role-rotation/claude-account-failover.md` | 159 `4.3` (`:127`), 132 `section 2` (`:11`), 060 `D4` (`:29`) | L7 |

## 2. Rows

Kinds follow the fleet kind table
(`csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md`)
and `csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`. Live
`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` (`csi-spl-orc`, 2026-11-25T08:26Z):

| kind | pick at 08:26Z | main / backup | notes |
|---|---|---|---|
| `complex_coding` | `claude` | `claude` / `agy` | no `mistral` (`mistral_coding_allowed: false`, owner msg `91bf8278`) |
| `simple_coding` | `agy` | `claude` / `agy` | no `mistral`; never `mistral` on `csi-spl-wui/` (developer guide 5.1) |
| `tests` | `claude` | `claude` / `agy` | no `mistral` |
| `specs_and_docs` | `agy` | `agy` / `claude` | L7 writes `wui:public/help-md/` via `sync-help.mjs`, so never `mistral` |
| `i18n` | `agy` | `agy` / `claude` | required language check is Google Cloud Translation (`do_spl_lang_review_gct`); agy optional |
| `secret` | `claude` | `claude` / `grok` | data rule (`20-spawn-an-agent.md:28-35`): `claude` or `grok` only, never `agy`, `qwen`, `mistral`, or `codex`; brief names no credential path; `grok` is off fleet-wide (`all.env.yaml:1493,1539`) |

**Secret-class rows (L3, L4, L8).** Every row whose code handles login files,
auth codes, tokens, CLI login flows, or box-to-box credential copy is
`Kind: secret`: **L3**, **L4**, and **L8**. Author is `claude` only (`grok` is
the sole legal backup and is off fleet-wide); never `agy`, `qwen`, `mistral`,
or `codex`. None of their briefs names any credential file path.

**R7 cross-vendor review (rulebook 2.7.2).** `agy` reviews `claude`, `claude`
reviews `agy`. `mistral` sits on no review seat (`mistral_review_allowed: false`,
`all.env.yaml:1530`, owner msgs `65a45673` and `591ca574`); `grok` is off
fleet-wide (`all.env.yaml:1493,1539`). For `L1`, `L2`, `L5`, `L6`, and `L7`
this gives strict cross-vendor review (`agy` on `claude`-authored rows;
`claude` on `agy`-authored L7, or `agy` if backup `claude` authors L7). For
`Kind: secret` rows (`L3`, `L4`, `L8`), whether `agy` may sit on the R7 seat
reading only the public git diff and synthetic `SPOOL_TEST=1` fixtures (never
live credentials) is **owner question Q1** (section 2.4 & section 6; first
option recommended: `agy` on public diff + synthetic tests only).

### 2.1 Action table

| row | what | kind | vendor | R7 reviewer | red control | depends on | batch |
|---|---|---|---|---|---|---|---|
| L1 | rdb + hub: `vendor_logins.manage` to `admin` & `biz_owner`, act-as & unconfirmed-manager refusals, per-workspace relay switch (operator on; customer per-vendor), widen box check to all enrolled pins | `complex_coding` | `claude` | `agy` | R2, R4, R6 | L0 (on master) | 1 |
| L3 | orc + cnf: `do_spl_ws_signin_relay` per workspace OS user on every enrolled box, ops `out`/`renew`/`status`, non-secret box fact output, seams for L4/L5/L8, `env.box.signin_relay_kinds` | `secret` | `claude` (backup `grok` [off]; never `agy`/`qwen`/`mistral`) | `agy` on public diff + synthetic tests (Q1 A; else `claude` waiver, Q1 B) | R1, R7, R10 | L0 (on master) | 1 |
| L2 | rdb + hub + wire + cmd: `/v1/vendor-logins*` fan-out & status, audit + label + pending tables, box facts ingestion, offline/new-box catch-up & notice, `cmd/spool/signin_relay.go` new ops & report fields | `complex_coding` | `claude` | `agy` | R1, R3, R5 | L1, L3 | 2 |
| L4 | orc + cnf: measure `grok` and `agy` CLI terminal login flows (Q3), wire URL+code or device-code login else report `no_relay`, update `env.box.signin_relay_kinds` & `operator_signin_relay_kinds` if wired | `secret` | `claude` (backup `grok` [off]; never `agy`/`qwen`/`mistral`) | `agy` on public diff + synthetic tests (Q1 A; else `claude` waiver, Q1 B) | a `no_relay` kind offered start/Log in -> fails | L3 | 2 |
| L5 | rdb + hub + cmd + orc: `KindPause` keyed by (`<W>`, kind, box) for all workspaces, switch lifts own entry, logout sets entry, post-switch restart of every `<W>` seat via `do_spl_agent_identity_restore` | `complex_coding` | `claude` | `agy` | R8, R9, R10 | L2, L3 | 3 |
| L8 | orc: box-to-box copy [Q-2 B] (`agent-login-cred.sh` per workspace OS user + `grok`/`agy` login files; new `do_spl_ws_login_copy` checked against hub pin list) | `secret` | `claude` (backup `grok` [off]; never `agy`/`qwen`/`mistral`) | `agy` on public diff + synthetic tests (Q1 A; else `claude` waiver, Q1 B) | R5, R10 | L3, L4 | 3 |
| L6 | wui + help stub: **AI vendors** Settings section (`ai-vendors` after `split`, in `MOCK_GATED`), multi-box status/actions/confirms/labels/audit, Agent keys link, 19 locales + `do_spl_lang_review_gct`, e2e | `complex_coding` | `claude` (never `mistral`) | `agy` | member without perm sees section -> e2e fails; `no_relay` row with Log in -> e2e fails; code left in input/DOM/Pinia/storage -> e2e fails | L2, L4, L5, L8 | 4 |
| L7 | doc: full **AI vendors** section in `csi-spl-doc/doc/help/user-settings.md` + `sync-help.mjs` copy, spec 159 4.3 / 132 s2 / 060 D4 notes, spec 192 s12 row status | `specs_and_docs` | `agy`, backup `claude` (never `mistral`) | `claude` if `agy` (cross-vendor); `agy` if `claude` | `grep -c 'ai-vendors' csi-spl-wui/src/public/help-md/user-settings.md` -> 0 fails; `sync-help.mjs --check` fails on drift | L6 | 5 |

Row count: **8** (within rulebook 1.1's hard cap of 10). Max rows live in any
batch: **2** (batches 1, 2, and 3).

### 2.2 Batches and disjoint files (R1, R16)

No file path appears in two rows of any batch. Dependent batches place within
30 minutes of their prerequisites landing (R16).

- **Batch 1: L1, L3.**
  - **L1** (`csi-spl-rdb/` + `csi-spl-api/` only): new
    `rdb:<NNNN>_vendor_logins_manage.sql`; `api:rbac/rbac.go`;
    `api:config/config.go`; `api:hub/server.go` (`OperatorSigninRelayKinds`
    field); `cmd:hub.go` (pass-through of `OperatorSigninRelayKinds`);
    `api:hub/signin_relay.go`; `api:hub/signin_relay_test.go`;
    `api:store/humans_rbac_test.go`; `example.env.yaml`.
  - **L3** (`csi-spl-orc/` + `csi-spl-cnf/` only):
    `orc:src/bash/run/spl-ws-signin-relay.func.sh`;
    `orc:src/bash/run/spl-desk-up.func.sh` (only if Q2 A; omitted under Q2 B);
    `orc:src/bash/tests/ws-signin-relay.tst.sh`;
    `csi-spl-cnf/csi-spl/all.env.yaml` (add `env.box.signin_relay_kinds: "claude"`
    and `env.hub.operator_signin_relay_kinds: "claude"` if templated, plus
    rendered outputs via `do_tpl_gen`).
  - **Disjoint check:** L1 touches `csi-spl-rdb/`, `csi-spl-api/`,
    `example.env.yaml`; L3 touches `csi-spl-orc/`, `csi-spl-cnf/`. Zero
    overlap.
- **Batch 2: L2, L4** (after Batch 1 lands).
  - **L2** (`csi-spl-rdb/` + `csi-spl-api/` only): new
    `rdb:<NNNN>_vendor_login_audit.sql` (audit, label names, pending ops); new
    `api:store/vendor_logins.go`, `vendor_logins_postgres.go`,
    `vendor_logins_memory.go`, `vendor_logins_test.go`; `api:wire/signin_relay.go`;
    `api:wire/wire.go`; `api:hub/box_facts.go`, `box_facts_test.go`;
    `api:hub/ws.go`; `api:hub/vendor_keys.go` (register `routeVendorLogins`);
    new `api:hub/vendor_logins.go`, `vendor_logins_test.go`;
    `api:hub/signin_relay.go` (audit/copy hook); `api:hub/signin_relay_test.go`
    (R1 Postgres table walk); `api:hub/openapi.json`;
    `cmd:signin_relay.go`, `cmd:signin_relay_test.go`.
  - **L4** (`csi-spl-orc/` + `csi-spl-cnf/` only): new
    `orc:lib/bash/funcs/spl-ws-signin-kinds.func.sh` (grok/agy handlers or
    `no_relay`); `orc:src/bash/run/spl-ws-signin-relay.func.sh` (wire L3's kind
    seam); new `orc:src/bash/tests/ws-signin-relay-kinds.tst.sh`;
    `csi-spl-cnf/csi-spl/all.env.yaml` (+ `do_tpl_gen`, only if grok or agy is
    wired, updating `signin_relay_kinds` and `operator_signin_relay_kinds`,
    2.4 N5).
  - **Disjoint check:** L2 touches `csi-spl-rdb/` and `csi-spl-api/`; L4
    touches `csi-spl-orc/` and `csi-spl-cnf/`. Zero overlap.
- **Batch 3: L5, L8** (after Batch 2 lands).
  - **L5** (`csi-spl-rdb/` + `csi-spl-api/` + `csi-spl-orc/`): new
    `rdb:<NNNN>_workspace_kind_pauses.sql` (2.4 N3); `api:store/fleet_load.go`,
    `fleet_load_test.go`; `api:hub/fleet_load.go`, `fleet_load_test.go`;
    `api:hub/vendor_logins.go` (include per-box pause state & seat-restart
    summary in `GET /v1/vendor-logins`); `cmd:fleet_load.go`,
    `cmd:cli_verbs_test.go`; `orc:src/bash/run/spl-lane-mix.func.sh`,
    `orc:src/bash/run/spl-gc.func.sh`; new
    `orc:src/bash/run/spl-ws-vendor-restart.func.sh` (wired via L3's
    `spl_wsr_after_switch` seam, 2.4 N4); new
    `orc:src/bash/tests/ws-vendor-restart.tst.sh`, plus `spl-lane-mix.tst.sh`
    and `gc-agent.tst.sh` cases.
  - **L8** (`csi-spl-orc/` only): `orc:src/bash/scripts/agent-login-cred.sh`;
    new `orc:src/bash/run/spl-ws-login-copy.func.sh` (wired via L3's `op=copy`
    seam, 2.4 N4); new `orc:src/bash/tests/ws-login-copy.tst.sh`;
    `orc:src/bash/tests/spl-agent-login-check.tst.sh` (regression check).
  - **Disjoint check:** L5 touches `rdb:`, `api:`, `cmd:`, `spl-lane-mix`,
    `spl-gc`, `spl-ws-vendor-restart`; L8 touches `agent-login-cred.sh`,
    `spl-ws-login-copy`, `ws-login-copy.tst.sh`, `spl-agent-login-check.tst.sh`.
    Neither touches `spl-ws-signin-relay.func.sh` because L3 provides both
    seams (2.4 N4). Zero overlap.
- **Batch 4: L6** (after Batch 3 lands).
  - `wui:utils/tenant-settings-nav.ts`; new
    `wui:pages/tenant-settings/ai-vendors.vue`; new
    `wui:components/AiVendorCard.vue` (and helper sub-components if needed to
    keep every function <= 75 lines, developer guide 2.2.1); new
    `wui:utils/vendor-logins.mjs`; `wui:pages/tenant-settings/agent-keys.vue`;
    `wui:utils/spool-client.mjs`, `spool-client-lazy.mjs`; all 19
    `csi-spl-wui/i18n/locales/*.json`; new
    `csi-spl-doc/lang-review/<run>.json` (`do_spl_lang_review_gct`); minimal
    `ai-vendors` stub in `csi-spl-doc/doc/help/user-settings.md` + regenerated
    `wui:public/help-md/user-settings.md` via `sync-help.mjs` (2.4 N2); new
    `csi-spl-wui/tests/unit/vendor-logins.test.mjs`, new
    `csi-spl-wui/tests/e2e/ai-vendors.test.mjs`, and updates to
    `tests/unit/tenant-settings.test.mjs`, `tests/e2e/tenant-settings.test.mjs`,
    `tests/e2e/agent-keys.test.mjs`,
    `tests/unit/signed-out-member-pages.test.mjs`.
- **Batch 5: L7** (after Batch 4 lands).
  - `csi-spl-doc/doc/help/user-settings.md` (replace L6's stub with the full
    AI vendors help documentation); `wui:public/help-md/user-settings.md`
    (regenerated via `cd csi-spl-wui && node src/node/help/sync-help.mjs`,
    never hand-edited); `csi-spl-doc/specs/159-byo-ai-keys/spec.md` (4.3 note);
    `csi-spl-doc/specs/132-fleet-login-selfheal-3-boxes/spec.md` (section 2
    note); `csi-spl-doc/specs/060-role-rotation/claude-account-failover.md`
    (D4 note); `csi-spl-doc/specs/192-agent-login-from-wui/spec.md` (section 12
    row statuses and landed shas).

### 2.3 R3: live and queued lanes, read 2026-11-25T08:26-08:31Z

`lane-map.sh --check <row paths> --agent a-486`, run per row L1-L8:

- **Direct ownership collisions (exit 3):** **0** across all eight rows. No
  live lane on any box records a file belonging to L1-L8.
- **Lanes with no files recorded (exit 4):** 14 live lanes on another fleet
  box (`c-029`, `c-041`, `c-086`, `c-146`, `c-165`, `c-187`, `c-249`, `c-341`,
  `c-728`, `c-774`, `c-927`, `c-936`, `c-957`, `c-965` — rotation/customer
  seats, external-repo bug lanes, skills, and a finance spec amendment + review).
  By rule, exit 4 is not free: the placer re-runs `lane-map.sh --check` per row
  at placement (R3) and asks any lane still returning exit 4.
- **Spawn queue (`do_spl_spawn_queue`, 08:26Z, 12 rows):** r99 panel seat, 3
  bug lanes (hr-code-collision flake, issue-comment-edit-mark, external-repo archive warn
  log), s186 M9 qto-sync, 6 spec/answer/debate lanes (specs 006, 182, 193, 112,
  149, and a debate panel), and spec 039 FR-014 build planner. None names any file of
  spec 192. The placer re-checks at placement.

### 2.4 Rows needing a decision

**For the owner (asked as ONE poll block in section 6, first option
recommended).**

- **Q1. R7 reviewer for `Kind: secret` rows (L3, L4, L8) while `grok` is off.**
  The data rule (`20-spawn-an-agent.md:28-35`, `all.env.yaml:1540-1573`) keeps
  `Kind: secret` work on `claude`, `grok`, or `mistral` (never `agy` or
  `qwen`). Today `grok` is off fleet-wide (`all.env.yaml:1493,1539`) and
  `mistral` sits on no review seat (`mistral_review_allowed: false`,
  `all.env.yaml:1530`), while rulebook 2.7.2 requires cross-vendor R7 review.
  L3, L4, and L8's git diffs and `SPOOL_TEST=1` tests in this public repository
  carry zero real credentials, tokens, or personal data (synthetic fixtures
  only; live credential/account probes happen only inside the `claude` author
  lane).
  - **(A) (Recommended):** `agy` sits as the cross-vendor R7 reviewer on L3,
    L4, and L8's public git diffs and synthetic `SPOOL_TEST=1` unit tests only
    (never reading any box credential or live account); the `claude` author
    alone runs any live test-account probe.
  - **(B):** Keep `agy` off R7 on `Kind: secret` rows too: with `grok` off and
    `mistral` off reviews, L3, L4, and L8 take a fresh-session `claude`
    same-vendor R7 reviewer under waiver until `grok` returns.
  - Spot: R7 seat assignment for L3, L4, L8 only (does not block L1 or L2).
- **Q2. Wiring `SPOOL_SIGNIN_RELAY_CMD` on the fleet boxes' `hub-run` sidecars.**
  On `f2cb19298`, `spl-desk-up.func.sh` starts `spool hub-run` without setting
  `SPOOL_SIGNIN_RELAY_CMD`, so no fleet box advertises `FeatureSigninRelay` on
  its hello (`cmd:signin_relay.go:55`, `hub:signin_relay.go:510`).
  - **(A) (Recommended):** L3 wires `SPOOL_SIGNIN_RELAY_CMD` into
    `do_spl_desk_up` when `env.box.signin_relay_kinds` is non-empty (off when
    empty); the actual sidecar restart on fleet boxes still waits for an
    explicit owner go once L1-L3 land (agents never run `do_spl_desk_up` on
    prd without owner go).
  - **(B):** Keep `SPOOL_SIGNIN_RELAY_CMD` opt-in via `box.env` only, never
    wired in `do_spl_desk_up`, so each box opts in by hand.
  - Spot: L3 only (whether `spl-desk-up.func.sh` is edited in L3).
- **Q3. How L4 measures the `grok` and `agy` CLI terminal login flows.**
  Spec 192 5.2 says L4 measures each CLI's login flow on a test account first
  and wires it if it prints an https URL + pasted code or device code, else
  reports `no_relay`. Fleet boxes hold the production agent login only, not a
  spare test account.
  - **(A) (Recommended):** L4 runs each CLI's login command in an isolated
    throwaway `HOME` (no production login touched, no logout of the live agent
    user) up to its first prompt to prove whether it prints a relayable https
    URL + code / device code or requires a local-browser redirect (`no_relay`),
    and only completes an end-to-end test login if a dedicated test account is
    provided.
  - **(B):** Hold L4 until a dedicated test account for `grok` and `agy` is
    provided to the `claude` lane for full end-to-end login testing.
  - Spot: L4 only (does not block Batch 1 or L2).

**For the holder (no owner question).**

- **N1. Audit `actor` format (`HUM-<n>` vs UUID).** Spec 192 section 10 writes
  "`actor` is the member's id (the hub's human id, a uuid), never an email or
  a display name". On `f2cb19298`, the hub's human id is `HUM-<n>`
  (`humanIDRe = ^HUM-[0-9]+$`, `api:hub/keys.go:37`, `api:store/humans.go:101`,
  `rdb:0232:41`), not a UUID. L2 stores `actor` with
  `CHECK (actor ~ '^HUM-[0-9]+$')` (still never an email or display name, and
  joins to `humans` for display name at read time). L7 notes this in spec 192.
- **N2. Help sync & `help-settings-coverage.test.mjs` (L6 and L7).** Spec 192
  row L7 names `csi-spl-wui/src/public/help-md/user-settings.md` directly. On
  `f2cb19298`, `help-sync.test.mjs:20-22` enforces that `src/public/help-md/`
  is a generated copy of `csi-spl-doc/doc/help/` via
  `node src/node/help/sync-help.mjs`, and `help-settings-coverage.test.mjs:77-80`
  fails as soon as L6 adds `ai-vendors` to `TENANT_SETTINGS_SECTIONS` unless
  `csi-spl-doc/doc/help/user-settings.md` mentions `ai-vendors`. Therefore L6
  adds a minimal one-bullet stub for **AI vendors** (`/tenant-settings/ai-vendors`)
  to `csi-spl-doc/doc/help/user-settings.md` and runs `sync-help.mjs` so L6's
  unit suite passes; L7 expands it to the full user help documentation and runs
  `sync-help.mjs` again.
- **N3. Backward-compatible `KindPause` rollout (L5).** On `f2cb19298`,
  `tenants.fleet_agent_kinds_paused` (`rdb:0149:34`) is a flat
  `{kind: {until, reason, box}}` JSON object read by `spl-lane-mix.func.sh:513,523`,
  `spl-gc.func.sh:273,277`, `spl-hub-agent-kinds.func.sh:76`,
  `cmd:fleet_load.go`, and `wui:utils/fleet-load.mjs:153-162,202`. To avoid
  breaking live boxes and WUI builds during rolling deploys, L5 stores
  per-(`tenant_id`, `kind`, `box`) pauses in a new RLS-enforced table
  `workspace_kind_pauses` and serves them in an additive response field
  `agent_kind_box_pauses` on `fleet-load get` (and on `GET /v1/vendor-logins`),
  while keeping the legacy `agent_kinds_paused` field populated compatibly for
  the operator workspace until all box readers move over.
- **N4. L3's three seams keep Batch 2 and Batch 3 strictly disjoint (R1).** L3
  defines three clean seams in `spl-ws-signin-relay.func.sh`:
  1. a per-kind dispatch seam sourcing `spl-ws-signin-kinds.func.sh` if present
     (L4 adds `grok` and `agy` handlers there);
  2. `spl_wsr_after_switch "$tenant" "$kind" "$dry"`, a no-op hook unless
     `do_spl_ws_vendor_restart` is loaded (L5 supplies
     `spl-ws-vendor-restart.func.sh`);
  3. `op=copy` dispatching to `do_spl_ws_login_copy` when present, else
     `SIGNIN_RELAY state=failed reason=no_copy` (L8 supplies
     `spl-ws-login-copy.func.sh`).
  With these seams, L5 and L8 touch zero shared files in Batch 3.
- **N5. Hub operator-workspace wired-kind switch (`SPOOL_HUB_OPERATOR_SIGNIN_RELAY_KINDS`).**
  Spec 4.1 enables the operator workspace for `claude` now, and `grok` / `agy`
  once L4 wires them. L1 introduces `SPOOL_HUB_OPERATOR_SIGNIN_RELAY_KINDS`
  (default `"claude"`, fed from cnf `env.hub.operator_signin_relay_kinds`), so
  if L4 wires `grok` or `agy`, L4 updates only `csi-spl-cnf/` (`env.box.signin_relay_kinds`
  and `env.hub.operator_signin_relay_kinds` + `do_tpl_gen`) with zero Go file
  overlap against L2 in Batch 2.
- **N6. Workspace login storage binding (operator vs customer workspace).** On
  `f2cb19298`, customer workspaces use the tmpfs login dir of
  `spl-ws-claude-signin.func.sh:38,71-81` (spec 159 4.3), whereas the operator
  workspace's fleet agent user uses slot 1 resolved by `agent-login-cred.sh:58-65`
  (spec 192 6.2 & 7.1). L3 and L8 resolve the target OS user and storage root
  solely from the box's own binding of `<W>` (never from a hub frame) and
  refuse any cross-workspace target (R7, R10).

## 3. Proposed row briefs

Every row brief carries: `Epic: SPL-2398`,
`Spec: csi-spl-doc/specs/192-agent-login-from-wui`, `Class: feature`, its
`Kind:`, its action-table row verbatim (R4), its assigned R7 reviewer seat,
"re-measure every cited file:line on `origin/master` at work time", its red
control(s) and test column (R2), release-note trailers
(`csi-spl-doc/doc/help/release-notes.md`), and the fleet's standing Never list
(touch no file outside `Files: ONLY`, no prd writes, no installs, no keys, no
owner-topic posts, public repo hygiene: no customer/host/box/OS-user/personal
name, commit as the repo's identity with no AI trailers, explicit pathspecs, no
force-push). Every `Kind: secret` brief (L3, L4, L8) names NO credential path.
Each row files its own issue at placement under epic SPL-2398 and cites it in
its commit subject scope, e.g. `feat(api, SPL-<n>): ... (spec 192 L1)`.

### 3.1 L1 - `vendor_logins.manage` permission, refusals, per-workspace relay switch

- **Kind:** `complex_coding`. **Vendor:** `claude`. **R7:** `agy`. **Batch:** 1
  (after L0, already on master). `PRE_PUSH_TIER=full` (rdb migration).
- **Files:** new `rdb:<NNNN>_vendor_logins_manage.sql` (number from
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`);
  `api:rbac/rbac.go`; `api:config/config.go`; `api:hub/server.go`;
  `cmd:hub.go`; `api:hub/signin_relay.go`; `api:hub/signin_relay_test.go`;
  `api:store/humans_rbac_test.go`; `example.env.yaml`.
- **Work:**
  1. Add permission `vendor_logins.manage` in the new forward-only migration
     (mirroring `rdb:0232_vendor_keys_manage.sql:33-37`), granted to `biz_owner`
     and `admin` [Q-1 A]; add matching `VendorLoginsManage` constant,
     `Permissions` row, and `Defaults` grants in `api:rbac/rbac.go` so
     `TestRBACSeedMatchesDefaults` passes.
  2. Update `signinRelayActor` (`api:hub/signin_relay.go:223-238`) to require
     `rbac.VendorLoginsManage`, keep the `vendorKeyActAs` 403 refusal, and add
     the `VendorKeyManagerConfirmed` 403 `admin_unconfirmed` refusal for
     operator-made unconfirmed managers (mirroring
     `api:hub/vendor_keys.go:122-131`, spec section 2).
  3. Split `signinRelayKindOn` (`api:hub/signin_relay.go:242-253`) by workspace
     [Q-3 B, spec 4.1]: add `OperatorSigninRelayKinds` (`config.go`,
     `SPOOL_HUB_OPERATOR_SIGNIN_RELAY_KINDS`, default `"claude"`, passed
     through `cmd:hub.go` and `hub:server.go`, documented in `example.env.yaml`).
     When `tenant == operatorTenant` (`operator_workspaces.go:58`), check
     `OperatorSigninRelayKinds`; for every other workspace, check
     `SigninRelayKinds` (`SPOOL_HUB_SIGNIN_RELAY_KINDS`, default empty).
  4. Widen `signinRelayBox` (`api:hub/signin_relay.go:297-320`) from
     `dedicatedBoxes` to all enrolled pins of `<W>` (`ListPins` +
     `deskRecipient`, spec 4 A1), still refusing boxes outside `<W>` and pins
     without `box_x25519` (`409 box_key_not_enrolled`).
- **Done and red controls (R2, R4, R6):**
  - R2: member without `vendor_logins.manage` gets 403; planted defect removing
    the permission check sees 200 and fails.
  - R4: customer workspace with `SPOOL_HUB_SIGNIN_RELAY_KINDS` off gets 403
    `signin_relay_off` while operator workspace succeeds for `claude`; planted
    defect removing the switch check sees 201 and fails.
  - R6: act-as session gets 403 `act_as_refused` (and unconfirmed operator-made
    manager gets 403 `admin_unconfirmed`); planted defect removing the check
    sees 201 and fails.
- **Test column (R2):** `api:hub/signin_relay_test.go`,
  `api:hub/vendor_keys_test.go`, `api:store/humans_rbac_test.go`,
  `api:rbac/...`, `api:config/...`, `bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
  `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.
- **Not touched:** `csi-spl-orc/`, `csi-spl-wui/`, `csi-spl-cnf/`,
  `api:wire/`, `api:hub/box_facts.go`, `api:hub/ws.go`, `api:hub/openapi.json`.

### 3.2 L3 - Box side: `do_spl_ws_signin_relay` per workspace OS user, ops, box facts

- **Kind:** `secret`. **Vendor:** `claude` (backup `grok` [off]; never `agy`,
  `qwen`, `mistral`, or `codex`). **R7:** `agy` on public diff + synthetic
  `SPOOL_TEST=1` tests only (Q1 A; else `claude` waiver, Q1 B). **Batch:** 1
  (after L0, already on master).
- **Brief hygiene:** names NO credential path.
- **Files:** `orc:src/bash/run/spl-ws-signin-relay.func.sh`;
  `orc:src/bash/run/spl-desk-up.func.sh` (only under Q2 A; omit under Q2 B);
  `orc:src/bash/tests/ws-signin-relay.tst.sh`;
  `csi-spl-cnf/csi-spl/all.env.yaml` (+ rendered files from
  `ENV=dev ./run -a do_tpl_gen` and `ENV=prd ./run -a do_tpl_gen`).
- **Work:**
  1. Resolve `<W>`'s OS user from the box's own workspace binding (spec
     section 2; `spl-box-workspace.func.sh`): on an unclaimed operator box for
     the operator workspace, use `SPOOL_AGENT_USER` and slot 1 storage; for any
     other workspace (dedicated or fleet-hosted), use `<W>`'s own OS user and
     isolated runtime storage (`spl-ws-claude-signin.func.sh`). Refuse any op
     for a customer `<W>` aimed at `SPOOL_AGENT_USER` or another workspace's OS
     user, and refuse an operator-workspace op aimed at a customer's OS user
     (R7, R10). Never run as root or a human user.
  2. Extend `SIGNIN_RELAY_OP` to `start|input|end|out|renew|status|copy`:
     - `out`: runs the CLI's logout as `<W>`'s OS user and removes only that
       user's login files;
     - `renew`: runs login and compares the post-login account label
       (`acct-<8 hex>`, spec 5.3) to the prior label, reporting
       `state=failed reason=other_account` if it differs;
     - `status`: reads login probe, account label, plan kind (if CLI status
       prints one), expiry, weekly % and reset time (reusing
       `spl-box-quota.func.sh:68-93,202` and `watchdog/situations/lib.inc.sh:53-55`),
       and emits a non-secret status line/fact — never credential content or
       email (R1).
  3. Add the three clean seams (2.4 N4): per-kind dispatch sourcing
     `spl-ws-signin-kinds.func.sh` (for L4); `spl_wsr_after_switch` hook (for
     L5); `op=copy` dispatching to `do_spl_ws_login_copy` else `failed no_copy`
     (for L8).
  4. Add `env.box.signin_relay_kinds: "claude"` in
     `csi-spl-cnf/csi-spl/all.env.yaml` and re-render with `do_tpl_gen`
     (developer guide 2.3.3). Under Q2 A, wire `SPOOL_SIGNIN_RELAY_CMD` in
     `spl-desk-up.func.sh` when `env.box.signin_relay_kinds` is non-empty (do
     NOT run `do_spl_desk_up` on live boxes).
- **Done and red controls (R1, R7, R10):**
  - R1: synthetic input/code never appears in stdout, stderr, logs, or status
    output (planted defect printing input to log -> test fails).
  - R7: customer `<W>` op targeting `SPOOL_AGENT_USER` or another workspace's
    user is refused; operator op targeting a customer user is refused (planted
    defect removing the check -> op starts and test fails).
  - R10: two synthetic workspaces W1 and W2 on one box: W1 `start`/`input`/`out`
    leaves W2's login files untouched (planted defect writing to W2's user ->
    test fails).
- **Test column (R2):** `orc:src/bash/tests/ws-signin-relay.tst.sh`,
  `orc:src/bash/tests/box-workspace-isolation.tst.sh`,
  `orc:src/bash/tests/ws-claude-signin.tst.sh` (if present),
  `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`,
  `do_tpl_gen` + `git diff --exit-code`, `do_check_pre_push_lint`.
- **Not touched:** `csi-spl-api/`, `csi-spl-rdb/`, `csi-spl-wui/`,
  `orc:src/bash/scripts/agent-login-cred.sh`.

### 3.3 L2 - Hub fan-out, `/v1/vendor-logins`, audit & label tables, box facts, offline catch-up

- **Kind:** `complex_coding`. **Vendor:** `claude`. **R7:** `agy`. **Batch:** 2
  (after L1 and L3 land). `PRE_PUSH_TIER=full` (rdb migration + store + Postgres
  table walk).
- **Files:** new `rdb:<NNNN>_vendor_login_audit.sql` (number from
  `do_rdb_migration_next`); new `api:store/vendor_logins.go`,
  `vendor_logins_postgres.go`, `vendor_logins_memory.go`,
  `vendor_logins_test.go`; `api:wire/signin_relay.go`, `api:wire/wire.go`;
  `api:hub/box_facts.go`, `box_facts_test.go`; `api:hub/ws.go`;
  `api:hub/vendor_keys.go` (route registration only); new
  `api:hub/vendor_logins.go`, `vendor_logins_test.go`;
  `api:hub/signin_relay.go` (audit + copy hook); `api:hub/signin_relay_test.go`;
  `api:hub/openapi.json`; `cmd:signin_relay.go`, `cmd:signin_relay_test.go`.
- **Work:**
  1. Forward-only migration adding three RLS-enforced tenant tables
     (`TestRLSCoversEveryTenantTable`):
     - `workspace_vendor_login_audit` (`tenant_id`, `kind`, `box`, `op` CHECK
       `login|logout|renew|switch|copy`, `actor` CHECK `^HUM-[0-9]+$` [2.4 N1],
       `at`, `result` short machine word, `account_label` `acct-[0-9a-f]{8}` or
       NULL; append-only trigger mirroring `rdb:0174:116-125`);
     - `workspace_vendor_login_labels` (`tenant_id`, `account_label`, `name`
       CHECK `^[A-Za-z0-9 _-]{1,40}$` — refuses `@` and all other chars, R1);
     - `workspace_vendor_login_pending` (`tenant_id`, `kind`, `box`, `op`
       `logout|copy`, `at`; zero secrets, for offline/new-box catch-up, spec
       7.3).
  2. Extend `api:wire/signin_relay.go` (`SigninOpLogout`, `SigninOpRenew`,
     `SigninOpStatus`, `SigninOpCopy`, optional non-secret `Account`,
     `CopiedFrom`, `Peers`, `Relayable` fields) and `cmd:signin_relay.go`
     (allow the new ops, pass `TENANT_ID` from box binding, parse extended
     non-secret report fields).
  3. Extend `wire.BoxHost` (`api:wire/wire.go:994`) and `api:hub/box_facts.go`
     with a strictly sanitized `VendorLogins` status map (per kind: `signed_in`,
     `account`, `plan`, `expires_at`, `weekly_pct`, `weekly_reset`, `relayable`,
     `peer_tags`; drop anything email-shaped or outside strict bounds).
  4. Implement `api:hub/vendor_logins.go` behind L1's `vendor_logins.manage` +
     act-as + unconfirmed-manager actor check:
     - `GET /v1/vendor-logins`: per-kind switch state, enrolled pins of `<W>`
       with online/offline/`re-join needed` (no `box_x25519`), per-box status
       from box facts, admin-given label names, and audit rows joined to member
       display names at read time;
     - `POST /v1/vendor-logins/{kind}` `{op, box?}`: picks source box (enrolled
       pin of `<W>` reaching the most enrolled peers of `<W>`, else first
       online), opens its B11 relay, on `signed_in` triggers `op=copy` with
       ONLY hub-verified pins of `<W>` (R5), opens per-box relays for online
       boxes no peer reaches, records pending ops for offline boxes, writes one
       audit row per box per op on box answer;
     - `PUT /v1/vendor-logins/labels/{account_label}` `{name}`: 400
       `bad_label_name` on `@` or invalid chars (R1).
  5. Wire hello catch-up in `api:hub/ws.go` (beside `:266`): when an offline
     box reconnects or a new pin joins, execute pending logout automatically,
     trigger peer copy from an online peer of `<W>`, or post ONE notice to
     `<W>`'s `vendor_logins.manage` holders when no peer reaches it (spec 7.3).
  6. Register routes in `api:hub/vendor_keys.go` and document every route in
     `api:hub/openapi.json` (`TestOpenAPIRoutes`).
- **Done and red controls (R1, R3, R5):**
  - R1: extend `TestSigninRelayNeverStoresInput` Postgres base-table walk
    (`signin_relay_test.go:474`) across all new tables: planted defect writing
    input to audit result fails; label name `x@example.com` -> 400
    `bad_label_name` (defect removing check -> walk finds `@` row); audit row
    with email-shaped `actor` fails CHECK.
  - R3: fan-out for `<W>` never reaches a pin of another workspace; frame
    sealed to `<W>`'s desk recipient refused by another box/workspace desk.
  - R5: source box's `Peers` list from hub includes ONLY pins of `<W>`, never
    a non-pin box; no login bytes or sha > 12 hex in any hub table, frame, or
    log.
- **Test column (R2):** `api:store/vendor_logins_test.go`,
  `api:store/rls_test.go`, `api:store/rls_failclosed_test.go`,
  `api:hub/vendor_logins_test.go`, `api:hub/signin_relay_test.go`,
  `api:hub/box_facts_test.go`, `api:hub/openapi_routes_test.go`,
  `api:hub/openapi_serve_test.go`, `cmd:signin_relay_test.go`,
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `PRE_PUSH_TIER=full`.
- **Not touched:** `csi-spl-orc/`, `csi-spl-wui/`, `csi-spl-cnf/`,
  `api:store/fleet_load.go`, `api:hub/fleet_load.go`.

### 3.4 L4 - Box side: `grok` and `agy` terminal login flows (or `no_relay`)

- **Kind:** `secret`. **Vendor:** `claude` (backup `grok` [off]; never `agy`,
  `qwen`, `mistral`, or `codex`). **R7:** `agy` on public diff + synthetic
  `SPOOL_TEST=1` tests only (Q1 A; else `claude` waiver, Q1 B). **Batch:** 2
  (after L3 lands).
- **Brief hygiene:** names NO credential path.
- **Files:** new `orc:lib/bash/funcs/spl-ws-signin-kinds.func.sh`;
  `orc:src/bash/run/spl-ws-signin-relay.func.sh` (wire L3's per-kind seam); new
  `orc:src/bash/tests/ws-signin-relay-kinds.tst.sh`;
  `csi-spl-cnf/csi-spl/all.env.yaml` (+ `do_tpl_gen` outputs, ONLY if `grok`
  and/or `agy` proves relayable, updating `env.box.signin_relay_kinds` and
  `env.hub.operator_signin_relay_kinds`, 2.4 N5).
- **Work:**
  1. Empirically measure `grok` and `agy` CLI terminal login behaviour per Q3's
     answer (default Q3 A: isolated throwaway `HOME`, never touching any
     production login or logging out live agents) and record the exact command
     + observation in the commit body.
  2. For each of `grok` and `agy`:
     - If the CLI prints an https URL and reads a pasted code or completes via
       device code, wire `start`, `input`, `out`, `renew`, `status` (`relayable=yes`)
       in `spl-ws-signin-kinds.func.sh` under the same workspace OS-user and
       stdin-only `tmux load-buffer -` rules as `claude`;
     - If the CLI requires a local browser redirect or cannot be relayed,
       return `SIGNIN_RELAY state=failed reason=no_relay` on `start`/`input`/`renew`,
       report `relayable=no` in `status`, and keep `out` working (spec 5.2, 8).
- **Done and red control:**
  - Measured output for both `grok` and `agy` recorded in commit body.
  - Red control (spec 192 L4): a `no_relay` kind reporting `relayable=yes` or
    accepting `start` fails `ws-signin-relay-kinds.tst.sh` (seen RED, then
    GREEN, both in commit body); `out` still works on a `no_relay` kind; no
    input or token ever printed or logged (R1).
- **Test column (R2):** `orc:src/bash/tests/ws-signin-relay-kinds.tst.sh`,
  `orc:src/bash/tests/ws-signin-relay.tst.sh`,
  `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`,
  `do_tpl_gen` + `git diff --exit-code` (if cnf changed),
  `do_check_pre_push_lint`.
- **Not touched:** `csi-spl-api/`, `csi-spl-rdb/`, `csi-spl-wui/`,
  `orc:src/bash/scripts/agent-login-cred.sh`.

### 3.5 L5 - Per-(`workspace`, `kind`, `box`) pause and immediate post-switch seat restart

- **Kind:** `complex_coding`. **Vendor:** `claude`. **R7:** `agy`. **Batch:** 3
  (after L2 and L3 land). `PRE_PUSH_TIER=full` (rdb migration + store).
- **Files:** new `rdb:<NNNN>_workspace_kind_pauses.sql` (number from
  `do_rdb_migration_next`); `api:store/fleet_load.go`, `fleet_load_test.go`;
  `api:hub/fleet_load.go`, `fleet_load_test.go`; `api:hub/vendor_logins.go`
  (include per-box pause state & seat-restart count); `cmd:fleet_load.go`,
  `cmd:cli_verbs_test.go`; `orc:src/bash/run/spl-lane-mix.func.sh`,
  `orc:src/bash/run/spl-gc.func.sh`; new
  `orc:src/bash/run/spl-ws-vendor-restart.func.sh`; new
  `orc:src/bash/tests/ws-vendor-restart.tst.sh`;
  `orc:src/bash/tests/spl-lane-mix.tst.sh`, `gc-agent.tst.sh`.
- **Work:**
  1. Add RLS-enforced table `workspace_kind_pauses (tenant_id, kind, box,
     until, reason)` bounded by `MaxKindPause` (8 days) and `MaxPauseReason`
     (200 chars), keeping legacy `agent_kinds_paused` backward-compatible for
     existing readers (2.4 N3).
  2. Key `fleet_load_pause` and a new lift op (`fleet_load_unpause` or nil
     entry) by (`x.tenant`, `kind`, `x.box`) for EVERY workspace (operator and
     customer workspaces alike, spec 6.2 item 4), never cross-workspace or
     cross-box (R8, R10). Expose `spool fleet-load unpause <kind>` in
     `cmd:fleet_load.go`.
  3. Update `spl-lane-mix.func.sh` and `spl-gc.func.sh` to check this box's
     own (`<W>`, kind, box) pause first (falling back to legacy
     `agent_kinds_paused` only when the new field is absent).
  4. Implement `do_spl_ws_vendor_restart` (`spl-ws-vendor-restart.func.sh`),
     invoked by L3's `spl_wsr_after_switch` seam when a new login probes `ok`
     [Q-4 B, spec 6.2]:
     - lift (`<W>`, kind, box)'s pause entry;
     - stop every seat of `<kind>` owned by `<W>`'s OS user on this box — stuck
       or working, ignoring self-heal cooldown — using the pane-wrapper + own-pid
       stop path (`spl-agent-login-check.func.sh:372-403`), and restore each
       via `do_spl_agent_identity_restore`;
     - never touch seats of other kinds or other workspaces on a shared box
       (R9, R10);
     - skip unrestorable seats (no session, worktree, adapter, or transcript)
       without stopping them and report their ids;
     - on `out` (logout), set (`<W>`, kind, box)'s pause with reason
       `logged out` (bounded by `MaxKindPause`, refreshed on check while no
       login exists, spec 6.2 item 5).
- **Done and red controls (R8, R9, R10):**
  - R8: `<W>` switched on box A while box B is at its limit -> (`<W>`, kind,
    B)'s pause stays and another workspace's pause on A stays (planted defect
    lifting across all boxes or workspaces -> test fails).
  - R9: 3 seats of the kind on the box (1 stuck, 2 working), new login probes
    `ok` -> 3 stops and 3 restores, other kinds untouched; planted defect
    limiting restarts to stuck seats -> 1 restore and test fails; new login
    probing `expired` -> 0 stops.
  - R10: two workspaces W1 and W2 on shared box S: W1 switch/logout leaves W2's
    pause and W2's seats untouched (planted defect keying pause without
    workspace -> test fails).
- **Test column (R2):** `api:store/fleet_load_test.go`,
  `api:store/rls_test.go`, `api:hub/fleet_load_test.go`,
  `api:hub/vendor_logins_test.go`, `cmd:cli_verbs_test.go`,
  `orc:src/bash/tests/ws-vendor-restart.tst.sh`,
  `orc:src/bash/tests/spl-lane-mix.tst.sh`, `orc:src/bash/tests/gc-agent.tst.sh`,
  `csi-spl-wui/tests/unit/fleet-load.test.mjs` (regression guard),
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `PRE_PUSH_TIER=full`.
- **Not touched:** `orc:src/bash/scripts/agent-login-cred.sh`,
  `orc:src/bash/run/spl-ws-signin-relay.func.sh` (uses L3 seam),
  `csi-spl-wui/`.

### 3.6 L8 - Box-to-box login copy per workspace OS user (`agent-login-cred.sh` + `do_spl_ws_login_copy`)

- **Kind:** `secret`. **Vendor:** `claude` (backup `grok` [off]; never `agy`,
  `qwen`, `mistral`, or `codex`). **R7:** `agy` on public diff + synthetic
  `SPOOL_TEST=1` tests only (Q1 A; else `claude` waiver, Q1 B). **Batch:** 3
  (after L3 and L4 land).
- **Brief hygiene:** names NO credential path.
- **Files:** `orc:src/bash/scripts/agent-login-cred.sh`; new
  `orc:src/bash/run/spl-ws-login-copy.func.sh`; new
  `orc:src/bash/tests/ws-login-copy.tst.sh`;
  `orc:src/bash/tests/spl-agent-login-check.tst.sh`.
- **Work:**
  1. Extend `orc:src/bash/scripts/agent-login-cred.sh` with optional workspace
     binding (`LOGIN_TENANT`, resolved via the box's own workspace binding —
     operator agent user for operator workspace, `<W>`'s own user elsewhere,
     refusing cross-workspace writes, R7/R10) and `LOGIN_KIND` (`claude`
     default, plus `grok` and `agy` login files matching L4's verified
     locations, keeping existing zero-arg / slot 1-2 `claude` behaviour 100%
     unchanged for `do_spl_agent_login_check`). Temp + `mv`, mode 600, backup
     retention, sha12 + label at most in outputs/logs (never content in logs).
  2. Implement `do_spl_ws_login_copy` (`spl-ws-login-copy.func.sh`), invoked by
     L3's `op=copy` seam:
     - reads `SPOOL_LOGIN_PEERS` (as `_lc_peer_list` does) and intersects with
       the hub-verified pin list of `<W>` passed in the relay frame; any peer
       not in `<W>`'s pins is skipped and reported (R5);
     - pipes `agent-login-cred.sh get | ssh <peer> ... put` (and
       `acctget | acctput` for `claude`) from `<W>`'s OS user on source to
       `<W>`'s OS user resolved on the peer, probes on the peer, and reports
       per-peer `ok` or `copy_failed` with sha12 and account label only (never
       through the hub, never into a log).
- **Done and red controls (R5, R10):**
  - R5: source box whose peer list names a box outside `<W>`'s hub pin list ->
    0 copies to it, reported skipped; planted defect removing the pin check ->
    copy reaches non-pin box and test fails; no login bytes or sha > 12 hex in
    stdout/stderr/logs.
  - R10: two workspaces W1 and W2 on shared peer S: W1 copy into W1's OS user
    leaves W2's login file sha unchanged; planted defect targeting W2's OS user
    is refused and fails.
- **Test column (R2):** `orc:src/bash/tests/ws-login-copy.tst.sh`,
  `orc:src/bash/tests/spl-agent-login-check.tst.sh`,
  `orc:src/bash/tests/spl-agent-login-proof.tst.sh`,
  `orc:src/bash/tests/spl-agent-login2-sync.tst.sh`,
  `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`,
  `do_check_pre_push_lint`.
- **Not touched:** `csi-spl-api/`, `csi-spl-rdb/`, `csi-spl-wui/`,
  `orc:src/bash/run/spl-ws-signin-relay.func.sh` (uses L3 seam),
  `orc:src/bash/run/spl-lane-mix.func.sh`, `orc:src/bash/run/spl-gc.func.sh`.

### 3.7 L6 - Web UI: AI vendors section in Settings, Agent keys link, 19 locales, e2e

- **Kind:** `complex_coding`. **Vendor:** `claude` (never `mistral`, developer
  guide 5.1). **R7:** `agy`. **Batch:** 4 (after Batch 3 lands).
- **Files:** `wui:utils/tenant-settings-nav.ts`; new
  `wui:pages/tenant-settings/ai-vendors.vue`; new
  `wui:components/AiVendorCard.vue` (and helper components <= 75 lines/func);
  new `wui:utils/vendor-logins.mjs`; `wui:pages/tenant-settings/agent-keys.vue`;
  `wui:utils/spool-client.mjs`, `spool-client-lazy.mjs`; all 19
  `csi-spl-wui/i18n/locales/*.json`; new `csi-spl-doc/lang-review/<run>.json`;
  minimal stub in `csi-spl-doc/doc/help/user-settings.md` + regenerated
  `wui:public/help-md/user-settings.md` (`sync-help.mjs`, 2.4 N2); new
  `csi-spl-wui/tests/unit/vendor-logins.test.mjs`; new
  `csi-spl-wui/tests/e2e/ai-vendors.test.mjs`; updates to
  `tests/unit/tenant-settings.test.mjs`, `tests/e2e/tenant-settings.test.mjs`,
  `tests/e2e/agent-keys.test.mjs`,
  `tests/unit/signed-out-member-pages.test.mjs`.
- **Work:**
  1. Insert `{ id: 'ai-vendors', label: 'tenant_settings.ai_vendors', perm: 'vendor_logins.manage' }`
     into `TENANT_SETTINGS_SECTIONS` between `split` (`:31`) and `agent-keys`
     (`:32`) and add `'ai-vendors'` to `MOCK_GATED` (`:51`).
  2. Build `pages/tenant-settings/ai-vendors.vue` behind `useTenantSectionGate('ai-vendors', ...)`:
     - one card per kind (`claude`, `grok`, `agy`, `mistral`, `qwen`; fold any
       kind whose workspace split weight is 0);
     - per-box rows (`done` with label + `copied from <box>` or `signed in here`,
       `waiting for code`, `failed` with reason word, `offline`, `re-join needed`),
       account label + admin-given name editor (refusing `@` / invalid chars),
       plan, expiry ("renews itself"), weekly % and reset time;
     - buttons: **Log in**, **Switch account** (confirm naming running seats it
       restarts, spec 6.2), **Renew** (only on `expired`), **Log out** (confirm
       naming boxes and running seats);
     - switch-off kind shows "not switched on for this vendor" and no buttons;
       `no_relay` box row shows "sign in at the terminal" with no Log in,
       Switch account, or Renew button (Log out stays);
     - `mistral` and `qwen` show state per box and link to **Agent keys**
       [Q-5 B];
     - audit section ("who did what, when") showing joined member display name,
       box, kind, op, result word, account label;
     - code input is `type="password"`, cleared immediately on send, never
       stored in Pinia, `localStorage`, or `sessionStorage`.
  3. On `pages/tenant-settings/agent-keys.vue:36`, replace inline
     `SigninRelayPanel` with a link to `/tenant-settings/ai-vendors` for
     subscription sign-ins (spec 8).
  4. Add minimal `ai-vendors` stub in `csi-spl-doc/doc/help/user-settings.md`
     and run `cd csi-spl-wui && node src/node/help/sync-help.mjs` so
     `help-settings-coverage.test.mjs` and `help-sync.test.mjs` stay green
     (2.4 N2).
  5. Every visible string is a translation key across all 19 locales (developer
     guide 2.7); run `cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct`
     over new keys, fold references, re-run, commit the report, and include
     `Lang-review: gct <run id>` in the commit body.
- **Done and red controls (spec 192 L6):**
  - `pnpm run typecheck`, `pnpm run test:unit` (including `i18n-parity`,
    `i18n-untranslated`, `i18n-no-raw-text`, `cleancode`, `unused-exports`,
    `help-settings-coverage`, `help-sync`), and Chrome e2e on generated bundle
    (`BASE_URL=<bundle> pnpm run test:e2e ai-vendors tenant-settings agent-keys`).
  - Red controls (all three seen RED then GREEN in commit body):
    1. member without `vendor_logins.manage` shown the section -> e2e fails;
    2. `no_relay` row rendered with a Log in button -> e2e fails;
    3. pasted code left in any input, page text, Pinia, or web storage after
       send -> e2e fails.
- **Test column (R2):** `tests/unit/vendor-logins.test.mjs`,
  `tests/unit/tenant-settings.test.mjs`, `tests/unit/signin-relay.test.mjs`,
  `tests/unit/signed-out-member-pages.test.mjs`,
  `tests/unit/help-settings-coverage.test.mjs`, `tests/unit/help-sync.test.mjs`,
  `tests/unit/i18n-*`, `tests/unit/cleancode.test.mjs`,
  `tests/unit/font-size.test.mjs`, `tests/unit/focus-tokens.test.mjs`,
  `tests/e2e/ai-vendors.test.mjs`, `tests/e2e/tenant-settings.test.mjs`,
  `tests/e2e/agent-keys.test.mjs`, plus every e2e file selected by
  `cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`
  (reviewer runs that full selection, rulebook 2.7.4).
- **Not touched:** `csi-spl-api/`, `csi-spl-rdb/`, `csi-spl-orc/`.

### 3.8 L7 - User help documentation and cross-spec updates

- **Kind:** `specs_and_docs`. **Vendor:** `agy`, backup `claude` (never
  `mistral`: `sync-help.mjs` writes under `csi-spl-wui/`, developer guide 5.1).
  **R7:** cross-vendor (`claude` if `agy` authored; `agy` if `claude` authored).
  **Batch:** 5 (after L6 lands).
- **Files:** `csi-spl-doc/doc/help/user-settings.md`;
  `wui:public/help-md/user-settings.md` (ONLY via `sync-help.mjs`);
  `csi-spl-doc/specs/159-byo-ai-keys/spec.md` (`4.3`, `:127`);
  `csi-spl-doc/specs/132-fleet-login-selfheal-3-boxes/spec.md` (`section 2`,
  `:11`); `csi-spl-doc/specs/060-role-rotation/claude-account-failover.md`
  (`D4`, `:29`); `csi-spl-doc/specs/192-agent-login-from-wui/spec.md`
  (section 12 row statuses and landed shas, plus N1 actor-format note).
- **Work:**
  1. Replace L6's stub in `csi-spl-doc/doc/help/user-settings.md` (between
     **Vendor split** and **Agent keys**) with full plain-language
     documentation of **AI vendors** (`/tenant-settings/ai-vendors`): who sees
     it, Log in / Switch account / Renew / Log out, per-box fan-out & automatic
     copy, `no_relay`, label naming, audit trail, and mistral/qwen on Agent
     keys. Regenerate `wui:public/help-md/user-settings.md` via
     `cd csi-spl-wui && node src/node/help/sync-help.mjs`.
  2. Record the section 13 cross-spec notes in specs 159 (4.3), 132 (section 2),
     and 060 add-on (D4), and update spec 192 section 12 with the landed shas
     and row statuses.
- **Done and red control:**
  - `grep -c 'ai-vendors' csi-spl-wui/src/public/help-md/user-settings.md` >= 1
    (red control: 0 fails);
  - `cd csi-spl-wui && node src/node/help/sync-help.mjs --check` rc 0 (red
    control: leave the copy out and see rc 1);
  - `node csi-spl-wui/tests/unit/help-settings-coverage.test.mjs`,
    `node csi-spl-wui/tests/unit/help-sync.test.mjs`,
    `cd csi-spl-iac && ./run -a do_check_dist_hygiene`,
    `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`.
- **Not touched:** any Go, Bash, or TypeScript/Vue source file.

## 4. Consensus

| seat | vendor | sha | verdict |
|---|---|---|---|
| panel (tbd) | `claude` (cross-vendor to `agy` planner a-486) | pending | pending |
| holder | dispatch holder (`c-002`) | pending | pending |

## 5. Versions

| version | what |
|---|---|
| v0.1 | first plan for cross-vendor review, on `f2cb19298` (`origin/master`), 8 rows (L1-L8) in 5 batches on top of landed L0 (SPL-6345) |

## 6. Open points for the owner

Three small build-plan points need your pick (recommended first on each).
Batches 1 (`L1`) and 2 (`L2`) do not wait on Q1-Q3.

```poll
1. R7 code reviewer for Kind: secret rows (L3, L4, L8) while grok is off (their git diffs and SPOOL_TEST=1 fixtures carry zero real credentials)?
(A) agy reviews the public git diff and synthetic unit tests only (cross-vendor; claude author alone runs live box/account probes)
(B) claude same-vendor R7 reviewer under waiver (keep agy off Kind: secret reviews too until grok returns)

2. How should fleet boxes turn on SPOOL_SIGNIN_RELAY_CMD so hub-run advertises the sign-in relay?
(A) L3 wires SPOOL_SIGNIN_RELAY_CMD in do_spl_desk_up when env.box.signin_relay_kinds is non-empty (live sidecar restart waits for your explicit go)
(B) Keep SPOOL_SIGNIN_RELAY_CMD manual opt-in via box.env only (do_spl_desk_up unchanged)

3. How should L4 measure grok and agy CLI terminal login flows without risking a production login?
(A) Run each CLI login in an isolated throwaway HOME up to its first prompt to prove URL+code / device-code vs local-redirect no_relay (no production login touched)
(B) Hold L4 until dedicated test accounts for grok and agy are provided for full end-to-end login testing
```
