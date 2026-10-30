# 160 File streams: follow a box file live in Monitoring, and search it

Version v0.6 (2026-10-30): folds the owner's answers to Q5..Q7 (poll
`900699dd`, msg `369e7bfa`, 7.1): Q5 B, the default folders are the fleet's
box log folder and `/var/log`, minus the security files (3.8.2); Q6 A, every
match its own stream (3.8.7); Q7 A, no cnf key lifts a security file
(3.8.10). v0.5 (2026-10-29) fixed review W1-W3 of v0.4 (grok g-746 FAIL on
`7814f50a4`). v0.4 (2026-10-29) added 3.8, file globs typed in the web page by a
workspace owner or admin (owner answer B, poll `376e9435`) and a deny class
for security-related system files; rows B9..B12 planned
(change log, section 10). v0.3 (2026-10-26) was reviewed: claude review PASS (c-317 on
`2f1ee57b5`, section 8), after a FAIL on v0.1 (W1-W9) and on v0.2 (N1-N4).
The owner's GO and answers (section 7.1): Q1 A, Q2 A, Q3 A, Q4 GO (HUM-10,
msg 44ec2e44 on the v0.3 poll), then all A again on the v0.1 poll (msg
5c6686f2, 2026-10-27), whose Q1 A is the desk log the deny list refuses;
Q1 decided A, the token-burn cron log (msg 1a5ce9f1, 2026-10-28, 7.1). Row B1 is built (SPL-3820, section 5.1), its cron row off by cnf
until it is switched on; B2 to B6 are built (SPL-3888, sections 5.2 to
5.6); row B7's measure and the search fix it called for are built (5.7),
its cnf defaults are next. Row B8 (SPL-4124, owner msg b2717710), the
page as a list per box with a `tail -f` button per file, is built (5.8).

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
only files on an explicit allow-list, never a path typed in the browser
(from v0.4: a glob a workspace owner or admin types, which the box itself
expands under its allowed folders only, 3.8);
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

- Postgres is `db-custom-1-3840` (1 dedicated vCPU, 3.75 GB;
  `csi-spl-cnf/csi-spl/all.env.yaml:191` on `e4455240d`, SPL-2890 / SPL-2932,
  `:190` "Undo: db-f1-micro"), disk `disk_size_gb: 10` (`:193`). Its
  `max_connections` is unmeasured: the cnf sets no such flag
  (`git grep -n max_connections origin/master -- csi-spl-cnf` -> only the
  stale pool comment at `:467-468`, written for db-f1-micro's 25), and this
  lane has no read of the instance. The hub runs at most 2 instances
  (`:406`). A browser live
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
- **Which files.** Only the allow-list (3.2), and from v0.4 the globs a
  workspace owner or admin typed in the web page, expanded by the box under
  its allowed folders only (3.8). The browser never sends a path to open:
  it picks a stream the box announced (3.3), and a glob it sends is text the
  box checks itself (3.8.1).
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
    limit (3.7), then goes as it is; it is masked like any line, with the
    PEM state below, before it is queued.
- **Rhythm.** One long-lived process per box under `flock` (a second start
  exits 0), restarted by the minute cron when it is not running. It ticks
  every 2 s (cnf `env.box.file_streams.tick_s`), exits after 1 h so a code
  change reaches it, and runs at nice 10 and idle IO priority. A line
  reaches the hub within one tick plus one push (target <= 5 s, case C6).
- **Push.** Only when a tick has lines: one lane frame
  `lane_op file_streams_push` through `spool file-streams push --json -`
  (a new verb, `cli/file_streams.go`, the shape of `cli/fleet_tokens.go`).
  Lines stay queued on the box (its state dir, bounded by 3.7) until the
  hub acks their `seq`. The state dir defaults to the agent user's
  `~/.local/state/csi-spl/file-streams/<env>`; when that user cannot write
  `~/.local/state/csi-spl` (one box: root-owned) it is
  `~/.local/state/csi-spl-file-streams/<env>`, outside the nightly
  box-state backup (a lost state restarts each file at its last `N` lines); a failed push is retried next tick, so a hub
  restart loses no line and stores none twice (the hub keys on
  `stream_id, seq`).
  The hubs fed: env `FILE_STREAMS_HUBS`, else that key in the box's
  spool `box.env` (the cron line carries no env; owner poll 5a85c2c1:
  sat feeds prd only until its dev desk is pinned), else cnf
  `env.box.file_streams.hubs` (dev and prd). Each hub has its own
  follower and state dir `<env>`.
- **Masking first.** Every line passes `spool_redact.redact()` (2.3) inside
  the follower before it is queued: an unmasked line never touches the
  queue file and never the wire (case C9). The frame carries the redaction
  counts per kind; the hub stores the counts, never what was removed.
- **A key spans lines: the PEM state** (review W1). `spool_redact`'s PEM
  patterns are multi-line; fed one line at a time they mask the BEGIN line
  and pass the body and the END line unchanged (c-317, measured on a
  synthetic 4-line key). So the follower keeps, per file, a state "inside a
  PEM block" in the same state row as the offset (`pem_open`,
  `pem_lines`), so it survives a tick and a process restart:
  - a line holding a `-----BEGIN ... KEY-----` header opens the block: that
    line and every following line become one `<redacted:private-key>`
    marker each, counted once per block;
  - a line holding BEGIN and its END together (a key escaped into one JSON
    log line) opens NO block: `spool_redact` masks it as one string, and
    the next line is followed as usual (review N4; case C37);
  - the block closes on its `-----END ... -----` line (masked too), or on a
    rotation, truncation or new inode;
  - the cap: up to `pem_max_lines` lines (cnf
    `env.box.file_streams.pem_max_lines`, default 200; an 8192-bit RSA key
    is estimated at ~98 base64 lines, c-317, unchecked against a real key)
    every line is masked whatever it holds (an encrypted key's
    `Proc-Type:` header lines too). Past the cap, masking goes on while a
    line is pure base64 (`^[A-Za-z0-9+/=]{1,76}$`); the first other line
    closes the block with one `-- masked block cut at cap --` marker and is
    followed as usual (review N4). So a cut key with no END leaks no body
    line, and a block never swallows the log for good.

  Cases C9 (the key in one tick), C25 (a key split across 2 ticks), C26 (a
  cut key past the cap, no END), C37 (a one-line key).
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
  allow-list names it). Review W4: a list of known credential paths always
  misses one, so the home is denied by default:
  - every dot entry of the agent user's home, `$HOME/.*` (`.ssh`, `.gnupg`,
    `.config/gh`, `.config/gcloud`, `.docker/config.json`, `.kube`,
    `.pgpass`, `.netrc`, `.git-credentials`, `.claude*`, `.spool-hub`,
    `.vibe`, `.gcp`, `.aws`, `.jira`, `.confluence`, `.github`, `.local`,
    shell history files ...), except the exceptions named in code with a
    reason each; v0.3 names none;
  - every home but the agent user's (`/home/*`, `/root`, and each
    `getpwent` home other than `$HOME`);
  - the spool roots: the box's spool root, resolved as the repo does,
    `${SPOOL_ROOT:-/var/spool-hub}` (`git grep -c 'SPOOL_ROOT:-/var/spool-hub'
    -- csi-spl-orc` -> 131 files on `d1549ea17`, c-317), because the
    follower runs from the box crontab and the cron wrapper it copies sets
    no `SPOOL_ROOT` (`token-burn-collect-cron.sh`: 0 hits); the follower
    refuses to start when the resolved root is not a directory (review N1;
    case C35). Also every desk's own spool
    root and desk dir (`$SPL_STATE_DIR/desk/`, which holds `spool/` and
    `keys/`: section 7, Q1), all inboxes, keys and leases;
  - `/etc/shadow`, `/etc/gshadow`, `/etc/ssh/ssh_host_*_key`, `/proc/`,
    `/sys/`, `/dev/`;
  - from v0.4, the security-related system files of 3.8.10 (`/etc/passwd`,
    `/etc/group`, sudoers, pam, the login records, ...), reason
    `security file`;
  - any path with a `keys/` segment, and any file named `id_*`, `*.key`,
    `*.pem`, `*.p12`, `*.pfx`, `.env` or `.env.*`, `*_history` or
    `.*history`.
- **Open first, then check the opened file** (review W2, N3). A check of
  the path before the open races the open, and a check run once misses
  what changes later. A plain read open is not safe either: opening a
  device or special file reached through a symlink runs its driver's open
  before any `fstat` could refuse it. So on EVERY open and reopen (first
  sight, a new inode after a rotation, the `*` glob switching to a newer
  match, a file that reappears after `missing`) the follower:
  1. opens the allow-listed path with `O_PATH | O_CLOEXEC`: the name is
     resolved, no driver open runs and nothing can be read;
  2. checks that fd, never the name: `readlink(/proc/self/fd/N)` is the
     real path and the deny list is checked on it (so a symlink into a
     denied place, placed at start or after a rotation, is refused), and
     `fstat(fd)` must be `S_ISREG` (a fifo, socket, device or directory is
     refused) with `st_nlink == 1` (below);
  3. only then reopens for reading through `/proc/self/fd/N` with
     `O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC`, and compares the new
     fd's `(st_dev, st_ino)` with step 2's: a mismatch is refused;
  4. a refusal closes every fd before any byte is read.
- **Hardlinks** (review W3). `realpath` and `/proc/self/fd` do not resolve
  a hardlink: a link to `$HOME/.ssh/id_x` made in an allowed directory has
  an allowed name. So `fstat(fd).st_nlink > 1` is refused. A log rotated
  with `ln` (two names briefly) is refused for that tick and retried on
  the next; the `-- refused: hardlink --` marker is sent once.
- A refused entry is logged once per change of its state
  (`file-streams: refused <id>: <reason>`), never followed, and announced
  only as `refused`; the reasons are `denied path`, `not a regular file`,
  `hardlink`, `unreadable`.

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
tenant policy and its test, as every tenant table, developer guide 2.6.4;
case C30):

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
act-as clone (`hub/actas.go:29`, `readerIsActAsClone`) and the operator
service account are refused (cases C27, C28). A box session may announce
and push, never read (case C29).

The route gate is the intended one (review W6). Today
`visibleMonitoringTabs` (`wui/utils/monitoring-tabs.mjs:42-45`) draws a
`staff` tab for any operator (`who.operator`), so an operator who is not
owner or admin of W would see the tab and get 403. The file-streams tab
therefore is drawn on `who.staff` only, not on `who.operator`: row B5
adds a flag (`staffOnly: true`) that `visibleMonitoringTabs` reads, and
the Lanes tab keeps its operator rule (case C18).

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
  operatorsOnly: false, staff: true, staffOnly: true, ready: true }` after
  Lanes (`staffOnly`: the route gate of 3.4, no operator bypass);
  `wui/pages/monitoring/file-streams.vue` is its own lazy chunk (the
  initial bundle budget).
- **List** (row B8, owner HUM-10 msg b2717710: "some important file logs
  as a list from the file systems of the boxes (so that one could just
  click on the `tail -f` button and then see the output, and not as one
  giant output window)"). Every box, and under it a row per followed file:
  its `stream_key` (the path as hover text and as a second line), state,
  last line time and lines total, and its own `tail -f` button. The button
  opens THAT file's live view under its row; one file is open at a time,
  pressed again it closes, and the lines of two files are never merged.
  Nothing is open before a click. The open file is in the URL
  (`?box=&stream=`, each click a history entry), so it survives a reload
  and Back; only a box and stream the hub returned open, never a typed path
  (`fileStreamOpenOf`, no fallback to a first file). No stream: one line
  saying a box follows only the files on its allow-list (a text key, no
  path). File globs as inputs are not in B8 (owner msg 075974c4); the
  owner's answer B (poll `376e9435`) adds them as 3.8, rows B9..B12.
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
- Phone: the same page, a row's facts and button wrapped under its name. Every string is a key in
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
  can still search it (case C14). Decision D4. `channel:` is an alias of
  `in:` (`search/grammar.go:164`) sharing `channelValue`, so
  `channel:file-streams` is reserved too and means the same (review W7;
  case C14 tests both spellings).
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
- **Wire contract: `notices` is a new field** (review W7). The answer of
  `GET /v1/view/search` is today `{query, sort, types, warnings, groups}`
  (`hub/search.go:173-174`); `git grep -n notices` over `hub/search.go` and
  `search/` -> 0 hits. B4 adds `notices: [string]`, always present (`[]`
  when empty), a list of stable codes, never free text; `warnings` keeps
  its meaning (query parse problems). The WUI reads it in
  `wui/utils/search-results.mjs` and `wui/pages/search.vue`.
- WUI: `search.mjs:52` `values: ['dm', 'file-streams']`; the help rows
  list it; a result opens `/monitoring/file-streams?box=&stream=&seq=`
  at that line, Follow off.

### 3.7 Limits and retention

Budgets for the `db-custom-1-3840` instance with its 10 GB disk (2.6;
review W5: v0.1 said db-f1-micro, a tier undone on 2026-10-22). Each is a cnf value
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
| bytes kept per workspace | 256 MiB of text (`env.hub.file_streams.max_bytes_per_workspace`) | hub, AT INSERT, in the push's own transaction and tenant scope | that workspace's own oldest lines pruned to make room; never another workspace's |
| workspaces that stream | 4 (`env.hub.file_streams.max_workspaces`) | hub (announce) | the announce of a 5th workspace's box is answered `refused` for every key; nothing of the 4 is touched |
| retention | 7 days | hub sweep, every sweeper tick (10 min, `SweepInterval`), as `sweepFleetTokens` | pruned |

Retention is question Q3. Ten streams at the full rate fill 500 000 lines
in under 2 hours; then the cap, not the days, decides what stays, and the
tab shows the oldest line kept.

**What the cap means on disk** (review W5). At the 2048-byte line limit,
500 000 lines are 500 000 x 2048 = 1 024 000 000 bytes, about 0.95 GiB of
text per workspace, plus the STORED `tsvector` and the two btree indexes
(their size is unmeasured; B7 measures it, case C24). The instance's disk
is `disk_size_gb: 10` (`all.env.yaml:193`) for the whole hub, so two full
workspaces would take a fifth of it in text alone. Hence the byte cap per
workspace above.

**No cross-workspace pruning** (review N2). v0.2 had a hub-wide byte cap
pruned "oldest first, across workspaces": one noisy workspace could delete
another's lines before their 7 days. v0.3 has none. Each workspace is
bounded by its own caps (500 000 lines and 256 MiB of text, whichever
comes first), enforced at insert: the push transaction, in the pushing
workspace's tenant scope, deletes that workspace's own oldest lines until
the new ones fit. So the overshoot is at most one push (1000 lines, at most
1 MiB), not an hour of input: a box can send 8 x 600 x 60 = 288 000 lines
an hour, up to ~0.59 GB at 2048 B a line (c-317), which a periodic sweep
alone could not bound. The hub-wide total is then bounded by
`max_workspaces` x 256 MiB = 1 GiB of text by default, against the 10 GB
disk; a workspace past `max_workspaces` is refused at announce, never by
evicting another. The sweep keeps the 7-day retention, and re-applies the caps (5.6). Real
log lines are far shorter than 2048 bytes; B7 records the measured mean
line size and the bytes per stored line, then sets the caps.

**Measured** (row B7, case C24; 2026-10-28 on dev, hub `cfd6cfb7`,
`do_spl_file_streams_measure`, 500 000 synthetic log lines in one
workspace, 8 streams, the table holding nothing else): the mean text is
148.3 bytes and the stored `search_tsv` entry 301.8 bytes; table with toast
268 926 976 bytes plus indexes 81 182 720 bytes, **700.2 bytes per stored
line**, so a workspace at 500 000 lines takes about 350 MB of the 10 GB
disk, 4 workspaces about 1.4 GB. `in:file-streams` over those lines (n=5
per word, EXPLAIN ANALYZE of the hub's statement): matched on
`to_tsvector(l.text)` as built in B4 it took 14 846..16 906 ms (median
~15.6 s) for every word, past the 7 s search budget; matched on the
stored `l.search_tsv` (5.7) 425..483 ms for an absent word or one in a
thousand lines and 18..19 ms for one in three.

**Connections.** The follower's push uses the box's existing session (one
frame per tick with lines, 3.1) and the tab's poll is one indexed read
every 3 s per open tab; neither opens a pool of its own. The pool budget
of `all.env.yaml:467-472` was written for db-f1-micro's 25 connections;
the new tier's `max_connections` is unmeasured (2.6), so B7 reads it on
dev (`SHOW max_connections`) before any pool value is raised. Measured
2026-10-28 (row B7): 100 on dev.

### 3.8 File globs typed in the web page (owner answer B)

Planned, not built yet (v0.4). The owner, HUM-10 in `c168784c`, poll
`376e9435` "Where can a file glob be given?", msg `d925f9a3`, verbatim:
"Answer: B — Also pasted in the web page by a workspace owner or admin: the
box expands it, but only under allowed folders and never onto a denied
file". The other options were A (only each box's allow-list, cnf) and C
(both); B adds the web page to the cnf allow-list of 3.2, which stays.
His follow-up (msg `7f673aef`), verbatim: "Now, some obvious files from a
security point of view, such as etc/passwd, etc/groups, and others, which
are pretty much related to security, should not, of course, be allowed by
default." That is 3.8.10.

Every `file:line` below was read on origin/master `bf6991ecf` by c-601,
n = 1 read each.

#### 3.8.1 What changes in 3.2, and why it stays safe

3.1 and 3.2 said "the browser never sends a path". From v0.4 the browser
sends a glob PATTERN, as text, to the hub, for one box of its workspace.
What does not change:

- The hub never opens, lists or resolves the pattern. It checks the syntax,
  stores it, audits it, and hands it to that box when the box asks (3.8.5).
- The folders a glob may reach are the box's own cnf (3.8.2), a reviewed git
  commit, never a value the hub or the browser sends. The hub learns them
  only from the box's announce, to show them and to refuse an obvious miss
  early; that check is a convenience, not the gate.
- The box treats every pattern as untrusted input: it re-checks the syntax,
  resolves the directory through an fd, and puts every match through
  `open_checked` (`orc/scripts/file-stream-follow.py:262-298`), the same
  open-then-check of 3.2 that cnf entries pass. So every deny case of 3.2
  (C8, C31-C36: a denied path, a symlink into one at start or after a
  rotation, a newer glob match that is a symlink, a hardlink, a fifo or
  device, another home) applies to each match unchanged, plus a folder check
  on the opened fd's real path.
- The hub never treats a box path as inside an allowed folder on its own
  word: a glob's state (`following`, `partial`, `none`, `refused`) comes only
  from the box's announce, after the box's own check.

So the worst a stolen owner session or a compromised hub can do is have a
box follow a regular, single-link, non-denied file inside a folder the box's
cnf already allows, masked by `spool_redact` as every line is (3.1). That is
the set of files a cnf commit could add, minus nothing and plus nothing.

#### 3.8.2 Allowed folders: a new cnf key

- `env.box.file_streams.folders` in `csi-spl-cnf/csi-spl/all.env.yaml`
  (beside `allow`, `:1159-1174`): a list of directory paths, absolute or
  `$HOME/`, no glob. A box narrows or replaces it with `FILE_STREAMS_FOLDERS`
  in its `box.env`, as `FILE_STREAMS_HUBS` is read today
  (`orc/run/spl-file-stream-follow.func.sh:89`); `box.env` is the box's own
  file, never written from the hub.
- Today's `allow` entries do NOT become folder roots. An entry names one file
  that its cnf commit's review saw; making
  `/var/csi/csi-spl/token-burn/cron.log` a folder root would open every
  sibling under `/var/csi/csi-spl/` without that review (on one box,
  `find /var/csi/csi-spl -maxdepth 3 -type f | wc -l` -> 241: the box crons'
  `cron.log` and `cron.out` files, and their state tables and locks). A
  folder root is a wider grant than a file, so it is a new key.
- The default, the owner's answer Q5 B (msg `369e7bfa`, 7.1): two folders,
  the fleet's box log folder `/var/csi/csi-spl` (`BOX_CRONS_STATE_DIR`'s
  default, `orc/run/install-box-crons.func.sh:31`) and `/var/log`, minus the
  security files of 3.8.10. The "minus" needs no second list: every open of
  a match runs `spl_file_stream_denied` (3.2), whose `security file` class
  names the `/var/log` ones (`auth.log*`, `btmp*`, `wtmp*`, `audit/`,
  `journal/`, ...), so a glob `/var/log/*` follows `syslog` and is refused
  `auth.log`. Both folders have two segments, so the rule below keeps them.
- The box refuses a folder entry, and announces it `refused`, when it is `/`
  or has fewer than two segments (`/etc`, `/var`), holds a glob, or is
  denied itself or lies under a denied root (`$HOME/.config`, `/proc/x`,
  `/etc/ssh`, a spool root). A folder is resolved once per scan through an
  `O_PATH | O_DIRECTORY` fd, so a folder that is a symlink counts as where it
  points.

#### 3.8.3 Who may type a glob, and the routes

New routes in `hub/file_streams_view.go` (registered beside `:36-39`):

- `POST /v1/file-streams/globs` `{box_id, key, glob}` -> 201 `{id, ...}`
- `GET /v1/view/file-streams/globs` -> W's globs per box, each with the
  box's last reported state, `matched`, `followed`, `over_cap`, `reason`
- `DELETE /v1/file-streams/globs/{id}` -> 204
- `GET /v1/view/file-streams/globs/audit?before=&limit=` -> the audit rows
  (3.8.9)

The gate is the read routes' one, `fileStreamsStaffRefusal`
(`hub/file_streams_view.go:65-72`): a member session of W (an operator
service account or a box session has none: 403), not a live act-as clone
(403), and `TenantOwner || Has(rbac.Admin)` in W (403). Then:

- `box_id` must be a box that announced in W (a `file_streams` row of W
  names it); any other box, and another workspace's glob id on DELETE,
  answer 404, never 403 (no existence leak, as 3.4).
- A box under an owner lock (spec 025) takes a glob only from one of the
  lock's owners (`l.IsOwner(hum)`, `hub/box_lock_view.go:140`), else 403
  `box_locked`, so a lock is not bypassed through a stream.
- The syntax (400 `bad_glob`): one line of 1..512 bytes, UTF-8, no control
  character; absolute or `$HOME/`; `*` and `?` only, and only in the last
  segment; no `[`, `{`, `**`, no `.` or `..` segment. `key` matches
  `^[a-z0-9][a-z0-9-]{0,23}$` (24, so a match key fits 3.2's 32, 3.8.6) and
  is unique among W's live globs on that box (409 `glob_key_taken`).
- The glob's literal directory must be under one of the box's announced
  folders, compared as strings after `$HOME/` is kept unexpanded on both
  sides: else 400 `outside_folders`, the text naming the folders. Advisory
  only (3.8.1): a glob that passes here can still be refused on the box.
- At most `env.hub.file_streams.globs_per_box` (default 8, one per stream
  slot) live globs a box: 409 `too_many_globs`.

#### 3.8.4 Hub storage

One migration (the next free number at build time, after `0239`), owner and
runtime split, FORCE RLS with the NULLIF tenant policy and its test, as
every tenant table (developer guide 2.6.4):

- `file_stream_globs (tenant_id, id uuid, box_id, key, glob, created_by,
  created_at, removed_at, box_state, box_reason, matched, followed,
  over_cap, reported_at)`, unique `(tenant_id, box_id, key)` where
  `removed_at IS NULL`.
- `file_stream_glob_audit (tenant_id, id uuid, glob_id, box_id, action
  add|remove|refused, key, glob, actor, reason, at)`, key `(tenant_id,
  at)`.

#### 3.8.5 How a glob reaches the box: the box pulls

There is still no hub-to-box command channel (D1). The follower asks:

- a new lane op `file_streams_globs` (`wire/file_streams.go:31-34` gains the
  constant), payload `{}`, sent through the same verb as announce and push,
  `spool file-streams push --json -` (`cli/file_streams.go:78-110` gains the
  op). The ack is `{type: ack, globs: [{id, key, glob}]}`: the live globs of
  the session's box in the session's workspace. The box and the workspace
  are the session's, never the frame's (2.2; the strict decoder refuses a
  field it does not know, C46).
- At process start, then every `globs_s` (cnf `env.box.file_streams.globs_s`,
  default 30). Each hub env has its own follower (3.1), so a prd glob is
  followed and pushed only to prd.
- Fail closed: a failed pull keeps the last list for at most
  `globs_stale_s` (default 600); past it the box stops following every
  web-glob stream, sends one `-- glob list stale --` marker on each, and
  resumes on the next good pull. The list is not saved across a restart, so
  a deleted glob never outlives the process. cnf `allow` streams are not
  touched by any of this.
- The announce frame `FileStreamsAnnounceFrame` (`wire/file_streams.go:71-73`)
  gains `folders: [{path, state, reason}]` and `globs: [{id, state, matched,
  followed, over_cap, reason}]`; the stream entry `FileStreamAnnounced`
  (`:64-68`) gains `glob_id`; the decoder `DecodeFileStreamsAnnounce`
  (`:132`, strict through `strictDecode` `:122-126`) checks them. The hub
  stores the glob fields on the `file_stream_globs` row (3.8.4). Because the
  decoder is strict, the hub row (B9) lands and deploys before the box row
  (B10) sends them.

#### 3.8.6 How the box expands a glob

Every `glob_scan_s` (default 10 s, not every 2 s tick), per glob:

1. Re-check the syntax of 3.8.3 (the box never trusts the hub's check):
   else `refused` `bad glob`.
2. Expand `$HOME/`; open the literal directory `O_PATH | O_DIRECTORY |
   O_CLOEXEC`; its `/proc/self/fd/N` real path must be under a folder root's
   real path (3.8.2) and pass `spl_file_stream_denied`
   (`file-stream-follow.py:224-252`): else `refused` `outside allowed
   folders` or `denied path`. A directory inside a folder that is a symlink
   out of it is refused here (C48).
3. List that fd's entries, at most `glob_scan_max` (default 10 000) read, so
   a directory of a million files does not stall the tick (C52); match the
   last segment with `fnmatch`, where `*` and `?` never match a leading `.`.
   A name ending `.gz`, `.xz`, `.zst`, `.bz2`, `.lz4`, `.zip` or `.Z` is
   skipped as `compressed` (a rotated `auth.log.2.gz` is binary, and denied
   besides, 3.8.10).
4. Each match is opened with `open_checked` on every open and reopen (3.2,
   unchanged: O_PATH, the deny list on the fd's real path, `S_ISREG`,
   `st_nlink == 1`, dev and inode compared on the read reopen), and its fd's
   real path must also be under a folder root: a match that is a symlink out
   of the folder is refused `outside allowed folders`.
5. Its stream key is `<key>-<first 6 hex of sha256(real path)>`, stable
   across scans and restarts; a key equal to a cnf `id` on that box is
   refused `key taken` (the cnf wins).
6. From there it is a stream like any other: 3.1's `tail -F` rules, the
   masking and the PEM state, 3.7's limits.

The glob's state: `following` (every match followed), `partial` (some over
the cap or refused), `none` (no match yet; it is re-scanned), `refused` (the
glob itself, with its reason).

#### 3.8.7 Over the 8-stream cap

Q6 A, decided (msg `369e7bfa`, 7.1): every match is its own stream. The
cap stays 8 streams a box, cnf and web globs together
(`FILE_STREAMS_MAX`, `file-stream-follow.py:151-170`; the hub's
`streams_per_box`, 3.7). Slots go, in order: the cnf entries, in cnf order;
then the globs, oldest glob first; inside a glob, the newest match by mtime
first. A followed match keeps its slot while it exists and its glob is live,
so a busy directory does not swap streams every scan; a freed slot goes to
the next match in that order. A match past the cap is neither followed nor
announced as a stream (a glob over a large directory would flood the
announce); it is counted in `over_cap`, and the page shows "5 of 12 matches
followed (8 streams a box)". The hub still refuses an announced key past 8
(`streams_per_box`), as today.

#### 3.8.8 Removing a glob

`DELETE /v1/file-streams/globs/{id}` (the gate of 3.8.3) sets `removed_at`
and writes the audit row. The next pull omits it; within `globs_s` plus one
tick the box stops following its matches, and the next announce no longer
names their keys, which the hub turns `gone` (3.3); their lines stay until
retention (3.7). A glob of a box that stopped announcing stays listed under
that box until it is removed. Removing twice answers 404 and writes no audit
row.

#### 3.8.9 The audit

One `file_stream_glob_audit` row per add, remove and hub refusal of an add
(with its code: `bad_glob`, `outside_folders`, `too_many_globs`,
`glob_key_taken`, `box_locked`), carrying the actor's human id; an act-as
clone is refused before (3.8.3), so the actor is always the real person. A
refusal by the box is not an audit row: it is the glob's and the stream's
state and reason, as 3.2's refusals are. Rows are kept 365 days
(`env.hub.file_streams.glob_audit_retention`, 8760h), pruned by B6's
sweep. The page shows the newest 50 under the glob list.

#### 3.8.10 Security-related system files, denied by default

The owner's follow-up. Today `SYSTEM_FILES`
(`file-stream-follow.py:105`) is `/etc/shadow` and `/etc/gshadow`, plus
`/etc/ssh/ssh_host_*_key` (`:229`) and the roots `/proc`, `/sys`, `/dev`
(`:104`). Measured on `bf6991ecf`:
`python3 csi-spl-orc/src/bash/scripts/file-stream-follow.py --denied /etc/passwd`
-> exit 1 (not denied), the same for `/etc/group`, `/etc/sudoers` and
`/var/log/auth.log`; `/etc/shadow` -> `system secret`, exit 0. n = 1 each.

A new class in `spl_file_stream_denied`, reason `security file`. Because
every open runs through that function (3.2), it holds for cnf `allow`
entries, web-glob matches and folder roots alike:

| path | why |
|---|---|
| `/etc/passwd`, `/etc/group`, `/etc/passwd-`, `/etc/group-` | every account, uid, group membership, home and shell: the first map an intruder reads; the `-` files are their backups |
| `/etc/shadow-`, `/etc/gshadow-` | the backups of the hash files already denied |
| `/etc/subuid`, `/etc/subgid` (and their `-` backups) | the user namespace maps, by account name |
| `/etc/sudoers`, `/etc/sudoers.d/` | who may become root, and with which commands |
| `/etc/pam.d/`, `/etc/security/` | the login and auth policy; `/etc/security/opasswd` holds old password hashes |
| `/etc/ssh/` (the whole dir; today only the host keys) | `sshd_config` names who may log in and how |
| `/etc/ssl/private/`, `/etc/letsencrypt/` | TLS private keys (a `*.pem` is denied by name already; the dirs are denied whatever the name) |
| `/etc/krb5.keytab`, `/etc/sssd/`, `/var/lib/sss/` | domain credentials and their caches |
| `/etc/wireguard/`, `/etc/openvpn/`, `/etc/NetworkManager/system-connections/` | VPN keys and Wi-Fi passwords |
| `/etc/environment`, `/etc/crontab`, `/etc/cron.d/`, `/var/spool/cron/` | system env and crontabs, which often carry a token in an env line |
| under `/var/log/`: `auth.log*`, `secure*`, `btmp*`, `wtmp*`, `lastlog*`, `faillog*`, `audit/` | who logged in, from where, and failed logins, where a password typed at the user prompt is logged as the user name |
| `/var/log/journal/`, `/var/log/private/` | the binary journal (it holds the auth messages too) and the logs of services that run as a dynamic user |
| under `/var/log/`: `tallylog*`, `sudo.log*`, `sudo-io/`, `fail2ban.log*`, `sssd/` (v0.6, Q5 B opens `/var/log`) | failed-login counts, who ran what as root, sudo's session recordings (every keystroke, a typed password included), banned login sources, the domain auth daemon's log |
| under `/var/log/`: `pacct*`, `account/`, `installer/` (v0.6) | process accounting (every command of every user); the installer's answers (`cdebconf/questions.dat` may hold a password hash) |

- Q7 A, decided (msg `369e7bfa`, 7.1): no cnf key, `box.env` value or hub
  field lifts a security file. An exception lives only in code, each with
  its reason (as the dot-entry rule of 3.2), and none exists today.
- The class is a list of paths, and a list catches only what it names: a
  copy of `/etc/passwd` written into an allowed folder is a new file, and
  this class does not see it (`spool_redact` masks secrets in it, not
  account names). It narrows what is followed; it proves nothing absent.
- `token-burn-cron` (`/var/csi/csi-spl/token-burn/cron.log`), the one cnf
  entry, is in none of these and stays followed (C53).

#### 3.8.11 Owner questions

Answered (v0.6): Q5 B, Q6 A, Q7 A, HUM-10 msg `369e7bfa` on poll
`900699dd` (7.1), folded into 3.8.2, 3.8.7 and 3.8.10.

Only what answer B leaves open. The dispatch holder posts them in
`c168784c` as one form; the recommended answer is first.

```poll
Q5 Which folders may a typed glob reach, by default?
(A) Only the fleet's own box log folder, /var/csi/csi-spl (recommended)
(B) That folder and /var/log, minus the security files of 3.8.10
(C) None: ship the list empty, folders are added by a cnf commit later
Q6 One glob matches several files: what does the box follow?
(A) Every match as its own stream, newest first, up to 8 streams a box (recommended)
(B) Only the newest match, as a cnf entry's * does today
Q7 May a security file of 3.8.10 ever be followed?
(A) No: an exception only in code with its reason, none today (recommended)
(B) Yes: a per-box cnf key may lift one named file
```

Not asked, decided here (a reviewer may challenge each): a glob is for one
box, not for every box of the workspace (D6); any owner or admin of W may
remove any glob of W, not only its author (D7); the box pulls its globs
(3.8.5) instead of a new hub-to-box channel (D1 stands).

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
| C7 | B1 | a file whose mode bits say the agent user may read it but the open is denied (an ACL `user:<agent user>:---` on a mode 644 file), and a file whose mode bits say no but a group read grants it: the first is `refused` (`unreadable`), the second is followed | decide by a mode-bit check instead of the open: the ACL'd file is followed (and its open fails mid-tick) and the group-readable one is refused |
| C8 | B1 | each deny-list class (3.2), and a symlink to a synthetic `$HOME/.ssh/id_x` placed in an allowed dir at start, is refused although allow-listed | the deny check on the name, not on `/proc/self/fd/N`: the symlink is followed |
| C9 | B1 | lines with `ghp_`, `Bearer`, `JIRA_API_TOKEN=` and `password:`, and a synthetic 4-line PEM key written line by line in one tick, reach the push frame AND the queue file masked (no base64 body line of the key in either), with counts in `redactions` | per-line `redact()` with no PEM state: the BEGIN line is masked, the body and END lines reach the queue file (c-317's measurement); also queue before redact: the token is in the queue file |
| C10 | B1 | the hub is down for 3 ticks, then up: every line arrives once, in seq order | drop on a failed push: a gap |
| C11 | B2 | a push from box B pinned in W stores rows in W only; the frame cannot name another box or tenant | the box taken from the frame: rows land under the named box |
| C12 | B3 | a member (not owner or admin) of W: 403 on all three routes; owner and admin: 200 | a membership-only gate: the member gets 200 |
| C13 | B3 | the owner of W1 asks for W2's stream id: 404, the body names nothing of W2 (cross-tenant, as `crosstenant_test.go:122`) | read by id without the tenant: W2's lines |
| C14 | B4 | `in:file-streams token` and `channel:file-streams token` = stream lines only; `in:#file-streams token` and `channel:#file-streams token` = the channel named file-streams | strip `#` first (today's `channelValue`): all four are the channel |
| C15 | B4 | a plain `/s token` returns no stream line | `TypeFileLine` in `DefaultTypes`: it does |
| C16 | B4 | a member's `in:file-streams x` answers 200, no line, `notices: ["file_streams_staff_only"]` | no gate on the section: lines reach a member |
| C17 | B4 | W1's owner searches `in:file-streams <W2 marker>`: nothing of W2 | the section without the tenant scope: W2's line |
| C18 | B5 | the tab is drawn for an owner or admin, not for a member, and not for an operator who is neither owner nor admin of W; Lanes is still drawn for that operator (unit, as `monitoring-tabs.test.mjs`) | `staff` without `staffOnly`: the operator sees a tab its routes answer 403 |
| C19 | B5 | e2e: pick box and file; a line the stub appends shows within 2 polls; Pause sends 0 requests in 10 s; Resume shows "N new lines" | the poll ignores Pause: requests continue |
| C20 | B5 | e2e: scrolling up turns Follow off; "Jump to latest" turns it on | always scroll: the reader cannot read back |
| C21 | B5 | a search result opens the tab at that line, Follow off | a link without `seq`: lands at the bottom |
| C22 | B6 | the sweep prunes lines past retention and over the workspace cap, oldest first | no sweep: the row count only grows |
| C23 | B2 | a push over the limits of 3.7 gets 413 or the `dropped` marker, never a partial store | store first, check after: half a frame stored |
| C24 | B7 | the time of `in:file-streams` over 500 000 lines of one workspace on dev, n >= 5, the bytes per stored line (text + tsvector + indexes) and `SHOW max_connections`, recorded in 3.7 | n/a: a measurement; its check is the recorded n |
| C25 | B1 | a synthetic PEM key whose BEGIN and first body line land in tick 1 and the rest in tick 2 (the follower restarted between them): every line masked, one block counted | the PEM state kept in memory only, or not at all: tick 2's body lines are queued as written |
| C26 | B1 | a cut synthetic key, BEGIN and 250 base64 body lines, no END, then one plain log line: all 251 key lines masked (past the 200 cap, because pure base64), one `masked block cut at cap` marker, the plain line followed | a hard cap at 200: body lines 201-250 reach the queue file; or no cap: the plain line and every later one is masked forever |
| C27 | B3 | an act-as clone of an owner of W: 403 on all three routes | the gate on `TenantOwner` only: the clone inherits the owner's 200 |
| C28 | B3 | the operator service account: 403 on all three routes | an operator bypass on the gate: 200 |
| C29 | B3 | a box session of a box pinned in W: 403 on all three read routes; its announce and push still pass | the read routes accept any W session: the box reads lines |
| C30 | B2 | `file_streams` and `file_stream_lines` are FORCE RLS with the NULLIF tenant policy: a statement without a tenant reads 0 rows, the runtime role cannot bypass (`rls_test.go` covers both tables) | a table without FORCE RLS: `TestRLSCoversEveryTenantTable` fails, and the tenantless read returns rows |
| C31 | B1 | a followed file is rotated and the new file at its name is a symlink to a synthetic `$HOME/.ssh/id_x`: refused on the reopen, nothing of it read | the deny check run only at first open: the symlink is followed after the rotation |
| C32 | B1 | an allow-list glob whose newest match becomes a symlink into a denied place: refused on the switch, the old match's stream ends with a marker | the deny check on the glob's name: the symlink is followed |
| C33 | B1 | a hardlink (same dev and inode) to a synthetic key file, made in an allowed dir under an allowed name: refused `hardlink` | `realpath` only: the link's name is allowed, its content is followed |
| C34 | B1 | allow-list entries for a `$HOME/.config/x.log`, another user's home, a `.env`, a `*_history` and a synthetic `/etc/ssh/ssh_host_x_key`: each refused `denied path` | v0.1's named list: `$HOME/.config/x.log` and the host key are followed |
| C35 | B1 | the follower started with an empty env (no `SPOOL_ROOT`, as under cron) and an allow-list entry under a synthetic default spool root's inbox: refused `denied path`; a resolved root that is not a directory: the follower does not start | the deny entry taken from `$SPOOL_ROOT` only: empty under cron, the inbox file is followed |
| C36 | B1 | an allow-listed name that is a symlink to a fifo with no writer, and to a character device: refused, the follower's tick is not blocked, no read open of the target happens (traced with `strace -e openat`: only an `O_PATH` open) | a plain `O_RDONLY` open first: the fifo open blocks the tick (without `O_NONBLOCK`) and the device's driver open runs |
| C37 | B1 | one line holding a whole synthetic key (BEGIN, body and END escaped in one JSON line), then 3 plain lines: the key line masked, the 3 lines followed unchanged | open the block on any BEGIN: the 3 plain lines are masked |
| C38 | B2 | workspace A's boxes push 3x its byte cap while workspace B holds lines inside its own caps: B's line count and oldest line are unchanged; A never exceeds its cap by more than one push | v0.2's hub-wide prune across workspaces: B's oldest lines are deleted |
| C39 | B8 | e2e: the page lists every box and, under it, each stream the hub returned as a row with its own `tail -f` button; no view is open before a click | the two selects of B5: no row, no button |
| C40 | B8 | e2e: `tail -f` on one row shows only that stream's lines, in one view under its row, the open file in the URL; a reload keeps it open; `tail -f` on another row moves the one view there; Back opens the file before | one merged pane, or the view opened on the first file without a click: another stream's lines, or a view before the click |
| C41 | B9 | a member of W: 403 on POST, GET and DELETE of globs; an owner and an admin: 201 / 200 / 204; an act-as clone of an owner, the operator service account and a box session: 403 | a membership-only gate: the member's POST is 201 |
| C42 | B9 | W1's owner POSTs a glob for a box of W2 only, and DELETEs W2's glob id: 404 both, the body names nothing of W2 | `box_id` taken from the body unchecked: the glob is stored for W2's box |
| C43 | B9 | each bad glob of 3.8.3 (relative, `**`, `*` in a directory, `[`, `{`, a `..` segment, a control character, 513 bytes) is 400 `bad_glob`; a bad or taken key 400 / 409; a 9th live glob on one box 409 `too_many_globs`; a glob outside the announced folders 400 `outside_folders` | accept any string: each is 201 |
| C44 | B9 | a box under an owner lock: an admin who is not a lock owner gets 403 `box_locked`; a lock owner gets 201 | no lock check: the admin's glob is 201 |
| C45 | B9 | an add, a remove and one refused add each write one audit row with the actor and the reason code; a second DELETE of the same glob is 404 and writes none | audit on success only: the refused add leaves no row |
| C46 | B9 | the `file_streams_globs` pull of box B's session in W returns B's live globs in W only (not another box's, not a removed one); a frame naming a box or a tenant is `bad_file_stream` | the box taken from the frame: another box's globs come back |
| C47 | B10 | folders `[<tmp>/a]`: a glob `<tmp>/a/*.log` follows its matches; a glob `<tmp>/b/*.log`, relayed by a stub hub that accepts anything, is refused `outside allowed folders` on the box | the box trusts the hub's check: `<tmp>/b/x.log` is followed |
| C48 | B10 | inside folder `<tmp>/a`, a dir `out -> <tmp>/b` and a glob `<tmp>/a/out/*.log`: refused; a match `<tmp>/a/y.log -> <tmp>/b/y.log`: refused `outside allowed folders` | the folder check on the glob's text, not on the fd: both are followed |
| C49 | B10 | C8, C31, C32, C33, C34 and C36 re-run with the entry made by a glob match, not a cnf entry: a match that is a symlink to a synthetic `$HOME/.ssh/id_x`, a hardlink to a key file, a fifo, a device, a `.env`, another home: each refused with 3.2's reason, nothing read | a match opened with a plain open, skipping `open_checked`: the key's lines reach the queue file |
| C50 | B10 | 2 cnf entries and a glob matching 12 files: 6 matches followed, newest mtime first; the glob reports `matched 12, followed 6, over_cap 6`; touching an older unfollowed file does not take a followed one's slot | no cap: 12 announced, the hub refuses 6 as `streams_per_box` and the newest may be among them |
| C51 | B10 | the glob removed on the stub hub: within `globs_s` + 1 tick its streams leave the announce; the stub hub down past `globs_stale_s`: each web-glob stream stops with one `glob list stale` marker while the cnf stream keeps pushing | keep the last list for good: a removed glob is followed while the hub is down |
| C52 | B10 | a matched dir of 50 000 entries: one scan reads at most 10 000, no tick takes more than 1 s; `x.log.2.gz` under a `*.log*` glob is skipped `compressed` | `glob.glob` over the whole dir: the tick blocks, and the `.gz` is followed as text |
| C53 | B11 | `--denied` prints `security file` for each path of 3.8.10's table (`/etc/passwd`, `/etc/group`, `/etc/sudoers.d/x`, `/etc/security/opasswd`, `/etc/ssh/sshd_config`, `/var/log/auth.log.1`, `/var/log/btmp`, `/var/spool/cron/crontabs/x`, ...); as cnf entries each is announced `refused` (`denied path`); `/var/log/syslog` and `/var/csi/csi-spl/token-burn/cron.log` are not denied | today's list: `--denied /etc/passwd` exits 1 (measured on `bf6991ecf`, 3.8.10), so `/etc/passwd` is followed |
| C54 | B10 | folder entries `/`, `/etc`, `/etc/ssh`, `$HOME/.config` and `/proc/x` are each announced `refused`, and no glob under them is followed | no folder check: a glob `/etc/ssh/*` reaches `open_checked` and only the per-file list stands between it and the file |
| C55 | B12 | e2e on the mock: an owner or admin sees "Add a file glob" under each box and no operator who is neither does (C18's rule); the form sends `{box_id, key, glob}` only; a hub 400 shows its code's text key; a glob row shows its state and "N of M matches followed"; Remove asks first, then calls DELETE | the form drawn on `who.operator`: the operator sees a form the hub answers 403 |
| C56 | B12 | every new text key is in `en.json` and every locale (`i18n-parity`), and agy reviewed them before they ship (language rule) | a key in `en.json` only: `i18n-parity.test.mjs` fails |

## 5. Build rows

Each row is one lane and one issue, with its tests and red controls in the
same commits; each lands after its own review PASS and the dispatch
holder's GO. Order: B1 and B2 may run in parallel (3.3's frames are their
contract); B3, B4 and B6 after B2; B5 after B3; B7 after B4 and B6.

| row | scope | paths | cases |
|---|---|---|---|
| B1 | box follower, deny list, open-then-check, PEM state, masking, cron row | `orc/run/spl-file-stream-follow.func.sh`, `orc/scripts/file-stream-follow.py`, `orc/scripts/file-stream-follow-cron.sh`, `csi-spl-orc/cnf/box-crons/box-crons.manifest`, cnf `env.box.file_streams`, `orc/tests/spl-file-stream-follow.tst.sh` | C1-C10, C25, C26, C31-C37 |
| B2 | frames, push verb, migration, store, push handler, limits | `wire/file_streams.go`, `cli/file_streams.go`, `rdb/<next>_file_streams.sql`, `store/file_streams*.go`, `hub/file_streams.go` | C11, C23, C30, C38 |
| B3 | read routes, RBAC | `hub/file_streams_view.go`, `hub/crosstenant_test.go` | C12, C13, C27-C29 |
| B4 | the search scope and the `notices` field | `search/grammar.go`, `search/values.go`, `store/search_postgres.go`, `hub/search.go` (the answer at `:173-174` gains `notices`), `wui/utils/search.mjs`, `wui/utils/search-results.mjs`, `wui/pages/search.vue` | C14-C17 |
| B5 | the WUI tab, `staffOnly` | `wui/utils/monitoring-tabs.mjs`, `wui/pages/monitoring/file-streams.vue`, i18n locales, e2e | C18-C21 |
| B6 | the retention sweep | `store/file_streams_postgres.go`, `hub/file_streams.go` | C22 |
| B7 | measure the limits on dev, set the defaults in cnf | cnf `env.hub.file_streams`, this spec 3.7 | C24 |
| B8 | the File streams page as a list per box, a `tail -f` button per file (3.5 List) | `wui/pages/monitoring/file-streams/index.vue`, `wui/utils/monitoring-file-streams.mjs`, i18n locales, `i18n-keep-english.json`, e2e | C39, C40 |

Docs: each row updates this spec's status line; B5 adds the tab to the
Monitoring help page and B4 the syntax to the search help
(`csi-spl-doc/doc/help/`).

### 5.1 Row B1 as built (SPL-3820)

- Code: `orc/scripts/file-stream-follow.py` (follower, deny list
  `spl_file_stream_denied`, `open_checked`, PEM state), the action
  `do_spl_file_stream_follow` (`orc/run/spl-file-stream-follow.func.sh`:
  reads cnf `env.box.file_streams`, runs the follower as the first
  `spl_cost_agent_users` user, `sudo -n -H -u` when that is not the caller),
  the cron wrapper `orc/scripts/file-stream-follow-cron.sh` and the manifest
  row `file-streams` (every minute; the follower's flock makes a start while
  one runs exit 0).
- Off until B2: cnf `env.box.file_streams.enabled: false`, so the cron row
  logs one `file-streams: off` line a minute and opens no file. The test
  fails while `enabled` is not false and no `file_streams_push` is under
  `csi-spl-api/src`; it retires itself when B2 lands. The allow-list ships
  with the owner's Q1 A file, `token-burn-cron` =
  `/var/csi/csi-spl/token-burn/cron.log`.
- Tests: `orc/tests/spl-file-stream-follow.tst.sh`, cases C1-C10, C25, C26,
  C31-C37, each run on the follower and on a copy with one planted defect,
  which must go red (the control). C7 uses the owner and other mode bits
  (`0044` refused, `0400` followed): a test cannot make a file another user
  owns without root, so the ACL form of 4 is not run. C36's `O_PATH`-only
  check uses strace when the box can trace, else it checks only that the
  tick is not blocked.
- Beyond 3.1/3.2, all stricter: the deny list also refuses `inbox/` and
  `outbox/` segments, the follower's own state dir, and the cnf
  `spool_root`, `workspace_base`, `fleet_workspace_base` and
  `$SPL_STATE_DIR/desk`; first sight runs the PEM state over up to 1 MiB
  above its start, so a key whose BEGIN is above the last 200 lines still
  masks its body; the announce sends the cnf path (`$HOME/` unexpanded), not
  the resolved one; the tick line is logged on a change, else every 300
  ticks.
- For B2: the push runs `timeout 20 spool file-streams push --json -` as
  the agent user, the frame on stdin, an ack is a stdout JSON line with
  `"type": "ack"` (then the frame's lines leave the queue). Which hub
  session the agent user's push rides (the token burn pushes as the box
  owner's desk, `spl_token_burn_spool`) is B2's to settle;
  `FILE_STREAMS_PUSH_CMD` replaces the command.

### 5.2 Row B2 as built (SPL-3888)

- Code: `wire/file_streams.go` (the two frames, `DecodeFileStreamsAnnounce`,
  `DecodeFileStreamsPush`), `cli/file_streams.go` (`spool file-streams push
  --json <file|->`: reads a follower frame, sends its lane payload, prints
  the ack as one JSON line of type `ack`), rdb
  `0237_file_streams.sql` (the next free prefix at push time;
  renumbered at each rebase if another lane lands first),
  `store/file_streams.go` (the contract and the shared rules),
  `store/file_streams_memory.go`, `store/file_streams_postgres.go`,
  `hub/file_streams.go` (lane ops `file_streams_announce` and
  `file_streams_push`, routed from `hub/box_lane.go`).
- The box and the workspace are the session's: the decoders refuse any
  field they do not know, so a frame naming a box or a tenant is
  `bad_file_stream` (C11). A push stores nothing when refused (C23): 413
  `too_large` past 1000 lines or the byte cap, 429 `rate_limited` when a
  minute of the stream would hold more than twice the line rate (counted
  after the insert inside the push's transaction, so a re-sent seq never
  counts twice, then rolled back), 409 `not_announced`, 403 `refused` for a
  stream the hub refused at announce.
- **The frame size is 448 KiB, not 1 MiB.** The hub's socket reads at most
  512 KiB a frame (`hub/ws.go` `maxFrameBytes`), so the CLI splits a
  follower frame (up to 1 MiB, 3.7) into parts of at most
  `wire.FileStreamPushMaxBytes` = 448 KiB and 1000 lines, in seq order;
  `dropped` and `redactions` ride the first part only. The hub keys on
  `(tenant, stream, seq)`, so a part re-sent after a failure is acked and
  not stored twice.
- **The caps at insert** (3.7, N2, C38): `file_streams` keeps
  `lines_kept` and `bytes_kept` per stream, updated in the push's own
  transaction, so the workspace's totals are a sum over its few stream
  rows. Over a cap, the push deletes the workspace's own oldest lines (by
  `at`, stream, seq; at most 1000 a statement, and for the byte cap only as
  many as the overshoot needs) in its tenant scope; never another
  workspace's.
- **Workspaces that stream** (`max_workspaces`): counted over the streams
  that are `following` or `missing`, inside the announce's transaction
  (the one operator-scope read, `fileStreamWorkspaces`, listed in
  `operatorCallers`); a 5th workspace's announce is stored and answered
  `refused` (`max_workspaces`) on every key. A refused-only list does not
  count. Keys past 8 per box are `refused` (`streams_per_box`).
- Times: a line older than the 7 days is acked and not stored; a line
  more than 2 minutes ahead of the hub's clock is stored at the hub's now.
- `dropped` and the redaction counts are added per push; a push re-sent
  after a lost ack adds them again (the lines are not stored twice). The
  hub's caps are `hub.Options.FileStreamLimits`, defaults in code until B7
  puts them in the cnf (done: `env.hub.file_streams`, 5.7).
- Not in B2: the follower stays off (cnf `enabled: false`); which hub
  session the agent user's push rides is settled when it is switched on.
- Tests: `wire/file_streams_test.go`, `store/file_streams_test.go` (memory
  and Postgres: C11, C23, C30, C38, the caps, the times, a push with no
  redactions), `store/crosstenant_test.go` (`seedTenantAll` seeds both
  tables, so `TestCrossTenantEveryTable` covers them),
  `hub/file_streams_test.go` (C11, C23 over the socket),
  `cli/file_streams_test.go` (the frame, the split, the refusals).

### 5.3 Row B3 as built (SPL-3888)

- Code: `hub/file_streams_view.go` (`routeFileStreams`, registered in
  `hub/server.go`; both routes in `hub/openapi.json`), and the store read
  `FileStreamLines(ctx, tenant, id, FileStreamLinesQuery{After, Before,
  Limit})` in `store/file_streams.go`, which replaces B2's
  `FileStreamLinesAfter`, in memory and in Postgres (the newest-first page
  is read `ORDER BY seq DESC LIMIT n`, then reversed, so a page is always
  oldest first).
- The gate, in this order: a member session (an operator service account
  or a box has none: 403), not a live act-as clone (403), then
  `TenantOwner || Has(rbac.Admin)` in W (403). The 403 body names
  `file_streams.staff`, which is a label, not an rbac permission. A store
  without file streams answers 501.
- The list carries three fields more than 3.4 names: `reason` (why a
  stream is `refused` or `missing`), `last_seq` (where the tab's first
  `after=` poll starts) and `lines_kept`.
- `after` and `before` together are 400; `after` < 0, `before` < 1 or
  `limit` < 1 is 400; `limit` above 1000 is read as 1000.
- C13 is tested in `hub/file_streams_view_test.go`, not in
  `crosstenant_test.go` as row B3 of the table says: another workspace's
  id is 404 `not_found` there, and the body names nothing of W.
- Tests: `hub/file_streams_view_test.go`: C12, the lines paging, C13, C27
  (Postgres only: the clone store), C28. C29 is tested as a call with no
  member session, which is what a box has on a view route; a box's own
  socket session asking a read route is not exercised. Red control for
  C27: with the clone check taken out, the clone reads all three paths 200.

### 5.4 Row B4 as built, the hub half (SPL-3888)

- Grammar 1.5 (`search/grammar.go`, `search/values.go`): the type
  `file_line` (group `file_lines`, alias `file_lines`), in `Types` and not
  in `DefaultTypes`. `in:file-streams` and `in:file-stream` (and the same
  after `channel:`), with no `#`, set `Term.FileStreams`, so the term
  applies to `file_line` only. Any other `in:` value applies to message,
  topic and file as before, and `in:#file-streams` is the channel. A
  negated `in:file-streams` is `400` (it picks the section, as `type:`
  does). `box:`, `name:` (the stream key) and `before:` / `after:` / `on:`
  apply to `file_line`; `from:`, `to:`, `topic:`, `is:` and `has:` do not.
- `store/search_file_lines_postgres.go`: `FileLineSearcher.SearchFileLines`,
  one statement in the tenant scope under the search budget. It joins
  `file_streams` with both tables pinned to the tenant, matches free text
  with `to_tsvector('spool_search', l.text)` and orders newest first, keyset
  `(at, stream_id, seq)`. The hub's own marker lines are never a hit.
  Postgres only, as the doc section: a hub on the memory store answers the
  section empty.
- **No index entry for the lines** as B4 built it: every `in:file-streams`
  search computed `to_tsvector(l.text)` for every line it read, up to the
  500 000-line cap per workspace (3.7), under the same search budget as
  any search, past which the answer is `503 search_budget`. Row B7
  measured ~15.6 s on dev, so the match is now on the stored
  `l.search_tsv` (5.7).
- `hub/search.go`: `fileLineSection` runs `fileStreamsStaffRefusal`, the
  read routes' gate (`hub/file_streams_view.go`). A refused caller gets the
  section `[]` and the notice `file_streams_staff_only`. Every answer
  carries `notices` (`[]` when empty). Contract: search-v1 sections 3.1,
  3.2, 4 and 4.11; `openapi.json` names the field.
- Tests: `search/golden_test.go` (C14's four spellings, the reserved word,
  applicability, the negation), `hub/search_file_lines_test.go`: C16 on
  any store; C14, C15 and C17 on Postgres. Red control for C16 (Postgres):
  with the gate taken out of `fileLineSection`, the member's
  `in:file-streams` returns W's two lines and no notice.
- The WUI half: `search-results.mjs` (group `file_lines` after `docs`, the
  row's line and highlights, a target
  `/monitoring/file-streams?box=&stream=&seq=` that a junk box, key or seq
  never builds, the answer's `notices` kept as stable codes only),
  `search.vue` (one muted line per notice, key `search.notice.<code>`),
  `search.mjs` (`in:` and `channel:` offer `file-streams`, `type:` offers
  `file_line`), the side list (box and stream key, the line's time). Keys
  `search.group.file_lines` and `search.notice.file_streams_staff_only` in
  every locale; agy reviews them before they ship.

### 5.5 Row B5 as built (SPL-3888)

- `utils/monitoring-tabs.mjs`: the tab `file-streams` after Lanes, with
  `staff: true, staffOnly: true`; `visibleMonitoringTabs` draws a
  `staffOnly` tab for `who.staff` alone, so an operator who is neither owner
  nor admin sees Lanes and not this tab (C18). The label key is
  `monitoring.tab.file_streams` (a key has no hyphen).
- `pages/monitoring/file-streams/index.vue`, its own chunk;
  `utils/monitoring-file-streams.mjs` holds the logic (pick, merge, find,
  the poll, the mock) and loads only from the page and the lazy client
  (`spool-client-lazy.mjs` `getFileStreams`, `getFileStreamLines`).
- The view: the newest `FS_FIRST` = 200 lines, then a poll of
  `after=<last seq>` every `FS_POLL_MS` = 3 s while the browser tab is
  visible and the view is not paused. At most `FS_VIEW_MAX` = 2000 lines
  (oldest dropped), one per seq. "Load older" reads `before=<first seq>`.
  A search hit (`?seq=`) reads the lines up to and after it, marks it and
  starts with Follow off (C21). A stream that is not `following` says so
  with its reason.
- The mock (lde and e2e): box-a `app` grows one line per poll, `cron`,
  box-b `web` missing; the mock answers 403 unless `spool.mock.me` is an
  owner or admin.
- Keys: `monitoring.tab.file_streams` and 16 under
  `monitoring.file_streams` in every locale, drafted by claude with each
  locale's existing words (Box, Load older, Resume); agy reviews them before
  they ship.
- Tests: `tests/unit/monitoring-tabs.test.mjs` (C18),
  `tests/unit/monitoring-file-streams.test.mjs` (the helpers, the poll's 0
  calls while paused or hidden, the mock),
  `tests/e2e/monitoring-file-streams.test.mjs` (C19, C20, C21 and a
  developer's 403 line, on the mock bundle). The mock answers in the page,
  so C19's Pause check is that the view gains no line in 10 s (a poll would
  add one per 3 s), not a request count.

### 5.6 Row B6 as built (SPL-3888)

- `store.FileStreamStore.SweepFileStreams(now, lim)`, Memory and
  Postgres. The one cross-workspace read is the list of the ids of the
  workspaces that keep lines (`file_streams.lines_kept > 0`, operator scope,
  listed in `store/operator_scope_test.go`). Everything else runs in each
  workspace's own scope (`sweepFileStreamTenant`): first its lines older
  than 7 days (`FileStreamsRetention`) are deleted, oldest first, 1000 a
  statement and one transaction per batch (`ix_file_stream_lines_tenant_at`),
  with the streams' `lines_kept` and `bytes_kept` lowered in the same
  statement. Then B2's `pruneFileStreamsToCaps` brings the workspace within
  its 500 000 lines and 256 MiB, which only a cap lowered in the cnf since
  the last push can still exceed.
- `hub/file_streams.go` `sweepFileStreams` runs on every sweeper tick
  (`RunSweeper`, `SweepInterval` 10 min), next to `sweepFleetTokens`, and
  logs only a pass that deleted something.
- Tests: `store/file_streams_test.go` `TestFileStreamSweep` (C22, memory
  and Postgres: an expiry, then a lowered cap, oldest first, counts in step,
  the other workspace whole). It drives the per-workspace step for its own
  two workspaces, because a whole-store sweep days ahead would delete other
  runs' lines in the shared Postgres test database.
  `hub/file_streams_sweep_test.go` (memory): a sweeper tick removes 8-day-old
  lines with no push. Red controls: an expiry that deletes nothing reads
  "A kept 6 lines from seq 1"; `RunSweeper` without the call keeps the 3
  lines and times out after 5 s.

### 5.7 Row B7 as built (SPL-3888)

- `csi-spl-orc` `do_spl_file_streams_measure` (ENV=dev only): `fill`
  (DRY_RUN=0) has a pinned probe box announce up to 8 keys
  `b7-measure-<n>` and push seeded synthetic log lines through `spool
  file-streams push`, the follower's own verb, each line's `at` spread over
  the last minutes at `MEASURE_RATE` (1000) a minute per key, under the
  hub's refusal at twice 600; `size`, `time` (`MEASURE_N` >= 5 runs of
  EXPLAIN ANALYZE of the hub's statement per word, `MEASURE_MATCH` tsv as
  the hub or text as before) and `conns` read through `do_spl_db_query`.
  The numbers are in 3.7. The lines stay on dev until the sweep removes
  them.
- The search fix the measure called for: `store/search_file_lines_postgres.go`
  `fileLineLeaf` matches a text term on the stored entry `l.search_tsv`
  (rdb 0237), as a message's `textMatch` does, never on
  `to_tsvector(l.text)`. No GIN index and no migration:
  `file_stream_lines` is FORCE RLS and `@@` is not LEAKPROOF, so the
  planner could not use one under the tenant policy (rdb 0122, 0143,
  0227), and the stored entry alone is ~35 times faster (3.7).
- Tests: `store/search_file_lines_test.go` (the statement matches on
  `l.search_tsv` and never calls `to_tsvector`, for a word, a phrase, a
  prefix and a negation; red control: the old leaf fails both checks) and
  `csi-spl-orc` `file-streams-measure.tst.sh` (the frames the hub takes,
  the refusals, the timing parse; red control: the fill at twice the rate).
- Its cnf (B7b): `csi-spl-cnf/csi-spl/all.env.yaml` `env.hub.file_streams`
  holds the hub's six caps of 3.7 (`per_box` 8, `max_workspaces` 4,
  `max_lines_per_workspace` 500 000, `max_bytes_per_workspace` 268 435 456,
  `rate_per_min` 600, `retention` 168h). The measure keeps the defaults: at
  700.2 bytes a stored line, 4 full workspaces take ~1.4 GB of the 10 GB
  disk. `do_spl_merged_cnf` derives `SPOOL_HUB_FILE_STREAMS_<KEY>` from each
  key (as `env.hub.embed`), `config.Hub` reads them and refuses a value
  below 1 or a retention below 1h, and `baseOptions` hands them to the hub
  as `hub.Options.FileStreamLimits`. The retention, a fixed 7 days in B6,
  is now `FileStreamLimits.Retention`, read by both sweeps. The values reach
  Cloud Run with the next apply of step 030 (its tfvars carry them); until
  then the hub runs the same defaults from code.
- Tests (B7b): `config_test.go` `TestLoadHubFileStreams` (defaults, each
  value below its floor refused), `hub_wiring_test.go` `TestBaseOptions`
  (the cnf defaults equal the store's `Norm`, a set value reaches the caps),
  `store/file_streams_test.go` `TestFileStreamSweepRetentionFromCnf`
  (memory and Postgres; red control: the fixed 7 days keeps the 2-day-old
  lines) and `csi-spl-iac` `hub-file-streams-030.tst.sh` (every key is
  derived, read by config.go and in the dev and prd 030 tfvars; control: a
  changed value is derived, a key with no hub field is caught).

### 5.8 Row B8 as built (SPL-4124)

- `pages/monitoring/file-streams/index.vue`: the two selects are gone. One
  `fs-group` per box (`fileStreamGroupsOf`, boxes in order, streams by key),
  one `fs-row` per stream with its key, path, state, last line time
  (`isoDateTime`), lines total and its `fs-tail` button (`aria-pressed` on
  the open one). The live view of B5 (Follow, Pause, Jump to latest, Find
  in view, Load older, the 3 s poll, a search hit) now sits under the open
  row; one file is open at a time.
- `utils/monitoring-file-streams.mjs`: `fileStreamOpenOf(query, streams)`
  replaces `fileStreamPickOf`: only an exact box and stream the hub
  returned, else nothing open (no fallback to the first file, so a typed or
  stale URL opens nothing). `fileStreamsOf` keeps `lines_total`. The mock's
  lines name their stream (`INFO cron mock line 3`) and carry
  `lines_total`, so C40 can tell two streams' lines apart.
- A click is `router.push` (Back opens the file before); pressing the open
  file's button again clears the query.
- Keys under `monitoring.file_streams`: `tail` (`tail -f`, kept English in
  every locale, listed in `i18n/i18n-keep-english.json` as a command name),
  `tail_title`, `last_line`, `lines_total`; `box` and `file` (the select
  labels) removed. Drafted by claude; agy reviews them before they ship.
- Tests: `tests/e2e/monitoring-file-streams.test.mjs` C39, C40 (and C18-C21
  on the open row), `tests/unit/monitoring-file-streams.test.mjs` (groups,
  the open file without fallback, the mock's stream-named lines, no
  `<select>` in the page). Red controls on origin/master `84b6d36cd`: the
  e2e reads `FAIL C39 every stream of every box is a row with a tail -f
  button []` and stops at `No element found for selector:
  [data-test=fs-row][data-stream=cron] [data-test=fs-tail]`; the unit file
  cannot import `fileStreamGroupsOf`.

### 5.9 Rows for answer B: web globs and the security files

B9 is built (5.10), B11 is built (5.11); the rest planned, not built yet. The format of the rounds rulebook
(`csi-spl-doc/doc/md/rounds-rulebook.md` 3.1). Every site was read on
origin/master `bf6991ecf`. Vendor: the data rule (a stream carries box
logs: claude, grok or mistral, never agy or qwen) and the owner's rule of
2026-10-17 (no mistral coding or testing lane) leave claude as main and
grok as backup for every row; a WUI row never goes to mistral either. Each
row is one lane and one issue, after the owner's answers to Q5..Q7.

| row | what | sites (sha `bf6991ecf`) | red control | measure after | vendor | kind | batch |
|---|---|---|---|---|---|---|---|
| B9 | hub: glob store and migration, the four routes and their gate, the `file_streams_globs` pull op, the announce's new fields, the audit | `hub/file_streams_view.go:36-39,65-72`; `hub/file_streams.go:54-70`; `wire/file_streams.go:31-34,64-68,71-73,122-126,132`; `store/file_streams.go:130-136`; `hub/box_lock_view.go:140`; new `rdb/<next>_file_stream_globs.sql` | C41: a membership-only gate gives the member 201; C42-C46 as in section 4 | `go test ./internal/hub/ ./internal/store/ ./internal/wire/ -run 'FileStreamGlob'`; `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (a migration) | claude (backup grok) | complex_coding | 1 |
| B11 | the `security file` deny class of 3.8.10 | `orc/scripts/file-stream-follow.py:92-105,224-252`; `orc/tests/spl-file-stream-follow.tst.sh` | C53: `--denied /etc/passwd` exits 1 on master today | `--denied <path>` prints `security file` for each row of 3.8.10's table; `bash orc/tests/spl-file-stream-follow.tst.sh` green | claude (backup grok) | complex_coding | 1 |
| B10 | box: `folders` cnf, the pull, the expansion through fds, the cap order, the stale rule | `orc/scripts/file-stream-follow.py:140-191,262-298,565-579,626-653`; `orc/run/spl-file-stream-follow.func.sh:89,187-205`; `csi-spl-cnf/csi-spl/all.env.yaml:1159-1174`; `cli/file_streams.go:78-110` | C47: a box that trusts the hub's folder check follows `<tmp>/b/x.log`; C48-C52, C54 | `bash orc/tests/spl-file-stream-follow.tst.sh` (each case on the follower and on its planted defect); `ENV=dev ./run -a do_tpl_gen` + `git diff --exit-code` (cnf) | claude (backup grok) | complex_coding | 2 (after B9: the pull op and the strict announce; after B11: same `.py`) |
| B12 | WUI: the glob form, list, state and Remove under each box; the audit list; the help page line | `wui/pages/monitoring/file-streams/index.vue:28-45`; `wui/utils/monitoring-file-streams.mjs:30-78`; `wui/utils/spool-client-lazy.mjs:1760-1779,2080`; `csi-spl-wui/i18n/locales/en.json:3307-3311` and every locale | C55: the form drawn on `who.operator`; C56: a key in `en.json` only | `pnpm run typecheck`; `BASE_URL=<mock bundle> pnpm run test:e2e`; agy review of the keys before land | claude (backup grok; never mistral, a WUI row) | complex_coding | 2 (after B9: its routes; disjoint from B10's files) |

Docs: B9 adds the routes to `hub/openapi.json`; B12 adds the glob form to
the Monitoring help page (`csi-spl-doc/doc/help/`); each row ticks its
status line here.

Status: B9 built (SPL-4294, section 5.10). B11 built (SPL-4321, section
5.11). B10, B12 planned.

### 5.10 Row B9 as built (SPL-4294)

- `rdb/0242_file_stream_globs.sql`: `file_stream_globs` and
  `file_stream_glob_audit` as 3.8.4, plus `file_stream_folders`
  `(tenant_id, box_id, path, state allowed|refused, reason, reported_at)`:
  the folders a box last announced, which 3.8.3's `outside_folders` check
  and the page read (3.8.4 named no home for them). A glob's `box_state` is
  `pending` until the box first reports it. All three FORCE RLS with the
  NULLIF tenant policy (`TestFileStreamGlobRLSTenantless`, seeded in
  `crosstenant_test.go`).
- `wire/file_stream_globs.go`: the op `file_streams_globs` (payload `{}`
  only; a field, `null` or a second value is `bad_file_stream`), its ack
  `globs: [{id, key, glob}]` (always a list), the syntax check of 3.8.3
  (`CheckFileStreamGlob`) and the string folder check
  (`FileStreamGlobUnder`). The announce gains `folders`, `globs` and a
  stream's `glob_id`, all optional: an announce without them (a box before
  B10) decodes as before and changes no glob or folder row; `folders: []`
  clears the box's folders.
- `hub/file_stream_globs.go`: the four routes of 3.8.3 behind
  `fileStreamsCaller` (the read routes' gate, now shared). A POST checks, in
  order: the box announced in W (else 404), the box lock (403 `box_locked`),
  the syntax (400 `bad_glob`), the key (400 `bad_key`, not audited: a
  malformed request), the announced folders (400 `outside_folders`), then
  in the store under a per-box advisory lock a taken key (409
  `glob_key_taken`) and the cap (409 `too_many_globs`,
  `SPOOL_HUB_FILE_STREAMS_GLOBS_PER_BOX`, default 8). The audit list is
  newest first, `limit` 1..500 (default 50), `before` an RFC 3339 time
  (`next_before` on a full page). Audit rows past
  `SPOOL_HUB_FILE_STREAMS_GLOB_AUDIT_RETENTION` (8760h) are pruned by the
  file streams sweep. The two keys are hub env with their defaults; the cnf
  `env.hub.file_streams` does not set them yet.
- Tests: `go test ./internal/hub/ ./internal/store/ ./internal/wire/ -run
  'FileStreamGlob'`, memory and Postgres 16. C41 `TestFileStreamGlobRBAC`,
  `TestFileStreamGlobOperatorSA`, `TestFileStreamGlobActAsClone`; C42
  `TestFileStreamGlobCrossTenant`; C43 `TestFileStreamGlobRefusals`,
  `TestFileStreamGlobSyntax`; C44 `TestFileStreamGlobBoxLock`; C45
  `TestFileStreamGlobAudit`; C46 `TestFileStreamGlobPull`,
  `TestFileStreamGlobPullFrame`. Each case's planted defect and its red run
  are in the commit body.

### 5.11 Row B11 as built (SPL-4321)

- `orc/scripts/file-stream-follow.py`: `SECURITY_FILES` (exact paths),
  `SECURITY_ROOTS` (dirs, denied with everything under them) and
  `SECURITY_LOGS` (names matched with `fnmatch` against the first segment
  under `/var/log`, so `auth.log.2.gz`, `wtmp.db` and `journal/x/...` are
  caught), read by `security_file()`. `spl_file_stream_denied` returns
  `security file` right after `system secret`, so `/etc/shadow` and the ssh
  host keys keep their reason. Every open runs it (3.2), so a cnf entry and,
  from B10, a glob match are both refused `denied path`.
- The 3.8.10 table gained `/etc/subuid-`, `/etc/subgid-`, `/etc/crontab` and
  the `/var/log` names Q5 B makes reachable (`tallylog*`, `sudo.log*`,
  `sudo-io/`, `fail2ban.log*`, `sssd/`, `pacct*`, `account/`, `installer/`).
  A list names only what it names (3.8.10): a security file under another
  name is not seen.
- Test C53 in `orc/tests/spl-file-stream-follow.tst.sh`: `--denied` prints
  `security file` for 46 paths, one or more per table row; `/etc/passwd`
  and `/etc/group` as cnf entries are `refused denied path` and no line of
  them is pushed or queued; `/var/log/syslog`, `/var/log/dpkg.log`,
  `/var/log/csi-spl/x.log` and the token-burn cron log are not denied. Red
  control `no-security-class` (the class switched off): red. On the
  follower before B11 C53 is red: `--denied /etc/passwd` exits 1 and an
  `/etc/passwd` cnf entry is `following`.

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
- **D6 A web glob is for one box** (3.8.3), not for every box of the
  workspace: each box has its own folders and its own 8 slots.
- **D7 Any owner or admin of W may remove any glob of W** (3.8.8), not only
  its author: the audit row keeps who did what.

## 7. Owner questions

The dispatch holder posts them in `c168784c` as one form; the recommended
answer is first.

**Q1 changed in v0.2** (review W9). v0.1 recommended "the box desk's own
log". Its real path, from the code on `e4455240d`:

- `orc/run/spl-dispatch-lease.func.sh:1840-1847`: the desk dir is
  `$SPL_STATE_DIR/desk/<tenant>/<box>`, its log `$d/spool/.hub/hub-run.log`;
  the same path in `orc/run/spl-desk-up.func.sh:374,440,443`.
- `orc/run/spl-desk-up.func.sh:174,203`: that desk runs with
  `SPOOL_ROOT="$d/spool"` and `SPOOL_KEYS_DIR="$d/keys"`, so the log sits
  inside a spool root, beside the desk's keys.
- `SPL_STATE_DIR` defaults to `$HOME/.local/share/<org-app>/cloud/<env>`
  (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:136`).

So it is denied three times by 3.2 (a spool root, the desk dir, and
`$HOME/.*`), and v0.1's answer A would have streamed nothing. The new A is
a box cron log outside the home and every spool root: the token burn
collector's tick log, `token-burn/cron.log` under `BOX_CRONS_STATE_DIR`
(default `/var/csi/csi-spl`, `orc/run/install-box-crons.func.sh:31`;
manifest row `csi-spl-orc/cnf/box-crons/box-crons.manifest:33`). Why that
one: it is written every minute (a live stream to see), its lines are tick
summaries rather than message bodies, and B1's tests can write a synthetic
file of the same shape. Unchecked: whether the agent user can read it on
each box (the box owner's crons write it); if not, the open refuses it and
the tab shows `refused`, which is the design, not a leak. This lane opened
no real log.

```poll
Q1 Which file should a box follow first?
(A) The box's token-burn cron log, a minute tick log outside the home (recommended)
(B) The box's system journal, exported to a file
(C) None yet: ship with an empty list, I add files later
Q2 Whose box streams into which workspace?
(A) The box's own workspace, the one it is pinned in (recommended)
(B) Also let a customer workspace see an operator box's streams
Q3 How long are stream lines kept for the search?
(A) 7 days, at most 500 000 lines per workspace (recommended)
(B) 30 days, at most 2 000 000 lines (needs a bigger disk)
(C) 24 hours
Q4 GO to build rows B1..B7 in the order of section 5?
(A) GO
(B) Not yet
```

### 7.1 The owner's answers

Four answers, all from HUM-10 in `c168784c`, read on prd with
`do_spl_db_query` (`messages.received_at`, n = 1 read each):

| msg | poll | at (UTC) | answers |
|---|---|---|---|
| `44ec2e44` | `a1ada7ba` (the v0.3 form) | 2026-10-27 10:02 | GO; Q1 A the token-burn cron log; Q2 A; Q3 A |
| `5c6686f2` | `75d8db39` (the v0.1 form) | 2026-10-27 16:26 | GO; Q1 A "The box desk's own log"; Q2 A; Q3 A |
| `1a5ce9f1` | `f5bc82a1` (the Q1 poll) | 2026-10-28 13:26 | Q1 A: keep the token-burn cron log, as built; the key-folder rule stays with no exception |
| `369e7bfa` | `900699dd` (the Q5..Q7 form, 3.8.11) | 2026-10-29 11:40 | Q5 B "That folder and /var/log, minus the security files of 3.8.10"; Q6 A; Q7 A |

Folded:

- **Q4 GO**: rows B2..B7 are built in the order of section 5 (brief
  `c001-s160-build-rows`, issue SPL-3888, epic SPL-2403).
- **Q2 A**: a box streams into the workspace it is pinned in, the
  session's tenant (3.3, D5). No cross-workspace view.
- **Q3 A**: 7 days, at most 500 000 lines per workspace (3.7, row B6).
- **Q1**: the two answers differ. The later one (`5c6686f2`) answers the
  v0.1 form, whose A is the desk log. v0.2 found that file inside a spool
  root, beside the desk's keys, under `$HOME/.*` (section 7, W9), so 3.2
  refuses it three times and B1's follower announces it `refused`. B1
  ships the v0.3 answer (`token-burn-cron`, 5.1), and this lane does not
  weaken the deny list: following the desk log needs a deny-list
  exception named in code with its reason (3.2: "v0.3 names none").
  **Decided A** (`1a5ce9f1`, poll `f5bc82a1`): the token-burn cron log
  stays, as built; the key-folder rule keeps no exception, so B1 does not
  change and the desk log stays refused.
- **Q5 B, Q6 A, Q7 A** (`369e7bfa`; its two partial copies `e99036b6`
  and `6194b133`, 11:39:56 and 11:40:00, carry Q5 B and Q6 A, the same
  answers): the default folders are `/var/csi/csi-spl` and `/var/log`
  (3.8.2), every glob match is its own stream (3.8.7), and no cnf key lifts
  a security file (3.8.10). With `/var/log` reachable, row B11's
  `security file` class must name every security file under it.

## 8. Review record

| reviewer | vendor | sha | verdict | msg |
|---|---|---|---|---|
| m-313@sat | mistral | `0860285a7` | PASS, VOID: it carried no evidence (no command, no output) | `7d8f18ae`; voided by c-001, msg `e8de14f9` |
| c-317@sat | claude | `0860285a7` | FAIL, W1-W9 (W1 a blocker) | `9e743c9a` (task `c5a8ed9d`) |
| c-317@sat | claude | `7f392fa97` (v0.2) | FAIL, N1-N4 (N1, N2 blockers; W1-W9 folded) | `83da0ab7` (task `c5a8ed9d`) |
| c-317@sat | claude | `2f1ee57b5` (v0.3) | PASS, no blocker | `cd907b2e` to c-319, `4cd4bca3` to c-002 (task `c5a8ed9d`) |

v0.1 is not reviewed: its only PASS was void, its evidenced review a
FAIL. The plan and the section 7 poll posted in `c168784c` (msg
`75d8db39`) went out on the void PASS; nothing is built before a real PASS
and the owner's GO (Q4). v0.2, by c-319 (editor after the retired author),
folded W1-W9 (line numbers below are v0.2's, sha `7f392fa97`):

| defect | what changed | v0.2 lines |
|---|---|---|
| W1 PEM body leaks through per-line redaction | the PEM state across lines, ticks and restarts, with a cap; C9's red control is per-line redaction; new C25, C26 | 186-188, 205-222, 460 (C9), 476-477 (C25, C26), 496 (B1) |
| W2 deny check racy and not re-run on reopen | open first, check `/proc/self/fd/N` and `fstat` S_ISREG on every (re)open; new C31, C32; C8's red control | 258-269, 459 (C8), 482-483 (C31, C32) |
| W3 hardlink bypasses `realpath` | `st_nlink > 1` refused; new C33 | 270-274, 484 (C33) |
| W4 credential homes missing | `$HOME/.*` denied by default, every other home, desk dirs, ssh host keys, `.env`, history files; new C34 | 239-257, 275-278, 485 (C34) |
| W5 stale DB tier | 2.6 and 3.7 restated for `db-custom-1-3840`; bytes of the cap vs `disk_size_gb: 10`; a hub-wide byte cap; `max_connections` unmeasured, B7 reads it (C24) | 148-154, 406-407, 419, 426-442, 475 (C24), 570 (Q3 B) |
| W6 refusals without cases, tab vs route gate | C27-C30; the route gate is intended, the tab gets `staffOnly`; C18 | 296, 316-327, 345-346, 469 (C18), 478-481 (C27-C30), 497-498, 500 |
| W7 `channel:` alias, `notices` field | `channel:file-streams` reserved too (C14); `notices` named in the wire contract and in B4's paths | 377-380, 393-399, 465 (C14), 499 (B4) |
| W8 C7's red control | an ACL / group-read case the mode bits contradict | 458 (C7) |
| W9 the desk log is denied | its real path found; Q1's recommended answer changed to an allowed file | 535-558, 562 (Q1 A) |

v0.3, by c-319, folds c-317's N1-N4 on v0.2 (line numbers are v0.3's):

| defect | what changed | v0.3 lines |
|---|---|---|
| N1 the box spool root is open under cron | `${SPOOL_ROOT:-/var/spool-hub}` resolved as the repo does; no start when it is not a directory; new C35 | 259-265, 521 (C35) |
| N2 the hub-wide byte cap pruned across workspaces | no cross-workspace pruning: a byte cap per workspace enforced at insert in the pushing tenant's scope (overshoot at most one push), `max_workspaces` 4 refused at announce; new C38 | 440-441, 456-470, 524 (C38), 536 (B2) |
| N3 the read open runs a driver's open before the check | `O_PATH` open, check the fd, then reopen through `/proc/self/fd/N` with `O_NOCTTY` and compare dev+inode; new C36 | 273-290, 522 (C36) |
| N4 PEM edge cases | a one-line BEGIN+END opens no block (C37); cap 200, then masking goes on while lines are pure base64 (C26) | 213-232, 512 (C26), 523 (C37) |

## 9. Not in scope

- Following a file on a box the workspace does not own, or a path sent from
  the browser and opened as sent: a typed glob is text the box checks
  under its own allowed folders (3.8).
- Writing to a file, or running a command, from the tab.
- Alerts on a pattern in a stream (a later spec, if the owner asks).
- A workspace's cloud logs (Cloud Logging).

## 10. Change log

| version | date | by | change |
|---|---|---|---|
| v0.1 | 2026-10-26 | c-131 | first draft |
| v0.2 | 2026-10-26 | c-319 | folds review W1-W9 (section 8) |
| v0.3 | 2026-10-26 | c-319 | folds review N1-N4; reviewed PASS |
| v0.4 | 2026-10-29 | c-601 | 3.8: web-typed file globs under allowed folders (owner answer B, poll `376e9435`, msg `d925f9a3`) and the `security file` deny class (owner msg `7f673aef`); 3.1, 3.2, 3.5 and section 9 say what changed; cases C41-C56; rows B9-B12 (5.9); D6, D7; owner questions Q5-Q7 (3.8.11) |
| v0.5 | 2026-10-29 | c-601 | review of v0.4 (grok g-746 FAIL on `7814f50a4`): W1 3.8.5 and row B9 cite the announce frame at `wire/file_streams.go:71-73` (`folders`, `globs`), the stream entry at `:64-68` (`glob_id`), the strict decoder at `:132` / `:122-126`; W2 section 1's asks-list sentence points at 3.8; W3 the 32-character key bound is 3.2's, not 3.3's; note: 3.8.7 and C50 say they hold only if Q6 = A |
| v0.6 | 2026-10-30 | c-563 | folds the owner's answers to Q5..Q7 (poll `900699dd`, msg `369e7bfa`, 7.1): 3.8.2 sets the default folders, `/var/csi/csi-spl` and `/var/log` minus the 3.8.10 security files (Q5 B); 3.8.7 and C50 drop the "if Q6 = A" condition (Q6 A); 3.8.10 states Q7 A; 3.8.11 answered |
