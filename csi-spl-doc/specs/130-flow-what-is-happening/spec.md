# 130: Flow: what is happening

Status: **v1.0** (panel merge by s130-c1; seat signatures in section 11).
Q1 and Q2 decided by the owner (section 10).

Amends and supersedes parts of 062.

## 0. The owner's ask

prd t1 #spool-hub-devel, topic da98036e-f62b-4482-a354-c71585be933d, HUM-10:
> "We should reconsider the flow view or the flow functionality... what it should be presenting is the things which are happening in the system, both from the point of view of persons and also from the agent's point of view. That is, what actually is happening? What is important is that a person should not receive anything in the flow from messages in which he is not involved... I would like to be able to quickly jump from the flow to the actual discussion or issue which triggered that flow. All of the releases, all of the 'something is ready', and all of the 'something is blocked' should go to the flow."

> "Kind of a place where there is a condensed answer to the question 'What is happening?' and then you are able to actually jump from there to the actual topics or channel discussions"

Same topic, msg a34aa111:
> "And show summary in one line. Means on desktop, of course. On mobile, it cannot fit, so it might need three lines on the vertically oriented smartphone."

Same topic, msg e1e37246 (Q1):
> "Everyone should be able to see releases."

Same topic, msg 8efbb023, 17:44Z (Q2):
> "No, no, only mine are needed, so it should be basically a customized view of the flow of the events for each user. Then the user will get more info the more he's engaged with the system. This is the way it should work."

## 1. Today's Flow, measured

Tree: origin/master 965fb39e7 (2026-10-11). prd numbers are
`cd csi-spl-orc && ENV=prd SQL="<query>" ./run -a do_spl_db_query`
(read-only transaction, operator RLS scope), run 2026-10-11 16:57..17:24Z by
the seats named. The reviews in `reviews/` carry each query in full.

- **Kinds.** `flow_events.kind` is CHECKed to `mention, poke, dm, reply`
  (`grep -n "kind IN" csi-spl-rdb/src/sql/postgres/spool-hub/0104_flow_events.sql`
  -> line 36).
- **Who gets an event.** Only human seats: the insert keeps
  `member_id ~ '^(HUM|GST)-[0-9]+$'`
  (`csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go:39`),
  the memory twin uses `IsFlowMember` (`internal/store/flow_mentions.go:117-120`),
  and the live push skips non-human sockets (`internal/hub/flow.go:186`).
- **Where it is written.** `flowInsertCTE` (`flow_postgres.go:29-54`) is CTEs
  of the statement that stores the message: 0 extra round trips, 0 extra
  connections. Candidates: mentions and `to` (rank 1), poke (2), DM `to` (3),
  `flow_watches` of the task (4), behind the channel door (`channel_humans`,
  lines 40-42).
- **Watching exists.** `flow_watches (tenant_id, task_id, member_id)`
  (`0104_flow_events.sql:23-29`), written for the author and every rank < 4
  candidate (`flow_postgres.go:44-47`).
- **Mine / All.** `FLOW_SCOPES = ['mine', 'all']`
  (`csi-spl-wui/src/utils/flow-badge.mjs:20`), store default Mine
  (`csi-spl-wui/src/stores/flow.ts:55-56`), radio group
  `csi-spl-wui/src/components/FlowList.vue:9-19`.
- **Agents are refused the read.** `GET /v1/view/flow` answers 403 "the flow
  needs a signed-in member session" without a human seat
  (`internal/hub/flow.go:109-115`). No MCP `spool_flow` exists: the tools are
  `spool_put_file, spool_send, spool_recv, spool_get_file, spool_tail,
  spool_issue` (`grep -n '"spool_' internal/mcp/mcp.go` -> lines 109-129).
- **Releases** enter the hub already: wf 20 and wf 30 run
  `do_release_note_ingest` (`.github/workflows/20_hub-build-deploy.yml:697-700`,
  `.github/workflows/30_wui-build-deploy.yml:557-562`), which POSTs
  `/v1/operator/release-notes` (`internal/hub/release_notes.go:59`) into
  `release_notes` (rdb 0108, no `tenant_id`). The ingest re-sends a 500-commit
  window (`RELEASE_NOTE_DEPTH`, `release-note-ingest.func.sh`) and the upsert
  restamps `ingested_at` on every re-sent row
  (`internal/store/release_note_postgres.go:115`) while keeping the first
  `version` (line 110). The step is `continue-on-error: true` (wf 20 line 699).
  `do_release_note_link` only prints a line.
- **Acceptance** ("ACCEPTED") is a body convention read by bash
  (`csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh:139`),
  in no non-test Go file (`grep -rn ACCEPTED csi-spl-api/src/go/spool-hub-api --include=*.go | grep -v _test` -> 0).
  A same-box `spool-send.sh` never reaches the hub (`spool-send.sh:21-29`).

prd volume:

| measure | value | query / seat |
|---|---|---|
| flow events, all time | 8456 rows / 8207 lines, fan-out **1.0303** | `count(*)::float / count(distinct msg_id) FROM flow_events` (c1; a1 1.0306, g1 8457/8208, c2 8464/8215: same ratio) |
| flow events, 7 d | 5108 rows / 4886 lines | same, `at > now()-interval '7 days'` (c1) |
| busiest member (the owner seat), 7 d | **4665** events (666 a day) over 428 topics | `member_id, count(*), count(distinct task_id) ... GROUP BY 1` (c2; g1 4677) |
| the same folded per (topic, kind, hour) | 1610 (230 a day) | `count(distinct (task_id, kind, date_trunc('hour', at)))` (c2; g1 1612) |
| the same folded per (topic, UTC day) | 524 (~75 a day) | distinct `(task_id, day)` (g1) |
| messages, 7 d | 13466; 829 `blocker`, 2722 `result` | `kind=` (c1) |
| blocker lines to a human, 7 d | 566, of them 550 to the owner seat over 313 (topic, hour) pairs | (c2) |
| blocker lines that already have a flow row | 593 of 819 | `exists (... flow_events f WHERE f.msg_id = m.msg_id)` (c2) |
| lines starting `ACCEPTED`, 7 d | **0** (873 contain it, after a relayed `from_agent:` header) | `body like 'ACCEPTED%'` (c1, g1, c2) |
| events for non-human ids | 0 | `member_id !~ '^(HUM|GST)-'` (c1, g1) |
| tenants / memberships | 15 / 48; t1 **14** | `count(*) FROM tenant_memberships WHERE tenant_id='t1'` (a1, re-run by c-002 -> 14; c2) |
| distinct agent ids posting in t1, 7 d | 651, from 805 (id, box) pairs; 154 ids on 2+ boxes | (c1, c2) |
| versions, last 24 h | 83, over 25 clock hours | `count(distinct version) ... committed_at > now()-'24 hours'` (c2) |
| `release_notes` rows re-stamped by one deploy | 500 at 17:12 | `date_trunc('minute', ingested_at), count(*)` (c2) |

## 2. The condensed "what is happening" view

1. **One line per topic per UTC day.** A member's events in one `task_id` on
   one UTC calendar day fold into ONE line, whatever their kind. The line
   shows the strongest kind of the day (`blocked`, `ready`, `mention`,
   `poke`, `dm`, `reply`), the count when > 1, the topic title, up to two
   ids then `+N`, and the newest time:
   `@ 4 in "Flow v2" · c-002 +2 · 16:40Z`. Why the day and not the hour: the
   owner seat's 4665 events in 7 d fold to 1610 lines per (topic, kind,
   hour), still ~230 a day, and to 524 per (topic, day), ~75 a day
   (section 1).
2. **Release is one line per UTC day**: the version span and the count,
   `v1.3.400 .. v1.3.420 (21 versions) · 2026-10-11`. Each environment's hub
   holds its own `release_notes`, so a prd Flow lists prd releases only and
   the line carries no environment name.
3. **One line on desktop, at most three on a portrait phone** (owner, msg
   a34aa111). The summary is clamped to 1 line on desktop and to at most 3
   lines on a portrait phone, with an ellipsis beyond; the whole line stays
   one link. Acceptance: at 1440x900 every Flow summary box is 1 line high;
   at 390x844 at most 3 (the e2e reads the box height against the line
   height, and `scrollHeight > clientHeight` shows the clamp is live).
4. **Direct links.** A topic-day line links to its newest message
   (`/t/<task_id>#<msg_id>`); when its strongest kind is `blocked`, to the
   issue of that `task_id` when one exists (`issues` is
   `UNIQUE (tenant_id, task_id)`, `0047_issues.sql:72`), else to the
   message. A release line links to `/releases/<sha>` of the day's newest
   version.
5. **Opening a folded line marks all of it read.** It writes the topic mark
   `t:<task_id>` at the newest event, which `flowCoveredSQL` already honours
   (`flow_postgres.go:82-89`). A release line writes `f:rel:<version>`
   (the 0104 `mark_key` CHECK, line 69, admits it).
6. **The fold is in the hub read, over a bounded window.** The hub folds the
   member's newest 200 raw events (`FLOW_CAP`,
   `csi-spl-wui/src/utils/flow-entries.mjs:15`) and returns the first 30
   lines. The cursor stays the raw `(at, msg_id)` of the oldest event read,
   so "Load more" folds the next 200; a group cut by the window edge shows as
   two lines. The WUI and `spool flow` (section 5) show the same lines.

## 3. Relevance and "All"

A person or agent sees only events from discussions they are **part of**.

- **Part of** = a `flow_watches` row for (tenant, task, member). The insert
  already writes one for the author, every mentioned seat and the `to`
  (`flow_postgres.go:44-47`). Setting an issue assignee writes a row for the
  assignee on the issue's `task_id` (new; prd t1: 333 of 1454 issues have an
  assignee, s130-g1). "Explicitly watching" is a new write to the same table.
  No new table.
- **Never** from a channel the member merely belongs to: the door
  (`flow_postgres.go:40-42`) only filters candidates, it adds none.
- **"All" switch**: removed (Q2, owner msg 8efbb023). The Flow is one
  per-user view of the events the user is involved in. Removing All stops
  the not-involved stream; it does not condense Mine. Section 2 does that.

## 4. New kinds: release, ready, blocked

| kind | when it is emitted | emitted by | link goes to |
|---|---|---|---|
| `release` | A commit first gets a `version` in this hub's `release_notes`: new column `released_at`, set by the ingest upsert only when the stored `version` was NULL and the new one is not, never restamped. | Hub, at **read time** from `release_notes`; no `flow_events` rows. The writer stays `do_release_note_ingest` (wf 20 / 30); no new API, no new emitter. | `/releases/<sha>` |
| `ready` | A `result` is accepted. The acceptance is a structured key `accepts: <msg_id>` on the v:1 message, set by `spool-send.sh --kind result --accept <msg_id>` and the WUI accept action, mirrored to the hub also for a same-box send. Until `accepts` exists, `ready` is not emitted. No body parsing. | Hub, inside `flowInsertCTE`, when the stored line carries `accepts` | the accepted result's topic |
| `blocked` | A stored `blocker` line. The strongest rank in `flowInsertCTE` (ahead of `mention`), for the same candidates as today's ranks: mostly a relabel (593 of 819 blocker lines in 7 d already have a row). | Hub, `flowInsertCTE` | the issue of the topic when one exists, else the message |

`ready` without `accepts` never fires: 0 hub lines in 7 d start with
`ACCEPTED`, and same-box acceptances never reach the hub (section 1).
`ingested_at` cannot say "went live": one deploy re-stamps 500 rows.

## 5. Agents: they get the Flow, without duplicating their inbox

Reverses 062 Q5.

- **What an agent gets**: `mention`, `blocked`, `ready`, `release`, by the
  same rules as a human. **Not** `dm` and **not** `reply`: its spool inbox
  already delivers both, and reply-watches for agents would have written
  ~40 907 rows in 7 d against 5108 human rows (8x; agent watchers per line
  p50 1, p95 12, max 45; query in `reviews/s130-c1.md` section 5, g1
  measured 38 655 / 7.6x with a first-post variant).
- **The key is `<id>@<box>`**: 154 of 651 agent ids posted from 2+ boxes in
  7 d, so a bare id would mix two agents' flows. `IsFlowMember`
  (`flow_mentions.go:119-120`) and the insert filter (`flow_postgres.go:39`)
  admit it for the agent kinds only.
- **The door**: agents are not in `channel_humans`; the door gains the
  agent's channel membership as a second branch; a public channel needs
  nothing.
- **How they read it**: `spool flow [--kind] [--limit] [--before]` sends a
  `flow_read` frame on the CLI WebSocket session, answered by the same
  `FlowRead` the WUI route calls, keyed by the session's agent. This is the
  `spool issue` path: `hubclient.Issue` dials `wire.RoleCLI`
  (`internal/hubclient/issue.go:24`) and sends `wire.TIssue` (line 35),
  answered by `onIssue` (`internal/hub/issues_agent.go:29`). No hub HTTP
  route takes a box signature today. The MCP tool `spool_flow` wraps the
  CLI. The frame is not named `flow`: that is the WUI's live push.
- **No agent backfill**: an agent's past is its inbox; its Flow starts at
  deploy.

## 6. Data and performance

Under FORCE RLS on `db-f1-micro` (`max_connections` 25, hub pool 8):

- **The write is one statement.** Per-member rows (`mention`, `poke`, `dm`,
  `reply`, `blocked`, `ready`) stay CTEs of the message INSERT: 0 extra round
  trips, 0 extra connections. An async batch would ADD a writer and a
  connection; it is not done. Bench (postgres:16-alpine, 0104 table and
  indexes, prd's 8456 background rows, n = 200 lines each, s130-c1):

  | watchers per line | mean ms per line |
  |---|---|
  | 1 (agent p50) | 0.189 |
  | 12 (agent p95) | 0.250 |
  | 45 (agent max) | 0.504 |
  | 665 (t1 + every 7 d agent id: a release fanned out to all) | 8.985 |

  g1 re-ran it as a non-superuser under FORCE RLS: 0.097 / 0.233 / 0.481 /
  14.732 ms at 1 / 12 / 32 / 666.
- **Release has no rows.** Everyone sees the same lines, so it is one read:
  the page merges `release_notes` by `released_at DESC` (new index; 0108 /
  0114 index only the version key), folded per UTC day. Written as rows it
  would be 83 versions a day x 14 t1 members, or x 665 with agents, each
  fan-out ~9..15 ms in the deploy's write.
- **The folded page read is bounded.** Bench at the owner seat's volume
  (4665 events / 428 topics), `EXPLAIN (ANALYZE)`, n = 50 (s130-c2):

  | read | p50 ms | p95 ms | plan |
  |---|---|---|---|
  | today's page, 30 rows | 0.281 | 0.357 | index scan `flow_events_member_at` |
  | fold over the whole history | 7.937 | 11.231 | seq scan + HashAggregate |
  | fold over the newest 200 | 1.006 | 1.323 | index scan + HashAggregate |

- **Badge**: unchanged for humans (`flowCountsSQL`, `flow_postgres.go:112`),
  plus the release lines newer than `f:seen`. Agents read the counts with
  the page.

## 7. Migration and back-compat

- `flow_events.kind` CHECK adds `blocked`, `ready` (not `release`: no rows).
- `release_notes.released_at timestamptz NULL`, set once in the ingest
  upsert; index `(released_at DESC) WHERE released_at IS NOT NULL`. Backfill
  `released_at = committed_at` for rows that have a version: the history
  reads as past days, all older than `f:seen`, so the badge does not flood.
- Agent `member_id` = `<id>@<box>`; filter and `IsFlowMember` widen for the
  agent kinds only; the door gains agent channel membership.
- `accepts` added to the v:1 message schema
  (`csi-spl-doc/specs/002-box-agent-messaging/contracts/message-schema.md`);
  an old box that drops unknown keys emits no `ready`.
- Issue assignee -> `flow_watches` row.
- The Mine / All switch goes (Q2) (`flow-badge.mjs:20`,
  `flow.ts:55-56`, `FlowList.vue:9-19`) and a stored scope of `all` reads as
  Mine.
- No agent backfill.

## 8. Functional requirements

| FR | requirement |
|---|---|
| FR-001 | The Flow pane shows one line per topic per UTC day and one release line per UTC day, each one link, folded in the hub over the newest 200 events; the summary is 1 line at 1440x900 and at most 3 at 390x844, ellipsis beyond. |
| FR-002 | Relevance: a `flow_watches` row (posted, mentioned, `to`, issue assignee, explicit watch). Channel membership alone is never a reason. |
| FR-003 | The WUI All switch is removed (Q2, owner); a stored `all` reads as Mine. |
| FR-004 | `release` is read from `release_notes.released_at` (set once), folded per UTC day, no `flow_events` rows; `do_release_note_ingest` stays the writer. Every member of every tenant on that hub sees its releases (Q1). |
| FR-005 | `ready` is emitted only when the stored line carries `accepts`. No body parsing. |
| FR-006 | `blocked` is the strongest rank for a stored `blocker`, linking to the topic's issue when one exists. |
| FR-007 | Agents (`<id>@<box>`) receive `mention`, `blocked`, `ready`, `release`, never `dm` / `reply`, read by the `flow_read` CLI-session frame, `spool flow` and `spool_flow`. |
| FR-008 | The send path gains 0 round trips, pinned in `TestRoundTripsPerRequest` (062 FR-010). No async fan-out. |
| FR-009 | Opening a folded line writes `t:<task_id>` (a release line `f:rel:<version>`), clearing every event it folds. |
| FR-010 | The folded page read stays an index scan, pinned by a store test of the 200-event window. |
| FR-011 | i18n: every new string in all locales; no literal host or domain. |

## 9. Code lanes

| lane | scope | waits on |
|---|---|---|
| **L1 hub/store** | kind CHECK; `blocked` / `ready` ranks in `flowInsertCTE`; agent key, kinds and door; `accepts` in the v:1 schema and hub mirror; `released_at` (upsert, backfill, index) and the release merge; the day fold over the 200 window; assignee -> `flow_watches`; the `flow_read` frame, `spool flow`, `spool_flow` | no |
| **L2a WUI** | render the folded lines; the 1-line / 3-line clamp; `t:` / `f:rel:` marks on open | no |
| **L2b WUI** | remove the Mine / All switch | no (Q2 decided: remove) |
| **L3 emitters** | `spool-send.sh --accept`; the WUI accept action. No release emitter: wf 20 / 30 already ingest | no |
| **L4 tests+proof** | e2e at 1440x900 and 390x844; one deploy -> one new release line, not 500; an agent reads a blocker via `spool flow`; round-trip budget unchanged; L2b's test only with L2b | no |

No lane waits on an owner question: L1, L2a, L2b, L3 and L4 can start at once.

## 10. Owner questions

| Q | question | panel vote | decided |
|---|---|---|---|
| **Q1** | A release nobody involved you in: does everyone get the event? | Everyone (a1, c1, c2, g1, m1) | **Everyone.** Owner, t1 da98036e, msg e1e37246: "Everyone should be able to see releases." `release_notes` has no `tenant_id`, so this means every member of every tenant on that hub (prd: 15 tenants). |
| **Q2** | The "All" switch: A remove it, B keep it behind the switch? | A remove (a1, c1, c2, g1, m1) | **A, remove.** Owner, t1 da98036e, msg 8efbb023, 17:44Z: "No, no, only mine are needed, so it should be basically a customized view of the flow of the events for each user." The owner's decision, not the panel's vote. |

## 11. Panel record

Reviews: `reviews/s130-a1.md` (agy, 374ec1b11), `reviews/s130-c1.md`
(claude, dc5fc8a92), `reviews/s130-c2.md` (claude, b4aa48b4c),
`reviews/s130-g1.md` (grok, 769c3c196), `reviews/s130-m1.md` (mistral, f8bbd7d4f).

| decision | a1 | c1 | c2 | g1 | m1 | in v1.0 |
|---|---|---|---|---|---|---|
| 1: measured state, file:line + prd counts | CHANGE (file refs) | CHANGE | AGREE + rows | CHANGE | CHANGE (no file:line) | merged, all seats' numbers |
| 2: fold grain | task + member + hour | topic + kind + hour | topic + kind + hour, 200 window | topic + UTC day | task + kind + hour | **topic + UTC day** (g1), 200 window (c2): the hour fold leaves ~230 lines a day for the owner seat (c2's and g1's own count) |
| 2: release fold | n/a | env + hour | hour | UTC day | n/a | **UTC day**, same grain as the topics |
| 2: 1 line desktop / 3 phone | n/a | yes | n/a | yes | n/a | owner requirement, test at 1440 / 390 |
| 2: open writes `t:` | n/a | n/a | yes | n/a | n/a | adopted |
| 4: `ready` source | body `ACCEPTED` at insert | `accepts` key | `accepts` key | `accepts` key | `ACCEPTED` status -> `POST /v1/flow/ready` | `accepts`; body parsing matches 0 lines |
| 4: `release` clock | new call in `do_release_note_link` | `ingested_at` (withdrawn) | `released_at`, backfill | `versioned_at`, no backfill | `POST /v1/flow/release` from CI | `released_at` set once, backfilled from `committed_at` |
| 4: `blocked` | issue or topic | strongest rank | strongest rank, relabel | strongest rank | `POST /v1/flow/blocked` on insert | strongest rank |
| 5: agent kinds | the same Flow | no `dm` / `reply` | no `dm` / `reply` | no `dm` / `reply` | the same Flow | no `dm` / `reply` |
| 5: agent read path | MCP `spool_flow` | box-signed HTTP (withdrawn) | `flow_read` CLI frame | box-signed HTTP | `GET /v1/view/flow?member_id=` | `flow_read` CLI frame: no HTTP route takes a box signature |
| 5: agent key | n/a | n/a | `<id>@<box>` | n/a | n/a | `<id>@<box>` |
| 6: async batch (old FR-008) | keep | delete | delete | delete | keep | deleted |
| 6: release rows | 14 per release | none | none | none | one per member | none |
| Q1 / Q2 votes | Everyone / Remove | Everyone / Remove | Everyone / Remove | Everyone / Remove | Everyone / Remove | both decided by the owner |

Not folded from s130-m1, with the reason:

- Its section 6 table "measured on prd (n=10 tenants)": avg 42, p50 38,
  p95 89 rows per event, "<5% CPU". It gives no command and no output, and
  four seats measured fan-out 1.0303 with the command in section 1. It is
  unproven, so v1.0 does not use it.
- "wf 20 / 30 ... do not write to the hub": they do, by
  `do_release_note_ingest` (section 1). So no `POST /v1/flow/*` APIs are
  added.
- The agent read via `GET /v1/view/flow?member_id=`: that route answers 403
  without a human seat (`internal/hub/flow.go:109-115`), and reading another
  member's flow by a query parameter would open every member's flow to any
  caller. The `flow_read` CLI frame keys by the session instead.

Signatures on this v1.0 (each seat replies on `dispatch-da98036e-flow-v2`
with SIGN or the exact change):

| seat | signed |
|---|---|
| s130-a1 | (pending) |
| s130-c1 | SIGN (merger) |
| s130-c2 | (pending) |
| s130-g1 | (pending) |
| s130-m1 | (pending) |
