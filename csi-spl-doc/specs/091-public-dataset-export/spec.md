# 091: Public dataset export of the Spool Hub workspace (daily bootstrap seed)

**Feature ID**: `091-public-dataset-export` · **Status**: Draft, panel round 1 (v0.1.0)
**Created**: 2026-10-05 · **Author**: c-307 (claude) · **Panel**: g-308 (grok), a-287 (agy), c-288 (claude)
**Topic**: `67b63c88-9de3-40d9-a54e-66aae05e4583` (also `afa6259d…`, `acec3b7f…`)
**Authority**: this file for behaviour and requirements. Status vocabulary: `../README.md` §2.3. Docs only:
this spec builds nothing (`../README.md` §2.4). Build starts only after the Consensus section (§13) says YES.

Builds on, and does not repeat:
- [044 open source](../044-spool-open-source/spec.md) (the export gate FR-OS-001/002: allow-list, fail closed)
- [029 backups](../029-spool-db-backup-health/) and workflow `45_db-backup.yml` (`do_spl_db_backup`,
  `do_spl_db_backup_verify`: restore into a throwaway Postgres and compare)
- [065 release notes table](../065-release-notes-table/spec.md), `do_release_note_link`, `do_release_stable`
- [077 demo users](../077-demo-users/spec.md) (isolation by workspace is the strongest fence, §2.4)

Wording: this spec says **workspace** everywhere. `tenant` appears only where it cites a code identifier
(`tenant_id`, `app.tenant_id`, `tenants`).

## 1. The owner's ask (HUM-10, verbatim)

1. msg `dae6a3fa`: "We need to add the DB exports for only the Spoolhub tenant, which are done on a daily basis,
   with their links to the release notes. This is so that the persons who are checking out the open source would
   be able to also download not only the schemas but also the data of the first tenant of the school, at least on
   a daily basis."
2. msg `356619c8`: "There should be a separate, entirely public bucket for that. Really important: only the
   Spoolhub tenant data should be exported. This has to be verified multiple times: no other internal data should
   be exported."
3. msg `1b49301e`: "This verification that no other data other than the public SpoolHub tenant data is exported
   has to be done separately by AntiGravity, by Grok, and by Claude. Each instance should verify separately that
   there is no internal data from the other tenants other than the SpoolHub tenant."
4. msg `113d2463`: "And only after this is done, then this should be started for implementation. And actually
   published so that anyone checking out the open source project would be able to also download and apply the
   database so that he will get an initial boot with at least one tenant, which is the Spool Hub tenant. All of
   the rest of the data for the creation of the other tenants should not be exported."

In one line: **once a day, an allow-listed, verified slice of the Spool Hub workspace is published as a seed file;
on a fresh database, the repo's migrations plus that file boot a working instance with exactly one workspace,
Spool Hub, and nothing about any other workspace.**

## 2. Today, measured (trunk `65d92246`)

| fact | command or file | result |
|---|---|---|
| the schema is public: forward-only migrations in the repo | `ls csi-spl-rdb/src/sql/postgres/spool-hub/*.sql \| wc -l` | 124 |
| the workspace fence is Postgres RLS, FORCE on every `tenant_id` table | `grep -n 'FORCE ROW LEVEL' csi-spl-rdb/src/sql/postgres/spool-hub/0014_tenant_rls.sql` | line 38 (one generic loop) |
| a session sees one workspace through `app.tenant_id`; an empty setting matches nothing | `0021_rls_fail_closed.sql` | `NULLIF(current_setting('app.tenant_id', true), '')` |
| the other way in is the operator scope `app.rls_scope = 'operator'` | `0014_tenant_rls.sql` line 43 | the export must never set it |
| some tables are estate-wide: no `tenant_id`, no RLS | `humans`, `human_identities`, `password_credentials`, `rbac_*`, `release_notes` | RLS cannot fence them |
| `humans` holds `email` and `display_name` | `0006_users_and_memberships.sql` | a global table |
| `messages` holds the signed envelope twice (`msg` jsonb, `env` bytea, `env_sig`) and `files` | `0001_hub_core.sql` | a column allow-list must drop them |
| DMs are messages with no channel; private channels have `channels.is_private = true` | `0001`, `0002` | the row filter needs both |
| the daily backup exports as the instance superuser, which bypasses RLS | `45_db-backup.yml` header | that path cannot be reused for a public file |
| the backup proves itself by restoring into a throwaway Postgres | `do_spl_db_backup_verify` | the pattern §9.3 reuses |
| terraform steps 045..052 are GCS buckets; 053..058 are free | `ls csi-spl-iac/src/terraform` | next free: `053` |
| stable releases are cut weekly with notes listing the migrations; every deploy mints a `v<X.Y.Z>` tag | `do_release_stable`, `do_release_version` | where the link goes (§7) |

## 3. Principles

1. **A public dataset, not a dump.** What leaves is an **allow-list** of tables, columns and rows (§4). A table,
   column or row not on it is excluded, including anything a future migration adds.
2. **Three fences, each enough on its own** (§5): a dedicated Postgres login that can only SELECT the allow-listed
   columns; that login's session pinned under FORCE RLS to the Spool Hub workspace; a `tenant_id = <Spool Hub>`
   filter in every query. The export fails if any row carries another workspace's id.
3. **Fail closed, publish nothing.** A gate failure, a verifier FAIL or a missing verdict means that day is not
   published; the previous file stays the latest.
4. **A pattern list cannot prove absence.** The gate's scans only catch what someone guessed. That is why the three
   verifiers (§8) each use a different method, and why one of them reads the data.
5. **A seed, not a mirror.** The file boots a fresh instance (§9). No member can sign in with a real secret; the
   instance's first admin is created at load time.
6. **Nothing ad hoc.** Every step is a named action plus its test; the buckets are a terraform step; the apply
   needs the owner's go.

## 4. The allow-list (version 1)

Source: the **prd** Spool Hub workspace, its id read from cnf (`env.public_dataset.workspace_id`), never a literal.

### 4.1 Rows and columns that ARE exported

| table | rows | columns | transform |
|---|---|---|---|
| `tenants` | the Spool Hub row only | `tenant_id`, `display_name`, `created_at` | `root_pubkey` NOT exported; the loader generates a new key (§9.1). `billing_status` written as `internal`, `plan_id` as `default` |
| `channels` | `is_private = false AND deleted_at IS NULL` | `channel_id`, `name`, `description`, `created_by`, `created_at`, `archived_at` | `created_by` is a member or agent id (§4.3) |
| `messages` | `channel` in the exported channels | `msg_id`, `task_id`, `parent_task_id`, `channel`, `ts`, `from_id`, `to_id`, `kind`, `body`, `is_parent`, `archived_at`, `received_at`, `expires_at` | `from_box` / `to_box` set to one synthetic box id; `msg`, `env`, `env_sig`, `files`, `typed_by` NOT exported (§11 Q6) |
| `humans` | Spool Hub members who author or are named in an exported row | `human_id` | `display_name` = `human_id`; `email` NULL; `disabled_at` NULL |
| `tenant_memberships` | Spool Hub rows of the humans above | `tenant_id`, `human_id`, `role`, `created_at` | `role` forced to `member`; `admitted_by` = `seed` |
| `release_notes` | rows whose `version` is at or below the export's version | every column | public by design (065: hygiene-filtered at ingest) |

Topics are not a table: a topic is a `task_id` thread, so it comes with its messages.

Specs and help are not in the database: they are Markdown in the repo (`csi-spl-doc`), public with the code, and
the manifest links them at the export's version. Workspace docs (spec 075 Phase 2) live in a per-workspace bucket,
not the database, and are out of v1 (§11 Q4).

### 4.2 Never exported (the gate refuses these whatever an allow-list says)

Emails and any other contact data; real names (members become their `HUM-n` id); `password_credentials`,
`human_identities`, `human_keys`, sessions, `tenant_invites`, `email_verification_tokens`,
`password_reset_tokens`, `agent_join_tokens`; tokens, keys and signatures of any kind (`root_pubkey`, `pins`,
`pins_history`, `env`, `env_sig`); IPs and user agents; DMs (`channel IS NULL`) and private channels; files and
`files` columns; auth, audit and telemetry tables (`operator_audit`, `human_events`, `flow_events`,
`wui_perf_samples`, `member_activity`); payment and seat tables; fleet tables (`fleet_*`, `boxes`, `box_stats`,
`roster`, `deliveries`); message revisions (an earlier version may hold what an edit removed); issues (§11 Q5);
and **every row of every other workspace**.

### 4.3 Member ids

A member is published as the `HUM-n` id the workspace already shows, nothing else. Agent ids (`c-NNN` and the like)
are product ids and stay. The mapping is identity: no pseudonym table that could itself leak.

### 4.4 Changing the allow-list

The allow-list lives in ONE file (`csi-spl-orc/cnf/public-dataset/allow-list.v<N>.yaml`), versioned in its name,
and matches §4.1. A change is a spec change first (this section, a panel review), then the file, and bumps `N`.
The verifiers check against this section, not the file (§8).

## 5. The export (`do_spl_public_dataset_export`, csi-spl-orc)

### 5.1 Fence 1: a login that cannot read anything else

A new Postgres role `spool_public_export`: `LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT`, not a table owner, never
granted the operator scope. It holds **column-level** `GRANT SELECT (<cols>) ON <table>` for exactly the §4.1
columns and nothing else, so a query naming any other column fails in Postgres itself. The grants are a file in
`spool-hub-roles/`, generated from the allow-list file, with a store test that pins the two equal. Its password is
a Secret Manager secret seeded by a named seed action, like the other `spl-*-secret-seed` actions.

### 5.2 Fence 2: FORCE RLS pinned to Spool Hub

Every export transaction starts with `SET LOCAL app.tenant_id = <Spool Hub id>`; `app.rls_scope` is never set.
FORCE RLS (0014, fail closed since 0021) hides every other workspace's row from this role even if a query forgot
its filter. Estate-wide tables (no RLS) are read only through the joins in §4.1, never whole.

### 5.3 Fence 3: the explicit filter

Every query carries `WHERE tenant_id = $1` (or joins through a row that does). After the read, every emitted row's
`tenant_id` is compared with the Spool Hub id; one mismatch = FATAL, nothing written.

### 5.4 Where it runs

On the GitHub-hosted runner through the Cloud SQL proxy as `spool_public_export` (the env key opens the proxy
only). Unlike the backup, rows transit the runner, but only rows the three fences let out, which are meant to be
public. The output goes to the PRIVATE staging bucket (§6), never straight to the public one.

### 5.5 The gate (fail closed, before staging)

1. **Shape**: every table and column in the file is in the allow-list; anything else = FATAL.
2. **Workspace**: no `tenant_id` other than Spool Hub's; `tenants` has exactly one row.
3. **Content scan** of the whole file: e-mail addresses, IPv4/IPv6 addresses, JWTs, PEM blocks, cloud, Slack and
   GitHub token shapes, `iam.gserviceaccount.com`, gitleaks with the repo's config, and every other workspace's id
   and display name (read at run time, matched as whole words). A hit in a **message body** removes that message
   and counts it in the manifest by class; a hit anywhere else = FATAL. After removal the scan runs again and must
   be clean (§11 Q3: drop or fail).
4. **Size sanity**: row counts within ±50% of the previous file unless the allow-list version changed; else FATAL
   (a mass drop or mass add is a defect until someone explains it).

### 5.6 The file

- `spool-hub-public-<YYYY-MM-DD>-v<X.Y.Z>.sql.gz`: plain SQL, data only (`COPY ... FROM stdin`), tables in FK
  order. `<X.Y.Z>` is the version prd's hub reports on `/version` at export time, so the file matches that
  version's migrations.
- `<same name>.manifest.json`: the file's sha256, the version and its commit sha, the migration head, the
  allow-list version and its sha256, row counts per table, the rows removed by class (§5.5.3), the link to that
  version's release note, and once published the three verdicts (§8).

## 6. Storage: terraform step `053-gcs-public-dataset` (csi-spl-iac)

| bucket | cnf key (no literal name in this spec) | access | content |
|---|---|---|---|
| public | `env.steps."053-gcs-public-dataset".public_bucket_name` | uniform access, `allUsers` object viewer, used for this dataset only | published files, manifests, verdicts, `latest.json` |
| staging | `env.steps."053-gcs-public-dataset".staging_bucket_name` | private; the env SA writes, the verifier lanes read and write `verdicts/` | the day's candidate and its verdicts |

- The env SA gets object **create** on the public bucket, not delete: names are dated, a published file never
  changes. Removal is by lifecycle rule or by the take-down action (§10).
- **Retention** (a lifecycle rule in the step, numbers in cnf): daily files 30 days; the file a stable release
  links (§7) is copied under `stable/` and kept 365 days (§11 Q2).
- `latest.json` (the one overwritten object, `Cache-Control: no-cache`) names the newest published file.
- The step runs through the tf-runner (`make do-tf-plan`, then `make do-provision` with the owner's go). Both envs
  get it: dev's buckets carry dev's Spool Hub workspace to test the pipeline; only prd's is linked from releases.

## 7. Links to the release notes

- **Manifest to note**: each manifest carries `do_release_note_link` of its version.
- **Note to file**: the weekly stable release (`do_release_stable`, workflow 55) gains a "Data" section linking the
  newest published file whose version is at or below the stable commit, next to that release's migrations (the
  schema). The README's self-hosting section links `latest.json`.
- No per-commit release note row changes: one file a day against ~5 deploys an hour; the version in the file name
  is the join.

## 8. Verification: three independent verifiers, publish only on 3/3 PASS (owner msg 3)

### 8.1 The lanes

Every day, after the export stages a candidate, three verifier lanes check the SAME staged file, bound by its
sha256: one **agy** (`a-NNN`), one **grok** (`g-NNN`), one **claude** (`c-NNN`). Each gets the staged file's URI and
sha256 and this spec, nothing else: no access to the export action's code or allow-list file, no view of the other
verdicts before writing its own, no write access to the public bucket.

### 8.2 What each checks (different methods on purpose)

| lane | method | checks |
|---|---|---|
| **claude** | **structure**: restore into a throwaway Postgres at the file's migration head | every table and column against §4.1 as written here; `tenants` has one row with the Spool Hub id; no row with another `tenant_id`; every §4.2 table empty; `humans.email` all NULL and `display_name = human_id`; no DM, no private channel (cross-checked against the live channel list read as `spool_public_export`) |
| **grok** | **content**: its own scanners, written by that lane, not the gate's | every string token of the file against its own patterns for contact data, credentials and keys; gitleaks default rules; a list of **sha256 hashes** of every other workspace's id and display name, lower-cased, which the export stages next to the file (the verifier never sees the names in clear) |
| **agy** | **reading**: a human-style review | a stratified random sample of at least 200 messages (every channel, every day present) plus every message new since the previous published file, read for what no pattern finds: another workspace or a customer named in prose, a quote from a private channel or DM, an internal host, path or credential described in words; and a shape diff against the previous file (new table, column or channel) |

A FAIL names the row (table, primary key) and the reason. A lane may add checks; none may drop the ones above.

### 8.3 The verdict file

`verdicts/<sha256>/<lane-kind>.json` in staging: `{v:1, file_sha256, lane_id, lane_kind (agy|grok|claude),
method, checks:[{name, n, result, detail}], verdict (PASS|FAIL), ts, hub_msg_id}`. The lane also posts the same
verdict as a spool message on the dataset topic from its own id; `hub_msg_id` is that message, carried in the box's
signed envelope like every hub message.

### 8.4 Enforcement (`do_spl_public_dataset_publish`)

Publishes only when, for the candidate's sha256: three verdict files exist; their `lane_kind`s are exactly
{agy, grok, claude}; their `lane_id`s are distinct and match their kind's prefix; each says `PASS`; each
`hub_msg_id` resolves to a hub message from that `lane_id` carrying the same sha256 and verdict. Then a server-side
copy of the file, the manifest (with the verdicts) and the verdicts to the public bucket, then `latest.json`.
Anything less = nothing published, and a note on the dataset topic names what is missing. A candidate not published
within 24 h is dropped.

Residual risk, stated: this proves that three lanes of three kinds posted PASS, not which model ran inside a lane.
That trust is the fleet's lane registry, as for every other agent action.

## 9. The bootstrap seed: load and test

### 9.1 Loading (`do_spl_public_dataset_load`, csi-spl-orc; one command)

`SEED_FILE=<path or URL> SEED_ADMIN_EMAIL=<email> ./run -a do_spl_public_dataset_load`

1. Fetches the file and its manifest; checks the sha256; refuses a manifest without three PASS verdicts.
2. Refuses unless the target database is at the manifest's migration head (`spool migrate` first) and holds **no
   workspace row**: the seed is for a fresh database only, never a merge.
3. Loads in one transaction under the operator scope, then checks: one workspace; counts equal the manifest.
4. Creates the instance's own secrets: a new workspace root keypair (the private key written to the operator's
   path, mode `0600`, never into the database), and the **first admin**: a new human (`humans_seq` set past the
   highest loaded `HUM-n`), membership role `owner`, a native password credential for `SEED_ADMIN_EMAIL` with a
   generated password printed once.
5. Prints how to sign in.

### 9.2 What replaces the stripped credentials

No loaded member has an identity, password, key or e-mail, so no one can sign in as a member of the real workspace;
loaded members stay only as authors of their messages. The one principal that can sign in is the admin from step 4.
The real box keys (`pins`) are not exported, so no real box can talk to a seeded hub.

### 9.3 Tests

| test | where | proves |
|---|---|---|
| seed round trip | CI on every PR touching the export, the loader or a migration: a fresh Postgres service, `spool migrate`, a **synthetic** two-workspace fixture, export, load into a second fresh Postgres, boot the hub, sign in as the seeded admin | the loader; the fences (the second workspace never appears); sign-in works with no real member's credentials |
| fences | store tests on Postgres: `spool_public_export` cannot read a non-allow-listed column, and sees no other workspace with or without the filter | §5.1, §5.2, §5.3 each on its own |
| grants equal allow-list | store test | §5.1 |
| the published file boots | scheduled, daily after publish: the round trip from `latest.json` | the published artifact, not only the code |
| the gate catches plants | gate tests with a planted e-mail, token, other workspace's name, extra column, extra workspace row | each §5.5 class fails closed |

## 10. Operations

- **Schedule**: a new workflow (next free number), daily, after the 00:17 backup slot: export to staging (prd and
  dev), dispatch the three verifier lanes (prd), publish on 3/3 (§11 Q7 for dev).
- **Kill switch**: cnf `env.public_dataset.enabled`, default `false` until the owner's go; `false` = the workflow
  says so and exits 0.
- **Take-down**: if something wrong is found after publishing, a named action deletes that file from the public
  bucket and points `latest.json` at the previous good one (a delete: the owner's go). A downloaded copy cannot be
  recalled, which is why §8 runs before publishing.

## 11. Open owner questions

| # | question | recommendation |
|---|---|---|
| Q1 | **Members' consent**: are the Spool Hub workspace's members told that their public-channel messages (under their `HUM-n` id) are published daily, and can a member opt out? | not decided here. If opt-out exists, an opted-out member's messages are dropped by the export and counted in the manifest |
| Q2 | Retention: 30 days for daily files, 365 days for the stable-linked copy | yes |
| Q3 | A scan hit in a message body: drop that message and publish the rest, or fail the whole day | drop and count; fail the day if more than 1% of messages are dropped |
| Q4 | Workspace docs (spec 075 Phase 2 bucket) in the dataset | not in v1 |
| Q5 | Issues (the workspace's tracker) in the dataset | not in v1 |
| Q6 | Loaded messages carry no signed envelope; accept that they are history only (shown, never re-delivered) | yes; the build measures the hub's behaviour first |
| Q7 | Three verifier lanes every day is ~3 agent sessions a day. Keep it daily (the owner's words), or daily gate plus each vendor's verifier script (written once by that lane, run in CI), with the three lanes re-verifying on any allow-list or schema change and weekly. Dev: gate only? | daily lanes for prd as the owner said; dev publishes on the gate alone |
| Q8 | Go for the terraform apply of step 053 and for `env.public_dataset.enabled: true` on prd | the owner's go each, once the build is green |

## 12. Functional requirements

| FR | requirement | severity |
|---|---|---|
| FR-PD-001 | Allow-list only (§4.1); §4.2 never, enforced by the gate whatever the allow-list says | must |
| FR-PD-002 | Three fences (§5.1-§5.3), each tested on its own | must |
| FR-PD-003 | The gate (§5.5) fails closed; the export never writes to the public bucket | must |
| FR-PD-004 | Separate public bucket and private staging, step `053-gcs-public-dataset`, names from cnf, retention rule | must |
| FR-PD-005 | Daily file named with date and version; manifest with sha256, counts, links | must |
| FR-PD-006 | Three verifier lanes (agy, grok, claude), methods §8.2, verdict files §8.3, publish only on 3/3 PASS §8.4 | must |
| FR-PD-007 | One-command loader on a fresh database; first admin at load time; no real secret loaded | must |
| FR-PD-008 | CI round trip and daily boot of the published file (§9.3) | must |
| FR-PD-009 | Release note links both ways (§7) | should |
| FR-PD-010 | Kill switch and take-down action (§10) | must |

## 13. Consensus

Pending: round 1 sent to g-308 (grok), a-287 (agy), c-288 (claude). Each writes `<name>-opinion.md` next to this
file and answers on topic `67b63c88`.

## 14. Version log

| version | date | change |
|---|---|---|
| v0.1.0 | 2026-10-05 | first draft for the panel (c-307) |
