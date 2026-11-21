# Spec 190: Media in Qto docs (pictures, video, audio)

Status: **Draft v0.1** (2026-11-21). Lane `c-700` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). Nothing below is built.
Epic: **SPL-2403**. Issue: **SPL-6152** (priority 5, the owner's `prio:05`).
Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:bc3df46d-9048-4a64-91dc-c6e5c8cdf40d` (`t1`), task
`dispatch-bc3df46d`.
Builds on: [137 Qto as the only doc editor](../137-qto-only-doc-editor/spec.md)
(and its [unified-fs.md](../137-qto-only-doc-editor/unified-fs.md) section 7,
the `foo.assets/` picture layout),
[114 workspace doc privacy and sharing](../114-workspace-doc-privacy-sharing/spec.md)
(each workspace's own private bucket, step 052),
[113 workspace docs](../113-workspace-docs-qto/spec.md) and
[120 Qto doc tree](../120-qto-doc-tree/spec.md). It extends the Qto picture
path (section 2.4). The post attachment path (section 2.3) was measured; only
its streaming upload, its quota and its sweep are reused.

Number: the highest spec on `origin/master` `cd2012822` is
`188-channel-rules-dialog`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`), and
`origin/review/c-601-s-new-topic-list-end-v01` holds
`189-new-topic-list-end`; no other remote ref holds a `19x-` folder
(`git ls-tree` over all 514 remote refs -> none), so this is 190.

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`,
`wui/` = `csi-spl-wui/src/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`tf/` = `csi-spl-iac/src/terraform/`, `cnf/` = `csi-spl-cnf/csi-spl/`.
Every `file:line` was read on `cd2012822`.

## 0. The owner's ask (verbatim)

HUM-10, t1 topic `bc3df46d`, msg `b04212f4-3cb9-430a-9407-4b1516650d74`:

> "add the capability to insert pictures or multimediaa - videos songs etc
> into the qto docs - the files will be stored in s3 - whoever has access t
> othe qto doc , must have access to the media files as well ... prio:05"

Three requirements follow; every section below serves one of them:

- **M1** insert pictures, video and audio ("songs") into a Qto doc;
- **M2** the bytes sit in object storage ("s3");
- **M3** can read the doc = can read its media; nothing else can (no
  public link, no link that outlives the reader's access).

**"s3" on this estate.** The estate is GCP only. Every file byte of the
hub already sits in a GCS bucket (section 2.5). GCS also speaks the S3 XML
API (HMAC keys), and the hub already carries an S3 driver
(`api/blob/s3.go:35-47`, `OpenS3` `:76`). So M2 is met by a GCS bucket,
with no AWS account. AWS S3 is an option in the form (Q1 C) only because
the owner wrote "s3".

## 1. Owner questions (one form)

The holder posts this form. The first option of each question is the
recommendation. Keys are at most 3 characters. Every later section marks
what it depends on as **[Qn X]**; an answer other than the first option
rewrites only those parts.

Recommended: **Q1 A, Q2 A, Q3 A, Q4 A, Q5 A, Q6 A, Q7 A**. "s3" is met by
the workspace's own GCS bucket (S3-compatible API, no AWS needed).

```poll
Q1. Where are the media files stored? ("s3" is met by GCS: it speaks the S3 API; no AWS needed)
(A) In each workspace's own private GCS bucket (step 052), next to its Qto pictures
(B) One new GCS media bucket per environment, a prefix per workspace
(C) AWS S3 (a new AWS account, keys and egress to GCP)
Q2. How does the browser fetch a media file?
(A) Through the hub, which checks the doc on every request (no link works without the session)
(B) A short-lived signed URL (5 min) issued after the doc check (works for anyone holding it until it expires)
(C) Pictures and audio through the hub, video by signed URL
Q3. Size caps?
(A) Picture 5 MiB (as today), audio 32 MiB, video 32 MiB; all inside the workspace's 10 GiB file quota
(B) Picture 10 MiB, audio 100 MiB, video 500 MiB, quota 50 GiB (needs resumable uploads)
(C) Caps per workspace in its settings, defaults as A
Q4. Which file types?
(A) Pictures, video (mp4, webm) and audio (mp3, m4a, ogg, wav)
(B) A, plus any other file shown as a download card
(C) Pictures and video only
Q5. How is a file inserted?
(A) Upload button, drag and drop and paste, as pictures are today
(B) A, plus picking a file already attached to a post you can read
(C) Upload button only
Q6. What happens to a file when its doc or section is deleted, or the doc is shared or unshared?
(A) Access follows the doc at every fetch; a file no doc names is deleted after a 7-day grace
(B) Access follows the doc; a file no doc names is kept 30 days, then deleted
(C) Access follows the doc; files are never deleted automatically
Q7. Print, PDF and markdown export?
(A) Pictures print inline; video and audio print as a card (caption, type, length); md export keeps the link
(B) A, and a video prints its first frame as a poster
(C) A, and the md export writes the media files next to the .md
```

### 1.1 The owner's answers

None yet. The holder relays them; v0.2 writes them in here and removes
the **[Qn]** marks the answers settle.

## 2. What exists (measured on `origin/master` `cd2012822`)

### 2.1 The Qto doc storage model

- A doc is a `workspace_doc` row (`rdb/0157_workspace_docs.sql:33`):
  tenant, title, `rev`. Its sections are `workspace_doc_item` rows (`:44`):
  `parent_id` + `ord` (the outline), `title`, a markdown `body` of at most
  1 000 000 characters (`:51`) and an `attrs` JSON object (`:52`). Every
  edit is a `workspace_doc_rev_log` row (`:71`).
- The tree (folders, docs) is the nested set `workspace_doc_node`
  (`rdb/0165_workspace_doc_node.sql:39`), spec 120.
- The text stays in Postgres; the files go to the bucket (owner msg
  78f4ffd3, quoted at `api/hub/wsdoc_assets.go:28-30`).

### 2.2 The doc access check

- Every doctree route resolves its caller with `docTreeCaller`
  (`api/hub/wsdoc_tree.go:175`): an agent token (`docTreeWho`, `:221`) or a
  signed-in member holding the route's permission (`rbac.DocsRead` /
  `rbac.DocsWrite`, `s.permit`). The doc must be the caller's tenant's:
  `DocHeadOf(ctx, tenant, doc)` (`api/store/wsdoc_hub.go:81`), else 404.
- A doc locked to one person (spec 125 B8,
  `rdb/0256_workspace_doc_restricted_to_human.sql`, column
  `restricted_to_human` `:49`) is enforced by the database: the hub marks
  the request with the reader's human (`docTreeHuman`,
  `api/hub/wsdoc_lock.go:32`) and the RESTRICTIVE `human_lock` policies
  decide every read (`api/hub/wsdoc_lock.go:10-17`). `DocHeadOf` runs under
  that mark, so a locked doc's pictures answer 404 to everyone but its human.
- Spec 114's per-node grants table `workspace_doc_acl`
  (`rdb/0192_workspace_doc_acl.sql:28`: subject, action
  read|edit|manage|share, allow|deny) exists, but no hub read path
  consults it: `grep -rln workspace_doc_acl api/store/ api/hub/` lists only
  `channel_move_docs_postgres.go`, `channel_copy_apply_postgres.go` and
  tests. So today "can read the doc" = a member of the workspace holding
  `docs.read` (or an agent token), minus a doc locked to another human.
  **M3 is therefore a rule on top of whatever the doc check is**: the media
  route calls the same check as the doc read, and when spec 114's grants
  are enforced on the doc read, the media follow with no change of their
  own (section 7.1 C1).

### 2.3 Post attachments today

- Upload: `POST /v1/files` (`api/hub/server.go:487`, `handlePutFile`
  `api/hub/rest.go:31`) with the WS-issued upload token. The body is
  streamed to a scratch object while hashed (`streamUpload` `:105`), then
  promoted to its content key `t/<tenant>/files/<sha256>`
  (`api/blob/blob.go:1-4`).
- Caps: 32 MiB per file (`api/msg/msg.go:44` `MaxFileBytes`), checked on
  the declared length (`uploadFitsDeclared` `api/hub/rest.go:81`) and on
  the stream. Per-tenant quota `SPOOL_HUB_QUOTA_FILE_BYTES` = 10 GiB
  (`cnf/all.env.yaml:586` `"10737418240"`); its usage already counts the
  workspace's Qto pictures (`fileUsage.extra`, `api/hub/fileusage.go:26-28`).
- Read: `GET /v1/files/{file_id}` (`api/hub/rest.go:188`), proxied by the
  hub, never a signed URL: a session or token of the tenant, then the read
  door `mayReadFile` (`:284`, `fileReadableBy` `:311`: the file is as
  private as the messages carrying it). Served as
  `application/octet-stream`, `Content-Disposition: attachment` (`:231`),
  CSP `sandbox`, cached `private, immutable` for 24 h, the whole object by
  `io.Copy` (`:245`): **no `Range` support**
  (`grep -n 'Range\|ServeContent' api/hub/rest.go` -> none).
- Retention: an upload no message carries is readable by its uploader for
  `FileUploadGrace` = 1 h (`api/hub/file_retention.go:26`), then swept; a
  blob a doc names is kept (`fileKept`, `api/hub/wsdoc_assets.go:310`).

Fit for M3: its door is the **message** rule, not the doc rule, so it is
not reused for the read. Its streaming upload, quota and sweep are.

### 2.4 Pictures in Qto docs today (the path this spec extends)

Two routes already put pictures into a doc, both registered at
`api/hub/wsdoc_tree.go:143-146`:

| route | key in the workspace's bucket | where the doc names it |
|---|---|---|
| `POST /v1/workspace/doctree/{doc}/images` (`api/hub/wsdoc_media.go:75`), `GET .../images/{name}` (`:106`) | `.doctree/<doc>/<sha256>.<ext>` (`:49`) | a section's `attrs.img_http_path`, or a `![caption](<path>)` token in a body |
| `PUT /v1/workspace/doctree/{doc}/assets/{path...}` (`api/hub/wsdoc_assets.go:110`), `GET` (`:249`) | `qto-assets/<sha256>` (`:50`); tenant `system` uses the hub store | the doc root's `attrs.assets` map, path `<doc>.assets/NN-name.ext` |

Both: at most 5 MiB (`DocTreeImageMax`, `api/hub/wsdoc_media.go:34`),
png/jpeg/gif/webp sniffed from the bytes and matching the sent type, no
SVG; read with `rbac.DocsRead` through `DocHeadOf` (section 2.2); served
by the hub with `nosniff` + CSP `sandbox` (`docHeaders`,
`api/hub/workspace_docs.go:194`), the whole object, no `Range`.

The WUI: `useDocPictures.ts` takes a picture from the file picker, a paste
or a drop (`wui/composables/useDocPictures.ts:27-33`, `:59-66`), checks it
as the hub does (`DOC_IMAGE_TYPES`, `DOC_IMAGE_MAX`,
`wui/components/workspace-docs/-doctree-api.ts:28-29`), uploads it and
writes the token. The viewer reads each picture with the session's
credentials into a **`data:` URL** (`-doctree-api.ts:57-61`,
`readDataUrl`) and shows it in an `<img>`
(`wui/components/workspace-docs/WorkspaceDocView.vue:249-250`); print shows
it with its "Figure N:" caption (`WorkspaceDocPrint.vue:62`).

Retention: `qto-assets/` objects no doc names are swept from each
workspace's own bucket (`api/hub/wsdoc_assets_orphan_sweep_test.go:1-5`,
SPL-2963). **`.doctree/<doc>/` objects have no sweep**: outside tests,
`grep -rn '\.doctree/' api/hub/*.go api/store/*.go` finds only the key
function and its comment (`wsdoc_media.go:26,49`).

### 2.5 Object storage on the estate

- `tf/050-gcs-files/03-files-bucket.tf:15-22`: the hub's file bucket, one
  per env, uniform access, `public_access_prevention = "enforced"`, no
  CORS, reached only by the hub's runtime SA.
- `tf/052-gcs-workspace-docs/03-workspace-docs-buckets.tf:18-32`: **one
  private bucket per workspace** (spec 114 section 9), the same hygiene,
  versioning on, soft delete 7 days. Its only lifecycle rules are for
  `backup/` (`:38-41`: "No other prefix has a lifecycle rule"). So a
  deleted object of any other prefix stays as a **noncurrent generation
  with no expiry**, a gap for media GC (G7).
- `tf/051-gcs-docs`, `053-gcs-public-dataset`, `054-gcs-blog-media`: repo
  docs, a public dataset, blog media. None is for private doc media.
- The hub's drivers: GCS native (`api/blob/blob.go:248` `type GCS`,
  `OpenGCS` `:256`), S3 (`api/blob/s3.go:76`, for a compose S3 or any S3
  endpoint) and a local `Dir` for tests and lde.

### 2.6 The browser side

- The deployed CSP (`csi-spl-wui/nuxt.config.ts:156-160`, `CSP_PROD`) has
  `img-src 'self' data:`, `connect-src 'self' <hub>` and **no `media-src`**:
  a `<video>` or `<audio>` falls back to `default-src 'self'`, so today it
  can play neither a hub URL nor a `blob:` URL (G5).
- The session cookie is `SameSite=Lax` (`api/auth/handler.go:1676`); the
  WUI calls the hub with `credentials: api.credentials`
  (`-doctree-api.ts:59`). I believe, unchecked, that a
  `<video crossorigin="use-credentials">` on the hub's origin sends that
  cookie (the WUI and the hub are the same site); row W2 proves it in
  Chrome before anything relies on it.

## 3. The flow, end to end

1. **Insert** (WUI editor): the existing picture controls widen to media.
   The file picker, a paste and a drop take a picture, a video or an audio
   file **[Q4 A, Q5 A]**. The editor checks type and size as the hub does
   (C3) before any byte leaves the browser.
2. **Upload**: `POST /v1/workspace/doctree/{doc}/media` with the bytes and
   their `Content-Type` (C2). The hub runs `docTreeCaller(rbac.DocsWrite)`
   and `DocHeadOf` (the doc is the caller's tenant's and not locked to
   someone else), checks the per-type cap and the workspace quota on the
   declared length (as `uploadFitsDeclared`), then **streams** the body to
   a scratch key while hashing it (as `streamUpload`; never `readAllCapped`
   for video, which holds the whole body in memory), sniffs the first 512
   bytes and promotes it to `qto-media/<sha256>.<ext>` in the workspace's
   bucket **[Q1 A]**.
3. **Reference**: the hub answers `{name, bytes, kind, http_path}`; the
   editor writes the token `![caption](<http_path>)` at the cursor. It is
   the token pictures use, so `-doc-pics.ts` `picRuns`, export and print
   find it. The doc's text names the file; the media index records it (C6).
4. **Render** (WUI viewer): a token whose path ends in a picture extension
   stays an `<img>` (data: URL, as today). A video extension renders
   `<video controls preload="metadata" crossorigin="use-credentials">`, an
   audio one `<audio controls preload="metadata" ...>`, both with `src` =
   the hub URL, streamed with `Range`, never read whole into a data: URL
   **[Q2 A]**. This needs `media-src` in the CSP (G5, row W2).
5. **Fetch with the access check**:
   `GET /v1/workspace/doctree/{doc}/media/{name}` runs the doc read check of
   section 2.2 on **every** request (C1), then serves the object with
   `http.ServeContent` semantics (`Range`, `206`, `Accept-Ranges`), the
   stored type, `nosniff`, CSP `sandbox` and `Cache-Control: private,
   no-cache` (not `immutable`: a revoked reader's browser must go back to
   the door, C5) **[Q2 A]**.
6. **Delete / GC**: removing a token from a section, deleting a section or
   deleting the doc leaves the object in place. The sweep deletes a
   `qto-media/` object no doc of the workspace names once the grace has
   passed **[Q6 A: 7 days]**, and a 052 lifecycle rule expires its
   noncurrent generation (G7). Sharing, unsharing or locking the doc
   changes nothing in storage: the next fetch's check answers it (C1).

### 3.1 Reused

- The workspace's own 052 bucket and its `WorkspaceDocs.Store` resolver
  (`api/hub/wsdoc_media.go:67`, `docAssetBucket` `wsdoc_assets.go:54`).
- `docTreeCaller` + `DocHeadOf` + the `human_lock` policies: the doc rule,
  unchanged.
- `streamUpload`, `keepUpload` and `fileUsage` (`api/hub/rest.go:105,131`,
  `fileusage.go`): streaming, dedup by sha256, the 10 GiB quota.
- The own-bucket orphan sweep of `qto-assets/` (SPL-2963), widened to
  `qto-media/` and `.doctree/` (G6).
- The WUI picture controls, the token, `picRuns`, print and md export.

### 3.2 Gaps

| id | gap | where | row |
|---|---|---|---|
| G1 | no route takes video or audio; the picture routes cap at 5 MiB and hold the body in memory | `wsdoc_media.go:34,80` | H1 |
| G2 | no `Range` read: a 30 MiB video downloads whole before it plays, and a seek downloads it again | `rest.go:245`, `wsdoc_media.go:130`; `blob.Store` has no range read | B1, H2 |
| G3 | no media index: the sweep would have to parse every body to know what a doc names | `wsdoc_assets.go:310` (`fileKept` asks the root attrs only) | D1 |
| G4 | the WUI reads every picture into a data: URL; a video read that way is the whole file in memory | `-doctree-api.ts:57-61` | W2 |
| G5 | no `media-src` in the deployed CSP | `nuxt.config.ts:156-160` | W2 |
| G6 | `.doctree/<doc>/` pictures are never swept | section 2.4 | H3 |
| G7 | 052 keeps a deleted object's noncurrent generation for ever outside `backup/` | `052-.../03-workspace-docs-buckets.tf:38-41` | T1 |
| G8 | Cloud Run's request size limit: I believe, unchecked, that an HTTP/1 request body over 32 MiB is refused before the hub sees it, so caps above 32 MiB need a resumable or chunked upload **[Q3 B]** | Cloud Run | H1 measures it first |

## 4. The access rule (M3)

**Can read the doc = can read its media. Nothing else can.**

- The media route asks exactly the doc read's question, in the same
  request, with the same caller resolution and the same `human_lock` mark:
  no cached past answer, no capability in the URL.
- The `name` (a sha256) is **not** a capability. The object is looked up
  under the doc in the path, and that doc must pass the check; a sha256
  known from another doc or another workspace answers 404 (C1).
- Never a public link: the bucket keeps `public_access_prevention =
  enforced`, no object ACL, no signed URL **[Q2 A]**. Under **[Q2 B]** a
  signed URL is a bearer link for its TTL; the form says so.
- "Not yours" and "no such file" answer the same 404, as the attachment
  door does (`rest.go:196-205`).
- Agents: an agent token reads media as it reads the doc (`docTreeWho`),
  and never a doc locked to a human.

## 5. Data (rdb) **[Q4, Q6 A]**

One new tenant table, the media index (G3), at the next free migration
number:

`workspace_doc_media (tenant_id, doc_id, sha256, ext, kind, bytes, name, created_by, created_at)`,
primary key `(tenant_id, doc_id, sha256)`, `kind IN ('image','video','audio')`
**[Q4 A]** (`'file'` added under **[Q4 B]**), RLS like `workspace_doc_item`
(the tenant policy, plus the `human_lock` RESTRICTIVE policy through
`doc_id`). The upload writes it with `INSERT ... ON CONFLICT DO NOTHING`.
The doc's text stays the truth of what is shown; the index is what the
read door (C1), the sweep and the quota read. A row is dropped once no
body of its doc has carried its token for the grace; an object is deleted
once no row names it (C7).

## 6. Build order (rows a later lane can take in parallel)

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| T1 | 052: a lifecycle rule deleting noncurrent `qto-media/`, `qto-assets/` and `.doctree/` generations after 7 days; `make do-tf-plan` dev and prd, apply on the owner's go | `tf/052-gcs-workspace-docs/03-workspace-docs-buckets.tf`, `02-variables.tf`, `cnf/all.env.yaml`; `do_tpl_gen` | Q1 A, Q6 | plan: 0 to destroy, N in-place; `git diff --exit-code` after `ENV=<env> ./run -a do_tpl_gen` | a plan that replaces a bucket is refused |
| B1 | `blob.Store` range read: `GetRange(ctx, key, off, n)` and `Size` in the GCS (`NewRangeReader`), S3 (`Range` header), cached and Dir drivers | `api/blob/blob.go`, `api/blob/s3.go`, `api/blob/cached.go` + tests | none | `go test ./internal/blob` reads bytes 10-19 of a fixture on every driver | a driver returning the whole object fails the length assert |
| D1 | migration `workspace_doc_media` + RLS + `human_lock`; store methods `DocMediaPut`, `DocMediaNamed`, `DocMediaSweep` | `rdb/<next>_workspace_doc_media.sql`, `api/store/workspace_docs_media.go` + Postgres tests | Q4, Q6 | `TestRLSCoversEveryTenantTable` green; a locked doc's row is invisible to another human | the table without its policy fails `TestRLSCoversEveryTenantTable` |
| H1 | hub upload `POST .../media`: caller + doc check, per-type cap and quota on the declared length, stream to scratch, sniff, promote to `qto-media/`, index row; first measure G8 on dev | `api/hub/wsdoc_media_av.go` (new), route next to `wsdoc_tree.go:143-146` | D1, Q3, Q4 | Go tests: a 20 MiB mp4 is stored; a 33 MiB one is 413 before the body; an mp4 sent as `audio/mpeg` is 415; an agent token stores | the route with `readAllCapped` in place of the stream fails the memory bound test |
| H2 | hub read `GET .../media/{name}`: the doc check on every request, `Range`/`206`, the headers of C5 | same file | B1, D1, Q2 | Go tests: `Range: bytes=0-99` -> 206 + 100 bytes; another workspace's sha -> 404; a doc locked to someone else -> 404 | the route without `DocHeadOf` must FAIL the 404 tests |
| H3 | sweep: `qto-media/` and `.doctree/<doc>/` objects no doc names, after the grace | `api/hub/file_retention.go`, the own-store walk of SPL-2963 | D1, Q6 | Go test on a fake clock: a deleted doc's video is gone after grace + 1 s, a named one stays | the sweep without the `qto-media/` prefix leaves the gone doc's video and fails |
| W1 | WUI editor: picker, paste and drop accept video and audio; client caps; the token | `wui/composables/useDocPictures.ts` (or a sibling `useDocMedia.ts`), `-doctree-api.ts` | the C2 contract only, Q4, Q5 | unit test of the type and size checks; e2e on the mock hub inserts an mp4 and sees the token | a 40 MiB file reaching the mock hub fails the test |
| W2 | WUI viewer: `<video>` / `<audio>` with the hub `src`; `media-src 'self' <hub>` in `CSP_PROD` and `firebase.json` | `WorkspaceDocView.vue`, `-doc-pics.ts`, `csi-spl-wui/nuxt.config.ts`, `csi-spl-wui/firebase.json` | the C5 contract only, Q2 | Chrome e2e: the video plays and seeks, a 206 in the network log; `csp-violations.test.mjs` 0 violations | the CSP without `media-src` must make `csp-violations` FAIL |
| W3 | print, PDF and md export of media | `WorkspaceDocPrint.vue`, `-doctree-export.ts` | W2, Q7 | print snapshot shows the media card; the md export keeps the token byte-stable | an export that drops the token fails the round trip |
| E1 | e2e on dev: upload, play, lock or unshare, the next fetch is 404 | `csi-spl-wui/tests/e2e/` | H1, H2, W1, W2 | the lock flips the fetch from 206 to 404 within one request | the same test against a route without the check must FAIL |
| X1 | docs: the user help page and this spec's state | `csi-spl-doc/doc/help/`, this file | H1, W2 | `./run -a do_check_fleet_rules_drift` green | - |
| X2 | i18n: every new key in every locale; **agy reviews the text last** (language rule) | `csi-spl-wui/i18n/locales/*.json` | W1, W2, W3 | `i18n-parity.test.mjs` and the raw-text ratchet green | a key missing from one locale fails parity |

Parallel at once: T1, B1, D1, W1 (against C2), X1. Then H1, H2, H3, W2,
W3; E1 and X2 last. The live doc-view lanes (header cleanup, background
themes) touch `WorkspaceDocView.vue`: W2 and W3 check
`lane-map.sh --check` first and wait for them.

## 7. Contracts

### 7.1 Binding contracts

- **C1 the door.** `GET` and `POST .../doctree/{doc}/media...` call
  `docTreeCaller` with `rbac.DocsRead` / `rbac.DocsWrite`, then
  `DocHeadOf(ctx, tenant, doc)` under the `human_lock` mark, on every
  request. The object key is derived from the path's `{doc}` workspace
  and `{name}` only after that check passes and the index names `{name}`
  for that doc. Any refusal of the doc, an unknown name, or a name not
  indexed for that doc answers **404 `not_found`** with the same body.
  When the doc read gains a check (spec 114 grants), the media routes call
  the same function, never a copy.
- **C2 upload.** `POST /v1/workspace/doctree/{doc}/media`, body = the raw
  bytes, `Content-Type` one of C3. `201 {name, bytes, kind, http_path}`,
  `name` = `<sha256>.<ext>`, `http_path` =
  `/v1/workspace/doctree/<doc>/media/<name>`; the same bytes again answer
  the same name with `200`. Errors: `413 too_large` (declared or streamed
  over the type's cap), `415 bad_media` (sniffed type not the sent one),
  the quota answer of `writeQuota`, `404` as C1.
- **C3 types and caps** **[Q3 A, Q4 A]**: image png/jpeg/gif/webp 5 MiB;
  video `video/mp4` (`mp4`), `video/webm` (`webm`) 32 MiB; audio
  `audio/mpeg` (`mp3`), `audio/mp4` (`m4a`), `audio/ogg` (`ogg`),
  `audio/wav` (`wav`) 32 MiB. Never SVG or HTML. One table in the hub,
  mirrored in `-doctree-api.ts`, with a test that reads both.
- **C4 storage.** Key `qto-media/<sha256>.<ext>` in the workspace's own 052
  bucket **[Q1 A]**; tenant `system` keeps the hub store
  `t/system/files/<sha256>`. Never public, no CORS, no object ACL. The
  bytes count against the workspace file quota (`fileUsage.extra`).
- **C5 read.** `200` or `206` with `Accept-Ranges: bytes`, `Content-Range`,
  the stored `Content-Type`, `X-Content-Type-Options: nosniff`,
  `Content-Security-Policy: sandbox; default-src 'none'`,
  `Content-Disposition: inline`, `Cache-Control: private, no-cache`,
  `Vary: Cookie, Authorization`. No signed URL, no redirect to the bucket
  **[Q2 A]**.
- **C6 the token.** `![caption](/v1/workspace/doctree/<doc>/media/<name>)`
  in a section body; the extension picks `<img>`, `<video>` or `<audio>`.
  No other syntax.
- **C7 GC** **[Q6 A]**: an object is deleted only when no
  `workspace_doc_media` row of the workspace names it and 7 days have
  passed since the last row went; 052 expires its noncurrent generation
  7 days after that.

### 7.2 Not in this spec

Transcoding, thumbnails and posters (beyond **[Q7 B]**), streaming
formats (HLS, DASH), media in channel posts (the attachment path stays as
it is), public sharing of a doc, and spec 114's grant enforcement on the
doc read itself.

## 8. Review

v0.1 goes to the holder with the form. The panel's findings and the
owner's answers fold into v0.2 (section 1.1 and the **[Qn]** marks).
