# 062: Flow per user: only what concerns me, with a count on top

Status: **decided** (section 8, owner 2026-10-02 ~17:05Z). The API and WS
contract is frozen in `contracts/flow-v1.md`.

## 0. The owner's ask

prd t1 #spool-hub-devel, topic `25826b7b-c1d2-486b-a12e-04c1b32f52dd`, HUM-10,
2026-10-02:

> 11:21:02Z: "we need the feature to implment the numbers of "tagging or
> poking" , the number of new messges send to a thread where sombody has
> participated etc. facebook like numbering on top of the flow pane , and that
> flow page to show ONLY the flow events relevant to that user ..."
>
> 11:21:22Z: "which seems to be a bit different compared to how the current
> way the flow works .."

The ask has two parts:

1. **A number on top of the Flow pane**, like Facebook's notification count:
   how many tags/pokes, new replies in my threads and DMs I have not seen.
2. **The Flow lists only events relevant to the viewer**, not every message
   they can read.

## 1. Today's Flow, measured

Tree: origin/master `4109abd4` (2026-10-02). Every claim cites the file and
line it was read from.

### 1.1 What Flow shows, and to whom

- Flow is a sidebar tab (`csi-spl-wui/src/components/ChannelSidebar.vue:437-447`,
  `<LazyFlowList>`). It is a list of short entries, newest first, at most
  `FLOW_CAP = 200` held (`csi-spl-wui/src/utils/flow-entries.mjs:12`) and
  `FLOW_PAGE = 30` shown per page (`flow-entries.mjs:17`).
- **It shows every message the reader is allowed to read.** No relevance
  filter exists. The first read is `GET /v1/view/topics?limit=12&per_topic=3`
  (`csi-spl-wui/src/stores/flow.ts:16-17,63`). That is the 12 newest topics of
  the tenant, from every channel the reader is in plus every DM they are an
  end of, with each topic's 3 newest lines inlined. The read door is the
  same as every topic list: `handleViewTopics` → `readerScope`
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/view.go:492-532,562-573`).
- A fill reads up to `FLOW_FILL_PAGES = 4` topic pages until 30 entries can
  be vouched for (`flow.ts:19,75-79`; the window rule is `flowWindow`,
  `flow-entries.mjs:139-145`).
- Live: the tab-wide `all` WS follow feeds every frame into the list
  (`flow.ts:124-132`). Server side, an `all` socket gets every channel line
  of a channel it is a member of, plus every DM it is a party to
  (`hub/wui.go:400-427` subscribe, `hub/wui.go:446-476` `wants`).
- So for a member of #lobby and #spool-hub-devel, every agent status line
  in those channels is a Flow entry. This is the "different from how the
  current way the flow works" the owner names.

### 1.2 How it is fed

| leg | route / code | per first paint |
|---|---|---|
| hub | `GET /v1/view/topics` (`hub/view.go:46`), `listTopics` + `inlineMessages` (`view.go:576-623,625`) | `limit=12&per_topic=3`: 4..5 DB round trips, 17.5 KB from the DB, 14.1 KB JSON / 3.1 KB gzip (`csi-spl-doc/doc/md/db-payload-audit-2026-10-02.md` section 3, n = 3 x 5) |
| WUI store | `stores/flow.ts` `readPage` / `fill` / `follow` (`flow.ts:62-132`) | 1..4 pages |
| WUI pane | `components/FlowList.vue` maps entries to `SideHitList` rows (`FlowList.vue:74-90`) | |

Each entry carries the whole message envelope. The pane uses only `from`,
`channel`/peer, 90 characters of text, the time and an unread dot
(`flow-entries.mjs:59-85`).

### 1.3 How the counts and "N new" work today

There are four different mechanisms, and Flow has none of its own:

| count | where it is computed | read state | file:line |
|---|---|---|---|
| channel unread (`#chan 3`) | **hub**: the channels stats batch counts lines after the later of the `read=` cursor and the stored `ch:` mark, skipping own lines and lines read inside their thread | `read_marks` `ch:` (rdb 0098) | `store/channels_postgres.go:303,397-404,418-427` |
| DM unread + total (`<new>/<total>`) | **hub** since cut 1 (`b90eae41`): `topics?dm=true&dm_counts=true` counts per peer from a thin read; the WUI reads the maps (`732307ba`) | the `dm_read=` cursors the browser sends | `hub/view_dm_counts.go:11-31,157`; `stores/channel.ts:177-185` |
| thread `<new>/<total>` on a card | WUI, from `t:` cursors, seeded when a channel opens (CLE-77930 `1ae6c82f`) | `read_marks` `t:` | `stores/notification.ts:300-311` |
| mention count (`@2` on a channel row) | **WUI only**: `bump(key,'mention')` when a live or loaded line names `@<me>` in its body, or has `to = me` | memory only. Cleared by `markRead` and lost on reload | `stores/notification.ts:81-82,374-379,384-415`; `utils/notify.mjs:51-66`; shown at `ChannelSidebar.vue:257` |

- Read marks follow the member across devices and tabs since CLE-77930. The
  table is `read_marks(tenant_id, member_id, mark_key, at, msg_id, seen)`,
  with keys `ch:` / `t:` / `dm:` and forward-only writes
  (`csi-spl-rdb/src/sql/postgres/spool-hub/0098_read_marks.sql:10-24`). The
  routes are `GET`/`PUT /v1/me/reads` (`hub/view.go:55-57`,
  `hub/read_marks.go:88`), and the WUI pushes moved marks every 5 s and when
  the tab hides (`utils/read-sync.mjs:19,154`).
- **The Flow tab's indicator is a pip, not a number.** It shows when any DM
  or channel is unread: `flowUnread = dmUnread || channelUnread`
  (`ChannelSidebar.vue:916-921`, the pip at `:45`).
- **The Flow entry dot** reads the browser-local cursors plus a per-tab
  `opened` set (`flow-entries.mjs:115-121`, `FlowList.vue:57-62,88`). It
  is not synced: an entry opened on the phone stays dotted on the desktop
  until its place's mark syncs.

### 1.4 How @-mentions and pokes are stored

- **A mention is not stored as data.** It is text in the body. The WUI finds
  it with `MENTION_RE` (`utils/notify.mjs:14,23-30`). The hub parses only a
  LEADING `@ID` for dispatch (`hub/dispatch.go:49-91`). No column, table or
  index records "message M mentions member X".
- **A poke is an ordinary DM.** After a text is stored, the AUTHOR'S browser
  sends one DM to each newly mentioned id (spec 042 K3; `pokeTargets`,
  `utils/mention-poke.mjs:19-28`). The body is
  `<author> needs you in <link>: "<excerpt>"` (`mention-poke.mjs:60-62`),
  and the link is `<origin>/t/<task_id>` (`mention-poke.mjs:65-67`). Since
  `6cf874d2` (CLE-77852), an agent seated in the workspace but outside the
  channel is DM-poked anyway, and the author sees a notice
  (`composables/useMentionPoke.ts:7-8`).
- **Consequence**: a member who is @-mentioned gets two things today, the
  channel line that names them and a poke DM. Nothing marks the DM as a
  poke, except its body shape.

## 2. "Relevant to the viewer"

### 2.1 Event kinds

Every entry in the new Flow is a **flow event**: one message, for one
member, with one reason. A message produces at most one event per member.
When several reasons match, the strongest wins (top of the table first):

| kind | the member X gets an event when | counts in the badge |
|---|---|---|
| `mention` | the body names `@X` or `@X@<box>` (the same grammar as `MENTION_RE`), in a channel X can read | yes |
| `poke` | a poke DM to X (section 2.3). It folds into the `mention` of the same task when there is one | yes, once per mention |
| `dm` | a DM whose `to` is X, or a DM in a topic X is an end of | yes |
| `reply` | a line lands in a thread (`task_id`) X **watches** (2.2) | yes |
| `channel` | any line in a channel X is a member of (today's Flow) | **no** by default (Q2) |

Never an event:

- X's own line, including a line X typed at an agent's terminal (`typed_by`,
  CLE-77889; the same rule as `isViewersOwn`).
- A line in a channel X cannot read. The read door applies to events too.
- A line in an archived topic (specs/041), or an expired line.

### 2.2 A watched thread

X watches a `task_id` once any of these happens, and from then on:

1. X posted in it (the root or a reply).
2. X was `@`-mentioned in it.
3. X is the `to` of a line in it.

Watching is stored as a row (section 4.2), so it costs no scan at read time.
**Unwatching** (a "mute this thread" item) is out of scope for 062. The
existing channel mute keeps working for alerts.

### 2.3 Pokes

A poke DM is recognised by the hub when it is stored. Its body matches
`^<ID> needs you in <url>/t/<task_id>: "` (the `pokeBody` shape), and it was
sent by the author of a line in `<task_id>` that mentions the poke's `to`.
Such a DM becomes a `poke` event linked to that mention. The Flow shows ONE
entry ("FirstName LastName tagged you in #chan") and counts it once. For
an AGENT, the poke DM is still delivered exactly as today: its desk and pane
read DMs (spec 028).

### 2.4 Read and seen state

There are two states, as on Facebook:

| state | meaning | clears when | stored as |
|---|---|---|---|
| **unseen** | newer than the last time X opened the Flow pane | X opens the Flow pane (or the phone's Flow level) | one `read_marks` row, key `f:seen` |
| **unread** | X has not looked at it | X opens the entry from the Flow, OR X reads its place: the `ch:` / `t:` / `dm:` mark covers it | the existing `ch:` / `t:` / `dm:` marks, plus `f:<msg_id>` for an entry opened from the Flow |

- **The badge number is unseen and unread.** Opening the pane resets the
  number to 0. The entries stay highlighted as unread until each one is
  opened or its place is read.
- **Sync across tabs and devices.** Both states live in `read_marks`, so the
  existing `GET`/`PUT /v1/me/reads` carries them. Because a badge that lags 5 s
  looks broken, a mark write ALSO makes the hub push a `flow` frame
  (section 3.2) to every socket of that member. The other tab and the phone
  drop the number at once, not at the next 5 s sync.
- Marks are forward-only, as today. `f:<msg_id>` rows are swept with their
  message (expiry), so the table does not grow without bound.

## 3. The badge

### 3.1 What it shows

- **One number** on the Flow tab icon. It replaces the pip
  (`ChannelSidebar.vue:45`) for the Flow tab only. It is the sum of the
  unseen + unread `mention`, `poke`, `dm` and `reply` events. It shows `99+`
  above 99, and it is hidden at 0 (Q3).
- Inside the pane, a header row shows the split as three chips:
  `@ 2 · ↳ 5 · ✉ 1` (mentions incl. pokes, replies, DMs). A click on a chip
  filters the list to that kind. A chip with 0 is shown dimmed and does not
  filter.
- The channel and DM rows keep their own badges (`#chan 3`, `<new>/<total>`)
  unchanged. 062 adds a count; it moves none.

### 3.2 Live updates over WS

- New server frame on the WUI socket (`wui-live-ws` contract, next minor):
  `{"type":"flow","counts":{"mention":2,"reply":5,"dm":1,"total":8},"event":{...}|null}`.
  It goes ONLY to the sockets of the member the event is for. It is sent
  when an event row is written, and when that member's `f:` mark moves.
  `event` is the thin entry from 4.2, or null for a counts-only frame.
- The WUI does not count Flow events itself. It shows the hub's `counts`,
  so two tabs can never disagree. On a reconnect it re-reads
  `GET /v1/view/flow?counts_only=true` (one statement).
- The existing `message` frame is unchanged. The Flow stops reading it.

### 3.3 Phone and PWA

- On a phone (<= 820 px), the level-1 strip already shows the Flow tab with
  its label (`ChannelSidebar.vue:43`). The same number sits on it.
- An installed PWA (`public/manifest.webmanifest:8`, `display: standalone`)
  sets the app-icon badge with `navigator.setAppBadge(total)` where the
  browser has it, and calls `clearAppBadge()` at 0. Nothing in the WUI calls
  it today (`grep -rn setAppBadge csi-spl-wui/src` → 0). Where the API is
  missing, nothing happens.
- The tab title gets the number as a prefix, `(8) Spool`, on every platform.
- **Out of scope**: Web Push to a CLOSED app. The badge updates only while a
  tab or the PWA is running (Q4).

## 4. Data and performance

### 4.1 Where the counts are computed

**In the hub, at write time, into one table.** Read time costs one indexed
statement.

The alternative is to compute relevance at read time ("lines in threads I
ever posted in, newer than my mark"). That walks every topic the member
ever posted in. Under FORCE RLS, it is the planner shape that already
failed for search (non-leakproof filters, no index use). It grows with
history, not with what is new. Rejected.

### 4.2 Tables (one new migration, next free number at landing)

```sql
-- what a member watches: one row per (member, thread)
CREATE TABLE flow_watches (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id    uuid        NOT NULL,
    member_id  text        NOT NULL,
    since      timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, task_id, member_id)
);

-- one row per (member, message): the Flow, already filtered
CREATE TABLE flow_events (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id   text        NOT NULL,
    msg_id      uuid        NOT NULL,
    task_id     uuid        NOT NULL,
    kind        text        NOT NULL CHECK (kind IN ('mention','poke','dm','reply')),
    at          timestamptz NOT NULL,   -- the message's received_at
    expires_at  timestamptz NOT NULL,   -- copied from the message: swept with it
    PRIMARY KEY (tenant_id, member_id, msg_id)
);
CREATE INDEX flow_events_member_at ON flow_events (tenant_id, member_id, at DESC);
```

- Both tables get RLS in the 0098 shape: tenant and operator policies, with
  the NULLIF guard. Each gets a cross-tenant seed in the store's
  `crosstenant_test`.
- `read_marks.mark_key` CHECK widens from `^(ch|t|dm):` to
  `^(ch|t|dm|f):`, for `f:seen` and `f:<msg_id>`.
- **Write**: on store, in the SAME pgx batch as `INSERT messages`, so it adds
  0 round trips:
  1. Upsert `flow_watches` for the author, for each mentioned id and for `to`.
  2. Insert `flow_events` for each watcher of the task (except the author),
     each mentioned member and the DM `to`, with the kind picked by the 2.1
     precedence. The mention parse is a Go port of `MENTION_RE`, pinned to
     the WUI copy by a parity test (the emoji-list pattern, SPL-1002).
- **Read the counts** (badge, reconnect): one statement, index-only on
  `flow_events_member_at`, anti-joined against the member's marks:

  ```sql
  SELECT kind, count(*) FROM flow_events e
  WHERE e.tenant_id=$1 AND e.member_id=$2 AND e.at > $seen AND e.expires_at > now()
    AND NOT EXISTS (<the place mark or f:<msg_id> covers e>) GROUP BY kind
  ```

- **Read the list** (`GET /v1/view/flow?limit=30&before=<cursor>&kind=`): the
  page of `flow_events`, joined to `messages` for THOSE 30 rows only. It
  returns the thin projection of audit cut 1b (msg_id, received_at, from,
  from_box, to, to_box, typed_by, channel, task_id, parent_task_id, 90-char
  text, file count), and never `env`, `sig`, deliveries or reactions.

### 4.3 Budget, against the payload audit

The DB payload audit (`csi-spl-doc/doc/md/db-payload-audit-2026-10-02.md`)
sets the direction: count in the hub, send thin rows, add no round trips.

| read | today (audit §3, n = 3 x 5) | 062 target (to be measured by lane L5, same harness) |
|---|---|---|
| Flow first paint | `topics?limit=12&per_topic=3`, 1..4 pages: 4..5 round trips EACH, 17.5 KB DB down, 14.1 KB JSON each | `GET /v1/view/flow?limit=30`: door + 1 batch = **<= 2 round trips**, one page, no `env` |
| badge on load | none (a pip, from channels + DM reads already made) | `counts_only`: rides the same batch as the page, **0 extra round trips** |
| send | 5 round trips (audit §4) | **+0 round trips** (the flow writes ride the INSERT batch), + 1 row per watcher |

- Write amplification: one row per watcher per line. A thread with 40
  watchers writes 40 rows. Measure on prd, read-only, before L2 lands:
  watchers per task (p50/p95) and lines per day. The query goes in L5 as a
  named action, not ad hoc.
- `TestRoundTripsPerRequest` gets a budget for `GET /v1/view/flow` (2) and
  keeps the send budget unchanged.

## 5. Migration and back-compat

### 5.1 The old Flow

- The Flow pane gets a two-way switch, **Mine / All**. Mine is the default
  (Q1). All is today's stream (`stores/flow.ts`, unchanged), kept for
  operators who watch everything. The choice is a view pref: its rdb column
  is applied on dev+prd BEFORE the hub key ships, or `GET /session` nulls
  every setting.
- The badge always counts Mine, whichever switch is on.

### 5.2 Backfill

The migration (or a named action `do_spl_flow_backfill`, `DRY_RUN=1` by
default) fills `flow_watches` from the messages still within retention:
author, `to`, and mentioned ids per task. It fills `flow_events` only for
the last 7 days, and `f:seen` = deploy time for every member. The first
badge is therefore 0, not a flood.

### 5.3 Agents as viewers

- Agents do not use the WUI Flow. Their inbox is their flow (the desk, the
  pane, `spool recv`, the MCP tools). 062 writes events only for members
  with a human seat (`HUM-`/`GST-`) (Q5).
- Delivery to agents is unchanged: what reaches an agent stays the spool's
  routing (spec 028). 062 adds no delivery.
- Later, outside 062: an MCP `spool_flow` tool over the same table.

## 6. Functional requirements

| FR | requirement |
|---|---|
| FR-001 | The Flow pane's default list shows only the viewer's flow events (2.1), newest first, 30 per page, with Load more. |
| FR-002 | A message produces at most one event per member, with the kind chosen by the 2.1 precedence. The member's own lines (including `typed_by`) never produce one. |
| FR-003 | Watching (2.2) starts on the member's first post, mention or `to` in a task, and is stored as a `flow_watches` row. |
| FR-004 | A poke DM that matches 2.3 folds into its mention: one entry, one count. A poke with no matching mention is a `poke` event of its own. Agents still receive the poke DM unchanged. |
| FR-005 | The badge shows the unseen + unread total from the hub. It is hidden at 0, shows `99+` above 99, and clears to 0 when the Flow pane opens (`f:seen`). |
| FR-006 | An entry is unread until it is opened from the Flow (`f:<msg_id>`) or its place's `ch:`/`t:`/`dm:` mark covers it. |
| FR-007 | A mark that moves on one tab or device updates the badge on every socket of that member within 1 s (the `flow` frame), not on the 5 s sync. |
| FR-008 | Every count comes from the hub. The WUI never counts Flow events from `message` frames. |
| FR-009 | The read door applies: no event for a line in a channel the member cannot read. A removed member's events in that channel stop counting at the next read (the door), and their rows are deleted by the membership writer. |
| FR-010 | `GET /v1/view/flow` costs <= 2 DB round trips and returns no `env`. The send path gains 0 round trips. Both are pinned in `TestRoundTripsPerRequest`. |
| FR-011 | The new tables have RLS (tenant + operator), cross-tenant seeds, and are swept with their message's `expires_at`. |
| FR-012 | Mine / All switch. Mine is the default; All is today's Flow. The choice persists as a view pref. |
| FR-013 | Installed PWA: `setAppBadge(total)` where the browser supports it. Tab title `(N) …`. Both clear at 0. |
| FR-014 | The Go mention parser and the WUI `MENTION_RE` are pinned equal by a parity test. |
| FR-015 | i18n: every new string is in all locales (`csi-spl-wui/i18n/locales/*.json`). |
| FR-016 | No literal host or domain anywhere (distribution-hygiene gate). |

## 7. Code lanes

The lanes run in order L1 → L2 → L3. L4 can start against the mock once the
section 3.2 / 4.2 contract is frozen in L3's first commit. L5 goes last.

| lane | scope | files (new unless marked) | must NOT touch |
|---|---|---|---|
| **L1 rdb** | migration: `flow_watches`, `flow_events`, the index, RLS, the `read_marks` CHECK widened to `f:`. Apply on dev+prd with the owner's go | `csi-spl-rdb/src/sql/postgres/spool-hub/01NN_flow_events.sql` | any other migration |
| **L2 store** | `FlowEvents` interface (memory + Postgres): write in the send batch, the counts read, the page read, sweep on expiry, cross-tenant seed | `internal/store/flow.go`, `flow_postgres.go`, `flow_test.go`; the send batch hook in `store/postgres.go` (**coordinate with CLE-100002, DB cut 7, which owns the send path**) | `store/view_*.go` (c-010), the door memo (c-008) |
| **L3 hub** | Go mention parser + parity fixture; `GET /v1/view/flow` (+`counts_only`, `kind`, `before`); the `flow` WS frame; `f:` marks in `PUT /v1/me/reads`; the round-trip budgets | `internal/hub/flow.go`, `flow_test.go`, `flow_mentions.go`; one route line in `hub/view.go` (**after c-010 has landed**); a call in `hub/wui.go` fan-out; `hub/read_marks.go` | the view message encoder (c-010) |
| **L4 WUI** | `stores/flow.ts` reads `/v1/view/flow`; the Mine/All switch; the chips; the number on the Flow tab; the `flow` frame in `live-ws.mjs`; `setAppBadge` + title; i18n all locales; stay within the 160 KB initial budget (all of it lazy) | `stores/flow.ts`, `components/FlowList.vue`, `utils/flow-entries.mjs`, `utils/flow-badge.mjs` (new), `components/ChannelSidebar.vue` (Flow tab only), `utils/live-ws.mjs`, `i18n/locales/*.json` | `utils/view-api.mjs` (c-010), `stores/notification.ts` channel/DM counts |
| **L5 tests + proof** | mock e2e (`tests/e2e/flow-mine.test.mjs`); live proof with two members on dev t1 and prd e2e (`tests/e2e/flow-counts-live.proof.mjs`): A mentions B, B's desktop badge goes 0 → 1, B opens the Flow on the phone, the desktop badge goes back to 0 within 1 s; payload harness numbers for 4.3; the read-only prd watcher-count query as a named action `do_spl_flow_watch_stats` | listed | everything else |

## 8. Owner decisions

The owner accepted all five recommended answers, prd t1 #spool-hub-devel,
topic `25826b7b-c1d2-486b-a12e-04c1b32f52dd`, 2026-10-02 ~17:05Z: "Okay let's
accept your suggestions for all of those five decisions." / "And start the
implementation."

| Q | question | decided |
|---|---|---|
| **Q1** | Should the old all-events Flow stay? | **Yes, as a Mine / All switch. Mine is the default.** |
| **Q2** | Do plain lines in my channels count, or list in Mine? | **No.** Only mentions, pokes, DMs and replies in threads I am part of. Channel lines keep their `#chan N` badge |
| **Q3** | One number, or one per kind on the icon? | **One total on the icon**, `99+` above 99. The per-kind split shows as `@` / reply / DM chips inside the pane |
| **Q4** | Should opening the pane clear the number? | **Yes, Facebook style** (`f:seen`). Entries stay highlighted until opened or read in place. Web Push to a closed app is a later spec |
| **Q5** | Should a poke and its mention count once, and are agents outside the Flow? | **Yes to both.** The poke folds into its mention; agents get no Flow events |
