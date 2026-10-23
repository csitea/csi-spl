# 151 Dedicated bots: add agents to a DM, and a blobatar avatar

Version v0.1 (2026-10-23). This is step 1 of the owner rule for a big
change: the written spec. Nothing in it is built until the owner says go
(dispatcher answers
`1f5d0ca6`
and
`b3e3431a`).

Sources: prd topics in the owner's workspace, `/t/c1459184-8e76-4921-b8af-7be1f54d25cd`
(the avatar) and `/t/cf359a19-1356-447c-9f94-c4cb5324b2ef` (agents in a
DM; dispatcher answer
`637bed7a`).
Issues: SPL-3032 (this v0.1) and epic SPL-3030. Each build row in
[tasks.md](tasks.md) has its own issue.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`
- `store/` = `api/store/`
- `hub/` = `api/hub/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`

Every `file:line` was read on origin/master `e829c971f`.

## 1. The owner's asks, verbatim

All times are 2026-10-23 UTC.

| part | topic | msg | time | text |
|---|---|---|---|---|
| 2 | c1459184 | `8dc2c599` | 10:42 | "take the bot avatar from thie page https://blobatar.dev/ and make it the default icon for dedicated bots only - deciated = which are explicitly added by hand on a channel or directs msg" |
| - | c1459184 | `1fb92ff9` | 10:4x | "create the git-spec and create the issue objects for those and let me know when you are ready with the plan" |
| 1 | cf359a19 | `5117c382` | 10:46 | "I would like to be able to add agents explicitly in the direct msgs" |
| 1 | cf359a19 | `f719d30e` | - | a screenshot of the row menu of a DIRECT MESSAGES sidebar row: Open, Copy link, Block, Mute, Pin, Remove from list, Remove |
| 1 | cf359a19 | `4df110b9` | - | "as an additional menu entry similarly to how it is done on the channel properties" |

Part 1 (agents in a DM) is built first. An agent added to a DM by hand
becomes one of the "dedicated" bots of part 2.

## 2. What exists on origin/master today

### 2.1 Avatars

- `wui/utils/avatar.ts:121` `avatarSvg(id, box)` draws an identicon for a
  human (`isHuman`, `:35`, which covers HUM-* and GST-*). Anything else gets
  the robot (`robotSvg`, `:53`). The key is `id@box` (`:122`).
- `wui/utils/avatar.ts:132` `avatarDataUri(id, box)` returns that SVG as a
  `data:image/svg+xml;utf8,` URI. It is memoised per id and box, at most
  1000 entries (`:128-141`).
- `wui/utils/avatar.ts:171` `avatarImageUrl` returns a stored picture, for a
  member HUM-* only (`isMember`, `:40`). No agent has a stored picture today.
- `wui/components/SpoolAvatar.vue:35-37` shows the stored picture once it
  has loaded, and `avatarDataUri` until then. Every avatar in the WUI is
  this component.
- `csi-spl-doc/doc/md/SPEC-spool-avatars.md` section 2 says:
  - bots get "a wild, funny robot" and humans an identicon;
  - the default is bundled or generated in the client, never hotlinked from
    a CDN.
- That file is generated from qto doc `7a99eb3d-766d-44fd-9d89-99c577b3c102`
  (see its line 3). An edit goes to that doc first, then
  `do_spl_doctree_export_md` rewrites the file.
- CSP: `csi-spl-wui/nuxt.config.ts:158` and `csi-spl-wui/firebase.json:40`
  both set `img-src 'self' data:`, so a picture has to be a `data:` URI.

### 2.2 How an agent gets into a channel

**The table.** `channel_subscriptions` (`rdb/0002_channels.sql:15-23`) has
one row per (tenant, channel, agent, box).

- `origin` is `announce`, `invite` or `removed`
  (`rdb/0032_channel_subscription_origin.sql:11-18`; `removed` came in
  `0033`).
- The row has **no column for who added the agent**.

**Announce no longer seats anyone.** `SetSubscriptions`
(`store/channels_postgres.go:207-224`) only deletes old `announce` rows. The
only way an agent joins a channel is an `invite` row.

**Two things write an `invite` row:**

1. **A person, by hand.** The Agents picker in the channel properties dialog
   (`wui/components/ChannelPropertiesDialog.vue:140` `channel-agent-picker`,
   `wui/composables/useChannelAgentPick.ts:84-99`) calls
   `POST /v1/channels/{channel}/agents` (`hub/channel_members.go:37`, handler
   `:339-399`). That runs `InviteChannelAgent`
   (`store/channels_postgres.go:226-243`). The handler knows the caller
   (`hum`) but never stores it.
2. **The fleet, by operator SQL.** `do_spl_dispatch_subscribe`
   (`csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh`, header
   lines 3-4: "Put every OD seat ... of every box of the fleet in every
   channel") runs `do_spl_channel_agent_add_op`. That INSERTs the same
   `invite` row through the Cloud SQL proxy.

**The fleet's seats** are the role numbers `001` (orch) and `002`, `003`
(dispatch), with any vendor letter (`hub/role_group.go:41` `roleNumbers`,
`:132` `roleNumber`).

**The members answer** (`GET /v1/channels/{channel}/members`,
`hub/channel_members.go:36`) lists each agent as `{id, box, online, seated}`
(`wui/types/mjs-shims.d.ts:143`). Nothing in it says who added the agent.

**Measured on prd** with `do_spl_db_query` (read-only, 2026-10-23 ~11:10Z):

- `channel_subscriptions` holds 0 `announce` rows, so every agent in a
  channel is an `invite` row.
- In the owner's workspace (the one of both source topics) there are 127
  invite rows, and every one is a role seat: c-001, c-002, c-003, g-001,
  g-002 and g-003, each on two fleet boxes, in 11 or 12 channels each. So by the rule below, no bot in the owner's workspace is
  "dedicated" today.
- Across all tenants there are 1,069 role-seat rows and 109 rows for other
  agents:

  | workspace | non-role rows |
  |---|---|
  | the fleet's main workspace | 82 (78 agents) |
  | the e2e workspace | 10 |
  | five other workspaces | 6, 5, 3, 2, 1 |

  The query was `select tenant_id, (agent_id ~ '-0*(1|2|3)$'), count(*) ...
  where origin='invite' group by 1,2`.

### 2.3 What "dedicated" means, and whether the WUI can tell today

**Dedicated** = a bot that a person added by hand to a channel's or a DM's
members.

**Not dedicated:**

- the fleet's role seats, which the operator path puts in every channel;
- a bot that only talks to people in DMs it was never added to.

**The WUI cannot tell today:**

- A hand pick and the fleet's seeding write the same `invite` row (2.2), and
  the store keeps no `invited_by`.
- The roster (`GET /v1/view/roster`, `hub/view.go:266`) lists each box's
  `agents []string` with `seated_at` and `agent_presence`
  (`hub/view.go:225-256`). It has no per-agent origin.
- In code, "dedicated" exists only as a box's join mode
  (`rdb/0170_box_join_switch.sql:16-19`, `pins.box_mode`).
  `grep -rliE "dedicated (bot|agent)" csi-spl-api csi-spl-wui/src` -> no
  hit. In the specs it hits spec 144 (section 2.6) and some reviews.

The WUI could guess "in a channel and not a role number", but that guess
would mark the fleet's non-role helpers wrongly and could never see a DM
add. So the API has to change (section 4.2).

### 2.4 How a DM is stored

- **There is no DM entity.** A DM is a `messages` row with `channel IS NULL`
  and a single `to` (`rdb/0001_hub_core.sql:57-67`: one `from_box`/`from_id`,
  one `to_box`/`to_id`).
- **A DM thread** is a topic (`task_id`) with no channel. A person's DM list
  with one peer is the set of topics where both of them appear
  (`hub/view.go:623-671`, `?peer=` and `dm=true`; the SQL is `walkParties`,
  `store/view_postgres.go:283-299`).
- **Who can read it:** only its two ends (`readableBy`,
  `store/view.go:336-341`).
- **Delivery:** `commitRowTyped` (`hub/ws.go:948`) stores the message and
  queues it once, to its `to_box` (`hub/ws.go:984`). `routeChannel`
  (`hub/ws.go:995`, `hub/channels.go:261-302`) fans a channel post out to
  the channel's member agents. For a DM it does nothing.
- **So a DM has exactly two parties.** `grep -rniE "group[ _-]?dm|dm_members|mpim"`
  over the api, rdb, wui and specs -> no hit. The main case is a DM between
  a person and a bot (`store/dm_pointers.go:22-25`).

### 2.5 The DM row menu

- `wui/utils/sidebar-row-menu.mjs:17-58` `rowMenuItems` builds the menu:
  - Open and Copy link (`:20-21`);
  - for a person row (`o.person`, `:38-56`): Block, Mute, Pin, Remove from
    list (`hide`, `:54`) and Remove (admins only, `:55`).

  That is the list in the screenshot.
- `wui/components/ChannelSidebar.vue:238` renders the menu for a DM row. A
  row is `{id, box, label}`, where `label` = `id@box`, and its route is
  `/dm/<label>` (`wui/utils/live-follow.mjs:270-297`).
- On a bot, Remove only hides the row in this browser
  (`wui/composables/useSidebarPeers.ts:55-69`).
- The labels are `sidebar.row_menu.*` in
  `csi-spl-wui/i18n/locales/en.json:544-562`; there are 19 locale files. The
  channel dialog's "Add an agent" is `channels.properties.add_agent`
  (`en.json:1210`).

### 2.6 Spec 144 uses the same word

`csi-spl-doc/specs/144-dedicated-agents/spec.md` (v0.2, "Status: Planned
(Spec Only)", its line 3; epic SPL-2390) defines a "Dedicated Agent" as a
bot bound to ONE channel or ONE topic, with a private scope, an idle
timeout and abuse limits. None of it is built:
`grep -rlnE "dedicated_scope|is_private_scope|dedicated_agent" csi-spl-api/src csi-spl-rdb/src csi-spl-wui/src`
-> no hit.

The two specs do not conflict:

- This spec's "dedicated" is the owner's own definition for the avatar
  (msg `8dc2c599`): added by hand to a channel or a DM. It adds no scope
  limit and no isolation.
- A spec 144 binding is also an agent a person dedicated by hand, so once
  spec 144 is built, its binding table joins the T007 query and that bot
  gets the blobatar too.
- If spec 144 is built first, T007 reads its table as well. Neither spec
  needs the other to start.

## 3. blobatar

Everything below was read from the published tarball `blobatar-2.7.0.tgz`
(npm `dist.integrity`
`sha512-tL1p2J3dXE/Z9U/ITwHqU7HBHmTH+Am+hif1J1hWAhvFT1VYC2HG+eXtN7081yuY+L2lrp9bs/VaF7dVH3S2jw==`).

**Licence and dependencies**

- MIT (the `LICENSE` file in the tarball).
- No `dependencies`.
- The `peerDependencies` (react >=18, vue >=3) are both `optional`
  (`peerDependenciesMeta`), so pnpm installs neither.

**API**

- `blobatar(name, opts) -> string` (SVG markup), from `blobatar`.
- `blobatarUri(name, opts) -> string`, from the subpath `blobatar/uri`: a
  percent-encoded `data:image/svg+xml,` URI.
- The options this spec uses:
  - `size`;
  - `background`: `false` by default, or `"circle"`, `"square"`,
    `"squircle"`;
  - `title` (escaped by the library).
- The `animate` and `expression` options are not used. Without `animate`
  the SVG has no `style` and no `class`.

**Deterministic.** The seed is a hash of the name after NFC, trim and
lower-casing (`dist/uri.js`, `Rt`). The library promises "the same name
always produces the same output within a major version"
(`dist/blobatar.d.ts`).

**Size.** `dist/uri.js` is a single self-contained file
(`grep -o 'import[^;]*from"' dist/uri.js` -> no hit): 13,164 B raw,
**5,908 B gzip -9**. The brief's "~3.7 KB" did not reproduce, so this spec
uses the measured 5.9 KB.

**Budget.** The `ci_initial_gzip_kb` ceiling is 155 KB
(`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:4`).
The last recorded measure in that file (`headroom`) is 146.9 KB; it was not
re-measured for this spec. `SpoolAvatar.vue` is on the first screen, so a
static import would add about 5.9 KB to first paint.

**Decisions.** The code settles these three:

- **Use the npm package, pinned exactly.** Put `"blobatar": "2.7.0"` (no
  caret) in `csi-spl-wui/package.json`, with the lockfile integrity above.
  Vendoring was rejected: it copies a minified file and its licence into the
  tree and loses the lockfile's integrity check. The package costs one
  import path and pulls in no other code.
- **Load it lazily.** Call `import('blobatar/uri')` the first time a
  dedicated bot is drawn, so first paint does not change. Until the chunk
  arrives, that bot shows today's robot, which is then swapped in place in
  a box of the same size (`SpoolAvatar.vue:5-7`).
- **Render it as a `data:` URI:**
  `blobatarUri(id@box, { background: 'squircle' })`, the same rounded tile
  as the robot, memoised like `avatarDataUri`. The key is `id@box`, the
  same avatar key as `avatarSvg` (`avatar.ts:122`) and SPEC-spool-avatars
  section 1.

## 4. The design

### 4.1 Part 1: add agents to a direct message (built first)

**The model: a DM gets an agent list, as a channel has.**

A new table comes in the rdb migration `NNNN_dm_agents.sql` (the next free
number; on master today that is `0214`). It has one row per (tenant, DM,
agent, box), where the DM is its two ends as a sorted pair of `id@box`.
Each row also holds:

- `origin`: `invite` or `removed`;
- `invited_by`: the HUM-* who added the agent;
- the time.

**API.** The hub applies the same rules as the channel agent door
(`hub/channel_members.go:339-399`):

| route | does |
|---|---|
| `GET /v1/dms/{peer}/agents` | lists the agents added to the caller's DM with `{peer}` (`id@box`) |
| `POST /v1/dms/{peer}/agents {id, box}` | adds one announced agent; 201 |
| `DELETE /v1/dms/{peer}/agents/{box}/{id}` | takes it out (`origin = removed`) |

**Who may add or remove an agent.** The caller must be:

- a person who is one of the DM's two ends;
- holding `channels.edit` (so not `demo_user`, as in `channelDoor`);
- in a workspace that may write (`billing.AllowsWrite`);
- past the box lock (`boxLockRefusal`).

The agent must be announced on the roster, otherwise the answer is
`not_a_member`. If the agent has a sender allow-list
(`rdb/0188_agent_sender_allow.sql`), the person adding it must be on that
list. Anyone else gets 404, never 403, as the read-door rule requires.

**What the agent receives.** It gets every DM message on that pair from the
moment it was added; it gets no history. Each message is queued to its box
next to the `to_box` leg in `commitRowTyped` (`hub/ws.go:984`). The recv
frame names it as an added agent, the way `recvAgents` does for a channel
(`hub/channels.go:311-336`).

**Its replies** go in the same topic. The hub delivers an added agent's
message to both ends of the DM and to the other added agents. `readableBy`
(`store/view.go:336-341`) gains one case: "a message in a DM topic of my
pair, written by an agent added to it". So both people see the reply in
the same DM view.

**Removing an agent.** Its row stays, marked `removed`, and new messages no
longer reach it. The messages it already wrote stay in the DM.

**WUI.**

- `rowMenuItems` gets an `add-agent` entry ("Add an agent") for a person
  row, after Pin. Its label is either the existing key
  `channels.properties.add_agent` or a new `sidebar.row_menu.add_agent`.
- The entry opens a small dialog with the same picker and list as the
  Agents tab of the channel dialog: the combobox
  (`ChannelPropertiesDialog.vue:140-198`) and the list with a minus per
  agent (`:199-223`). The pick logic (`useChannelAgentPick.ts`) is given
  the DM's add, remove and list calls in place of the channel's.
- New client calls `listDmAgents`, `addDmAgent` and `removeDmAgent` go in
  `wui/utils/spool-client-lazy.mjs` (live and mock), with their types in
  `wui/types/mjs-shims.d.ts`.
- Every new text is a key in all 19 locales, and agy reviews it last (the
  language rule).

### 4.2 Part 2: the blobatar avatar

**The rule.** For each bot (`id@box`), the same everywhere it is drawn:

1. A stored picture wins. Today only member humans have one
   (`avatar.ts:171`).
2. A human: unchanged (the identicon).
3. A **dedicated** bot: the blobatar of `id@box` (section 3).
4. Any other bot: unchanged (the robot).

A bot is **dedicated** when this workspace has at least one live row in
which a person added it by hand. That row is either:

- in `channel_subscriptions`, with `origin = 'invite'` and `invited_by` a
  HUM-*; or
- in `dm_agents` (4.1), with `origin = 'invite'`.

**API changes.**

- The rdb migration `NNNN_channel_subscription_invited_by.sql` adds a
  nullable `invited_by text` to `channel_subscriptions`:
  - `InviteChannelAgent` stores the caller (`hum`,
    `hub/channel_members.go:399`);
  - the operator INSERT (`do_spl_channel_agent_add_op`) leaves it NULL;
  - the same migration backfills: an existing `invite` row whose agent is
    not a role number (001, 002, 003) gets `invited_by = 'legacy'`, which
    counts as a hand pick. The fleet's operator path seeds only role seats
    (2.2). On prd that is 109 rows.
- The roster (`GET /v1/view/roster`) gives each box an `agent_dedicated`
  list next to `seated_at` (`hub/view.go:225-256`), read from both tables in
  one query.
- The members answer gives each agent row `dedicated: true|false`.

**WUI.**

- Every avatar already reads the roster (`SpoolAvatar.vue:55-68`). That
  read also fills a shared set of dedicated `id@box`.
- `avatarDataUri` stays the synchronous robot. A new
  `dedicatedAvatarUri(id, box)` loads `blobatar/uri` once and memoises the
  result.
- `SpoolAvatar.vue` shows the blobatar when the bot is in the set, and the
  robot as before otherwise.

Once someone adds a bot anywhere, it counts as dedicated in the whole
workspace, so one bot keeps one face. Poll Q2 asks the owner to confirm
this.

## 5. Red controls

Each case FAILS on origin/master `e829c971f` today and passes once its row
is built. Cases marked "guard" are green today and must stay green.

| case | row | check | today |
|---|---|---|---|
| C1 | T001 | store: `AddDMAgent`, then `DMAgents(pair)` returns the agent; `RemoveDMAgent` marks it removed (Postgres) | no such store method: compile fails |
| C2 | T002 | hub: `POST /v1/dms/HUM-2@box-wui/agents {c-9, box-a}` by HUM-1 -> 201; by HUM-3 (not an end) -> 404 | route absent: 404 for both |
| C3 | T002 | hub: after C2, a DM HUM-1 -> HUM-2 queues a delivery to `box-a`, with c-9 in the recv frame | one delivery, to HUM-2's box only |
| C4 | T002 | hub: c-9's reply in that topic is readable by both HUM-1 and HUM-2 | HUM-2 is not an end: unreadable |
| C5 | T002 | hub: after `DELETE`, the next DM queues nothing to `box-a` | route absent |
| C6 | T003 | wui unit: `addDmAgent`, `listDmAgents` and `removeDmAgent` exist, live and mock | absent |
| C7 | T004 | wui unit: `rowMenuItems(false, {person: true})` has an `add-agent` item; a channel row does not | no `add-agent` |
| C8 | T004 | wui e2e (mock): DM row menu -> Add an agent -> pick -> the agent is listed with a minus | no entry |
| C9 | T006 | hub: `POST /v1/channels/{c}/agents` by HUM-1 stores `invited_by = HUM-1`, and the members answer says `dedicated: true` | no column, no field |
| C10 | T006 | store: an operator INSERT (no `invited_by`) -> `dedicated: false` | no field |
| C11 | T007 | hub: the roster's `agent_dedicated` lists a bot added to a channel by hand and a bot added to a DM, but not a role seat | no field |
| C12 | T008 | wui unit: `dedicatedAvatarUri('c-9', 'box-a')` starts with `data:image/svg+xml,`, equals blobatar 2.7.0's `blobatarUri('c-9@box-a', {background: 'squircle'})`, and returns the same string when called twice | no function |
| C13 | T008 | wui unit: `csi-spl-wui/package.json` has `"blobatar": "2.7.0"` (exact) | absent |
| C14 | T008 | guard: a non-dedicated bot still gets `robotSvg`, a human still gets the identicon, and a member's stored picture still wins | green |
| C15 | T008 | guard: `perf-budget.py bundle` `ci_initial_gzip_kb` <= 155, and up by no more than 0.5 KB on the same box (A/B) | green |
| C16 | T008 | guard: `tests/unit/feed-avatar.test.mjs` (no `blob:`) and `csp-policy.test.mjs` | green |

## 6. Build order

Part 1 rows come before part 2, the API before the WUI, and the docs last.
The rows and their files are in [tasks.md](tasks.md). The build waits for
the owner's go.

## 7. Open owner questions

The code cannot settle these two; each is a product choice.

```poll
Q1. When you add an agent to a direct message, where does the conversation with it happen?
(A) In the same direct message: the agent joins it, and both people see its answers there (this spec)
(B) The direct message becomes a new private channel with the two of you and the agent
```

```poll
Q2. A bot added by hand to one channel or DM: where does it show the blobatar face?
(A) Everywhere in the workspace, so a bot always has one face (this spec)
(B) Only in the channels and DMs it was added to; everywhere else it stays a robot
```

<!-- version: 0.1.0 · updated: 2026-10-23 -->
