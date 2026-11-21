# Spec 190: Media in Qto docs (pictures, video, audio, files)

Status: **v1.0** (2026-11-21): the owner's answers are in (section
1.1) and the cross-vendor review passed (section 8). Lane `c-700` (`claude`, backup for
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
its streaming upload, its quota and its sweep are reused. v0.2 re-read the
parts it changes on `origin/master` `a83052abd`; the files cited in 2.3, 2.4,
052 and `-doctree-api.ts` have no diff between `cd2012822` and `a83052abd`
(`git diff --stat cd2012822 a83052abd -- <those paths>` -> empty).

Number: the highest spec on `origin/master` `cd2012822` is
`188-channel-rules-dialog`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`), and
`origin/review/c-601-s-new-topic-list-end-v01` holds
`189-new-topic-list-end`; no other remote ref holds a `19x-` folder
(`git ls-tree` over all 514 remote refs -> none), so this is 190.
Re-measured by the v1.0 review (m-755, on `origin/master` `f8667b9b`):
`189-new-topic-list-end` is on master now, the remote refs are 3417, and
no non-master head holds a `19x-` folder, so 190 is still free.

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
recommendation. Keys are at most 3 characters. In v0.1 every later
section marked what it depended on as a Q mark; v0.2 settled them all
(section 1.1).

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

HUM-10, t1 `bc3df46d`, msg `653f9c91-6f1d-4dd7-b835-0cf30e258de2`
(08:13:22Z, poll `fd47ab36`), relayed by the dispatch holder (msg
`5ada054b`):

| q | answer (the chosen option of the form, verbatim) | vs the recommendation |
|---|---|---|
| Q1 | **A**: "In each workspace's own private GCS bucket (step 052), next to its Qto pictures" | same |
| Q2 | **B**: "A short-lived signed URL (5 min) issued after the doc check (works for anyone holding it until it expires)" | **differs** (A was hub-proxied) |
| Q3 | **A**: "Picture 5 MiB (as today), audio 32 MiB, video 32 MiB; all inside the workspace's 10 GiB file quota" | same |
| Q4 | **B**: "A, plus any other file shown as a download card" | **differs** (A was media only) |
| Q5 | **A**: "Upload button, drag and drop and paste, as pictures are today" | same |
| Q6 | **A**: "Access follows the doc at every fetch; a file no doc names is deleted after a 7-day grace" | same |
| Q7 | **A**: "Pictures print inline; video and audio print as a card (caption, type, length); md export keeps the link" | same |

What the two changed answers change, and where:

- **Q2 B.** The hub never serves media bytes. After the doc check it
  signs a GCS V4 URL valid 300 s, and the browser reads the bucket
  directly: issuing (C5), expiry and refresh (C8), `Range` and seek, which
  GCS answers itself (section 3 step 5), the CSP `media-src` and `img-src`
  for the bucket host (G5, C9), and the bearer property: **a leaked URL
  works for anyone until it expires** (section 4). The signing needs a
  grant the estate does not have (G9, row T2). Gap G2 (the hub has no
  `Range` read) is no longer on the media path; row B1 becomes the signer.
- **Q4 B.** Any other file is kind `file`: stored, counted and swept like
  media, never rendered inline, shown as a download card, served by a
  signed URL that forces `Content-Disposition: attachment` and
  `Content-Type: application/octet-stream`, with a deny list of executable
  types (C3, C10, row W4).

Every other section is written for these answers; no **[Qn]** mark is
left open.

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
- The WUI calls the hub with `credentials: api.credentials`
  (`-doctree-api.ts:59`). Under Q2 B the bucket read carries no cookie and
  no `crossorigin` attribute: the signature in the URL is the credential,
  so the v0.1 question about `use-credentials` on `<video>` is moot.
- Both CSPs (`nuxt.config.ts:156-164` and `csi-spl-wui/firebase.json:39`)
  have `img-src 'self' data:` and no `media-src`; neither names a bucket
  host (`git grep -n storage.googleapis.com origin/master --
  csi-spl-wui/nuxt.config.ts csi-spl-wui/firebase.json` -> none).
- `Referrer-Policy: strict-origin-when-cross-origin`
  (`nuxt.config.ts:802`, `firebase.json:27-28`): a request to the bucket
  carries only the WUI's origin, never the doc page's path.

### 2.7 Signing on the estate

- No code signs a URL: `git grep -n -iE
  'SignedURL|SignURL|signBlob|Presign' origin/master -- csi-spl-api` finds
  only the aws sdk's indirect `presigned-url` module in `go.mod:51` and
  `go.sum`.
- The hub holds no key (repo rule: no key outside the out-of-band project
  keys). A keyless V4 signature on Cloud Run goes through the IAM
  Credentials `signBlob` call, which needs `iam.serviceAccounts.signBlob`
  on the signing SA. The only `roles/iam.serviceAccountTokenCreator` grants
  in terraform are `055-gcp-kms-marketing/04-hub-key-grant.tf:17-21` (the
  kms check SA on the runtime SA) and `056-gcs-box-state/04-box-writer.tf:25`;
  **the runtime SA has none on itself** (G9).

## 3. The flow, end to end

1. **Insert** (WUI editor): the existing picture controls widen to media.
   The file picker, a paste and a drop take a picture, a video, an audio
   file or any other file (Q4 B, Q5 A). The editor checks type and size as the hub does
   (C3) before any byte leaves the browser.
2. **Upload**: `POST /v1/workspace/doctree/{doc}/media` with the bytes and
   their `Content-Type` (C2). The hub runs `docTreeCaller(rbac.DocsWrite)`
   and `DocHeadOf` (the doc is the caller's tenant's and not locked to
   someone else), checks the per-type cap and the workspace quota on the
   declared length (as `uploadFitsDeclared`), then **streams** the body to
   a scratch key while hashing it (as `streamUpload`; never `readAllCapped`
   for video, which holds the whole body in memory), sniffs the first 512
   bytes and promotes it to `qto-media/<sha256>.<ext>` in the workspace's
   bucket (Q1 A). A file outside the media table of C3 is kind `file`,
   refused if its extension is on the deny list (C3), stored with
   `Content-Type: application/octet-stream` whatever was sent.
3. **Reference**: the hub answers `{name, bytes, kind, http_path}`; the
   editor writes the token `![caption](<http_path>)` at the cursor. It is
   the token pictures use, so `-doc-pics.ts` `picRuns`, export and print
   find it. The doc's text names the hub path, **never a signed URL**
   (a signed URL expires in 5 minutes and is a bearer link); the media
   index records the file (C6).
4. **Issue** (Q2 B): for each media token on screen the viewer calls
   `POST /v1/workspace/doctree/{doc}/media/{name}/url`. The hub runs the
   doc read check of section 2.2 (C1) and, only if it passes, signs a GCS
   V4 `GET` URL for the object, valid **300 s**, with the response headers
   pinned in the signed query (C5). It answers `{url, expires_at}` with
   `Cache-Control: no-store` and never logs the query string.
5. **Render and fetch**: the `src` of an `<img>` (kind `image`), a
   `<video controls preload="metadata">` or an `<audio controls
   preload="metadata">` is the signed URL; no `crossorigin` attribute, no
   `fetch()`, so the bucket needs no CORS. The browser reads the bucket
   directly. **Range and seek**: GCS answers `Range` on a signed `GET` with
   `206` itself; `Range` is not a signed header, so every seek inside the
   300 s works with the same URL, and no byte passes through the hub (G2
   is off the media path). A kind `file` token renders a **download card**
   (name, type, size) whose link asks for a fresh URL on click; the signed
   response forces `attachment` (C10). The CSP must allow the bucket host
   in `media-src` and `img-src` (G5, C9, row W2). Pictures inserted by the
   two existing picture routes (section 2.4) keep their hub path unchanged;
   only files uploaded through the media route are signed.
6. **Expiry and refresh** (C8): a URL is used only to start a read. A
   player that is still open asks for a new URL before `expires_at - 60 s`
   and swaps `src` keeping `currentTime` and the paused state; a `403` from
   the bucket (expired, or a seek after a sleep) makes the viewer ask once
   more, and a `404` from the issue route (access gone) replaces the player
   with "no longer available". The door is asked again at every issue, so a
   reader who loses access can start no new read; a URL already issued
   works **until it expires, for anyone holding it** (section 4).
7. **Delete / GC**: removing a token from a section, deleting a section or
   deleting the doc leaves the object in place. The sweep deletes a
   `qto-media/` object no doc of the workspace names once the grace has
   passed (Q6 A: 7 days), and a 052 lifecycle rule expires its
   noncurrent generation (G7). Sharing, unsharing or locking the doc
   changes nothing in storage: the next issue's check answers it (C1),
   and URLs already out lapse within 300 s.

### 3.1 Reused

- The workspace's own 052 bucket and its `WorkspaceDocs.Store` resolver
  (`api/hub/wsdoc_media.go:67`, `docAssetBucket` `wsdoc_assets.go:54`).
- `docTreeCaller` + `DocHeadOf` + the `human_lock` policies: the doc rule,
  unchanged.
- `streamUpload`, `keepUpload` and `fileUsage` (`api/hub/rest.go:105,131`,
  `fileusage.go`): streaming, dedup by sha256, the 10 GiB quota.
- GCS itself for the read: `Range`, `206`, the bytes. The hub serves none.
- The own-bucket orphan sweep of `qto-assets/` (SPL-2963), widened to
  `qto-media/` and `.doctree/` (G6).
- The WUI picture controls, the token, `picRuns`, print and md export.

### 3.2 Gaps

| id | gap | where | row |
|---|---|---|---|
| G1 | no route takes video or audio; the picture routes cap at 5 MiB and hold the body in memory | `wsdoc_media.go:34,80` | H1 |
| G2 | no `Range` read in the hub. **Off the media path under Q2 B**: GCS answers `Range` on the signed URL | `rest.go:245`, `wsdoc_media.go:130` | none |
| G3 | no media index: the sweep would have to parse every body to know what a doc names | `wsdoc_assets.go:310` (`fileKept` asks the root attrs only) | D1 |
| G4 | the WUI reads every picture into a data: URL; a video read that way is the whole file in memory | `-doctree-api.ts:57-61` | W2 |
| G5 | no `media-src`, and `img-src` without the bucket host, in both CSPs | `nuxt.config.ts:156-164`, `firebase.json:39` | W2 |
| G6 | `.doctree/<doc>/` pictures are never swept | section 2.4 | H3 |
| G7 | 052 keeps a deleted object's noncurrent generation for ever outside `backup/` | `052-.../03-workspace-docs-buckets.tf:38-41` | T1 |
| G8 | Cloud Run's request size limit: I believe, unchecked, that an HTTP/1 request body over 32 MiB is refused before the hub sees it. Q3 A caps at 32 MiB, so it bites only if a cap is raised later | Cloud Run | H1 measures a 32 MiB upload on dev first |
| G9 | no URL signer: no signing code, and the runtime SA holds no `signBlob` on itself | section 2.7 | T2, B1 |
| G10 | no path for a non-media file in a doc, and no download card | section 2.4 (sniffed pictures only) | H1, W4 |

## 4. The access rule (M3)

**Can read the doc = can read its media. Nothing else can.**

- The issue route asks exactly the doc read's question, in the same
  request, with the same caller resolution and the same `human_lock` mark:
  no cached past answer. A URL is issued only after that answer is yes.
- The `name` (a sha256) is **not** a capability. The object is looked up
  under the doc in the path, and that doc must pass the check; a sha256
  known from another doc or another workspace answers 404 (C1).
- Never a public link: the bucket keeps `public_access_prevention =
  enforced`, no object ACL, no CORS. The signed URL is not a public link,
  but it **is a bearer link** (the owner chose this, Q2 B): whoever holds
  it, signed in or not, in this workspace or not, reads that one object
  until it expires. So:
  - the TTL is 300 s and is not a parameter of the call (C5);
  - a reader who loses access (unshared, removed, the doc locked to
    someone else, the doc deleted) can start no new read, but a URL issued
    before that keeps working **for up to 300 s**; "access follows the doc
    at every fetch" (Q6 A) holds at the issue, not at each byte;
  - the URL is never written into a doc body, an export, a print, a post,
    a log line or an error (C6, C8); hub logs carry the route and the
    name, never the query;
  - a copied URL forwarded to someone else works for the rest of its
    300 s; nothing in GCS revokes one early except deleting the object;
  - `Referrer-Policy: strict-origin-when-cross-origin` (section 2.6) keeps
    the doc page's path out of the bucket request.
- "Not yours" and "no such file" answer the same 404, as the attachment
  door does (`rest.go:196-205`).
- Agents: an agent token is issued URLs as it reads the doc
  (`docTreeWho`), and never for a doc locked to a human.

## 5. Data (rdb)

One new tenant table, the media index (G3), at the next free migration
number:

`workspace_doc_media (tenant_id, doc_id, sha256, ext, kind, bytes, name, created_by, created_at)`,
primary key `(tenant_id, doc_id, sha256)`, `kind IN
('image','video','audio','file')` (Q4 B), RLS like `workspace_doc_item`
(the tenant policy, plus the `human_lock` RESTRICTIVE policy through
`doc_id`). The upload writes it with `INSERT ... ON CONFLICT DO NOTHING`.
The doc's text stays the truth of what is shown; the index is what the
issue door (C1), the sweep and the quota read. A row is dropped once no
body of its doc has carried its token for the grace; an object is deleted
once no row names it (C7).

## 6. Build order (rows a later lane can take in parallel)

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| T1 | 052: a lifecycle rule deleting noncurrent `qto-media/`, `qto-assets/` and `.doctree/` generations after 7 days; `make do-tf-plan` dev and prd, apply on the owner's go | `tf/052-gcs-workspace-docs/03-workspace-docs-buckets.tf`, `02-variables.tf`, `cnf/all.env.yaml`; `do_tpl_gen` | none | plan: 0 to destroy, N in-place; `git diff --exit-code` after `ENV=<env> ./run -a do_tpl_gen` | a plan that replaces a bucket is refused |
| T2 | the runtime SA may sign as itself: `roles/iam.serviceAccountTokenCreator` (or a custom role holding only `iam.serviceAccounts.signBlob`) of the runtime SA **on the runtime SA only**, never on the project; `make do-tf-plan` dev and prd, apply on the owner's go | a new file in the step that owns the runtime SA's grants (030 or 055; the lane reads both and picks the one that defines the runtime SA) | none | plan: 1 to add, 0 to change or destroy; the signer test of B1 on dev gets a 200 from the bucket | the same call before the apply answers `IAM_PERMISSION_DENIED`, recorded in the row's note |
| B1 | the signer: `blob.Signer` with `SignGet(ctx, key, ttl, respType, respDisposition) (url, expires)`; GCS: V4 through IAM Credentials `signBlob` (no key), host from cnf; S3: the sdk presign; Dir (lde, tests): an HMAC'd hub route with the same expiry and headers | `api/blob/sign.go` (new), `api/blob/s3.go` + tests | T2 for the dev check only | `go test ./internal/blob`: a Dir URL works at 299 s and answers 403 at 301 s on a fake clock; `Range: bytes=10-19` through the Dir URL answers 206 + 10 bytes | a signer that drops `response-content-disposition` from the signed query fails the header assert |
| D1 | migration `workspace_doc_media` + RLS + `human_lock`; store methods `DocMediaPut`, `DocMediaNamed`, `DocMediaSweep` | `rdb/<next>_workspace_doc_media.sql`, `api/store/workspace_docs_media.go` + Postgres tests | none | `TestRLSCoversEveryTenantTable` green; a locked doc's row is invisible to another human | the table without its policy fails `TestRLSCoversEveryTenantTable` |
| H1 | hub upload `POST .../media`: caller + doc check, per-type cap and quota on the declared length, stream to scratch, sniff, promote to `qto-media/`, index row; kind `file` with the deny list of C3; first measure G8 on dev | `api/hub/wsdoc_media_av.go` (new), route next to `wsdoc_tree.go:143-146` | D1 | Go tests: a 20 MiB mp4 is stored; a 33 MiB one is 413 before the body; an mp4 sent as `audio/mpeg` is 415; a `.pdf` is kind `file`, stored as `application/octet-stream`; an `.exe` is 415 `denied_type`; an agent token stores | the route with `readAllCapped` in place of the stream fails the memory bound test |
| H2 | hub issue `POST .../media/{name}/url`: the doc check on every call, then `SignGet` with TTL 300 s and the response headers of C5/C10; `no-store`; the query never logged | same file | B1, D1 | Go tests: a reader gets `{url, expires_at}` with `expires_at - now = 300 s`; another workspace's sha -> 404; a doc locked to someone else -> 404; a kind `file` URL carries `attachment` and `application/octet-stream`; the log capture holds no `X-Goog-Signature` | the route without `DocHeadOf` must FAIL the 404 tests |
| H3 | sweep: `qto-media/` and `.doctree/<doc>/` objects no doc names, after the grace | `api/hub/file_retention.go`, the own-store walk of SPL-2963 | D1 | Go test on a fake clock: a deleted doc's video is gone after grace + 1 s, a named one stays | the sweep without the `qto-media/` prefix leaves the gone doc's video and fails |
| W1 | WUI editor: picker, paste and drop accept video, audio and any other file; client caps and the deny list; the token | `wui/composables/useDocPictures.ts` (or a sibling `useDocMedia.ts`), `-doctree-api.ts` | the C2/C3 contracts only | unit test of the type, deny and size checks; e2e on the mock hub inserts an mp4 and a pdf and sees both tokens | a 40 MiB file or an `.exe` reaching the mock hub fails the test |
| W2 | WUI viewer: the issue call, `<img>` / `<video>` / `<audio>` with the signed `src`, refresh before expiry keeping `currentTime`, the 403 retry and the 404 "no longer available"; the bucket host (from cnf) in `media-src` and `img-src` of `CSP_PROD` and `firebase.json` | `WorkspaceDocView.vue`, `-doc-pics.ts`, `-doctree-api.ts`, `csi-spl-wui/nuxt.config.ts`, `csi-spl-wui/firebase.json` | the C5/C8/C9 contracts only | Chrome e2e on the mock hub with the Dir signer: the video plays and seeks (206 in the network log), a fake clock past 240 s swaps `src` and keeps `currentTime`; `csp-violations.test.mjs` 0 violations | the CSP without the bucket host in `media-src` must make `csp-violations` FAIL |
| W3 | print, PDF and md export of media | `WorkspaceDocPrint.vue`, `-doctree-export.ts` | W2 | print snapshot shows pictures inline (fresh URLs at print time) and a card for video, audio and files; Chrome e2e on the mock hub: `emulateMedia({media: 'print'})` shows the picture and the cards and no `<video>`, and `page.pdf()` of a doc with one picture and one video is not empty; the md export keeps the hub-path token byte-stable and holds no `X-Goog-Signature` | an export that writes a signed URL fails the round trip |
| W4 | WUI download card for kind `file`: name, type, size, a link that issues a fresh URL on click; never an inline frame, `<object>` or preview | `WorkspaceDocView.vue` (or a new `DocFileCard.vue`), `-doc-pics.ts` | the C10 contract only | unit test: a `.pdf` and a `.html` token both render the card, neither an `<iframe>`; e2e: the click downloads with `attachment` | a card rendering an `<iframe>` for a `.pdf` fails the test |
| E1 | e2e on dev: upload, play, lock or unshare, the next issue is 404 and the URL already out stops at its expiry | `csi-spl-wui/tests/e2e/` | H1, H2, T2, W1, W2 | the lock flips the issue from 200 to 404 within one request; the old URL answers 403 after 300 s | the same test against a route without the check must FAIL |
| X1 | docs: the user help page and this spec's state | `csi-spl-doc/doc/help/`, this file | H1, W2 | `./run -a do_check_fleet_rules_drift` green | the help page naming an action that is not on the tree makes `do_check_fleet_rules_drift` fail |
| X2 | i18n: every new key in every locale; **agy reviews the text last** (language rule) | `csi-spl-wui/i18n/locales/*.json` | W1, W2, W3, W4 | `i18n-parity.test.mjs` and the raw-text ratchet green | a key missing from one locale fails parity |

Parallel at once: T1, T2, B1, D1, W1 (against C2/C3), X1. Then H1, H2,
H3, W2, W3, W4; E1 and X2 last. The live doc-view lanes (header cleanup,
background themes) touch `WorkspaceDocView.vue`: W2, W3 and W4 check
`lane-map.sh --check` first and wait for them.

### 6.1 Row status

| row | state | evidence |
|---|---|---|
| T1 | **built, not applied** (SPL-6152, lane c-747): commit `chore(iac, SPL-6152): step 052 deletes the noncurrent ...`; the apply waits for the owner's go | `csi-spl-iac/src/bash/tests/tf-052-media-noncurrent.tst.sh` RED on `d42ec95e8` (rc 1), GREEN on the commit; `PLAN_REF=<that commit> make do-tf-plan` STEP 052 (tf-runner, plan only): dev `0 to add, 23 to change, 0 to destroy`, prd `0 to add, 22 to change, 0 to destroy`, every change `google_storage_bucket.workspace_docs[<slug>]` in place, the new `lifecycle_rule` only (no other attribute, no drift, no replace) |
| T2 | **built, not applied** (SPL-6152, lane c-747): commit `chore(iac, SPL-6152): step 030 lets the hub runtime SA sign as itself ...`, new file `030-cloud-run-hub/08-hub-self-sign.tf` (030, not 055: 030 defines the runtime SA and its grants, 055 only reads its account id); the apply waits for the owner's go | `csi-spl-iac/src/bash/tests/tf-030-hub-self-sign.tst.sh` RED without the file (rc 1), GREEN with it; `PLAN_REF=<that commit> make do-tf-plan` STEP 030, after the SPL-6045 030 apply: dev and prd each `1 to add, 0 to change, 0 to destroy`, the one add `google_service_account_iam_member.hub_self_sign` (`roles/iam.serviceAccountTokenCreator`, the runtime SA on itself), no drift. Red control on dev before the apply (2026-11-21, n=1): `signBlob` as the runtime SA on itself -> `403 PERMISSION_DENIED`, reason `IAM_PERMISSION_DENIED`, "Permission 'iam.serviceAccounts.signBlob' denied". The 200 from the bucket is B1's dev check, after the apply |

## 7. Contracts

### 7.1 Binding contracts

- **C1 the door.** `POST .../doctree/{doc}/media` and
  `POST .../doctree/{doc}/media/{name}/url` call
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
  `415 denied_type` (the deny list of C3),
  the quota answer of `writeQuota`, `404` as C1.
- **C3 types and caps** (Q3 A, Q4 B): image png/jpeg/gif/webp 5 MiB;
  video `video/mp4` (`mp4`), `video/webm` (`webm`) 32 MiB; audio
  `audio/mpeg` (`mp3`), `audio/mp4` (`m4a`), `audio/ogg` (`ogg`),
  `audio/wav` (`wav`) 32 MiB; these are sniffed and must match the sent
  type. **Any other file** is kind `file`, 32 MiB, not sniffed for a type,
  stored with `Content-Type: application/octet-stream`; SVG and HTML are
  never kind `image`, only kind `file`. **Deny list** (refused `415
  denied_type`, by extension, case-folded, and by an executable magic
  number: `MZ`, `\x7fELF`, Mach-O): `exe msi bat cmd com scr ps1 vbs js
  jar apk dmg app sh`, held in cnf so the owner can change it without
  code. One table in the hub, mirrored in `-doctree-api.ts`, with a test
  that reads both.
- **C4 storage.** Key `qto-media/<sha256>.<ext>` in the workspace's own 052
  bucket (Q1 A); tenant `system` keeps the hub store
  `t/system/files/<sha256>` and is signed the same way. Never public, no
  CORS, no object ACL. The bytes count against the workspace file quota
  (`fileUsage.extra`).
- **C5 issue.** `POST /v1/workspace/doctree/{doc}/media/{name}/url`, no
  body. After C1: `200 {url, expires_at}` (RFC 3339 UTC),
  `Cache-Control: no-store`. `url` is a GCS V4 signed `GET` for that one
  object, `X-Goog-Expires=300` (fixed, not a parameter), signed as the
  runtime SA through `signBlob`, with `response-content-type` = the stored
  type and `response-content-disposition` = `inline` (image, video, audio)
  or `attachment; filename="<name>"` (file) in the signed query. GCS
  serves the bytes, `Range` and `206`. The hub never proxies or redirects
  the bytes.
  `X-Content-Type-Options: nosniff` is **not** in the signed query: a V4
  signed `GET` overrides only `response-content-type` and
  `response-content-disposition` (I believe, unchecked on dev, that GCS
  takes no `nosniff` query parameter and no such object metadata key).
  The guard is the type itself: media kinds are sniffed at upload and
  must match their stored type (C3), and kind `file` is always
  `attachment` + `application/octet-stream` (C10). Whether GCS sends
  `nosniff` on its own is unmeasured; B1's dev check records the bucket's
  response headers in the row's note.
- **C6 the token.** `![caption](/v1/workspace/doctree/<doc>/media/<name>)`
  in a section body; the extension picks `<img>`, `<video>`, `<audio>` or
  the download card. No other syntax. A signed URL is never written into
  a body, an export or a print.
- **C7 GC** (Q6 A): an object is deleted only when no
  `workspace_doc_media` row of the workspace names it and 7 days have
  passed since the last row went; 052 expires its noncurrent generation
  7 days after that.
- **C8 expiry.** A signed URL lives 300 s. The WUI asks for a new one
  before `expires_at - 60 s` while a player is open, retries once on a
  bucket `403`, and on an issue `404` shows "no longer available". Access
  revoked at time t: no URL is issued after t; URLs issued before t work
  until their own expiry, at most t + 300 s, for anyone holding them.
- **C9 CSP.** `media-src 'self' <bucket host>` and `img-src 'self' data:
  <bucket host>` in `CSP_PROD` and `firebase.json`; the host comes from
  cnf (e.g. `hub.media.signed_url_host`), never a literal in code. No
  `connect-src` change: the WUI never `fetch()`es the bucket.
- **C10 download card.** Kind `file` is never rendered inline (no
  `<iframe>`, `<object>`, `<embed>` or preview); its URL forces
  `attachment` and `application/octet-stream`, so a `.html` or `.svg` file
  downloads and never runs in any origin.

### 7.2 Not in this spec

Transcoding, thumbnails and posters (the owner chose Q7 A), streaming
formats (HLS, DASH), media in channel posts (the attachment path stays as
it is), public sharing of a doc, and spec 114's grant enforcement on the
doc read itself.

## 8. Review

v0.1 went to the holder with the form; v0.2 writes in the owner's answers
(section 1.1).

Cross-vendor review: **PASS**, m-755@sat (mistral) on `f61dc3e13`, msg
`a9cb2421-8a6c-4824-bcc5-8a70da0323a8`, no W findings. The holder's GO
(c-002@sat, msg `afdc83ed-8bdd-4069-acf6-14dc2c6a3c96`) asked v1.0 to fold
the notes:

| note | where | v1.0 |
|---|---|---|
| N1 the 1.1 answers paraphrased | 1.1 | the answer column quotes each chosen option of the form verbatim |
| N2 no `nosniff` on the bucket response | C5 | stated why not: the signed query carries only the type and disposition overrides; the guard is C3 + C10; B1 records the real headers |
| N3 W3 had no Chrome e2e; X1 had no red control | 6 (W3, X1) | W3 gains a print-media Chrome e2e and a `page.pdf()` check; X1 gains a drift-check red control |
| N4 `storage.googleapis.com` inside a quoted `git grep` | 3 | kept: it is a command being cited, not a host the code uses (C9 keeps the host in cnf) |
| N5 stale ref count | header | re-measured line added under "Number" |

The G9 `signBlob` grant (row T2) stays an apply on the owner's go; this
landing is docs only.

## 9. Build status

Lane `c-745` (SPL-6152), rows D1, H1, H3. Each line names what was built
and where it differs from the text above; the landing sha is the commit
that carries the line.

- **D1 built**: rdb `0306_workspace_doc_media.sql`, store
  `api/store/workspace_docs_media.go` (`DocMediaPut`, `DocMediaNamed`,
  `DocMediaDrop`, `DocMediaSweep`, `DocGoneBefore`, `DocGoneDrop`,
  `DocMediaHold`), tests `workspace_docs_media_test.go` (Postgres). Red
  controls run: without the migration all three tests fail (`relation
  "workspace_doc_media" does not exist`); without its ENABLE / FORCE lines
  `TestRLSCoversEveryTenantTable` fails on the table; without its
  `human_lock` policy `TestDocMediaHumanLock` fails (an unmarked reader
  indexes into a locked doc). Differs from section 5:
  - the row has `unnamed_since` (NULL while a body of its doc carries the
    token; else when the sweep first saw none): it is what makes "7 days"
    measurable for C7;
  - a re-upload of the same bytes sets `unnamed_since = NULL` (`ON
    CONFLICT DO UPDATE`), so it restarts the grace; the first row's `ext`
    and `name` win;
  - a second table, `workspace_doc_gone (tenant_id, doc_id, gone_at)`,
    written by a `BEFORE DELETE` trigger on `workspace_doc`. Under RLS a
    deleted document and one locked to another human both read as "no
    document"; only the first may lose its files, so the sweep needs the
    tombstone. The FK of the media row cascades on the doc delete.
- **D1, channel move**: `workspace_doc_media` is classed Moved in
  `api/channelmove/catalogue.go` (its rows follow their doc, M8) and
  `workspace_doc_gone` not-channel. The Qto part of P4
  (`api/store/channel_move_docs_postgres.go`) stashes the media rows with
  the doc's other rows and inserts them under `<DST>`, since the FK cascade
  of the `<SRC>` delete takes them. It also drops the `<SRC>` tombstones the
  delete trigger wrote: the doc lives on in `<DST>`, and the bytes of its
  `qto-media/<doc>/` and `.doctree/<doc>/` stay in the source workspace's
  bucket, the only copy. That doc then reads as hidden in `<SRC>`, so the
  sweep keeps its files there; in `<DST>` they are not served until a
  copy step in P3 exists (not built, not a row of this spec). Test
  `TestApplyChannelMoveDocMediaNotGone` (Postgres); red control run:
  without the tombstone drop `<SRC>` keeps 1 gone row (R7 c-825 W2).
- **G8 measured** on dev, 2026-11-21T09:41Z, n=1 per size, `POST
  /v1/files` with no token (the hub answers 401 and stores nothing): a body
  of 33 554 000 bytes reached the hub (401); 33 554 432 bytes (exactly 32
  MiB) and 34 603 008 (33 MiB) got Google Frontend's own HTML 413. So on
  Cloud Run a file of exactly 32 MiB never reaches the hub; the hub's cap
  stays 32 MiB (Q3 A) and W1's client check should say so.
- **H1 built**: `api/hub/wsdoc_media_av.go` (`POST
  /v1/workspace/doctree/{doc}/media`, route at `wsdoc_tree.go` next to the
  picture routes), tests `wsdoc_media_av_test.go`. Done tests green: a 20
  MiB mp4 stored (heap +152 KiB for the upload), the same bytes again 200
  with the same name; a declared 33 MiB is 413 `too_large` with its body
  held after 64 KiB; an mp4 sent as `audio/mpeg` 415 `bad_media`; a `.pdf`
  kind `file`; `.exe` and an ELF named `.pdf` 415 `denied_type`; an agent
  token stores; quota 429 on the declared length. Red controls run: on the
  route reading the body with `readAllCapped` the memory bound fails (64
  MiB allocated); with no route every upload is 405. Differs from C2/C4:
  - the key is `qto-media/<doc>/<sha256>.<ext>`, one per document: a
    document's files go with it, and a sha256 from another doc names
    nothing (C1). The same bytes in two docs are stored twice;
  - kind `file` takes its extension from `?filename=<name>` (the body is
    raw bytes, C2), `bin` when it has none or when it is a media extension
    not sent as that type (so no file renders inline); the name is kept in
    the row for W4's card;
  - the deny list is cnf-able as `SPOOL_HUB_DOC_MEDIA_DENY` (hub config,
    default the C3 list); the cnf row itself and its tfvars render are not
    in this lane (terraform-adjacent);
  - tenant `system` (the repo tree) takes no media: 404 `media_off`;
  - the hub-side table is `docMediaTypes`; its mirror in `-doctree-api.ts`
    and the test that reads both are W1's.
- **H3 built**: `sweepOwnMedia` in `api/hub/file_retention.go`, run by
  `SweepFiles` after the `qto-assets/` walk of SPL-2963, test
  `wsdoc_media_sweep_test.go` (fake clock). Each workspace: rows no section body or attrs
  named for 7 days are dropped and their objects deleted; a doc deleted 7
  days ago loses every object under `qto-media/<doc>/` and
  `.doctree/<doc>/`; a backstop deletes any object there of a visible doc
  that nothing names and that is older than 7 days; scratch uploads
  (`qto-media.tmp/`) go after 24 h. A doc locked to a human is hidden from
  the sweep and keeps its files. Done test green: at grace - 1 s the gone
  doc's files and an unnamed video are kept; at grace + 1 s they and an
  unnamed picture are gone, the named video, the named picture and the
  locked doc's video stay (and still at 3x grace). Red controls run:
  without `qto-media/` in the per-doc walk the gone doc's video stays;
  with no media sweep (origin/master) four files stay. A doc deleted
  before rdb 0306 has no tombstone, reads as hidden, and keeps its files.
