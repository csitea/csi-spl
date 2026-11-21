# Spec 183: An Agent Exports Any Topic It Can Read to PDF

Status: **Accepted v0.7** (2026-11-20, dispatch holder msg `f87753ec`). Lane `c-977` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). v0.1 `f860d1b1b`; v0.2
`49d6ee226` folds the owner's answers to form `82bc7349` (msg `d2c6508b`)
and the P1 lane's contract question (msg `fffc8411`); v0.3 folds Q5 SVC
(form `ed3299a7`, msg `58733d06`) and the scale-to-zero order (msg
`ac761f15`): the renderer service of 7.1.6 and row P4; v0.4 folds the P2
lane's three gaps (msg `b8cb9d99`, approved by the dispatch holder, msg
`f718687c`); v0.5 folds P2's additions to 7.1.5 (R7 c-347 W1, msg
`145e456d`), a hung render's answer and the card author (holder msg
`3d1b6071`); v0.6 names the hub's wait env (P4 c-339, msg `57a09b32`)
and settles the default directory's agent id and P3's desk flags (P3
c-338, msg `b158b296`), holder msg `3436f7ab`; v0.7 builds the topic
link per workspace host (P1 c-981, msg `1576d8f6`; R7 c-075, msg
`7b084fa4`), states the 504 P2b landed (`f17b02d3b`) and the demo
moderation filter (holder msgs `2e5c5646`, `50e27e9e`); v0.8 answers a
box with no bound operator `403 no_operator` instead of `404 not_found`
(SPL-6188, lane c-851: every prd export from `sat` read "no such topic").
Every contract change is in section 9.
Epic: **SPL-2398**. Issue: **SPL-6031**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:f798e9aa-6548-44fa-aa8b-7425133bff2f` (`t1`).
Builds on: [182 topic loop prompt](../182-topic-loop-prompt/spec.md) (its
worked example 4.6 and its row L6, which this spec takes over, section 6)
and [005 spool WUI](../005-spool-wui/spec.md) FR-020 (the browser's Export
to PDF, SPL-5888).

Line references were measured on `origin/master` `656ab3389` (v0.2:
`64049c396`, v0.1: `91e92e63c`). Next free number at v0.1:
`git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c 183`
-> 0, and no `review/*` branch held a `183` folder.

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
- topic f798e9aa, msg `d2c6508b` (form `82bc7349`), verbatim: "Answer 1:
  HUB — On the hub: a hub route renders it Answer 2: F — A PDF file on its
  machine Answer 3: OP — Exactly what the person the agent works for can
  read in the web UI Answer 4: W — The whole topic as the web UI prints it:
  pictures inline, other files as links, no hidden loop prompts"
- topic f798e9aa, msg `58733d06` (form `ed3299a7`), verbatim: "Answer: SVC —
  A separate renderer service on Cloud Run that only the hub may call: the
  hub's own image, memory and start time stay as they are; a render after
  an idle period waits for the renderer to start"
- topic f798e9aa, msg `ac761f15`, verbatim: "make sure this is started
  ad-hoc - speed is not imprtant here , but the mear fact that the export
  to dpf is possible , no need to permanently use resources"

## 1. Decided, and what is open

| Q | Answer | What it decides here |
|---|---|---|
| Q1 | **HUB**: a hub route renders the PDF | 4 step 3, row P2, 7.1.1, 7.1.5 |
| Q2 | **F**: a PDF file on the agent's machine | 4 step 4, 7.1.2; row P6 of v0.1 is dropped |
| Q3 | **OP**: exactly what the person the agent works for reads in the WUI | 4 step 2, row P1, 7.1.1 (which person: 7.1.1) |
| Q4 | **W**: the whole topic as the WUI prints it, pictures inline, other files as links, no hidden loop prompt | 7.1.3 |
| Q5 | **SVC**: a separate renderer service on Cloud Run that only the hub may call; started ad hoc, no resources held while idle (msg `ac761f15`) | 7.1.5, 7.1.6, rows P2 and P4 |

Nothing is open in v0.3.

### 1.1 Q5, the measurements it was decided on

Where Chrome runs, inside "on the hub". Measured on this box with
`docker run alpine:3.22` (the hub's base, `csi-spl-api/src/docker/hub.Dockerfile:41`),
n=1 install, n=3 renders of a one-page HTML at `--cpus=1 --memory=1g`:
`apk add chromium` adds **784 MiB** (803 028 KiB; chromium 142.0.7444.59)
to an 8.5 MiB base; `font-dejavu` adds 11 MiB, `font-noto-cjk` 89 MiB;
one render, Chrome start included, takes **1.69-1.80 s** and peaks at
**189-191 MiB** RSS. The hub runs at `cpu: "1"`, `memory: 512Mi`,
`min_instances: 1`, `concurrency: 1000`
(`csi-spl-cnf/csi-spl/all.env.yaml:408,409,418,449`). The image pull and
cold start of a Cloud Run revision with that image were not measured.

The answer is **SVC**: a second Cloud Run service, the renderer, that only
the hub's service account may call (7.1.6). The hub's image, memory and
cold start do not change. The rejected **IMG** (Chrome in the hub image)
would have put ~800 MiB into every hub instance and needed its memory
raised above 512Mi.

### 1.2 The renderer starts ad hoc (msg `ac761f15`, binding)

- **R1** The renderer holds no resources while idle: `min_instance_count = 0`,
  CPU only during a request (`cpu_idle = true`), no `startup_cpu_boost`,
  no warm-up or keep-alive caller (no scheduler job, no uptime check, no
  probe from the hub). Only a render request starts an instance.
- **R2** Cold-start latency is accepted: there is no latency target. The
  hub waits up to cnf `hub.pdf.timeout` (default 120 s), which covers a
  cold start plus a render.
- **Check** (row P4, in its test and in its plan): a static test of the
  terraform step fails unless `min_instance_count = 0`, `cpu_idle = true`
  and `startup_cpu_boost` is absent or `false`, and unless no
  `google_cloud_scheduler_job` or `google_monitoring_uptime_check_config`
  in `csi-spl-iac/src/terraform/` names the renderer. After the apply on
  dev: `gcloud run services describe <renderer> --account=<dev SA>` shows
  `minScale` 0 (or unset), and 20 minutes with no export later the
  service's instance count metric reads 0. Red control: set
  `min_instance_count = 1` in a test copy, and the static test fails.

## 2. Terms

- **export**: one call of the route of 7.1.1 for one topic.
- **operator**: a person bound to the box in `box_operators`
  (rdb `0040_messages_typed_by_box_operators.sql`), checked by
  `BoxOperatorBound` (`internal/store/box_operators.go:17`); the one
  `spool send --typed-by` names (`cmd/spool/main.go:510`).
- **loop prompt row**: a message with `messages.loop_id` set (182 7.1.3).

## 3. What exists today (measured)

| part | where | what it does |
|---|---|---|
| browser export | `csi-spl-wui/src/components/TopicExportPdf.vue:44-53`, `src/utils/msg-print-run.ts:101-128` | prints the cards the pane shows through `window.print()`; a person only |
| file name | `csi-spl-wui/src/utils/msg-print.ts:17-37`, cases in `tests/unit/msg-print.test.mjs` | `printSlug(title)`, at most 60 characters, `topic` when empty |
| title | `csi-spl-wui/src/utils/view-api.mjs:32-50` (`topicTitleFromRows`, `topicOpening`), cases in `tests/unit/view-api.test.mjs` | the oldest row's body, whitespace collapsed, 100 characters then `...` |
| multipage fix | `review/c002-bug-wui-pdf-export-multipage` `01b8d3bef` (SPL-6023) | not on master at v0.1; browser only |
| hub export route | `internal/hub/hours_export.go:273-274` | hours only, `csv` or `xlsx`; any other format is a 400 |
| box REST with a box token | `GET /v1/files/{file_id}` (`internal/hub/server.go:479`), box bearer resolved by `bearerAny` (`internal/hub/resolve.go:207-216`), client `Session.rest` (`internal/hubclient/hubclient.go:1089`) as `FetchFile` uses it (`hubclient.go:1221-1230`) | a box calls a hub REST route with the token its session was issued |
| frame size | `maxFrameBytes = 1 << 20` on the CLI (`hubclient.go:439`), `512 << 10` inbound on the hub (`internal/hub/ws.go:30`) | a PDF does not fit a frame: the route answers over HTTP |
| file size | `msg.MaxFileBytes = 32 MiB` (`internal/msg/msg.go:44`) | the cap 7.1.1 reuses |
| box topic read | `cmd/spool/hub.go:1361` (`hub-tail`), `internal/hub/ws.go:1136-1162` (`onTail`) | the rows the box sent, received or was delivered; not the OP rule |
| read a WUI link | `internal/action/link.go:41,321` (`ParseLink`, `ReadLink`), MCP `spool_read_link` (`internal/mcp/mcp.go:191`) | a link or a uuid -> a task id and the desk to ask |
| person's read rule | `internal/hub/privacy.go:71,94,129` | channel membership, DM ends, topic door |
| pictures | the tenant blob store the hub writes (`PutFile`, `internal/hub/rest.go:589`) | the hub reads them itself; no box fetch |
| PDF tooling | `/usr/bin/google-chrome`, `/usr/bin/chromium`, `/usr/bin/pdftotext` on this box (`which`); none in the hub image | tests may use `pdftotext` |
| mail a file | none: `git grep -c Attach origin/master -- csi-spl-api/src/go/spool-hub-api/internal/mail/mail.go` -> 0 | 182 row L7 |

## 4. The flow end to end

1. **ask**: the agent runs `spool topic-pdf --task <uuid or WUI link>` or the
   MCP tool `spool_topic_pdf`. A link is parsed by `ParseLink` and tried on
   the box's desks in the order `ReadLink` uses (`link.go:148`). The CLI
   dials the hub as `hub-tail` does and calls the route of 7.1.1 with its
   session's box token.
2. **access check (OP)**: the hub resolves the operator (7.1.1), then
   `topicExportRows` returns the rows that person reads: `canReadTopic`
   (`privacy.go:129`) for the topic, `canReadMessage` (`privacy.go:94`)
   per row, no loop prompt row. A topic the person may not read answers as
   a missing one: `404 not_found`.
3. **render (HUB)**: the hub builds one self-contained HTML (CSS inline,
   pictures from its blob store as `data:` URLs, other files as their name
   and a link), and posts it to the renderer service (7.1.6), which
   starts if it is idle (1.2) and answers the PDF.
4. **file (F)**: the route answers the PDF bytes; the CLI writes them to
   the path of 7.1.4 and prints one JSON line (7.1.2). Nothing is stored
   on the hub and nothing is posted in the topic.
5. **mail (182 4.6)**: the loop's agent passes the path to
   `spool mail-file --task <uuid> --cause <loop prompt msg_id> --file <path>`
   (182 row L7), then answers "PDF sent" in the topic.

## 5. Reused, and the gaps

| part | reused as it is | gap (built here) |
|---|---|---|
| door | box bearer (`resolve.go:207`), `canReadTopic`, `canReadMessage`, `BoxOperatorBound` | the route, the operator choice, `topicExportRows` |
| link | `ParseLink`, desk order (`link.go:41,148`) | nothing |
| render | the card layout of `MessagePrint.vue` as the model | a Go HTML template in the hub; the renderer service and the hub's call to it (7.1.5, 7.1.6) |
| title, file name | `topicOpening` (`view-api.mjs:46`), `printSlug` (`msg-print.ts:17`) | their Go ports, held to the same cases |
| pictures | the blob store | the `data:` inline, each bounded as `msg-print-run.ts:56-59` does |
| CLI to REST | `Session.rest` (`hubclient.go:1089`) | a streaming variant that writes the body to a file |
| mail | none | 182 row L7 (not this spec) |

## 6. Build order (rows a later lane can take in parallel)

Every row builds against the contracts of 7.1. P1, P2, P3 and P4 start at
once; P4's apply needs P2's renderer image and the owner's go. This spec takes over 182's row L6:
`do_spl_topic_pdf` keeps the names 182 gives it, as a thin wrapper of the
CLI verb (P3). v0.1's row P6 (`--attach`) is dropped (Q2 = F).

| row | depends on | kind | files | done test, and red control |
|---|---|---|---|---|
| **P1 hub: route, operator, access** | — | `complex_coding` | `internal/hub/topic_export.go` (`handleTopicExport`, `topicExportOperator`, `topicExportRows`), `topic_export_test.go`, the route in `internal/hub/server.go`; the store read for the OP rule (Postgres + Memory) | A box whose operator reads the channel gets `200 application/pdf`; an operator outside the channel and a topic that does not exist both get `404 not_found`; a DM the operator is no end of is left out of a mixed topic; two operators and no `typed_by` -> `400 operator_ambiguous`; a `typed_by` not bound to the box -> `403 typed_by_not_bound`; no loop prompt row once 182 L1 has landed `messages.loop_id`. Tests stub the renderer of 7.1.5. `PRE_PUSH_TIER=full`. Red control: skip the per-row `canReadMessage`, and the DM test sees the DM. |
| **P2 hub: HTML and the renderer** | — | `complex_coding` | `internal/topicpdf/{html.go,template.html,slug.go,title.go,render.go,*_test.go}`; the renderer: `cmd/spool-pdf/main.go` (its HTTP server, 7.1.6) and `csi-spl-api/src/docker/pdf.Dockerfile` | A fixture of 3 rows and 1 picture makes a PDF whose `pdftotext` holds the 3 bodies and the title; the picture's `data:` URL is in the HTML; `Slug` and `Title` pass every case of `msg-print.test.mjs` and `view-api.test.mjs` for `printSlug` and `topicOpening`; a render past its timeout fails with `render_timeout`. Red control: drop the picture inline, and the picture check fails. |
| **P3 box: CLI verb, MCP tool, orc wrapper** | the route of 7.1.1 (tests use a stub hub) | `simple_coding` | `cmd/spool/topic_pdf.go`, `cmd/spool/main.go` (the `case`, the help line), `internal/hubclient` (`Session.TopicPDF`), `internal/mcp/mcp.go` (`spool_topic_pdf`), `csi-spl-orc/src/bash/run/spl-topic-pdf.func.sh` + its test | Flags, output and exit codes of 7.1.2 hold; the file holds exactly the bytes the stub served (sha256); a 404 exits 3 and writes no file; the MCP tool returns the same JSON; `do_spl_topic_pdf` with `TOPIC_ID`, `ENV`, `OUT` runs the verb. Red control: ignore `--out`, and the path test fails. |
| **P4 infra: the renderer on Cloud Run** | P2's image for the apply | `complex_coding` (terraform: the owner's go before any apply, dev before prd) | `csi-spl-iac/src/terraform/031-cloud-run-pdf/` (the service, its runtime service account with no roles, `roles/run.invoker` for the hub's service account only); cnf `pdf.cloud_run.*` and `hub.pdf.{url,timeout}` in `csi-spl-cnf/csi-spl/all.env.yaml` + the rendered tfvars; `csi-spl-orc/src/bash/run/build-push-pdf-image.func.sh` (`do_build_push_pdf_image`, as `build-push-hub-image.func.sh`) and its step in `.github/workflows/20_hub-build-deploy.yml` when `cmd/spool-pdf/**`, `internal/topicpdf/**` or `pdf.Dockerfile` change; the hub's env `SPOOL_PDF_URL` in `030-cloud-run-hub/04-cloud-run-service.tf` | The check of 1.2 (static test + the dev describe and the idle count); `make do-tf-plan` for dev shows only the new step and the hub's one env line; after the owner's go and the apply, an export on dev after 20 idle minutes returns a PDF, and its cold start and render time are written into this spec. Red control: call the renderer's URL with no token, and Cloud Run answers 403. |
| **P5 e2e** | P1, P2, P3 | `tests` | `csi-spl-api/src/bash/tests/topic-pdf-e2e.tst.sh` | On a local hub (memory store, the renderer from P2 run locally): post 3 rows and a picture, run `spool topic-pdf`, `pdftotext` holds the 3 bodies; a box whose operator may not read gets exit 3. Red control: turn the access check off, and the exit-3 case fails. |
| **P7 docs** | P3 | `specs_and_docs` | `csi-spl-doc/doc/md/spool-cli-reference.md`, this spec's row status, 182 row L6's status | `do_check_dist_hygiene`, `do_check_fleet_rules_drift`. |

### 6.1 Row P4 status (lane `c-339`, SPL-6045)

Built by `c-339`; applied in dev and prd on 2026-11-21 (the record at the
end of this section).

- Step `031-cloud-run-pdf`: service and runtime SA `<org>-<app>-<env>-pdf`
  (the SA holds no role), `roles/run.invoker` for the hub's runtime SA only,
  `min_instance_count = 0` as a literal (not cnf), `cpu_idle = true`,
  `startup_cpu_boost = false`, concurrency 1, max 2, 120 s, 1 cpu, 1Gi.
- cnf: `pdf.image.{name,tag}`, `pdf.cloud_run.*`, `hub.pdf.{url,timeout}`
  in `all.env.yaml`. `pdf.image.tag` is `""` until the first push, and 031
  refuses to plan with it; `hub.pdf.url` is `""` until 031's apply, and 030
  then passes no `SPOOL_PDF_URL` and no `SPOOL_PDF_TIMEOUT`.
- Hub env (v0.6 7.1.6): with the url set, 030 passes `SPOOL_PDF_URL` and
  `SPOOL_PDF_TIMEOUT` (cnf `hub.pdf.timeout`, `120s`; its variable refuses a
  value that is not minutes and/or seconds above 115 s and below 600 s).
- Image: `do_build_push_pdf_image` (csi-spl-orc) tags it `src-<12 hex>`, a
  hash of the committed inputs (`cmd/spool-pdf`, `internal/topicpdf`,
  `go.mod`, `go.sum`, `pdf.Dockerfile`), and pushes only a tag the registry
  lacks; a registry read that fails with anything but `NOT_FOUND` stops it
  before any build. Workflow 20's job `pdf-image` (its GCP project from cnf,
  `do_spl_cloud_cnf`, as the deploy job) runs it on every run and never rolls
  a service: step 031 runs cnf `pdf.image.tag`, so a new renderer is a cnf
  tag bump plus an apply of 031 with the owner's go.
- Check of 1.2: `csi-spl-iac/src/bash/tests/renderer-scale-to-zero-031.tst.sh`;
  its red controls (`min_instance_count = 1`, `cpu_idle = false`,
  `startup_cpu_boost = true`, an `allUsers` invoker, a keep-warm scheduler
  job, a 030 that drops `SPOOL_PDF_TIMEOUT` or leaves `pdf_timeout` out of
  its template hash) each fail it.

After the apply (dev, then prd; c-001, with the owner's go):

Applied 2026-11-21 by lane `c-769` (SPL-6172), owner go msg `888fc530`:
dev 031 then dev 030, one dev export, then prd 031 and prd 030, each prd
plan matching dev's. Image `src-73f6cd79d049` (cnf `b383c7a86`);
`hub.pdf.url` per env file (`ba10a2b5f` dev, `31a976ffb` prd). Every
after-plan reads `No changes`; the hub's `/version` stayed `a83052abd` in
both envs across the 030 applies. Plans, applies and after-plans:
`<spool root>/dispatch/spl6045-{031,030}-{dev,prd}-*-20261121.txt`.

| check | dev | prd |
|---|---|---|
| `minScale` (`gcloud run services describe`) | `0` (max `2`, cpu-throttling `true`) | `0` (max `2`, cpu-throttling `true`) |
| `run.invoker` | the hub's runtime SA only | the hub's runtime SA only |
| `POST /render` with no token | `403` | `403` |
| idle instance count (`run.googleapis.com/container/instance_count`) | `0` from 09:55Z to the read at 10:06Z (idle `2` after the 09:40Z export, `1` from 09:51Z) | `0` from 09:58Z to the read at 10:06Z (idle `1` from 09:43Z, after the apply) |
| export (`do_spl_topic_pdf`) | rc 0, 23907 B, 1 page A4, Producer Skia/PDF m142, 13.6 s end to end (run from a box with a dev desk) | not run |

Limits of these numbers (n=1): the export was a synthetic 1-row topic
with no picture, and the hub's HTTP status was not printed (rc 0 and a
written PDF imply 2xx). Not measured: an export after 20 idle minutes, so
the cold start and the render time apart are not known. The 13.6 s is no
cold-start figure: dev held 1 idle instance (09:28Z-09:39Z) when it ran. No
prd export. Scale to zero took ~15 min after the last request, n=1 per env.

### 7.1 Contracts for parallel rows (binding)

A row that needs to change one asks the dispatch holder first; the change
lands in this spec before the code. Every name is new unless a file:line
is cited.

#### 7.1.1 Hub route (P1 serves it, P3 calls it)

- `GET /v1/topics/{task_id}/export.pdf[?typed_by=HUM-<n>]`, authenticated
  by the box bearer token its session was issued, as `GET /v1/files/{id}`
  is (`resolve.go:207-216`); a WUI token (`WUIBox`) or a member session
  is refused `401` in v0.2.
- Operator (`topicExportOperator`), never the union of several (one
  person's DM would reach another):
  - `typed_by` given: it must be bound to the box (`BoxOperatorBound`) and
    a member of the tenant, else `403 typed_by_not_bound`;
  - no `typed_by` and exactly one operator bound to the box: that person;
  - no `typed_by` and several bound: `400 operator_ambiguous`;
  - none bound: `403 no_operator`, detail `box <box> has no bound operator
    in <tenant>`, answered before any topic is looked up, so it says
    nothing about the topic. The fix is a grant
    (`do_spl_box_operator_grant`, specs/036 FR-010); the bindings of a
    tenant: `ENV=<env> TENANT_ID=<t> ./run -a do_spl_box_operator_list`.
- Rows (`topicExportRows(ctx, tenant, task, human) ([]store.EditableMessage, error)`,
  the function the render calls): the topic door `canReadTopic`, then
  `canReadMessage` per row, oldest first (`ts`, then `msg_id`); no row with
  `loop_id` set, added once 182 L1 lands the column (it is not on master at
  v0.2).
- Demo moderation (specs/077 3.6, T016; `internal/hub/demo_moderation.go`)
  applies, as on every read: in the demo workspace the operator's
  `moderation` view drops the hidden rows (`keepMsgs`) unless the operator
  is a moderator (`moderatePerm`), whose export keeps them, as their WUI
  read does; outside the demo workspace nothing is filtered. P1 applies it
  in `topicExportRows`.
- Answer `200`: the PDF bytes, `Content-Type: application/pdf`,
  `Content-Disposition: attachment; filename="<name of 7.1.4>"`, headers
  `X-Spool-Rows: <n>`, `X-Spool-Pictures: <n>`.
- Refusals, JSON as every hub error: `404 not_found` (missing topic, a
  topic the operator may not read: one answer for both);
  `403 no_operator`; `400 operator_ambiguous`; `403 typed_by_not_bound`;
  `413 too_large` (a PDF over `msg.MaxFileBytes`, `msg.go:44`);
  `503 render_unavailable` (renderer down, busy or Chrome failed);
  `504 render_timeout` (past cnf `hub.pdf.timeout`, default 120 s, 1.2 R2,
  or a render past the renderer's own cap, 7.1.6: a hung Chrome gives
  `504`, never `503`). The status and token come from
  `topicpdf.Status(err)` (7.1.5).
- Client: `func (s *hubclient.Session) TopicPDF(ctx context.Context,
  taskID, typedBy string, w io.Writer) (TopicPDFInfo, error)`;
  `TopicPDFInfo{Name string; Rows, Pictures int}`.

#### 7.1.2 CLI verb and MCP tool (P3)

- Verb: `spool topic-pdf --task <uuid|WUI link> [--out <path>]
  [--typed-by HUM-<n>] [--timeout <duration, default 120s>]
  [--desks <dir>] [--desk-box <box>]`.
- `--desks` (default `$SPOOL_DESKS`) and `--desk-box` (default
  `$SPOOL_DESK_BOX`) are in the contract: the same flags, defaults and
  meaning as `spool tail --url` (`cmd/spool/main.go:617-618`). They give
  the desk order of section 4 step 1; with no `--desks`, this hub-mode
  spool is the one desk. The MCP tool takes no desk input: it uses its
  server's `spool mcp --desks/--desk-box` (`main.go:649-650`).
- Output on stdout, one JSON line:
  `{"task_id":"<uuid>","path":"<abs path>","bytes":<n>,"rows":<n>,"pictures":<n>,"sha256":"<hex>"}`.
- Exit codes: `0` written; `1` usage; `3` `404` from the hub; `4`
  `400 operator_ambiguous`, `403 typed_by_not_bound` or `403 no_operator`
  (stderr names the token). A desk that answers `no_operator` hands over
  to the next desk, as a `404` does; when none serves the topic, an
  unreachable desk is reported first, then `no_operator`, then the `404`; `5` `413`, `503` or `504` (stderr names the token). A failed
  export writes no file and leaves no partial one.
- MCP tool `spool_topic_pdf`, input `{"task":"<uuid|link>","out":"<path>",
  "typed_by":"HUM-<n>"}`, output the JSON of the verb.
- orc wrapper (182 row L6's names kept): `do_spl_topic_pdf` with
  `TOPIC_ID` (required), `ENV` (required), `OUT` (optional) runs the verb.

#### 7.1.3 What the PDF holds (Q4 W), and its title

- The title, then each row as the WUI prints a card: author, time,
  rendered markdown; pictures inline; other attachments as their name,
  plus a link to the topic in the WUI when the hub passes
  `topicpdf.WithTopicLink(url)` (7.1.5), else the name only; no loop
  prompt row.
- Card author, as the WUI's `typedByAuthor` (`typed-by.mjs`): when the
  row's `TypedBy` is a `HUM-<n>` other than `FromID`, the card shows that
  person and `via terminal <FromID>`; else `FromID`. P1 adds `TypedBy
  string` (`messages.typed_by`, rdb 0040, as `store.ViewMsg.TypedBy`,
  `store/view.go:125`) to `store.EditableMessage`
  (`store/message_edit.go:37`) and fills it in both stores' read; P1 also
  makes P2's card use it (P2 landed without the field). Until then the
  card shows `FromID`.
- Title, `topicpdf.Title(rows)`: the Go port of `topicTitleFromRows`
  without a pinned root (`view-api.mjs:32-50`): the oldest row's body,
  whitespace collapsed, 100 characters then `...`; `""` when no row has
  text, as the JS (`view-api.test.mjs:81`). The PDF's heading prints
  `topic` for an empty title, and `Slug("")` is `topic` (7.1.4).

#### 7.1.4 File naming

- Name: `<slug>-<task8>-<UTC yyyymmddThhmmssZ>.pdf`; `slug` is
  `topicpdf.Slug(title)`, the Go port of `printSlug` (`msg-print.ts:17-27`:
  the same 60-character cut and `topic` fallback); `task8` the first 8 hex
  digits of the task id. The hub names it (7.1.1); the CLI keeps it.
- Default directory: `$SPOOL_ROOT/<agent id>/exports/`, created `0700`.
  The agent id: the verb's `SPOOL_AGENT_ID`, the MCP tool's seat
  (`spool mcp --as`, `$SPOOL_MCP_AS`); when that is empty, the box id
  (`config.Config.BoxID`, env `SPOOL_BOX_ID`, `config/config.go:41`).
  The box config holds no agent id. In hub mode the box id is always set
  (`config.go:198`), so the fallback always names a directory. P3 does
  this at `a886216c7`.
- `--out` names the file itself; an existing file is replaced.
- Old exports: a later `csi-spl-utl` sweep rule (not P1-P7) removes files in
  `exports/` older than 7 days.

#### 7.1.5 The hub's renderer seam (P1 calls it, P2 builds it)

- `package topicpdf`:
  `type Renderer interface { Render(ctx context.Context, html []byte) ([]byte, error) }`;
  `func HTML(rows []store.EditableMessage, title string, blob func(fileID string) ([]byte, error), opts ...Option) ([]byte, int, error)`
  (the HTML and its picture count); `type Option func(*htmlOpts)`;
  `func WithTopicLink(url string) Option` sets the WUI link printed after
  each non-picture attachment (7.1.3). P1 passes it built as
  `topicLink` (`internal/hub/channel_move.go:396`) from
  `TenantHostPattern`: `GcalWorkspaceURL(TenantHostPattern, WUIApexTenant,
  "")(tenant) + "/t/" + task` (`gcal_connect.go:90`), so
  `https://<tenant>.<fqdn>/t/<task>`, or `https://<fqdn>/t/<task>` for
  the apex workspace; none without a pattern (that call then gives `""`,
  and a bare `/t/<task>` opens nothing). `hub.New` refuses a pattern
  without `{tenant}.` (`server.go:382`), so a running hub always passes
  one. Hub `Options` hold no `AppURL`. Without the option an attachment
  prints its name only.
- `topicpdf.HTTPRenderer{URL string}` posts the HTML to
  `POST <URL>/render` (7.1.6) through `idtoken.NewClient(ctx, URL)`
  (`google.golang.org/api`, already in `go.mod:29`), the hub's own
  identity as the ID token. `URL` is the env `SPOOL_PDF_URL`; empty (lde,
  tests without a renderer) answers `503 render_unavailable`.
- `HTTPRenderer{URL string; Timeout time.Duration; Client *http.Client}`
  (`render.go:63-70` on P2's `c55e6a5b5`): `Timeout` 0 =
  `DefaultTimeout` (120 s), a sooner deadline on the context is kept;
  `Client` nil = `idtoken.NewClient` (tests pass their own).
- Errors (`render.go:30-43`): `ErrUnavailable` (no URL, unreachable, or the
  renderer's `500`); `ErrBusy` wraps it (the renderer's `429`, or Cloud
  Run's `429` / `503` when no instance can start); `ErrTimeout` (past
  `Timeout`, or the renderer's `504`; also matched by
  `context.DeadlineExceeded`); `ErrTooLarge` (a PDF over
  `msg.MaxFileBytes`, or the renderer's `413`).
- `func Status(err error) (int, string)` (`render.go:47`) is the hub's
  answer of 7.1.1: `ErrTimeout` -> `504 render_timeout`, `ErrTooLarge` ->
  `413 too_large`, any other error (`ErrUnavailable`, `ErrBusy`) -> `503
  render_unavailable`, nil -> `200 ""`. P1 answers with it and maps no
  error itself.

#### 7.1.6 The renderer service (P2 builds the server, P4 deploys it)

- Program `cmd/spool-pdf` (module `spool-hub-api`), image
  `csi-spl-api/src/docker/pdf.Dockerfile`: `alpine:3.22` + `chromium` +
  `font-dejavu` (~795 MiB, 1.1); runs as a non-root user.
- HTTP on `$PORT` (Cloud Run's): `POST /render`, body `text/html` up to
  40 MiB (32 MiB of pictures as base64), answers `200 application/pdf`;
  `413` over the cap; `429` while a render runs (one at a time per
  instance); `504` when the render passes its own cap
  (`SPOOL_PDF_RENDER_TIMEOUT`, default 115 s, under Cloud Run's 120 s), the
  browser's process group killed; `500` with Chrome's last 20 lines on any
  other failed render. P2b (`f17b02d3b`, SPL-6049) answers the `504`
  (`cmd/spool-pdf/main.go:119`) only for that cap, its cause set by
  `context.WithTimeoutCause` (`main.go:143`); a client that goes away
  first is not the cap. No
  other route, no health route the hub calls (1.2 R1).
- Each render runs `chromium-browser --headless=new --no-sandbox
  --disable-gpu --disable-dev-shm-usage --no-pdf-header-footer
  --user-data-dir=<tmp>/profile --print-to-pdf=<tmp>/out.pdf <tmp>/in.html`
  in a fresh temp dir `<tmp>`, removed after the answer: no date, URL or
  page header from Chrome, and no profile shared between renders. The HTML holds no remote
  resource: every picture is already a `data:` URL (7.1.3).
- Cloud Run, terraform step `031-cloud-run-pdf`, cnf `pdf.cloud_run`:
  service `<org>-<app>-<env>-pdf`; `cpu: "1"`, `memory: 1Gi`,
  `min_instances: 0`, `max_instances: 2`, `concurrency: 1`,
  `timeout: 120s`, `cpu_idle: true`, no `startup_cpu_boost` (1.2 R1);
  ingress `all` with IAM: no `allUsers` invoker, `roles/run.invoker` for
  the hub's runtime service account (`030-cloud-run-hub/03-runtime-sa.tf:4`)
  only.
- The hub learns the URL from cnf `hub.pdf.url` (the step's output, set
  in cnf after the apply), passed as `SPOOL_PDF_URL`; cnf
  `hub.pdf.timeout` (default `120s`) is the hub's wait, passed by step
  030 as env `SPOOL_PDF_TIMEOUT`: a Go duration (`120s`, `2m`), unset =
  `120s`. P1 reads it into the hub's config (`config/config.go`, beside
  `SPOOL_HUB_WS_MAX_LIFE` at `:657`). A value that does not parse, or
  that is not positive, refuses the hub's start. P1 sets
  `HTTPRenderer.Timeout` (7.1.5) from it. It must stay above the
  renderer's `SPOOL_PDF_RENDER_TIMEOUT` (115 s), so a hung Chrome answers
  the renderer's `504` before the hub gives up. It must also stay under
  the hub's own request timeout (cnf `hub.cloud_run.timeout_seconds`,
  600 s).

## 8. Not in this spec

Mailing the file (182 row L7), the loop that asks for it (182 rows L1-L3),
and the WUI's own export (005 FR-020, SPL-6023).

## 9. Changes from v0.1

| v0.1 | v0.2 | why |
|---|---|---|
| 1: four open questions | Q1 HUB, Q2 F, Q3 OP, Q4 W decided; Q5 (where Chrome runs) open | msg `d2c6508b` |
| 7.1.1: WS frame `topic_export` answering `tail_msg` rows to the box | REST `GET /v1/topics/{task_id}/export.pdf` answering the PDF bytes | Q1 HUB; a PDF does not fit the CLI's 1 MiB frame (`hubclient.go:439`) |
| 7.1.1: request with `task_id` only | optional `typed_by`; one operator rule, `400 operator_ambiguous`, `403 typed_by_not_bound`, never a union | P1 lane, msg `fffc8411` |
| 7.1.1: rows with `loop_id` filtered | the filter lands once 182 L1 lands the column | P1 lane, msg `fffc8411`: not on master |
| 7.1.1: `hubclient.Session.TopicExport` (rows) | `hubclient.Session.TopicPDF` (bytes to an `io.Writer`) | Q1 HUB |
| 7.1.2: Go core `topicpdf.Export` on the box | removed: the box only writes bytes; the core is the hub seam of 7.1.5 | Q1 HUB |
| 7.1.2: flags `--attach`, `--chrome`, env `SPOOL_CHROME` | removed; `--typed-by` added | Q2 F; Q1 HUB; the operator rule |
| 7.1.2: exit `4` = no Chrome, `5` = render failed | `4` = operator refused, `5` = `413`/`503`/`504` from the hub | Q1 HUB |
| 7.1.4: the CLI names the file | the hub names it in `Content-Disposition`; the CLI keeps it | Q1 HUB |
| — | 7.1.5 the renderer seam, new | Q1 HUB |
| rows P2 box render, P4 Chrome on every box, P6 attach | P2 hub HTML + renderer, P4 the renderer on Cloud Run (terraform with the owner's go), P6 dropped | Q1 HUB, Q2 F |

### 9.1 Changes from v0.2

| v0.2 | v0.3 | why |
|---|---|---|
| 1.1: Q5 open, SVC or IMG | Q5 SVC decided; IMG removed from 7.1.5 and rows P2, P4 | msg `58733d06` |
| — | 1.2: R1 scale to zero, no warm-up; R2 no latency target; the check | msg `ac761f15` |
| 7.1.5: `HTTPRenderer` posts to `<hub.pdf.url>/render` | the same, through `idtoken.NewClient`, URL from env `SPOOL_PDF_URL`; empty -> `503` | the hub's identity is the only caller (Q5 SVC) |
| 7.1.5: `ErrBusy` -> `503` | also Cloud Run's `429`/`503` -> `503` | an instance may not start |
| — | 7.1.6: the renderer's program, image, HTTP contract, Cloud Run settings, step `031-cloud-run-pdf`, cnf `pdf.cloud_run`, `hub.pdf.{url,timeout}` | P4's design |
| `hub.pdf.timeout` default 60 s | 120 s | R2: a cold start is accepted |
| row P4: SVC or IMG | P4 = step 031, the image action and its workflow step, the hub's env line, the check of 1.2 | Q5 SVC |

### 9.2 Changes from v0.3

| v0.3 | v0.4 | why |
|---|---|---|
| 7.1.3: other attachments carry a WUI link; 7.1.5: `HTML(rows, title, blob)` has no link input | `HTML(..., opts ...Option)`, `WithTopicLink(url)`; without it the name only | P2, msg `b8cb9d99` (a) |
| 7.1.3: `Title` of no text = `topic` | `Title` = `""` as `topicTitleFromRows([])`; the heading and `Slug` print `topic` | P2, msg `b8cb9d99` (b): the port must pass `view-api.test.mjs:81` |
| 7.1.6: Chrome flags without header control or own profile | adds `--no-pdf-header-footer` and a per-render `--user-data-dir` | P2, msg `b8cb9d99` (c) |

### 9.3 Changes from v0.4

| v0.4 | v0.5 | why |
|---|---|---|
| 7.1.5: `HTTPRenderer{URL}`, `ErrBusy` | `HTTPRenderer{URL, Timeout, Client}`, `ErrUnavailable`, `ErrBusy`, `ErrTimeout`, `ErrTooLarge`, `Status(err)`; P1 answers with `Status` | P2 `c55e6a5b5`, R7 c-347 W1 (msg `145e456d`): the contract lands before the code |
| 7.1.6: a failed render answers `500` | a render past the renderer's cap answers `504`, so a hung Chrome is `504 render_timeout` at the hub, never `503` | R7 N2 (msg `3d1b6071`): `500` read as `503` hid a timeout |
| 7.1.3: card author unstated | `typedByAuthor`'s rule; P1 adds `EditableMessage.TypedBy` and wires it into the card | c-334's note (msg `3d1b6071`): `EditableMessage` has no `TypedBy` |

### 9.4 Changes from v0.5

| v0.5 | v0.6 | why |
|---|---|---|
| 7.1.6: cnf `hub.pdf.timeout` with no env name; step 030 passes only `SPOOL_PDF_URL` | env `SPOOL_PDF_TIMEOUT`, Go duration, default `120s`; P1 reads it into `HTTPRenderer.Timeout`; it stays above the renderer's 115 s and under the hub's 600 s | P4 c-339, msg `57a09b32` |
| 7.1.4: the agent id falls back to "the box config" | it falls back to the box id (`SPOOL_BOX_ID`), as P3 does; the MCP tool uses its seat (`--as`) | P3 c-338, msg `b158b296`: the box config holds no agent id |
| 7.1.2: no desk flags | `--desks` / `--desk-box` in the contract, as on `tail --url`; the MCP tool uses its server's | P3 c-338, msg `b158b296`: section 4 step 1's desk order needs them |

### 9.5 Changes from v0.6

| v0.6 | v0.7 | why |
|---|---|---|
| 7.1.5: the topic link from the hub's `AppURL`, none when it is empty | built as `topicLink` from `TenantHostPattern` (`https://<tenant>.<fqdn>/t/<task>`); none without a pattern | P1 c-981, msg `1576d8f6`; R7 c-075, msg `7b084fa4`: hub `Options` hold no `AppURL` and each workspace's WUI is on its own host |
| 7.1.6: P2 answers `500` for the cap and follows up with the `504` | P2b `f17b02d3b` answers `504` for the renderer's own cap | c-360 P2b N1: the follow-up landed |
| 7.1.1: demo moderation unstated | the specs/077 T016 filter applies to the export rows; a moderator's export keeps the hidden rows | R7 c-075 W1, msg `7b084fa4` |

### 9.6 Changes from v0.7

| v0.7 | v0.8 | why |
|---|---|---|
| 7.1.1: no operator bound to the box answers `404 not_found`, as a topic the box may not read | `403 no_operator`, `box <box> has no bound operator in <tenant>`, before any topic lookup; `404` stays for a missing topic and one the operator may not read | SPL-6188 (c-851): on prd t1 one other box had the only binding (`do_spl_box_operator_list`, 2026-11-21), so every export from `sat` read "no such topic" for topics its agents read; the new answer names the box, not the topic |
| 7.1.2: exit `4` = `operator_ambiguous` or `typed_by_not_bound` | also `no_operator`; such a desk hands over to the next one like a `404`, and is reported before the `404` | the same |
