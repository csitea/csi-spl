# Spec 183: An Agent Exports Any Topic It Can Read to PDF

Status: **Draft v0.1** (2026-11-20). Lane `c-977` (`claude`, backup for
`specs_and_docs`: no agy cli on this box).
Epic: **SPL-2398**. Issue: **SPL-6031**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:f798e9aa-6548-44fa-aa8b-7425133bff2f` (`t1`).
Builds on: [182 topic loop prompt](../182-topic-loop-prompt/spec.md) (its
worked example 4.6 and its row L6, which this spec takes over, section 6)
and [005 spool WUI](../005-spool-wui/spec.md) FR-020 (the browser's Export
to PDF, SPL-5888).

Line references were measured on `origin/master` `91e92e63c`. Next free
number: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c 183`
-> 0, and no `review/*` branch holds a `183` folder.

## 0. The owner's words (HUM-10, t1 #spool-hub-devel)

- topic f08c0c58, msg `e0293fcf`: "you can create a separate discussion to
  add the functionality for an agent to be able to export the pdf
  programatically for ANY topic in the spool-hub as long as he has access
  to it"
- topic f08c0c58, msg `92050cbc` (the first use): "an example loop would be
  I would like the whole discussion to be exported as pdf and send to me as
  an email after each reply to me by an agent"
- topic f798e9aa, msg `c0958ad0`: "this is prio-01 , throw as may agents as
  possible to it , it must be done asap"

## 1. Open questions (one form)

Each has a recommended answer, listed first. Section 7.1 is written for the
recommended answers; a part that changes with another answer is marked
**[Qn]**.

Q1. Where is the PDF rendered?
- **BOX** (recommended): the `spool` box CLI renders the rows it read to
  HTML and prints it with the box's own headless Chrome. This box has
  `/usr/bin/google-chrome` and `/usr/bin/chromium` (`which`); the hub
  image is `alpine:3.22` with no browser
  (`csi-spl-api/src/docker/hub.Dockerfile:41`). No new hub service.
- **HUB**: a new hub route renders it. It needs a browser in a hub image
  (or a second Cloud Run service), and the hub carries every render's
  memory and time.
- **WUI**: a headless browser on the box opens the WUI's topic page and
  runs its print (`csi-spl-wui/src/utils/msg-print-run.ts:101`). It
  prints exactly what a person sees, but the browser needs a member's
  session, which an agent does not have.

Q2. What does the agent get?
- **F** (recommended): a file path on the box; the mail step of 182 (row
  L7, `spool mail-file --file <path>`) takes it as it is.
- **FA**: the path, and with `--attach` also the PDF posted in the topic as
  a hub file (the existing `spool send --put-file`, `cmd/spool/main.go:505`).
- **A**: always a hub file posted in the topic. In the loop of 182 4.6 that
  is one more agent post in the topic on every run.

Q3. Which rows may the agent export (the access rule)?
- **OP** (recommended): the rows the box's bound operator (the person the
  box acts for) may read, by the browser's rule: `canReadTopic`
  (`internal/hub/privacy.go:129`) for the topic, then `canReadMessage`
  (`privacy.go:94`) per row. "The whole discussion" as that person sees it.
- **BOX**: only what `spool hub-tail` prints today: the rows the box sent,
  received or was delivered (`internal/store/postgres.go:660-666`), within
  a dedicated agent's scope (`internal/store/dedicated_postgres.go:143-152`).
  Nothing new on the hub, but I believe, unchecked, that a channel topic's
  posts never delivered to the box are missing, so it is not "the whole
  discussion".
- **GR**: OP, plus any topic its starter granted to the agent.

Q4. What does the PDF hold?
- **W** (recommended): the topic's title, then every row the rule of Q3
  allows, oldest first, each as the WUI prints a card (author, time,
  rendered markdown); pictures inline, other attachments as their name and
  a link; no hidden loop prompt (182 section 5.2).
- **WL**: W, plus the hidden loop prompts of the agent's own loops.

## 2. Terms

- **export**: one run of `spool topic-pdf` for one topic.
- **operator**: the person a box is bound to, the one `spool send
  --typed-by` names (`cmd/spool/main.go:510`).
- **loop prompt row**: a message with `messages.loop_id` set (182 7.1.3).

## 3. What exists today (measured)

| part | where | what it does |
|---|---|---|
| browser export | `csi-spl-wui/src/components/TopicExportPdf.vue:44-53`, `src/utils/msg-print-run.ts:101-128` | prints the cards the pane shows through `window.print()`; a person only |
| file name | `csi-spl-wui/src/utils/msg-print.ts:17-37`, cases in `tests/unit/msg-print.test.mjs` | `printSlug(title)`, at most 60 characters, `topic` when empty |
| title | `csi-spl-wui/src/utils/view-api.mjs:32-50` (`topicTitleFromRows`, `topicOpening`), cases in `tests/unit/view-api.test.mjs` | the oldest row's body, whitespace collapsed, 100 characters then `...` |
| multipage fix | `review/c002-bug-wui-pdf-export-multipage` `01b8d3bef` (SPL-6023) | not on master (`git merge-base --is-ancestor` -> no); browser only |
| hub export route | `internal/hub/hours_export.go:273-274` | hours only, `csv` or `xlsx`; any other format is a 400 |
| box topic read | `cmd/spool/hub.go:1361` (`hub-tail`), `internal/hub/ws.go:1136-1162` (`onTail`) | frames `tail` -> `tail_msg`* + `tail_end`, rows by the BOX rule of Q3 |
| read a WUI link | `internal/action/link.go:41,321` (`ParseLink`, `ReadLink`), MCP `spool_read_link` (`internal/mcp/mcp.go:191`) | a link or a uuid -> the topic's rows, through the box's desks |
| person's read rule | `internal/hub/privacy.go:71,94,129` | channel membership, DM ends, topic door |
| pictures | `GET /v1/files/{file_id}` (`internal/hub/rest.go:184-200`, `mayReadFile`), `spool hub-get-file` | a box token fetches a file it may read |
| attach a file | `spool send --put-file` (`cmd/spool/main.go:505`) | blobs a file and posts it |
| PDF tooling | `/usr/bin/google-chrome`, `/usr/bin/chromium`, `/usr/bin/pdftotext` on this box (`which`) | no action requires them |
| mail a file | none: `git grep -c Attach origin/master -- csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go` -> 0 | 182 row L7 |

## 4. The flow end to end

1. **ask**: the agent runs `spool topic-pdf --task <uuid or WUI link>` or the
   MCP tool `spool_topic_pdf`. A link is parsed by `ParseLink` and tried on
   the box's desks in the order `ReadLink` uses (`link.go:148`).
2. **access check**: the box sends the new frame `topic_export`; the hub
   applies the rule of Q3 and answers with the existing `tail_msg` frames
   and one `tail_end`. A topic the agent may not read answers exactly as a
   missing one: `not_found` **[Q3]**.
3. **render**: the CLI fetches each picture with the box token, writes one
   self-contained HTML file (CSS inline, pictures as `data:` URLs) and runs
   `<chrome> --headless=new --print-to-pdf=<out> <html>` **[Q1]**.
4. **file**: the PDF lands at the path of 7.1.4; the CLI prints one JSON
   line (7.1.2). With `--attach` the CLI also posts it in the topic **[Q2]**.
5. **mail (182 4.6)**: the loop's agent passes the path to
   `spool mail-file --task <uuid> --cause <loop prompt msg_id> --file <path>`
   (182 row L7), then answers "PDF sent" in the topic.

## 5. Reused, and the gaps

| part | reused as it is | gap (built here) |
|---|---|---|
| read rows | the `tail` frames (`ws.go:1136`), `retaskEnv` for moved rows (`ws.go:1157`) | the `topic_export` frame and its access rule **[Q3]** |
| link | `ParseLink`, desk order (`link.go:41,148`) | nothing |
| render | the card layout of `MessagePrint.vue` as the model | a Go HTML template; the headless Chrome call; the Chrome lookup |
| title, file name | `topicOpening` (`view-api.mjs:46`), `printSlug` (`msg-print.ts:17`) | their Go ports, held to the same cases |
| pictures | `GET /v1/files/{id}` with the box token | the fetch and the `data:` inline, each bounded as `msg-print-run.ts:56-59` does |
| attach | `spool send --put-file` | `--attach` calls it **[Q2]** |
| mail | none | 182 row L7 (not this spec) |

## 6. Build order (rows a later lane can take in parallel)

Every row builds against the contracts of 7.1, so P1, P2, P3 and P4 start at
once. This spec takes over 182's row L6: `do_spl_topic_pdf` keeps the names
182 gives it, as a thin wrapper of the CLI verb (P3).

| row | depends on | kind | files | done test, and red control |
|---|---|---|---|---|
| **P1 hub: `topic_export` frame + access** | — **[Q3]** | `complex_coding` | `internal/wire` (the frame type), `internal/hub/topic_export.go`, `topic_export_test.go`; the store read for the operator rule (Postgres + Memory) | A box whose operator reads the channel gets every row, oldest first, no loop prompt row; an operator outside the channel gets `not_found`, as a missing topic does; a DM the operator is no end of is left out of a mixed topic. `PRE_PUSH_TIER=full`. Red control: skip the per-row `canReadMessage`, and the DM test sees the DM. |
| **P2 box: render engine** | the frame of 7.1.1 (tests use a fake session) **[Q1]** | `complex_coding` | `internal/topicpdf/{render.go,template.html,slug.go,title.go,chrome.go,*_test.go}` | A fixture of 3 rows and 1 picture makes a PDF whose `pdftotext` holds the 3 bodies and the title; the picture's `data:` URL is in the HTML; `Slug` and `Title` pass every case of `msg-print.test.mjs` and `view-api.test.mjs` for `printSlug` and `topicOpening`; no Chrome -> exit 4 with the install command. Red control: drop the picture fetch, and the picture check fails. |
| **P3 box: CLI verb, MCP tool, orc wrapper** | P2's `topicpdf.Export` signature (7.1.2) | `simple_coding` | `cmd/spool/topic_pdf.go`, `cmd/spool/main.go` (the `case`, the help line), `internal/mcp/mcp.go` (`spool_topic_pdf`), `csi-spl-orc/src/bash/run/spl-topic-pdf.func.sh` + its test | Flags, output and exit codes of 7.1.2 hold; the MCP tool returns the same JSON; `do_spl_topic_pdf` with `TOPIC_ID`, `ENV`, `OUT` runs the verb. Red control: ignore `--out`, and the path test fails. |
| **P4 box requirement: Chrome** | — | `simple_coding` | `csi-spl-iac`: a `do_box_pkg_install` record for `chromium`; the box health check | the check reports a box with no Chrome; the record installs it. Red control: hide the binary from the test `PATH`, and the check fails. |
| **P5 e2e** | P1, P2, P3 | `tests` | `csi-spl-api/src/bash/tests/topic-pdf-e2e.tst.sh` | On a local hub (memory store): post 3 rows and a picture, run `spool topic-pdf`, `pdftotext` holds the 3 bodies; a box whose operator may not read gets exit 3. Red control: turn the access check off, and the exit-3 case fails. |
| **P6 attach** | P3 **[Q2: only FA or A]** | `simple_coding` | `cmd/spool/topic_pdf.go` (`--attach`) | the PDF posts in the topic as a file. Red control: drop the send, and the post check fails. |
| **P7 docs** | P3 | `specs_and_docs` | `csi-spl-doc/doc/md/spool-cli-reference.md`, this spec's row status, 182 row L6's status | `do_check_dist_hygiene`, `do_check_fleet_rules_drift`. |

### 7.1 Contracts for parallel rows (binding)

A row that needs to change one asks the dispatch holder first; the change
lands in this spec before the code. Every name is new unless a file:line
is cited.

#### 7.1.1 Wire frame (P1 serves it, P2 and P3 call it)

- Request: `{"type":"topic_export","task_id":"<uuid>"}` on a box session
  dialled as `hub-tail` dials (`wire.RoleCLI`, `cmd/spool/hub.go:1384`).
  Go constant `wire.TTopicExport = "topic_export"`.
- Answer: zero or more `tail_msg` frames (`wire.TTailMsg`), oldest first
  (`ts`, then `msg_id`, as `postgres.go:666` orders a tail), then one
  `tail_end` with `count` (`ws.go:1155-1161`): the frames of `tail`, so
  the client reads them with the code `Tail` uses.
- Refusal: `not_found` (404) for a missing topic and for one the rule of Q3
  does not allow, alike; `bad_json` (400) with no `task_id`.
- Rows: the rule of Q3 **[Q3]**; never a row with `loop_id` set **[Q4]**;
  moved rows retasked as `onTail` does (`ws.go:1157`).
- Client: `func (s *hubclient.Session) TopicExport(ctx context.Context,
  taskID string, fn func(*wire.Envelope)) (int, error)`.

#### 7.1.2 CLI verb, MCP tool, Go entry (P3 serves, P2 builds the core)

- Verb: `spool topic-pdf --task <uuid|WUI link> [--out <path>] [--attach]
  [--chrome <path>] [--timeout <duration, default 120s>]` **[Q2: --attach]**.
- Output on stdout, one JSON line:
  `{"task_id":"<uuid>","path":"<abs path>","bytes":<n>,"rows":<n>,"pictures":<n>,"sha256":"<hex>"}`.
- Exit codes: `0` written; `1` usage; `3` not found or not readable (one
  code, as the hub gives one answer); `4` no Chrome (stderr names the
  install command of P4); `5` render failed or timed out (stderr carries
  Chrome's last 20 lines).
- Chrome lookup: `--chrome`, else `$SPOOL_CHROME`, else the first of
  `google-chrome`, `chromium`, `chromium-browser` on `PATH`.
- MCP tool `spool_topic_pdf`, input `{"task":"<uuid|link>","out":"<path>",
  "attach":false}`, output the JSON of the verb.
- Go core, `package topicpdf`:
  `func Export(ctx context.Context, rows []action.TailRow, fetch
  func(fileID string) ([]byte, error), opt Options) (Result, error)`;
  `Options{Out, Chrome string; Timeout time.Duration}`;
  `Result{Path string; Bytes int64; Rows, Pictures int; SHA256 string}`.
  `action.TailRow` is `internal/action/link.go:114`.
- orc wrapper (182 row L6's names kept): `do_spl_topic_pdf` with
  `TOPIC_ID` (required), `ENV` (required), `OUT` (optional) runs the verb.

#### 7.1.3 Title

`topicpdf.Title(rows)`: the Go port of `topicTitleFromRows` without a
pinned root (`view-api.mjs:32-50`): the oldest row's body, whitespace
collapsed, 100 characters then `...`; `topic` when empty.

#### 7.1.4 File naming

- Default directory: `$SPOOL_ROOT/<agent id>/exports/`, created `0700`;
  the agent id from `SPOOL_AGENT_ID`, else the box config.
- Name: `<slug>-<task8>-<UTC yyyymmddThhmmssZ>.pdf`; `slug` is
  `topicpdf.Slug(title)`, the Go port of `printSlug` (`msg-print.ts:17-27`:
  the same 60-character cut and `topic` fallback); `task8` the first 8 hex
  digits of the task id.
- `--out` names the file itself; an existing file is replaced.
- Old exports: a later `csi-spl-utl` sweep rule (not P1-P7) removes files in
  `exports/` older than 7 days.

## 8. Not in this spec

Mailing the file (182 row L7), the loop that asks for it (182 rows L1-L3),
and the WUI's own export (005 FR-020, SPL-6023).
