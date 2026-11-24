# 194 Workspace Google Drive upload

Version v0.1 (2026-11-24), the first draft for the owner and the
cross-vendor review. Doc only: nothing is built, no GCP resource or key was
made, no Google API was called.

Source: the owner's topic in the csitea workspace, channel `#csi-legal`,
`topic:32f85fd8-ed3f-4cc2-95f6-431b2bfbcd0d`. Issue: SPL-6398, epic
SPL-2750. Sibling: [149 Google Calendar connect](../149-google-calendar-connect/spec.md)
(the only Google integration on master; it is per-member OAuth, this one is a
per-workspace service account).

Number: 194. `git ls-tree --name-only origin/master csi-spl-doc/specs/` ends
at `192-agent-login-from-wui`; 193 is used by the review branch
`review/c-774-spl6375-skills-per-kind` (`193-skills-per-agent-kind`), and no
other `review/*` branch adds a spec folder at 193 or above (all 360 checked
with `git ls-tree`).

Paths used below:

- `api/` = `csi-spl-api/src/go/spool-hub-api/`, `hub/` = `api/internal/hub/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `cnf/` = `csi-spl-cnf/csi-spl/`, `tf/` = `csi-spl-iac/src/terraform/`

Every `file:line` was read on origin/master `a626af26c` with `grep -n` or
`sed -n`. A claim about Google's own behaviour that was not tested is marked
"unchecked, I believe". This spec says **workspace**; **tenant** appears only
in code identifiers.

Placeholders: `<DRIVE_ROOT_FOLDER_ID>` (the folder the owner named, msg
c733355a; it lives in the workspace settings, never in git), `<SA_EMAIL>`
(the new service account), `<WS>` (a workspace id, e.g. `csitea`).

## 0. The owner's ask, verbatim (HUM-10, 2026-11-24)

- 8585027d: "create the programatic means to upload files uploaded here to
  the google drive of the csitea"
- 9fca2272: "for eample this document needs to be uploaded to the google
  drive ..." (a PDF, 805043 bytes, file_id `e5a0537e...3889`)
- c733355a: "it should up here https://drive.google.com/drive/folders/<DRIVE_ROOT_FOLDER_ID>"
- 7dcbeefb: "but as the admin and the biz owner of this csitea workspace I
  would like to have the system account and the means to be able to just
  update a file here in this system and for it to end up in the correct
  folders in the google drive , and the correct should be invesitgated by
  the agents and they should have the system account key files to do this ..."
- 19b79f6b: "aka we might have to create some integration and system account
  , we do have some system accounts and keys files though check the backup
  jobs under /opt , can we use some of them"
- 5e515539 (poll 612e62d9): **C - Both: automatic in #csi-legal, the action
  everywhere else.** Decided; this spec builds both triggers.

The topic was re-read from prd (`do_spl_db_query`, messages where task_id =
the topic: 8 rows, the last at 13:20Z): no later owner post.

## 1. What exists today

### 1.1 How a posted file is stored

- A file is a blob keyed by the sha256 of its bytes: `t/<tenant_id>/files/<sha256>`
  in one bucket (`api/internal/blob/blob.go:1-4`, `Key` at `:29`); the bucket
  is cnf `050-gcs-files.files_bucket_name` (`cnf/prd.env.yaml:158-161`).
- Upload: `POST /v1/files` (`hub/server.go:517`, `hub/rest.go:31`). The same
  bytes uploaded twice are stored once: `blobExists` answers the existing
  file_id (`hub/rest.go:57`). So **file_id = sha256 is already the
  idempotence key** this spec needs.
- A message carries its files as `Attachment{mode, kind, file_id, name,
  bytes, sha256}` (`api/internal/msg/msg.go:90-98`); in prd the owner's PDF
  is one `{"mode":"blob","bytes":805043,"file_id":"e5a0537e...","sha256":"e5a0537e..."}`
  on msg 9fca2272.
- Read: `GET /v1/files/{file_id}` (`hub/server.go:518`, `hub/rest.go:188`)
  behind the read door `mayReadFile` (`hub/rest.go:287`): a file is readable
  only by who may read a message carrying it. Delete: `DELETE
  /v1/files/{file_id}` (`hub/server.go:527`, `hub/wui.go:1375`).
- Retention: a blob that no message in retention carries is removed by
  `orphanDelete` (`hub/file_retention.go:192`). **The hub is not an archive;
  Drive would be the durable copy.**
- Specs 137 (Qto doc editor), 160 (file streams) and 190 (Qto doc media)
  were read for this: none stores a posted attachment elsewhere or exports
  it, so none applies beyond the blob store above.

### 1.2 How a desk agent gets the file

- The box client pulls every blob attachment of an inbound message into its
  box store: `fetchBlobs` (`api/internal/hubclient/hubclient.go:1100`) ->
  `FetchFile` (`:1240-1253`, `GET /v1/files/{id}`, re-hashed before it is
  kept) into `$SPOOL_ROOT/files/<file_id>` (`api/internal/config/config.go:1092`).
- An agent copies it out, verified, with `spool get-file` or the MCP tool
  `spool_get_file` (`api/internal/mcp/mcp.go:59-63`, `:175`).
- Checked: the owner's PDF is already in the csitea desk's box store (a
  `find` on the desk dir for `e5a0537e*` -> 1 file). The bytes are on the
  box where the desk agent runs; nothing new is needed to reach them.

### 1.3 How Google APIs are reached today

- Spec 149: per-member OAuth (cnf `gcal`, `cnf/all.env.yaml:1198-1205`),
  tokens sealed with the KMS sealer; the hub calls Calendar and People. No
  service account talks to a Google Workspace API.
- GCP service accounts: one project SA per env, its key minted out of band
  to the per-env key dir (repo `CLAUDE.md`, "Service accounts only, per
  environment"), with `roles/owner` on its project
  (`csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh:34`).
- The pattern for a **dedicated, narrow SA** exists: step
  `tf/071-gcp-evlog-reader-sa/03-sa.tf:11` makes the SA and says "NO key
  here"; the key is minted by `do_gcp_evlog_reader_key`
  (`csi-spl-iac/src/bash/run/gcp-evlog-reader-key.func.sh:90`, one `gcloud
  iam service-accounts keys create` as the env project SA, on the owner's
  go). This spec copies it.
- The Drive API is not enabled in any project the repo manages: cnf
  `001-enable-gcp-services.gcp_services` (`cnf/all.env.yaml:61-94`) lists
  `calendar-json` and `people` but no Drive;
  `git grep -n 'drive.googleapis' -- csi-spl-iac csi-spl-cnf` -> 0 lines.

### 1.4 The gap

Nothing in csi-spl writes to Google Drive: `git grep -niE
'googleapis.com/auth/drive|drive/v3|\brclone\b' origin/master` -> one hit,
the `rclone` package in a box package list
(`csi-spl-iac/cnf/box-pkgs/base-pc.txt:429`). Missing: an identity that may
write the folder, its key on the desk box, a routing map, a hub record per
upload, the two triggers and the reply.

## 2. Reuse first (owner 19b79f6b): the inventory

Read-only, names and roles only, 2026-11-24. Box 1 = the desk box (read by
this lane); box 2 = the second fleet box (read by its orchestrator for this
lane, relay msg e41f66a4, n=1). No key content, no key path and no other
organisation's project is named.

| what | box 1 | box 2 |
|---|---|---|
| crontab lines on backup, sync, rclone, gsutil, gcloud, drive, bucket | none about backups or Drive (the matches are clock and login sync); `/etc/cron.d` holds none | one user: `do_backup_creds` (2), `box-state-backup-cron.sh` (1), the `cron-no-stack.sh` wrapper (3), login and clock sync; **none mentions Drive or rclone** |
| backup code under /opt | the repo's own: workflow 45 (`.github/workflows/45_db-backup.yml`), steps 045 / 046 | the same repo actions (`spl-backup-offsite`, `spl-box-state-backup`, `spl-db-backup*`, `spl-wsdoc-backup`), the release repo's DB backups; no rclone script |
| rclone | not installed, no `rclone.conf` | installed; one `rclone.conf` with only a `DEFAULT:` entry: **no Drive remote is configured** |
| code that writes Drive | the web repos carry `do_upload_txt_to_gdrive` (rclone with `--drive-service-account-file`, a utility SA) | the same, plus personal Drive sync scripts; not checked whether any runs today |

Service accounts found (any GCP SA can call the Drive API once a folder is
shared with it; this lane did not check which folders are shared with each):

| SA (by role) | project | what it holds | reuse for Drive? |
|---|---|---|---|
| env project SA, dev / prd | the env project | `roles/owner` on it; held by every agent on the box and by CI (workflow 45 writes it from a GitHub secret, `45_db-backup.yml:42-43`) | **no**: the widest key there is; a share to it gives every agent and every CI job the legal folder |
| release SAs, dev / prd / all | the env projects | release and deploy | no: the same holders, an unrelated purpose |
| backup SA | the off-project backup project (step 046, `cnf/dev.env.yaml:114-133`) | owner of the backup project and the off-site dumps | no: one leak would expose both the DB backups and the legal Drive |
| billing SA | the satellite project | billing, budgets | no: unrelated; the billing key stays narrow by owner rule |
| utility "rclone backup" SA | a utility project outside this repo | a key on box 2 that no cron uses | possible, not advised: kept in a personal home, not made by a repo action, scope unknown |
| sheets-sync SA | the release satellite project | edits the owner's sheets and invoice files in Drive (box 2 note, unchecked here) | possible, not advised: already shared into other Drive files, so its key reaches more than this folder |

**Recommendation: a new, dedicated SA** (section 3). Reusing any of the
above adds every holder of that key to the readers of the legal folder; a
dedicated SA with **no GCP IAM role at all** reaches exactly the folders
shared with it and nothing in GCP. The one argument for reuse, "no console
step", does not hold: any SA needs the folder shared with it once.

## 3. Identity

- **One SA per workspace, in prd only**: account id from cnf
  `drive.sa_id` (e.g. `drv-<WS>`, at most 30 characters) in the prd
  project. Dev has no SA and no Drive: its tests run against a fake Drive
  (row B6), so a dev run can never land in the real folder.
- Made by a new terraform step `072-gcp-drive-sa` (the 071 shape: the SA, no
  IAM binding, no key), plan then apply in the tf-runner, the owner's go per
  apply. The Drive API is enabled through cnf `001-enable-gcp-services`
  (one line, `drive.googleapis.com`), the existing home for APIs.
- The key: minted out of band by a new named action `do_gcp_drive_sa_key`
  (the `do_gcp_evlog_reader_key` shape: `DRY_RUN=0` makes one key as the prd
  project SA, mode 0600, a `.prev` guard for rotation), on the owner's go.
  It is written only on the box that hosts the workspace's desk, readable
  only by that desk's OS user; its file name comes from cnf. Never in git,
  terraform state, a log, a message or the hub.
- Data rule: only `claude` or `grok` lanes touch the key (Kind `secret`),
  never `agy` or `qwen`.
- **Honest limit**: every fleet seed says "you keep sudo", so file mode keeps
  other OS users out, not other agents on that box. Real isolation is spec
  159's per-workspace OS user without sudo (159 rows L19, L21, T3; not
  built). Until then the key's reach is bounded by the share (section 7),
  not by the box.
- **The owner's one manual step** depends on the Drive kind (Q1):
  - a **Shared Drive** (Google Workspace): add `<SA_EMAIL>` as a member with
    the role Content manager. Files the SA uploads belong to the Shared
    Drive and use its storage. Recommended.
  - a folder in a **personal My Drive**: share it with `<SA_EMAIL>` as
    Editor. Unchecked, I believe: Google refuses a service account's upload
    into a My Drive folder, because a service account has no storage quota
    of its own (`storageQuotaExceeded`); the ways around it are domain-wide
    delegation (Workspace only) or a person's OAuth token, and the owner
    rule "no owner account" excludes the second. Row B8 proves which holds.
- No owner account and no member OAuth token is used for an upload.

## 4. Routing: "the correct folders"

- The map lives in the **workspace settings** (`tenants.settings`, rdb
  `0136_tenant_settings_jsonb.sql:32`, key `drive_map`, checked by the hub's
  settings registry): it is workspace data the workspace admin owns, not
  fleet config. cnf holds only the switch and the defaults:
  `drive.workspaces`, `drive.sa_id`, `drive.max_bytes`,
  `drive.auto_channels`. The root folder id is in the settings, never in
  git.
- The map is a list of rules, first match wins, then a default:
  `{match: {channel?, doc_type?, name_glob?}, folder_path, folder_id}`.
  `doc_type` is read from the file by the desk agent (invoice, contract,
  insurance, tax letter, bank statement, other), with the date and the
  counterparty, which name the file `YYYY-MM-DD_<type>_<counterparty>.<ext>`
  unless the owner keeps the posted name (Q5).
- **Investigation once**: a named action `do_spl_drive_tree` lists the
  folder tree under the root (folder names and ids, read only). The desk
  agent proposes a map from it and from the channel's past files; the
  dispatcher asks the owner **one poll form** to confirm it. Only a
  confirmed map is written to the settings.
- **Unknown case**: a file no rule matches with confidence is **not**
  uploaded; the agent asks the owner in the topic with a poll form (the
  likely folders as options), then adds the answer as a rule (Q4).
- **Dry run first**: `do_spl_drive_upload` with `DRY_RUN=1` (the default)
  prints, per queued file, the target path and name and writes nothing. The
  first real run waits for the owner's go on that listing.

## 5. Trigger

- **Automatic** in the channels of `drive.auto_channels` (`["csi-legal"]`
  for `csitea`): every message with a blob attachment queues one upload per
  file.
- **The action** everywhere else: "Save to Drive" on a file of a message
  card (`csi-spl-wui/src/components/FileAttachment.vue`), shown only when
  the workspace has Drive on and the viewer may read the file
  (`mayReadFile`) and may save (Q6). It queues the same row with
  `trigger = 'action'`.
- One queue, one worker: the hub writes a `drive_uploads` row (section 7)
  in state `queued`; the desk's worker (`do_spl_drive_upload`, run on a poke
  and every 5 minutes) claims it, gets the bytes with `spool get-file`,
  routes, uploads and reports the result back to the hub.
- **Idempotence by sha256**: unique `(tenant_id, file_id, folder_id)`. A
  re-post of the same bytes is a no-op that answers the existing Drive link;
  before an upload the worker also looks in Drive for
  `appProperties.spool_sha256 = <sha256>`, so a lost report never makes a
  duplicate.
- **A new version** (the same name, other bytes, the same folder): a new
  revision of the existing Drive file (Q3), so Drive keeps the history; the
  row records both sha256.
- **A delete in spool-hub** (a message or attachment removed, or retention):
  **Drive is untouched**. Drive is the archive; a removal there is the
  owner's, by hand.

## 6. What the poster sees

The desk agent replies in the topic, once per message, a markdown table
(`csi-spl-doc/doc/help/how-to-post.md`): file name, Drive path (e.g.
`<root>/Legal/Contracts/2026`) and the Drive link, or the error in plain
words (no access, too large, unknown folder -> the poll of section 4). A
no-op re-post answers "already in Drive" with the link.

## 7. Security

- **Scopes**: `drive.file` (the files the SA creates) plus
  `drive.metadata.readonly` (list the tree for routing). Unchecked, I
  believe: `drive.file` may create a file in a folder the SA did not make,
  once the folder is shared with it; if Google refuses, the fallback is
  `drive`, still bounded by what is shared. For a service account the share
  is the real boundary: it sees only what is shared with it.
- **Least privilege in GCP**: no IAM role at all; the SA cannot read the
  hub, the DB or a bucket.
- **Audit**: one `drive_uploads` row per upload (a new rdb table, RLS
  `tenant_scope` + `operator_scope`, its state changes append-only as rdb
  0174's audit table, `0174_workspace_vendor_keys.sql:74`): tenant,
  file_id, sha256, trigger, requested_by, channel, task, msg, folder_id,
  Drive file id, revision, state (`queued|done|noop|failed|asked`), error,
  timestamps. Never the key.
- **Rotation**: `do_gcp_drive_sa_key` rotates (a new key; `.prev` kept
  until the old one is deleted) every 90 days, and at once on any
  suspicion.
- **If the key leaks**: the holder can read and write exactly the shared
  folders, nothing in GCP. Response: delete the key in GCP (as the prd
  project SA, the owner's go), mint a new one, read Drive's activity log for
  the SA's edits since the leak.
- Gates: gitleaks and trufflehog (pre-push lint) on every push; the worker
  logs the SA email and the Drive ids, never a token or the key.

## 8. Build rows

| row | what | where | kind | vendor |
|---|---|---|---|---|
| B1 | terraform step `072-gcp-drive-sa` (the SA, no IAM) + the Drive API line in cnf 001 + tpl-gen + its test | `tf/072-gcp-drive-sa/`, `cnf/`, `csi-spl-iac/src/bash/tests/` | secret | claude |
| B2 | `do_gcp_drive_sa_key` (mint, rotate, `.prev` guard) + its test with a fake gcloud | `csi-spl-iac/src/bash/run/` | secret | claude |
| B3 | rdb `drive_uploads` + RLS + store + tests on Postgres | `rdb/`, `api/internal/store/` | complex_coding | claude |
| B4 | hub: queue on a post in an auto channel, `POST /v1/files/{id}/drive` for the action, the worker's claim and report routes, the `drive_map` settings key | `hub/` | complex_coding | claude |
| B5 | WUI: "Save to Drive" on `FileAttachment.vue`, i18n keys in every locale, e2e | `csi-spl-wui/` | simple_coding | claude, language review last |
| B6 | orc: `do_spl_drive_tree`, `do_spl_drive_upload` (dry run by default), tested against a fake Drive server | `csi-spl-orc/src/bash/run/` | secret | claude |
| B7 | desk agent: the routing prompt, the reply of section 6, the unknown-case poll | the desk seat brief | orchestration | claude |
| B8 | **acceptance**: the PDF of msg 9fca2272 (file_id `e5a0537e...3889`) lands in the confirmed folder, a re-post is a no-op, the reply names the path and link | prd, the owner's go | secret | claude |
| B9 | docs: the help page "Save files to Google Drive", the operations page (key, rotation, leak) | `csi-spl-doc/` | specs_and_docs | agy |

Owner steps, never a lane: S1 the go for the 072 apply; S2 the go for the
key mint; S3 share the root folder with `<SA_EMAIL>` (section 3); S4
confirm the map (poll); S5 the go on the first dry-run listing.

## 9. Open questions for the owner

- **Q1 Drive kind.** Is `<DRIVE_ROOT_FOLDER_ID>` in a Shared Drive of the
  csitea Google Workspace, or in a personal My Drive? (A) a Shared Drive: add
  the SA as Content manager - **recommended**; (B) My Drive, and I move the
  folder into a Shared Drive; (C) My Drive and it must stay there (then the
  SA likely cannot upload, section 3).
- **Q2 Reuse or new SA.** (A) a new dedicated SA per workspace with no GCP
  roles - **recommended**; (B) reuse the sheets-sync SA that already edits
  Drive files; (C) reuse the utility rclone-backup SA.
- **Q3 A changed file with the same name.** (A) a new revision of the same
  Drive file - **recommended**; (B) a new file with a suffix; (C) ask each
  time.
- **Q4 Unknown folder.** (A) ask me with a form and hold the upload -
  **recommended**; (B) upload to an `_Inbox` folder under the root and tell
  me.
- **Q5 File names in Drive.** (A) rename to `YYYY-MM-DD_<type>_<counterparty>`
  - **recommended**; (B) keep the posted name.
- **Q6 Who may press "Save to Drive".** (A) workspace admins and biz owners
  only - **recommended**; (B) every member who may read the file.
