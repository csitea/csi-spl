# 164 Channel Box Pin: Pin a Channel to Chosen Boxes (Default: Any Box of the Fleet)

Version: v1.2 (2026-10-30).
Status: **Draft v1.2**, Planned, not built (Placement slug `c003-channel-box-pin-spec`, Issue SPL-4171, Epic SPL-2398).
Class: feature.
Kind: specs_and_docs.

Source: owner HUM-10, prd t1 topic `021d4921-a6b9-427b-bf86-4eb0b945c82d` (msgs `f9234b11`, `6b6d092c`).
Authority: this file for the behaviour and specification. Each build row in section 8 gets its own issue when scheduled.

Paths used below:
- `wui/` = `csi-spl-wui/src/` (the WUI tests and locales sit outside it: `csi-spl-wui/tests/`, `csi-spl-wui/i18n/locales/`)
- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`
- `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/` (so `orc/run/...` is `csi-spl-orc/src/bash/run/...`)

Every `file:line` citation was read on origin/master `dc328aae3` (v1.1) and re-read for v1.2 on `5df9c0ead` (2026-10-30). Line numbers move; a build row re-reads them before it edits.

---

## 1. The Owner's Request (Verbatim)

From owner HUM-10, prd t1 topic `021d4921-a6b9-427b-bf86-4eb0b945c82d`:

- **msg f9234b11**: *"it should be possible to "fix" a channel to only certain boxes ..."*
- **msg 6b6d092c**: *"by default any channel should run on any box from the cluster , but one should be able to fix only certain boxes for a channel"*

---

## 2. Today: What Exists on Master

### 2.1 Workspace Box Pinning vs Channel Box Pinning
- **Box pinning is per workspace only**: the `pins` table (`rdb/0001_hub_core.sql:28-35`) keys on `(tenant_id, box_id)` with a 32-byte Ed25519 public key and a `revoked_at` column. The hub checks the pin before a dispatch (`hub/dispatch.go:161-163`: `if _, err := s.o.Store.GetPin(ctx, c.tenant, box); err != nil { return "", nil, "unpinned_box", http.StatusNotFound, ... }`).
- **No channel-level box binding exists**: `git grep -iE 'allowed_boxes|channel_boxes|channel_box_pins' origin/master -- csi-spl-api csi-spl-rdb csi-spl-orc csi-spl-wui` returns zero hits. Every pinned box of a workspace is equal for every channel.

### 2.2 The Ways a Channel Post Reaches a Box Today
1. **Fan-out to member boxes**: `hub/channels.go:264-305` (`routeChannel`). Members come from `channel_subscriptions` (`rdb/0002_channels.sql:15-23`, PK `(tenant_id, channel_id, agent_id, box_id)`). The loop, as the code has it:
   ```go
   for box, agents := range members {
       if box == WUIBox || (!fromBrowser && box == env.ToBox) {
           continue // the browser is no delivery target; the addressed box got the direct leg
       }
       if box == env.FromBox {
           if !agentPost {
               continue
           }
           agents = withoutAgent(agents, m.From)
       }
       agents = seats.filter(box, agents) // role seats: only the seated agent of a role hears it
       if len(channelTargets(agents)) == 0 {
           continue
       }
       if s.channelLockSkip(ctx, tenant, box, env, m) { // spec 025 B3: a locked box hears its owners and peers only
           continue
       }
       // Enqueue(..., now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox), then push to the live session
   }
   ```
   So a delivery goes to each member box that still has a target after the role-seat filter and the box-lock check, not to every box with members. Spec 058 row H7 (`csi-spl-doc/specs/058-multi-machine-fleet/spec.md:42`): one delivery per member box, by design.
2. **The direct leg** (`to_box`), two doors:
   - **From an agent's box** (the box WebSocket): `onSend` (`hub/ws.go:611`) runs its refusal chain (`:627-640`: `sendIDRefusal`, `sendSenderRefusal`, `sendRouteRefusal` (`:701`, checks only that `to_box` is pinned to the workspace), `boxSendLockRefusal`, `sendTenantRefusal`), then `commitRow` (`:950`) queues the row for `env.ToBox` (`Store.Enqueue`, `:1009`) and only then calls `routeChannel` (`:1020`).
   - **From the browser**: `dispatchCheck` (`hub/dispatch.go:125-168`), called only with a browser connection (`grep -n 'dispatchCheck(' hub/*.go` -> `wui.go:744`, `topic_reply.go:39`, `retired_reply.go:75`).
   - `routeChannel` skips the addressed box (`box == env.ToBox`) so it is not delivered twice. The operator replay of unsigned posts (`hub/replay_unsigned.go:122-157`) re-signs a browser envelope and goes through `routeChannel` only.
3. **The fallback responder**: `hub/fallback.go` (`fallbackBoxes` :54, `fallbackPick` :85, `fallbackOff` :133) picks an online agent on some box when nobody in the channel answers and the channel's `no_fallback` is off.
4. **Receiving**: `hub/channels.go:315-339` (`recvAgents`) picks, for a box that receives a queued channel row, the members it hosts (`members[x.box]`, role seats applied). The addressed box always gets its row: `own := e.ToBox == x.box` (`:320`) and `return a, own || len(a) > 0` (`:338`), even with no channel target.

Posting: `hub/channels.go:219-231` (`agentInChannel`) lets an agent post to a channel when it is in `members[box]`; others get `404 unknown_channel` (the read door).

Reading: an agent on a box never reads a topic over HTTP. Its box gets the post only through ways 1 to 3 above. The `GET /v1/view/...` routes (`hub/view.go:54-56`, `hub/search.go:51`) admit human sessions only (`viewDoor`, `hub/view.go:137`, calls `humanTenant`, `hub/resolve.go:60`). The orchestrator's sweep reads the database itself through the Cloud SQL proxy (`spl_sweep_rows`, `orc/run/spl-unanswered-sweep.func.sh:253-267`), not through the hub's read door.

### 2.3 How Lanes Are Placed Today
- **Queue and placement**: `do_spl_spawn_place` (`orc/run/spl-spawn-place.func.sh:158`) reads the hub's queued asks (`spl_spawn_q_rows`, `orc/run/spl-spawn-queue.func.sh`, through the box-signed `spool ask list`) and runs its holds in order (`:179-182`: `spl_spawn_place_agy_hold`, `_away_hold`, `_pin_hold`, `_agy_box_hold`).
- **Box selection** today:
  1. Hand-pinned slug (`HAND-PINNED SLUG`, the header at `orc/run/spl-spawn-place.func.sh:62-70`): `hand-<box>-<slug>` or `<box>hand-<slug>` launches with `SPAWN_BOX=<box>`; `spl_spawn_place_pin_hold` (`:861`) holds it while that box is full.
  2. `spl_spawn_place_agy_box_hold` (`:890-934`): the agy and mistral quota hold. It loops only over placements matching `^(mistral|agy):` (`:926`); it is not load balancing.
  3. Load balancing: `place_box` in `orc/features/spawn-agents/scripts/spawn-window.sh:260-320` asks `do_spl_box_pick` (`:295`) for the box under the fleet load target.
- Nothing links a channel to the box a lane for that channel runs on.

### 2.4 The 3-Minute Answer Rule and Sweeps Today
- **The rule**: `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md:198` (*"Every human post is answered within 3 minutes."*) and `:209` (still unanswered after 2 minutes -> the orchestrator lease holder takes it as the 3-minute backstop and owns the topic).
- **Taking a post**: `do_spl_take` (`orc/run/spl-take.func.sh:37`) posts the take line ("Taken by <id>@<box>: <plan>.").
- **Auto-take**: `do_spl_take_auto` (`orc/run/spl-take-auto.func.sh:43`), its skip rules in `spl_take_auto_skip` (`:74`); a channel's sole seat comes from `cr_sole_seat` (`orc/features/spawn-agents/lib/channel-rules.inc.sh:71-80`, column 6 of `<spool root>/channel-rules.tsv`).
- **Unanswered sweep**: `do_spl_unanswered_sweep` (`orc/run/spl-unanswered-sweep.func.sh:104`) with `orc/scripts/unanswered-sweep-classify.py` reports human posts with no agent reply past the take grace.

### 2.5 Real Production Use Cases (Anonymized)
Three production cases exist today where a channel must be answered only on one machine, kept today by seat briefs and habit:
1. **Workspace A, channel `#app-alpha`**: an automation seat on `box-x`; its tooling and runtime state live only on `box-x`.
2. **Workspace B, channel `#project-beta`**: a private member project whose secrets and data must stay on the member's own machine (`box-y`).
3. **Workspace C, channel `#service-gamma`**: customer repositories cloned only on `box-x`; never cloned or cached on another machine.

---

## 3. The Data Model

### 3.1 Table `channel_box_pins`
A new forward-only migration. The head on origin/master `dc328aae3` is `rdb/0241_fleet_ask_discussion.sql` (`git ls-tree --name-only origin/master csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`), so the file is `rdb/0242_channel_box_pins.sql`; B1 takes the next free number when it lands. The RLS block copies `rdb/0139_calendar_full_edit.sql:72-79` (the 0014 shape): `tenant_scope` on `app.tenant_id` (the key `store/rls.go:19` sets), `operator_scope` on `app.rls_scope = 'operator'` (`store/rls.go:20`), and `FORCE`.

```sql
-- 0242_channel_box_pins.sql: channel-level box pins (spec 164, SPL-4171).
-- No row for a channel = any pinned box of the workspace (the default).
CREATE TABLE channel_box_pins (
    tenant_id   text        NOT NULL,
    channel_id  text        NOT NULL,
    box_id      text        NOT NULL,
    pinned_at   timestamptz NOT NULL DEFAULT now(),
    pinned_by   text        NOT NULL, -- HUM-<n>, or 'operator'
    PRIMARY KEY (tenant_id, channel_id, box_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, box_id) REFERENCES pins (tenant_id, box_id) ON DELETE CASCADE
);
CREATE INDEX channel_box_pins_box ON channel_box_pins (tenant_id, box_id);

ALTER TABLE channel_box_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_box_pins FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON channel_box_pins
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON channel_box_pins
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

- The primary key already indexes `(tenant_id, channel_id, ...)`; the one extra index serves "which channels pin this box".
- Grants: the hub's runtime role is `:runtime_role` (`csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-role.sql`); B1 checks that `spool-hub-roles/runtime-grants.sql` covers a new table, and adds the grant there if it does not.
- `pins` keeps a row after a revoke (`revoked_at`), so the foreign key does not catch a revoked box. The hub's write check (4.1) refuses a revoked or unknown box; a box revoked after it was pinned stays in the list and receives nothing (the dispatch pin check refuses it already).

### 3.2 Relational Table vs Array Column
- **Table**: a foreign key to `pins`, so a box removed from the workspace leaves no dangling pin; tenant RLS like every tenant table (`TestRLSCoversEveryTenantTable`); who pinned and when, per box. Cost: one more read per channel route, cached like the channel members.
- **Array column `channels.box_pins text[]`**: one row read, but no foreign key, and a removed box stays in the array until code cleans it.
- **Decision**: the table.

### 3.3 Default: No Rows = Any Box
- **No rows** for `(tenant_id, channel_id)`: the channel is unpinned; every pinned box of the workspace may host its agents, receive its posts and run its lanes. This is the owner's default: *"by default any channel should run on any box from the cluster"*.
- **One or more rows**: the channel is pinned; only those boxes receive its posts, post into it as agents, or run its lanes.
- **A failed lookup is never read as "no rows"**: every reader in section 5 treats an error as "pinned to nobody" (fail closed), never as "unpinned" (fail open).

### 3.4 Store Interface (Go)
Added to `store/store.go`:

```go
// ChannelBoxPins: the boxes a channel is pinned to; nil = unpinned.
GetChannelBoxPins(ctx context.Context, tenant, channel string) ([]string, error)
SetChannelBoxPins(ctx context.Context, tenant, channel string, boxes []string, by string) error
ListChannelBoxPins(ctx context.Context, tenant string) (map[string][]string, error)
```

In `store/channel_box_pins.go` (Postgres, inside the tenant scope; the operator write inside the operator scope) and the memory store (`store/memory.go`), tested by `store/channel_box_pins_test.go` on PostgreSQL (`PRE_PUSH_TIER=full`).

---

## 4. Administration and APIs

### 4.1 Who May Pin, and What Is Checked
- Setting a channel's pins needs `rbac.TenantSettings` (`api/internal/rbac/rbac.go:27`, stage Administer).
- The hub refuses:
  1. a channel that does not exist or is archived: `404 unknown_channel`;
  2. a box that is not pinned to the workspace, or is revoked (`store.GetPin`): `400 unknown_box`;
  3. a default channel (`#lobby`, `#alerts`, `#feedback`, `#public`; `store/channels.go:16-25`): `400 channel_default_unpinnable`, unless the owner answers Q1 (section 9) the other way.

### 4.2 REST Routes (human session, the WUI)
1. `GET /v1/channels/{channel}/box-pins` -> `{"channel": "<c>", "box_pins": ["box-x"], "is_pinned": true}`; unpinned: `"box_pins": [], "is_pinned": false`.
2. `PUT /v1/channels/{channel}/box-pins`, body `{"box_pins": ["box-x"]}`; `[]` clears the pin (back to the default).
3. `GET /v1/tenant/channels` adds `box_pins: string[]` to each channel item.
4. `PUT /v1/operator/channels/{channel}/box-pins?tenant=<id>`: the operator form of 2, in the operator scope (the `operator_scope` policy), for the seed action of B8. It sits next to the existing `GET /v1/operator/channels/{channel}`.

### 4.3 Box-Signed Read (the placer and the launcher)
The orc scripts talk to the hub only through the box-signed `spool` CLI (`spl_asks_hub`, `orc/run/spl-asks-open.func.sh:94-98`, runs `spool ask ...`). So the placer and the launcher read a channel's pins through a new verb, built like `spool ask` (`api/cmd/spool/ask.go`, `api/internal/action/ask.go`, `hub/box_ask.go`):

`spool channel-pins --channel <c>` -> `{"channel": "<c>", "box_pins": [...], "is_pinned": bool}`, or a non-zero exit when the hub does not answer.

### 4.4 Web UI
- **Client (`wui/utils/spool-client-lazy.mjs`)**: the WUI has no pins call today (`grep -rn listPins csi-spl-wui/src` -> 0). B6 adds `listPins()` for the hub's existing `GET /v1/pins`, and `getChannelBoxPins(channel)` / `setChannelBoxPins(channel, boxes)` for 4.2.
- **`wui/components/ChannelPropertiesDialog.vue`**, settings tab (`v-show="tab === 'settings'"`, :298-329): a "Boxes" choice, "Any box (default)" or a checkbox per pinned box of the workspace (`listPins()`); read-only without `TenantSettings`.
- **`wui/pages/tenant-settings/channels.vue`**: a "Boxes" column in `tenant-channels-table` (:11), "Any box" when empty, else the box ids.
- Every string is a translation key in every locale under `csi-spl-wui/i18n/locales/`.

---

## 5. Enforcement

### 5.1 (a) Fan-Out, Direct Leg, Mention and Fallback (Fail Closed)
- **Fan-out** (`routeChannel`): one lookup before the loop; a box not in a non-empty list is skipped.
  ```go
  pinned, err := s.channelBoxPins(ctx, tenant, channel)
  if err != nil {
      s.o.Log.Error().Err(err).Str("channel", channel).Msg("channel box pins lookup failed; fan-out dropped")
      return // fail closed: no box gets it; the message stays stored
  }
  for box, agents := range members {
      if len(pinned) > 0 && !slices.Contains(pinned, box) {
          continue
      }
      // ... the existing filters, enqueue and push
  }
  ```
- **Direct leg, both doors** (the same check, one helper `channelBoxRefusal(tenant, channel, toBox)`): a frame on a pinned channel whose `to_box` is not in the list is refused, `403 channel_box_mismatch` (the box is pinned to the workspace; the channel refuses it); a lookup error refuses it too (`503 channel_pins_unavailable`). `to_box = box-wui` is never refused.
  - **Agent frames**: a new `sendChannelBoxRefusal` in the `onSend` chain right after `sendRouteRefusal` (`hub/ws.go:632`), so the refusal comes before `commitRow` stores or queues anything.
  - **Browser frames**: the same check in `dispatchCheck` (`hub/dispatch.go:125-168`).
- **Cross-box mention**: a post on a pinned channel that names `@<id>@<box>` for a box outside the list gets the same `403 channel_box_mismatch` at the same two places, so it fails fast rather than waiting for a box that will never get it.
- **Fallback** (`hub/fallback.go`): on a pinned channel `fallbackBoxes` keeps only the listed boxes; with none online, no fallback runs.
- **Receive** (`recvAgents`): a box that receives a queued row of a pinned channel it is not listed for gets no targets **and `own` is false**: the row is dropped, also when its `to_box` is that box (`hub/channels.go:320`, `:338`). This covers rows queued before the pin was set and any leg the refusals above miss. A lookup error drops the row too.
- **The browser box** (`WUIBox = "box-wui"`, `hub/wui.go:42`) is never filtered: it is no delivery target in the fan-out, and a human posting from the WUI is not an agent post. A pin limits machines, not people.

### 5.2 (b) Lane Placement
1. **The ask's channel**: the brief's `Channel: <tenant> #<channel>` line, read with the existing `cr_channel_of` (`orc/features/spawn-agents/lib/channel-rules.inc.sh:34-48`) on the file `spl_spawn_place_brief` (`orc/run/spl-spawn-place.func.sh:935`) returns. Ask rows in the hub get no new column. A brief with no `Channel:` line is unpinned.
2. **Its pins**: `spool channel-pins` (4.3), signed with the desk keys of **the `Channel:` line's tenant**, not the orchestrator's: `spl_asks_hub` (`orc/run/spl-asks-open.func.sh:94-98`) signs with `LANE_DESK_DIR="$SPL_STATE_DIR/desk/$LANE_TENANT/$LANE_DESK_BOX"` (`orc/run/spl-lane-map.func.sh:114`), the orchestrator's workspace, and a box of one tenant may not read another tenant's pins (B4's red control). So the placer resolves `$SPL_STATE_DIR/desk/<channel tenant>/<box>` and signs with it. No pinned desk in that tenant (`pinned` file missing), or the hub does not answer -> the ask holds (fail closed), reason `waiting: channel pins unreadable (<why>)`.
3. **The hold, `spl_spawn_place_channel_hold`**: a new step in the hold chain next to `spl_spawn_place_pin_hold` (`:181`), for every vendor (claude, grok, agy, mistral, qwen). For a pinned channel:
   - a listed box with room -> `spl_spawn_place_launch` (`:948`) launches with `SPAWN_BOX=<that box>` (the first listed box with room, in `do_spl_box_pick` order);
   - every listed box full, degraded, draining or offline -> the ask HOLDS, `.place.wait` reads `waiting: channel #<c> is pinned to <boxes> (<why each>)`;
   - it never moves the ask to another box.
4. **The launcher** (`orc/features/spawn-agents/scripts/spawn-window.sh`): a slug whose brief names a pinned channel, launched with no `SPAWN_BOX` or a `SPAWN_BOX` outside the list (a hand spawn), exits **15**, "channel box pin: <box> is not in #<c>'s boxes". 15 is the first free code: the header (`:38-48`) uses 0 and 2 to 14 (8 = the remote spawn on SPAWN_BOX did not start, `:337`; 14 = hub DNS, `:383`).

### 5.3 (c) Posting and Reading
- **Posting** (`agentInChannel`, `hub/channels.go:219-231`): an agent on a box outside the list gets `404 unknown_channel`, the read door's answer, so it cannot confirm the channel exists. A lookup error refuses too (fail closed: `return false, err`), never allows.
- **Reading**: a box reads nothing over HTTP (2.2), so 5.1 is the box read door: a box outside the list never receives the post, its topic or its attachments. No metadata endpoint is added.
- **Humans** keep reading every channel they are members of through the WUI (`/v1/view/...`, human sessions only); the pin does not change that.
- **The orchestrator's sweep** reads the database through the proxy (`spl_sweep_rows`), so it sees pinned channels' rows as today; B7 adds `channel_box_pins` to its row read so it can classify them (6.2).

### 5.4 (d) Every Listed Box Offline
1. **What is kept**: the message is stored. `routeChannel` queues a delivery for each listed member box (state `queued`).
2. **What is lost**: the queue has two limits (cnf `csi-spl-cnf/csi-spl/all.env.yaml:469-470`): `SPOOL_HUB_QUEUE_TTL: "168h"` and `SPOOL_HUB_QUEUE_MAX_PER_BOX: "1000"`. A delivery queued longer than 7 days expires, and past 1000 queued rows for a box the oldest are marked `expired` (`store/postgres.go:544-550`). A pinned box down longer than that misses those deliveries; the posts stay in the topic, readable by humans in the WUI.
3. **The WUI banner** under the channel header, while every listed box is offline: "This channel runs only on <boxes>, offline since <time>. Posts wait up to 7 days (at most 1000 per box); older ones will not reach it." The two limits are read from the hub's config, not typed in.
4. **Reconnect**: when a listed box reconnects (`/v1/ws`), the hub sends its queued, unexpired deliveries in order, as for any box.

---

## 6. The 3-Minute Rule for a Pinned Channel

### 6.1 The Conflict
The backstop (2.4) is the orchestrator lease holder, which may sit on a box outside the list. Taking the topic there breaks the pin: the tools or the data are on the listed box only. And by 5.1 that orchestrator never receives the post.

### 6.2 The Rule
1. **No take from outside the list**: `spl_take_auto_skip` (`orc/run/spl-take-auto.func.sh:74`) skips a post on a channel pinned to boxes that do not include `SPOOL_BOX_ID` (`skip: channel pinned to <boxes>`). `do_spl_take` refuses it the same way.
2. **The hub posts the holding notice** (if the owner picks Q2 = A): a check in `hub/pin_notice.go` on its own ticker (like `hub/presence.go:41`). A human post on a pinned channel with no agent reply after 120 s, while no listed box has a live session (`s.boxSession(tenant, box) == nil` for each), gets one notice from the hub's system sender in its topic: "This channel runs only on <boxes>, which are offline. Your post waits and will be handled when one reconnects." One notice per topic per outage; a reconnect resets it. Nothing outside the list takes or spawns.
3. **The sweep**: `orc/scripts/unanswered-sweep-classify.py` classifies such a post as `pinned-box-offline` (it reads `channel_box_pins` and the box's last seen time with its rows), listed under "waiting on a pinned box", not as a dispatcher miss. Once a listed box is back, the post is a normal unanswered post again.

---

## 7. Migration of the Production Cases

| Case | Workspace | Channel | Boxes | Why |
|---|---|---|---|---|
| M1 | Workspace A | `#app-alpha` | `["box-x"]` | Tooling and runtime state only on `box-x`. |
| M2 | Workspace B | `#project-beta` | `["box-y"]` | Private member data on the member's own machine. |
| M3 | Workspace C | `#service-gamma` | `["box-x"]` | Customer repositories cloned only on `box-x`. |

`do_spl_channel_box_pin_seed` (`orc/run/spl-channel-box-pin-seed.func.sh`) applies them with the operator route (4.2.4), a dry run unless `DRY_RUN=0`. The real workspace, channel and box ids are its input file outside git (`<spool root>/dispatch/channel-box-pins.tsv`), never in this repo. Running it twice changes nothing.

---

## 8. Build Rows

All rows: **Planned**, not built. Files are disjoint across rows.

| Row | Status | What | Files (only these) | Needs | Tests and red control |
|---|---|---|---|---|---|
| **B1** | Planned | Table and store | `rdb/0242_channel_box_pins.sql` (next free number)<br>`csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql` (only if a grant is missing)<br>`store/store.go`<br>`store/channel_box_pins.go`<br>`store/memory.go`<br>`store/channel_box_pins_test.go` | none | `TestChannelBoxPinsStore`, `TestRLSCoversEveryTenantTable` (it checks FORCE), on PostgreSQL.<br>**Red**: pins written under tenant A, then read through the hub's runtime login in tenant A's scope -> the same rows (a policy on the wrong setting reads 0 and fails this); read in tenant B's scope -> 0 rows; a pin of a box with no `pins` row -> FK error. |
| **B2** | Planned | Hub REST routes | `hub/channel_box_pins.go`<br>`hub/channel_box_pins_test.go`<br>`hub/server.go` (route lines)<br>`hub/tenant_settings.go` | B1 on master | `TestChannelBoxPinsAPI` (GET, PUT, operator PUT, `GET /v1/tenant/channels`).<br>**Red**: a member without `TenantSettings` -> 403 (not 200); an unknown or revoked box -> 400 `unknown_box`; `#lobby` -> 400 `channel_default_unpinnable` (per Q1). |
| **B3** | Planned | Fan-out, both direct-leg doors, mention, fallback, receive, posting | `hub/channels.go`<br>`hub/ws.go`<br>`hub/dispatch.go`<br>`hub/fallback.go`<br>`hub/channel_box_pins_route_test.go` | B2 on master | `TestRouteChannelBoxPin`, `TestSendChannelBoxPin`, `TestDispatchChannelBoxPin`, `TestRecvChannelBoxPin`, `TestFallbackChannelBoxPin`, `TestAgentInChannelBoxPin`.<br>**Red**: a pinned channel's post is queued for an unlisted member box; an agent on a listed box sends `to_box` = an unlisted box on a pinned channel over the box WebSocket and it is accepted (row stored or queued); the same from the browser is accepted; a row queued for an unlisted box before the pin (its `to_box` = that box) reaches it; a fallback picks an unlisted box; an agent on an unlisted box posts; a lookup error (store stub) delivers or allows. |
| **B4** | Planned | Box-signed read verb | `api/cmd/spool/channel_pins.go`<br>`api/internal/action/channel_pins.go`<br>`hub/box_channel_pins.go`<br>`hub/box_channel_pins_test.go` | B2 on master | `TestBoxChannelPins` and the CLI test.<br>**Red**: a box of tenant B reads tenant A's pins; the CLI exits 0 when the hub does not answer. |
| **B5** | Planned | Placer and launcher | `orc/run/spl-spawn-place.func.sh`<br>`orc/features/spawn-agents/scripts/spawn-window.sh`<br>`orc/tests/spl-spawn-place-channel-pin.tst.sh` | B4 served | `spl-spawn-place-channel-pin.tst.sh` (a stub `spool channel-pins`).<br>**Red**: a claude ask (not only agy or mistral) for a pinned channel launches on an unlisted box when the listed one is full; an unreadable pin list launches; the pins are read with the orchestrator's tenant keys instead of the `Channel:` line's tenant; no desk in that tenant launches instead of holding; `spawn-window.sh` with an unlisted `SPAWN_BOX` exits 0 instead of 15. |
| **B6** | Planned | WUI | `wui/utils/spool-client-lazy.mjs`<br>`wui/components/ChannelPropertiesDialog.vue`<br>`wui/pages/tenant-settings/channels.vue`<br>`wui/utils/tenant-settings.mjs`<br>`csi-spl-wui/i18n/locales/*.json`<br>`csi-spl-wui/tests/unit/channel-box-pins.test.mjs`<br>`csi-spl-wui/tests/e2e/tenant-channel-box-pins.test.mjs` | B2 served | unit, e2e in Chrome, i18n parity, `pnpm run typecheck`.<br>**Red**: the dialog saves without sending `box_pins`; `listPins()` is missing; the offline banner shows a typed 7 days instead of the hub's value. Text: agy review before land (language rule). |
| **B7** | Planned | Holding notice, take, sweep | `hub/pin_notice.go`<br>`hub/pin_notice_test.go`<br>`orc/run/spl-take-auto.func.sh`<br>`orc/run/spl-take.func.sh`<br>`orc/run/spl-unanswered-sweep.func.sh`<br>`orc/scripts/unanswered-sweep-classify.py`<br>`orc/tests/spl-unanswered-sweep-channel-pin.tst.sh` | B3 on master, Q2 answered | `TestPinNotice`, `spl-unanswered-sweep-channel-pin.tst.sh`.<br>**Red**: every listed box offline 3 min -> no post in the topic; auto-take on an unlisted box takes the post; the sweep reports it as a dispatcher miss. |
| **B8** | Planned | Seed the production cases | `orc/run/spl-channel-box-pin-seed.func.sh`<br>`orc/tests/spl-channel-box-pin-seed.tst.sh` | B2..B7 served | `spl-channel-box-pin-seed.tst.sh` on a test hub.<br>**Red**: `DRY_RUN=0` leaves the pins unset; an unknown box exits 0; a second run changes a row; a dry run writes. |

---

## 9. Owner Questions

Two questions for the owner, sent as one form (one form per post). I recommend **A** for both.

```poll
Q1. May a workspace admin pin a default channel (#lobby, #alerts, #feedback, #public) to chosen boxes?
(A) No: the default channels stay on every box; the hub refuses with channel_default_unpinnable
(B) Yes: any channel may be pinned
Q2. A human posts in a pinned channel and every box it is pinned to is offline. What answers within 3 minutes?
(A) The hub posts one notice after 2 minutes: the channel runs only on those boxes, they are offline, the post waits
(B) Nothing is posted; only the WUI banner shows the boxes are offline
```

Decided in this spec, no owner question (each can be reversed by a later spec):
- **Subscriptions survive a pin** (was Q3): `channel_subscriptions` rows stay; 5.1 only stops deliveries to unlisted boxes, so clearing the pin restores everything.
- **Cross-box mentions are refused, not delivered** (was Q4): delivering one would break the isolation the owner asked for (msg `6b6d092c`).
- **Fallback stays inside the list**: with no listed box online, no fallback runs.

---

## 10. Risks and Open Checks

1. **R1: one box, one point of failure.** A channel pinned to one box stops while that box is down. Mitigation: the banner (5.4.3) and the notice (6.2.2); an admin can add a box or clear the pin.
2. **R2: crowding one box.** Many channels pinned to one box queue their lanes there while other boxes idle. Mitigation: the placer's `.place.wait` names the pin, so the hold is visible in the queue.
3. **R3: cross-box mentions and direct legs.** Refused in the `onSend` chain and in `dispatchCheck` with `403 channel_box_mismatch`, and dropped on receive (5.1), built in B3.
4. **R4: queue limits.** A listed box down for more than 7 days, or with more than 1000 queued rows, loses deliveries (5.4.2). The banner says so.

---

## 11. Change Log

| Version | Change |
|---|---|
| v1.0 | First draft (`c05e273b0`). R7 review by c-594: FAIL, findings W1..W9. |
| v1.1 | **W1**: citations re-read on `dc328aae3`; `agy_box_hold` is the agy/mistral quota hold at :890-934 (the file moved), the HAND-PINNED header :62-70, `orc/` no longer doubled, `listPins()` named as a new B6 client call, the route quote keeps `seats.filter` and `channelLockSkip`. **W2**: RLS copies 0139/0014 (`app.tenant_id`, `operator_scope`, `FORCE`), `:runtime_role`, the migration is 0242 (0240 and 0241 are taken now), B1's red control reads through the hub login. **W3**: every lookup fails closed (3.3, 5.1, 5.3). **W4**: the hold is its own step for every vendor; the channel comes from the brief's `Channel:` line via `cr_channel_of`; the pins via a new box-signed `spool channel-pins` (4.3, B4); launcher exit 15 (8 and 14 are taken). **W5**: boxes read only through deliveries and humans only through `/v1/view`, so 5.1 is the read door and no metadata endpoint is needed; the browser box is never filtered; `dispatch.go` and `fallback.go` are in B3. **W6**: 5.4 states the 7-day TTL and the 1000-per-box cap, and the banner shows them. **W7**: the hub posts the holding notice (`hub/pin_notice.go`, B7, red control "offline 3 min -> no post"). **W8**: no real orchestrator box or seat id. **W9**: two owner questions in one `poll` form (Q3, Q4 decided in section 9); every row says Planned; B8 (seed) has a red control. |
| v1.2 | R7 re-review by c-594 (W1-W4, W6-W9 closed). **W5**: the agent direct leg goes `onSend` -> `commitRow` (`hub/ws.go:611`, `:1009`), not `dispatchCheck` (browser only); 2.2 now names both doors, 5.1 refuses in the `onSend` chain before `commitRow` and in `dispatchCheck`, and `recvAgents` drops a pinned channel's rows (own ones too) on an unlisted box; `hub/ws.go` joins B3 with red controls for both. **N1**: 5.2.2 signs `spool channel-pins` with the desk keys of the `Channel:` line's tenant; no desk there -> hold; B5 red controls. |

<!-- version: 1.2.0 · updated: 2026-10-30 -->
