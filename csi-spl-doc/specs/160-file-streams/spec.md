# 160 File streams: follow a box file live in Monitoring, and search it

Version v0.1 (2026-10-26): the first draft, reviewed: cross-vendor PASS
(section 8). Nothing is built. Docs only until the owner's GO (section 7), then the build
rows of section 5 land one by one, each after its own review PASS + GO.

Source: the owner's asks in the owner's customer workspace (section 1); the
discussion moved to the operator workspace topic
`topic:c168784c-c5ab-444c-ab42-0de8097eb0f3` (owner msg efe08362). Issue:
SPL-3621 (this spec), epic SPL-2403 (Monitoring, as
[153](../153-monitoring-lanes-tab/spec.md)). Each build row gets its own
issue when it is placed. Placement slug `c002-spec-file-streams`.

Data rule: a file stream carries box logs, so every row of this spec goes
to a lane that may take secrets (claude, grok or mistral), never agy or qwen
(global CLAUDE.md, "Data rule"). A text key a row adds still gets the agy
review of the language rule: the key and its translations, never a log line.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `hub/` = `csi-spl-api/src/go/spool-hub-api/internal/hub/`
- `store/` = `csi-spl-api/src/go/spool-hub-api/internal/store/`
- `search/` = `csi-spl-api/src/go/spool-hub-api/internal/search/`
- `wire/` = `csi-spl-api/src/go/spool-hub-api/internal/wire/`
- `cli/` = `csi-spl-api/src/go/spool-hub-api/cmd/spool/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/`

Every `file:line` was read on origin/master `f11ed1f7c` by c-131, n = 1
read each. No prd number is used: this lane has no prd read, and nothing
here depends on one (the limits of 3.7 are budgets, measured by row B7).

## 1. The owner's asks, verbatim

Owner HUM-10, in the owner's customer workspace (quoted by the brief of
SPL-3621):

| msg | text |
|---|---|
| `e192e391` | "there should be a function for the spool-hub to tail -f <<a-file>> which is accessible to the [agent user] and this file would be shown in the spool-hub interface in a file streams tab of the monitoring section" |
| `efe08362` | "create a separate discussion about this in the spool-hub devel channel in the t1 tenant" |
| `c667612b` | "also one should be able to search for those from the global search but with the following syntax: `/s in:file-streams <<str-to-search>>`" |

`[agent user]` stands for the OS user name the owner wrote: no literal
user name ships in the repo (developer guide 2.5.2).

Read as three asks:

- **F1** A box follows a file with `tail -f` semantics, as the box's agent
  user (the file must be readable by that user), and sends its lines to the
  hub.
- **F2** Monitoring gets a "File streams" tab: pick the box and the file,
  see the lines arrive live.
- **F3** `/s in:file-streams <text>` in the global search finds lines of
  those streams.

Added by the brief (dispatch, c-423 msg ac657d72), not by the owner:
only files on an explicit allow-list, never a path typed in the browser;
only the workspace's owners and admins see a stream; lines are masked
before they leave the box, then stored, indexed and kept for a limited
time.

## 2. What exists on master

### 2.1 No file stream today

- `git grep -lE 'tail -f|tail -F|fsnotify|inotify' origin/master -- '*.go'`
  -> 0 files (c-423 on `57bb0af7f`; c-131 on `f11ed1f7c`: 0).
- `ls csi-spl-wui/src/pages/monitoring/` -> agents, agents.vue, boxes,
  costs, events, lanes, tokens: no file-streams page.

### 2.2 The nearest precedent: the token burn collector (spec 140)

A box process that reads files incrementally and pushes rows to the hub
already exists; F1 copies its shape:

- `orc/run/spl-token-burn-collect.func.sh:2-27`: one incremental tick reads
  "only the bytes the transcripts grew by since the last tick (byte offset
  per file, reset to 0 on a new inode or a shorter file)". That rule is
  `tail -F` (follow by name, survive rotation and truncation).
- It pushes over the box's hub connection as
  `spool fleet-tokens push --json -` (`:8-9`, the frame `:496`), a lane
  frame `lane_op fleet_tokens_push` (`wire/fleet_tokens.go:13-28`). The
  hub answers on the same `msg_id`; "the writing box is the session's,
  never the frame's" (`:24`).
- It runs from the box user's crontab, every minute, two ticks 30 s apart,
  at nice 10 and idle IO priority
  (`orc/scripts/token-burn-collect-cron.sh:2-8`), installed by
  `do_install_box_crons` from `csi-spl-orc/cnf/box-crons/box-crons.manifest`.
- The agent users whose files it reads: `spl_cost_agent_users`
  (`orc/run/spl-cost-tokens-read.func.sh:149`).
- The hub keeps the rows for a fixed time and prunes them in a sweep
  (`hub/fleet_tokens.go:97-112`, `sweepFleetTokens`; rdb `0199` keeps
  minutes 30 days, `:14`).

### 2.3 The one redaction pass

`orc/features/spawn-agents/lib/spool_redact.py:1-12`: "the ONE redaction
pass for text that leaves this box through a desk". Its list (`:26-110`)
already covers what the brief names: slack, github, gitlab, npm, AWS,
Google, `sk-`, `xai-` and stripe tokens; PEM private keys, whole and cut
short; raw ed25519 keys; DSN and URL passwords; signed URLs; `password:`
in any form (an owner rule, `:69-79`); `Authorization:` and `Bearer`
(`:81-87`); cookies; JSON secrets; `token|secret|api_key = value` in any
case (`:93-97`, so `JIRA_API_TOKEN=abc123` matches on `TOKEN=`); typed
passwords; JWTs. Its test:
`orc/features/spawn-agents/tests/test-spool-redact.sh`. Used today by the
terminal mirror and the session export (`spool-mirror.py`,
`spool-session-export.py`).

### 2.4 The global search and its `in:` operator

- WUI catalogue: `wui/utils/search.mjs:52`
  `{ op: 'in:', example: 'in:#lobby', values: ['dm'] }`, the offline
  fallback of `GET /v1/view/search/operators` (`:23-27`,
  `hub/search.go:685`).
- Hub grammar: `search/grammar.go:164`, `OpIn` with alias `channel`,
  `Applies: msgTopicFile` (messages, topics, files). Its value parser,
  `search/values.go:123-137` `channelValue`, strips a leading `#`, then
  `dm` sets `term.DM`, a name matching `chanRe` (`:17`,
  `^[a-z0-9][a-z0-9-]{0,63}$`) sets `term.Channel`, anything else is an
  error. **`file-streams` matches `chanRe`**, so `in:file-streams` reads
  today as "the channel named file-streams".
- The SQL: `store/search_postgres.go:200-204` (messages) and `:288-292`
  (topics) turn `in:` into `m.channel` / `t.channel` predicates.
- The sections: `DefaultTypes` (`search/grammar.go:63`) are searched when
  no `type:` is given; the entity sections are dispatched in
  `hub/search.go:431-447`.
- The newest searched store, the Qto documents (SPL-3337), is the pattern
  for a new one: `rdb/0227_workspace_doc_search.sql:1-30`, a STORED
  generated `tsvector` in `spool_search`, no GIN because the table is
  FORCE RLS and `ts_match_vq` is not LEAKPROOF (rdb 0122), read through a
  tenant-leading key so one search never reads another workspace's rows.
- Cross-tenant test: `hub/crosstenant_test.go:122-130` searches B's marker
  and `in:<B's channel>` from A and asserts nothing of B comes back.

### 2.5 Monitoring tabs and who sees them

- `wui/utils/monitoring-tabs.mjs:17-30` `MONITORING_TABS`; a tab with
  `staff: true` (Lanes, `:27-29`) is drawn for an operator OR a workspace
  owner or admin (`:42-45`, `visibleMonitoringTabs`).
- The hub's matching gate: `a.TenantOwner || a.Has(rbac.Admin)`
  (`hub/embed_staff.go:63`, `hub/topic_archive.go:176,193`; spec 153 3.6).

### 2.6 What the hub runs on

- Postgres is `db-f1-micro`, `max_connections` 25; the hub runs at most 2
  instances (`csi-spl-cnf/csi-spl/all.env.yaml:406`). A browser live
  WebSocket exists (`GET /v1/wui/ws`, `hub/server.go:419`;
  `hub/wui.go:31-35`: subscribe and fan-out per `task_id`).

## 3. The design

### 3.1 Box: the follower (F1)

A new box action `do_spl_file_stream_follow`
(`orc/run/spl-file-stream-follow.func.sh`), its follower
`orc/scripts/file-stream-follow.py`, its cron wrapper
`orc/scripts/file-stream-follow-cron.sh`, and a row `file-streams` in
`csi-spl-orc/cnf/box-crons/box-crons.manifest`, installed by
`do_install_box_crons` like the token burn.

- **Who it runs as.** The box's agent user (`spl_cost_agent_users`, the
  `[agent user]` of the owner's ask), never root and never the box owner's login.
  A file that user cannot read is not followed: "readable by the agent
  user" is proven by the open, not by a mode check.
- **Which files.** Only the allow-list (3.2). The browser never sends a
  path: it picks a stream the box announced (3.3).
- **tail -F semantics** (the token burn rule, 2.2). One state row per file:
  `path, dev, inode, offset, seq`. Each tick:
  - first sight of a file (no state): start at its last `N` lines
    (cnf `env.box.file_streams.start_lines`, default 200), never at 0;
  - same inode, size >= offset: read from offset to the end;
  - a new inode (rotated) or size < offset (truncated, copytruncate):
    read the file from 0, and send a marker line `-- file rotated --` /
    `-- file truncated --`;
  - the file is gone: keep the state, send `-- file missing --` once,
    resume when it reappears (follow by name);
  - a partial last line (no `\n`) waits for the next tick, up to the line
    limit (3.7), then goes as it is.
- **Rhythm.** One long-lived process per box under `flock` (a second start
  exits 0), restarted by the minute cron when it is not running. It ticks
  every 2 s (cnf `env.box.file_streams.tick_s`), exits after 1 h so a code
  change reaches it, and runs at nice 10 and idle IO priority. A line
  reaches the hub within one tick plus one push (target <= 5 s, case C6).
- **Push.** Only when a tick has lines: one lane frame
  `lane_op file_streams_push` through `spool file-streams push --json -`
  (a new verb, `cli/file_streams.go`, the shape of `cli/fleet_tokens.go`).
  Lines stay queued on the box (its state dir, bounded by 3.7) until the
  hub acks their `seq`; a failed push is retried next tick, so a hub
  restart loses no line and stores none twice (the hub keys on
  `stream_id, seq`).
- **Masking first.** Every line passes `spool_redact.redact()` (2.3) inside
  the follower before it is queued: an unmasked line never touches the
  queue file and never the wire (case C9). The frame carries the redaction
  counts per kind; the hub stores the counts, never what was removed.
- **Languages.** Python 3 for the follower (it imports `spool_redact`:
  one list, one home), bash for the action and the cron wrapper, Go for the
  push verb and the hub. Decision D2.

### 3.2 Box: which paths may be followed

Two lists; the deny list wins.

- **Allow-list, cnf.** `env.box.file_streams.allow` in
  `csi-spl-cnf/csi-spl/all.env.yaml` (an env file may override): a list of
  `{ id, path }`. `id` is a stable short name (`[a-z0-9][a-z0-9-]{0,31}`)
  the WUI shows; `path` is absolute or starts with `$HOME/` (the agent
  user's home), may hold one `*` glob in its last segment (a dated log; the
  newest match is followed), and names no literal user or box (hygiene,
  developer guide 2.5). The list ships EMPTY: nothing is followed until a
  cnf commit adds an entry. Which file comes first is question Q1.
- **Deny list, code** (`spl_file_stream_denied`, refused even when the
  allow-list names it), checked on the path AFTER `realpath`, so a symlink
  into a denied place is refused too: `$HOME/.ssh/`, `$HOME/.jira/`,
  `$HOME/.confluence/`, `$HOME/.gcp/`, `$HOME/.github/`, `$HOME/.aws/`,
  `$HOME/.config/gcloud/`, `$HOME/.claude.json`, `$HOME/.netrc`,
  `$HOME/.git-credentials`, any path with a `keys/` segment, the spool
  root (`$SPOOL_ROOT`: the desk state, inboxes, keys, leases),
  `/etc/shadow`, `/proc/`, `/sys/`, `/dev/`, and any file named `id_*`,
  `*.key`, `*.pem` or `*.p12`. A refused entry is logged once per process
  start (`file-streams: refused <id>: denied path`), never followed, and
  announced only as `refused`.
- **Not a regular file** (a fifo, a socket, a device, a directory): refused
  the same way.

### 3.3 Wire and hub storage

**Frames** (`wire/file_streams.go`) over the box's authenticated session;
the box is the session's, never the frame's (as 2.2):

- `file_streams_announce`: the box's current list, `[{stream_key, path,
  state: following|missing|refused}]`, sent at process start and on a
  change. The hub upserts one row per `(tenant, box, stream_key)`; a key no
  longer announced turns `gone` (its lines stay until retention).
- `file_streams_push`: `{stream_key, lines: [{seq, at, text, marker}],
  dropped, redactions: {kind: n}}`. `seq` is per stream, strictly
  increasing, kept in the box state across restarts.

**Tables** (one migration, the next free number at build time; the owner
and runtime split as every table since rdb 0096; FORCE RLS with the NULLIF
tenant policy and its test, as every tenant table, developer guide 2.6.4):

- `file_streams (tenant_id, id uuid, box_id, stream_key, path, state,
  first_seen_at, last_line_at, lines_total, lines_dropped,
  redactions jsonb)`, unique `(tenant_id, box_id, stream_key)`.
- `file_stream_lines (tenant_id, stream_id, seq bigint, at timestamptz,
  text, marker bool, search_tsv tsvector GENERATED ALWAYS AS
  (to_tsvector('spool_search', text)) STORED)`, primary key
  `(tenant_id, stream_id, seq)` (tenant-leading, as rdb 0227), plus
  `(tenant_id, at)` for the sweep and the search's date window. No GIN,
  for the reason of rdb 0227 (2.4).

**Which workspace.** The tenant of the box's pin (the session's tenant).
A box pinned in the operator workspace streams into the operator
workspace. The ask came from a customer workspace; whose box streams where
is question Q2.

### 3.4 Hub routes and RBAC

All three need a member session of workspace W with
`TenantOwner || Has(rbac.Admin)` in W (2.5), else 403 `forbidden`; an
act-as clone and the operator service account are refused. A box session
may announce and push, never read.

- `GET /v1/view/file-streams`: W's streams, per box: `[{id, box_id,
  stream_key, path, state, last_line_at, lines_total, lines_dropped}]`.
- `GET /v1/view/file-streams/{id}/lines?after=<seq>&limit=<n>`: the lines
  after `seq`, oldest first; `limit` default 200, max 1000; without
  `after`, the last `limit` lines. A stream of another workspace answers
  404, never 403 (no existence leak, as `hub/crosstenant_test.go:115`).
- `GET /v1/view/file-streams/{id}/lines?before=<seq>&limit=<n>`: older
  lines, for scrolling up.

Live delivery is a poll of `after=<last seq>` every 3 s while the tab is
visible and Follow is on (decision D3); no new WebSocket channel.

### 3.5 WUI: the File streams tab (F2)

- `MONITORING_TABS` gets `{ id: 'file-streams', path:
  '/monitoring/file-streams', labelKey: 'monitoring.tab.file_streams',
  operatorsOnly: false, staff: true, ready: true }` after Lanes;
  `wui/pages/monitoring/file-streams.vue` is its own lazy chunk (the
  initial bundle budget).
- **Pick.** Two selects, Box then File (`stream_key`, the path as hover
  text); the pick is in the URL (`?box=&stream=`), so it survives a reload
  and Back. No stream: one line saying a box follows only the files on its
  allow-list (a text key, no path).
- **Live view.** A monospace list, newest at the bottom; each line shows
  its UTC time on hover; marker lines (rotated, truncated, missing,
  dropped N) are styled apart. Long lines wrap; no horizontal scroll. The
  view holds at most 2000 lines, dropping the oldest.
- **Follow** (default on): a new line scrolls the view to the bottom.
  Scrolling up turns Follow off; "Jump to latest" turns it on.
- **Pause**: stops the poll and freezes the view; Resume fetches what came
  meanwhile (`after=<last seq>`, pages of 1000) and shows "N new lines".
- **Find in view**: a filter over the loaded lines (client side); the
  stored search is 3.6.
- Phone: the same page, the selects stacked. Every string is a key in
  `en.json` and every locale (developer guide 2.7); agy reviews the
  translations.

### 3.6 Search: `in:file-streams` (F3)

- `search/grammar.go`: a new type `TypeFileLine` (group `file_lines`),
  NOT in `DefaultTypes`: a plain search never reads stream lines (cost,
  and they are staff only). `OpIn`'s `Applies` adds `TypeFileLine`.
- `search/values.go` `channelValue`: the bare value `file-streams` (also
  `file-stream`) sets `term.FileStreams`, which narrows the query to
  `TypeFileLine`, a reserved word as `dm` is. `#file-streams` (with the
  hash) stays the channel of that name, so a workspace with such a channel
  can still search it (case C14). Decision D4.
- Other operators on `TypeFileLine`: free text; `box:<id>`;
  `before:` / `after:` / `on:` on `at`; `name:<stream_key>`. `from:`,
  `to:` and `topic:` do not apply (the grammar's applicability error, as
  today).
- `store/search_postgres.go`: the section reads `file_stream_lines` of W
  only, in the tenant scope, newest first, with the same `spool_search`
  match as messages (a word matches a log line exactly as it matches a
  message); a result row is `{stream_id, box_id, stream_key, seq, at,
  text, highlights}`.
- `hub/search.go`: the section runs only for a caller who passes 3.4's
  gate; for anyone else it is absent and the answer carries
  `notices: ["file_streams_staff_only"]`, which the WUI shows as one line
  (a text key). The whole search is never refused.
- WUI: `search.mjs:52` `values: ['dm', 'file-streams']`; the help rows
  list it; a result opens `/monitoring/file-streams?box=&stream=&seq=`
  at that line, Follow off.

### 3.7 Limits and retention

Budgets for a `db-f1-micro` (2.6). Each is a cnf value
(`env.hub.file_streams.*` on the hub, `env.box.file_streams.*` on the
box); row B7 measures them before the defaults are final:

| limit | default | enforced by | over it |
|---|---|---|---|
| streams per box | 8 | box (allow-list), hub (announce) | the extra keys are `refused` |
| line length | 2048 bytes | box | cut, ` [cut N bytes]` appended |
| lines per stream per minute | 600 (10/s) | box, then hub | the box drops the rest and sends one `dropped N` marker; the hub refuses a push over twice the rate |
| lines per push | 1000, frame <= 1 MiB | hub | 413 `too_large`, the box splits |
| box queue | 20 000 lines | box | oldest dropped, counted in `dropped` |
| lines kept per workspace | 500 000 | hub sweep | oldest pruned first |
| retention | 7 days | hub sweep, hourly, as `sweepFleetTokens` | pruned |

Retention is question Q3. Ten streams at the full rate fill 500 000 lines
in under 2 hours; then the cap, not the days, decides what stays, and the
tab shows the oldest line kept.

## 4. Cases

Every case is planned; none is built. Each red control is what FAILS on
master today, or on the row's planted defect, and passes once its row
lands.

| id | row | case | red control |
|---|---|---|---|
| C1 | B1 | a new allow-listed file: the first push holds its last 200 lines, not line 1 | start at offset 0: the test sees 201+ lines |
| C2 | B1 | append 3 lines: the next tick pushes exactly those 3, seq +1 each | re-read from 0 each tick: duplicates |
| C3 | B1 | rotate (`mv f f.1; touch f`), then write: the new file's lines from 0, one `rotated` marker | follow the fd, not the name: the new lines never come |
| C4 | B1 | truncate (`: > f`), then write: the new lines from 0, one `truncated` marker | keep the offset: nothing until the file outgrows it |
| C5 | B1 | delete, then recreate: one `missing` marker, then the new lines | exit on ENOENT: the stream dies |
| C6 | B1 | a written line is on the (stub) hub within 5 s, timed | a 30 s tick: > 5 s |
| C7 | B1 | a file the agent user cannot read (mode 600, another owner) is announced `refused`, not followed | run as root: it is read |
| C8 | B1 | each deny-list path (3.2), and a symlink to `$HOME/.ssh/id_x` placed in an allowed dir, is refused although allow-listed | the deny check before `realpath`: the symlink is followed |
| C9 | B1 | a line with `ghp_`, `Bearer`, `JIRA_API_TOKEN=`, a PEM block and `password:` reaches the push frame AND the queue file masked, with counts in `redactions` | queue before redact: the token is in the queue file |
| C10 | B1 | the hub is down for 3 ticks, then up: every line arrives once, in seq order | drop on a failed push: a gap |
| C11 | B2 | a push from box B pinned in W stores rows in W only; the frame cannot name another box or tenant | the box taken from the frame: rows land under the named box |
| C12 | B3 | a member (not owner or admin) of W: 403 on all three routes; owner and admin: 200 | a membership-only gate: the member gets 200 |
| C13 | B3 | the owner of W1 asks for W2's stream id: 404, the body names nothing of W2 (cross-tenant, as `crosstenant_test.go:122`) | read by id without the tenant: W2's lines |
| C14 | B4 | `in:file-streams token` = stream lines only; `in:#file-streams token` = the channel named file-streams | strip `#` first (today's `channelValue`): both are the channel |
| C15 | B4 | a plain `/s token` returns no stream line | `TypeFileLine` in `DefaultTypes`: it does |
| C16 | B4 | a member's `in:file-streams x` answers 200, no line, `notices: ["file_streams_staff_only"]` | no gate on the section: lines reach a member |
| C17 | B4 | W1's owner searches `in:file-streams <W2 marker>`: nothing of W2 | the section without the tenant scope: W2's line |
| C18 | B5 | the tab is drawn for an owner or admin, not for a member (unit, as `monitoring-tabs.test.mjs`) | `staff` flag missing: a member sees it |
| C19 | B5 | e2e: pick box and file; a line the stub appends shows within 2 polls; Pause sends 0 requests in 10 s; Resume shows "N new lines" | the poll ignores Pause: requests continue |
| C20 | B5 | e2e: scrolling up turns Follow off; "Jump to latest" turns it on | always scroll: the reader cannot read back |
| C21 | B5 | a search result opens the tab at that line, Follow off | a link without `seq`: lands at the bottom |
| C22 | B6 | the sweep prunes lines past retention and over the workspace cap, oldest first | no sweep: the row count only grows |
| C23 | B2 | a push over the limits of 3.7 gets 413 or the `dropped` marker, never a partial store | store first, check after: half a frame stored |
| C24 | B7 | the time of `in:file-streams` over 500 000 lines of one workspace on dev, n >= 5, recorded in 3.7 | n/a: a measurement; its check is the recorded n |

## 5. Build rows

Each row is one lane and one issue, with its tests and red controls in the
same commits; each lands after its own review PASS and the dispatch
holder's GO. Order: B1 and B2 may run in parallel (3.3's frames are their
contract); B3, B4 and B6 after B2; B5 after B3; B7 after B4 and B6.

| row | scope | paths | cases |
|---|---|---|---|
| B1 | box follower, deny list, masking, cron row | `orc/run/spl-file-stream-follow.func.sh`, `orc/scripts/file-stream-follow.py`, `orc/scripts/file-stream-follow-cron.sh`, `csi-spl-orc/cnf/box-crons/box-crons.manifest`, cnf `env.box.file_streams`, `orc/tests/spl-file-stream-follow.tst.sh` | C1-C10 |
| B2 | frames, push verb, migration, store, push handler, limits | `wire/file_streams.go`, `cli/file_streams.go`, `rdb/<next>_file_streams.sql`, `store/file_streams*.go`, `hub/file_streams.go` | C11, C23 |
| B3 | read routes, RBAC | `hub/file_streams_view.go`, `hub/crosstenant_test.go` | C12, C13 |
| B4 | the search scope | `search/grammar.go`, `search/values.go`, `store/search_postgres.go`, `hub/search.go`, `wui/utils/search.mjs` | C14-C17 |
| B5 | the WUI tab | `wui/utils/monitoring-tabs.mjs`, `wui/pages/monitoring/file-streams.vue`, i18n locales, e2e | C18-C21 |
| B6 | the retention sweep | `store/file_streams_postgres.go`, `hub/file_streams.go` | C22 |
| B7 | measure the limits on dev, set the defaults in cnf | cnf `env.hub.file_streams`, this spec 3.7 | C24 |

Docs: each row updates this spec's status line; B5 adds the tab to the
Monitoring help page and B4 the syntax to the search help
(`csi-spl-doc/doc/help/`).

## 6. Decisions (this draft; the reviewer may challenge each)

- **D1 Always on, not on demand.** A box follows its allow-listed files
  all the time, not only while someone watches: F3 searches lines nobody
  watched, and on demand would need a hub-to-box command channel that does
  not exist. The cost is bounded by 3.7.
- **D2 A Python follower, one redaction list.** The follower imports
  `spool_redact` (2.3) instead of a Go port: two lists drift, and the
  owner's password rule (`spool_redact.py:69-79`) must hold in one place.
  The hub does not mask again; it stores what the box sends. A Go follower
  holding one WebSocket is the alternative if B7 shows the one-shot push
  sessions cost too much.
- **D3 Poll, not WebSocket fan-out.** With up to 2 hub instances a WS
  fan-out needs a cross-instance signal; the lines are in Postgres anyway,
  so a 3 s `after=` poll while visible is simpler and costs one indexed
  read. Revisit if B7 measures the polls as a load.
- **D4 `in:file-streams` is a reserved value, `#file-streams` the
  channel.** It matches the owner's syntax exactly and keeps a channel of
  that name searchable.
- **D5 The workspace is the box's pin.** No new mapping table; Q2 decides
  whether the owner wants more.

## 7. Owner questions

The dispatch holder posts them in `c168784c` as one form; the recommended
answer is first.

```poll
Q1 Which file should a box follow first?
(A) The box desk's own log (recommended)
(B) The box's system journal, exported to a file
(C) None yet: ship with an empty list, I add files later
Q2 Whose box streams into which workspace?
(A) The box's own workspace, the one it is pinned in (recommended)
(B) Also let a customer workspace see an operator box's streams
Q3 How long are stream lines kept for the search?
(A) 7 days, at most 500 000 lines per workspace (recommended)
(B) 30 days, at most 2 000 000 lines (needs a bigger database tier)
(C) 24 hours
Q4 GO to build rows B1..B7 in the order of section 5?
(A) GO
(B) Not yet
```

## 8. Review record

| reviewer | vendor | sha | verdict | msg |
|---|---|---|---|---|
| m-313@sat | mistral | `0860285a7` | PASS, no defects, no warnings | `7d8f18ae` (task `c5a8ed9d`) |

The reviewer ran nine checks, each with its command: the branch and the
one-file diff; the path model (allow-list in cnf, deny list in code after
`realpath`); masking by `spool_redact.py` before the queue; owner/admin
RBAC and the cross-tenant cases; the reserved `in:file-streams` value and
`TypeFileLine` outside `DefaultTypes`; the limits and retention; the 24
cases and their red controls; the poll form; `do_check_dist_hygiene`
clean. Its one note, not a defect: like every list, `spool_redact` misses
a token format it does not know (a custom `custom_abc123`); row B1's C9
tests the formats the brief names.

Dispatch GO to land this doc: c-002@sat, msg `5fc59ad9` (task
`c5a8ed9d`). A GO to build is the owner's (section 7, Q4).

Accepted by the dispatch holder c-002@sat (msg `76317007`, task
`c5a8ed9d`) on `0860285a7` + `1f4c79ec8`. The plan and the section 7 poll
are posted in the operator workspace topic `c168784c` (msg `75d8db39`).
SPL-3621 (this spec) ends here; each build row B1..B7 gets its own issue
and lane on the owner's GO.

## 9. Not in scope

- Following a file on a box the workspace does not own, or any path sent
  from the browser.
- Writing to a file, or running a command, from the tab.
- Alerts on a pattern in a stream (a later spec, if the owner asks).
- A workspace's cloud logs (Cloud Logging).
