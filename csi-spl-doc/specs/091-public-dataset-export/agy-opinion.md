# 091 public dataset export: agy reviewer opinion

**Reviewer**: a-287 (agy) · **Author**: c-307 (claude, `spec.md`) · **Topic**: `67b63c88-9de3-40d9-a54e-66aae05e4583`  
**Panel**: c-307 (author), g-308 (grok), c-288 (claude), a-287 (agy)  
**Read**: Database migrations under `csi-spl-rdb/src/sql/postgres/spool-hub/` (migrations 0001 through 0124), `spec.md` v0.1.0 (`d300b411f`), v0.2.0 (`c526b38d6`), v0.3.0 (`b76c46b2e`), and v0.4.0 at `51b40dcaa`.

---

## 1. Executive Summary & Core Principle

The owner requires a daily, automated database export containing strictly the public data of the Spool Hub workspace. This export serves two distinct, non-negotiable functions:
1. **A Public Dataset**: Published daily to an isolated, public-read bucket and linked directly in release notes, enabling open-source evaluators and researchers to inspect authentic platform data.
2. **A Functional Bootstrap Seed**: When applied onto a clean database migrated to HEAD, this file must immediately produce a fully functional, self-hosted Spool Hub instance with exactly one workspace (Spool Hub). All other workspaces, private communication, and real member credentials must be entirely absent.

### The Fundamental Rule: Strict Column Projection, Never a Dump
This export must **never** be generated via `pg_dump` or broad table-level dumps filtered after the fact. A raw dump exports every existing column, every future migration column, and every nested JSON document by default. 

Instead, the dataset must be constructed as an **explicit SQL projection**:
- Every query names its specific output columns explicitly (`SELECT col1, col2 ...`). `SELECT *` is strictly forbidden.
- An explicit, checked-in manifest (`public-dataset-manifest.yaml`) governs the entire pipeline. Any unclassified table or column added by future database migrations immediately halts the build.
- The database role executing the export operates with minimal SELECT privileges granted strictly on the allow-listed columns.

---

## 2. Privacy Threat Model & Data Leakage Attack Analysis

A systematic analysis of the database schema (124 migrations) identifies eight primary vectors through which confidential workspace data, private communications, or personally identifiable information (PII) could leak into the public export:

### 2.1 The Global Table Blindspot (The Fatal RLS Bypass)
Row Level Security (RLS) in the platform applies only to tables containing a `tenant_id` column (`0014_tenant_rls.sql`, `0021_rls_fail_closed.sql`). Multiple critical tables are hub-wide and completely lack `tenant_id`:
- `humans`: Contains `display_name`, real verified `email`, and UI preferences.
- `human_identities`: Contains external OAuth provider subjects, emails, and login timestamps.
- `password_credentials`: Contains argon2id password hashes and verified emails.
- `email_verification_tokens`, `password_reset_tokens`: Contain active security hashes.

**The Attack**: If the export process queries `humans` or related tables without strictly joining against Spool Hub's memberships, users from other private workspaces will be dumped. If credentials or identity rows are queried, authentication secrets will leak.

**Required Defense**:
- Tables `password_credentials`, `email_verification_tokens`, `password_reset_tokens`, `human_identities`, and `agent_join_tokens` are in a **Hard Deny** category. The export database role must have `REVOKE ALL` on these tables.
- For `humans`, rows must be queried exclusively via an `INNER JOIN tenant_memberships tm ON tm.human_id = h.human_id AND tm.tenant_id = :spool_hub_id`.
- The projected `humans` record must strip `email` (set to `NULL` or replaced with an unroutable synthetic placeholder `<handle>@example.invalid`), strip last login stamps, and retain only the public display handle and opaque `human_id`.

### 2.2 Direct Messages (DMs) and Task-Linked Cross-Contamination
In the core messaging model (`0001_hub_core.sql`), a message is a Direct Message when `channel IS NULL`. Furthermore:
- `0112_dm_ref_task.sql` introduces `ref_task_id`, allowing a private DM to reference a public channel's task.
- `0112_dm_ref_task.sql` also introduces `mirror_of`, allowing channel messages to mirror private DM answers.
- `0082_messages_topic_access.sql` structures topic access around `task_id`.

**The Attack**: If an export query fetches "all messages belonging to Spool Hub tasks", any private DM that referenced a public task via `ref_task_id` would be swept into the export! Similarly, a naive channel query that fails to check `channel IS NOT NULL` would export all DMs between workspace members.

**Required Defense**:
- Every message query must explicitly enforce:
  ```sql
  WHERE m.tenant_id = :spool_hub_id
    AND m.channel IS NOT NULL
    AND c.is_private = false
    AND c.deleted_at IS NULL
    AND m.archived_at IS NULL
  ```
- Any message row where `mirror_of IS NOT NULL` must be scrubbed (`mirror_of = NULL`) so internal DM message IDs and private linkages are never exposed.

### 2.3 Raw JSON Payloads and Binary Envelopes (`msg jsonb`, `env bytea`, `files jsonb`)
In `messages` (`0001_hub_core.sql`):
- `messages.body` holds the extracted message text.
- `messages.msg` (jsonb) holds the raw platform v:1 message object, including routing metadata, box endpoints, timestamps, and raw headers.
- `messages.env` (bytea) and `env_sig` (text) hold the signed wire envelope and cryptographic signatures.
- `messages.files` (jsonb) contains attachment metadata.

**The Attack**: A projection that sanitizes `messages.body` but includes `messages.msg` will leak box identities, internal routing headers, and potentially pre-signed file URLs. Exporting `messages.files` with internal storage bucket URLs will expose internal project bucket names and broken object references.

**Required Defense**:
- `messages.msg`, `messages.env`, and `messages.env_sig` must be strictly **withheld**.
- For the bootstrap seed, the seed loader or export projection must synthesize a clean, minimal canonical envelope object matching only the public columns, satisfying database NOT NULL constraints without leaking internal metadata (§4.4).
- `messages.files`: Private attachment links must be excluded. Only public assets explicitly staged to the public bucket may be referenced.

### 2.4 Message Revision History and Secret Redaction (`message_revisions`)
Migration `0026_message_revisions.sql` records every prior edit of a message body in `message_revisions`.
- When an author accidentally pastes an API key, email address, or private credential into a message and subsequently edits it out, the active `messages.body` is cleaned, but revision 1 in `message_revisions` retains the raw secret indefinitely.

**The Attack**: Exporting `message_revisions` would publish retracted or mistakenly pasted secrets to the world.

**Required Defense**:
- `message_revisions` must be **completely excluded** from the public dataset. A bootstrap seed only requires current active state to boot cleanly.

### 2.5 Soft-Deleted Channels and Archived Content
- `0052_channel_soft_delete.sql` implements soft deletion via `channels.deleted_at`. Deleted channels retain their messages in the database.
- `0065_messages_archived.sql` implements soft deletion and topic archival via `messages.archived_at` on thread root cards.

**The Attack**: Queries that join on channel ID without checking `c.deleted_at IS NULL` will restore deleted channels and their contents into the public release. Similarly, checking `archived_at IS NULL` only on individual rows will accidentally export replies within an archived topic.

**Required Defense**:
- The query predicate must strictly require `c.deleted_at IS NULL` on `channels`.
- The task root card's `archived_at` status governs the entire thread: all replies belonging to a task whose card is archived must be omitted.

### 2.6 Dual Database Isolation: Query Predicate AND Session RLS
Relying on a `WHERE tenant_id = :spool_hub_id` clause alone is susceptible to developer error, complex subquery joins, or Cartesian products. Relying on RLS alone fails because RLS does not cover global tables, and RLS can be bypassed if the connection assumes table ownership or the operator scope.

**Required Defense (Both, Not Either)**:
1. **Connection Role**: The export must connect using a dedicated read-only role (`spool_export_reader`). This role must **not** own any tables and must **not** possess `BYPASSRLS`.
2. **Session Configuration**: Every export transaction must execute `SET LOCAL app.tenant_id = :spool_hub_id`. The setting `app.rls_scope` must remain strictly unset (never set to 'operator').
3. **Restrictive Security Policy**: To guarantee that Fence 2 holds even if the operator scope is inadvertently activated, Postgres must enforce a `RESTRICTIVE` policy on `spool_public_export` locking rows to the configured Spool Hub workspace id.
4. **Explicit Query Predicate**: Every SQL statement must explicitly include `WHERE tenant_id = :spool_hub_id` on all workspace-scoped tables.
5. **Post-Query Invariant Check**: The exporter must programmatically verify that 100% of exported rows carrying a workspace column match the Spool Hub workspace ID. Any discrepancy aborts the process immediately.

---

## 3. The 3-Verifier Pre-Publish Gate (AntiGravity, Grok, Claude)

The owner specifically mandated that verification must be conducted independently by three separate AI engines: AntiGravity, Grok, and Claude.

### 3.1 Strict Separation and Independence
To ensure genuine redundancy and eliminate common-mode failures:
- The candidate export file is initially written to a **private staging storage prefix** (`gs://<project>-export-staging/<sha256>.sql.gz`), completely inaccessible to the public.
- Three independent verification jobs are triggered concurrently for AntiGravity, Grok, and Claude.
- Each verifier operates in an isolated environment with its own credentials and prompt context. No verifier is permitted to view the outputs, logs, or decisions of the other verifiers before filing their verdict.
- **Fail-Closed 3/3 Rule**: Promotion to the public bucket requires three independent `PASS` attestation tokens. If any single verifier reports `FAIL`, times out, or errors, the pipeline halts, the artifact is quarantined, and an alert is dispatched.

### 3.2 Concrete Verification Invariants per Engine
Each of the three verifiers independently executes a dedicated inspection checklist on the candidate file:
1. **Structural Workspace Integrity (Claude)**:
   - Restore into a throwaway Postgres at the file's migration head.
   - Verify that 100% of rows with a workspace column contain solely the Spool Hub workspace identifier.
   - Confirm that zero rows exist for any other workspace and all §4.2 tables are completely empty.
2. **Automated Content & Secret Scanning (Grok)**:
   - Scan every string token against independent pattern sets for emails, tokens, keys, hashes, internal hostnames, and IP addresses.
   - Match against a hashed list of all other workspace IDs and names (stored only in staging, never published).
3. **Semantic Reading Review (AntiGravity)**:
   - Perform human-style semantic reading on a stratified random sample of >= 200 public messages across all channels plus all new messages since the last export.
   - Detect what regex scanners miss: prose mentions of other workspaces, customers, internal host paths, and accidental quotes of private DMs or channels.
   - Perform structural shape diffs against the previous published file.
4. **Bootstrap Execution Smoke Test (Universal)**:
   - Verify that the seed-load command on a clean, isolated Postgres instance completes without constraint violations, boots the hub cleanly, and enables admin sign-in.

### 3.3 Attestation Artifacts
Each verifier signs and outputs a structured attestation manifest (`verdicts/<sha256>/<lane-kind>.json`):
```json
{
  "v": 1,
  "file_sha256": "...",
  "lane_id": "a-287",
  "lane_kind": "agy",
  "method": "reading",
  "checks": [
    {"name": "workspace_isolation", "n": 1000, "result": "PASS", "detail": "100% Spool Hub rows"},
    {"name": "semantic_sampling", "n": 250, "result": "PASS", "detail": "zero prose leaks"}
  ],
  "verdict": "PASS",
  "ts": "2026-10-05T08:00:00Z",
  "hub_msg_id": "..."
}
```
Only when valid `PASS` manifests from AntiGravity, Grok, and Claude are matched against the artifact SHA-256 does the promotion workflow trigger.

---

## 4. Dedicated Public Bucket & Cloud Infrastructure

### 4.1 Principle of Least Privilege
The public dataset must be hosted in an entirely dedicated, public-read bucket:
- **Bucket Configuration**: Created via Infrastructure as Code (Terraform step `053-gcs-public-dataset`) with uniform bucket-level access and `allUsers:roles/storage.objectViewer`.
- **Absolute Isolation**: No operational database backups, relay packets, private message files, or internal CI logs may share this bucket.
- **Strict Service Account Separation**:
  - `export-runner`: Granted read access to the database (via `spool_export_reader`) and write access **only** to the private staging bucket. It has zero permissions on the public bucket.
  - `verifier-runners`: Granted read access to staging and write access to the staging attestation directory.
  - `public-publisher`: Triggered only after 3/3 attestations pass. Granted read access to staging and write access **only** to the public bucket. It has zero database credentials.

### 4.2 Storage Layout & Release Integration
- Stored under: `daily/<YYYY-MM-DD>/spoolhub-<schema_version>-<sha256>.sql.gz`.
- Accompanied by:
  - `spoolhub-<schema_version>-<sha256>.sql.gz.sha256`
  - `attestations-<sha256>.json` (consolidated 3-verifier sign-offs)
  - `latest.json` (pointing to the newest verified daily snapshot)
- The release notes generation action (`065-release-notes-table`) links directly to the latest verified public dataset URL.

---

## 5. The Bootstrap Seed Architecture & Verification

Per owner instruction (msg `113d2463`), anyone cloning the open-source repository must be able to download this file, apply it to a local database, and immediately obtain an operational Spool Hub workspace.

### 5.1 The Load Workflow: One Command, One Action
- The load process must be packaged into a single named action:
  `./run -a do_spl_dataset_seed_load --file <path-or-url>`
  (or natively within the hub container: `spool dataset load <file>`).
- Execution Sequence:
  1. The local database is brought to current HEAD via `spool migrate` (or `docker compose up hub-init`).
  2. The loader validates schema compatibility: The dataset header specifies the schema migration level at which it was generated. If the target database is behind, the loader fails fast and instructs the user to run migrations.
  3. The SQL statements (structured strictly as `INSERT` or `COPY` operations inside a single transaction) populate the Spool Hub workspace, channels, public topics, and messages.

### 5.2 Credential Neutralization and First Administrator Creation
- **Zero Real Credentials Exported**: All real members' password hashes, tokens, session records, and OAuth identities are omitted. No external party can sign into the bootstrapped instance using a production member's identity.
- **Member Identities**: Existing members appear in the database with their public display handle, opaque `HUM-N` identifier, and unroutable placeholder emails (e.g. `member-1@example.invalid`).
- **Initial Administrator Bootstrap**:
  - The loader script requires or prompts for administrator credentials:
    `--admin-email admin@local.test --admin-password <secret>`
    (or generates a secure random password displayed in stdout upon completion).
  - The loader writes a fresh `humans` record (advancing `humans_seq` past any loaded IDs), inserts an argon2id hash into `password_credentials`, and assigns the user the `owner` role in Spool Hub via `tenant_memberships`.
  - In development mode, the instance can optionally activate `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true`, admitting the first local registrant as the workspace owner.

### 5.3 Automated CI Verification Test
Every daily export run and relevant CI workflow must validate the bootstrap seed on a pristine environment:
1. Spin up an ephemeral PostgreSQL service container.
2. Execute all repository migrations (`spool migrate`).
3. Execute the seed load command (`do_spl_dataset_seed_load`).
4. Boot the hub service binary (`spool hub`).
5. Execute end-to-end smoke tests:
   - Verify HTTP `/healthz` returns 200 OK.
   - Authenticate as the generated initial administrator.
   - Query public channels and confirm message counts match the export manifest.
   - Confirm that `SELECT count(*) FROM tenants` equals exactly 1.
   - Attempt authentication with production user identities and confirm 100% rejection.

---

## 6. Review History & Panel Consensus Evolution

### 6.1 Round 1 Review (`spec.md` v0.1.0 @ `d300b411f` & v0.2.0 @ `c526b38d6`)
AntiGravity validated the foundational architecture and filed four critical technical catches:
1. **Schema NOT NULL Constraints on Seed Load**: `messages.msg`, `messages.env`, and `messages.env_sig` are `NOT NULL`. Omitting them from the SQL export causes a NOT NULL constraint violation on load. The export projection must supply synthetic constant placeholders.
2. **DM Linkage Scrubbing**: Explicitly withhold `messages.ref_task_id` and `messages.mirror_of` (0112) so internal direct-message IDs are never published.
3. **Unclassified Column Fail-Closed Gate (C3)**: Require an explicit manifest classification (`public` or `withheld`) for every live column; fail the build if an unclassified column appears.
4. **Publisher Service Account Separation**: Ensure the account with database access cannot write to the public bucket, and the public publisher account cannot read the database.

AntiGravity also aligned with reviewer `c-288` on points R1-1 through R1-5 (public CI logging hygiene, out-of-band workspace name scanning, hash deletion, card-level task archival, and comprehensive canary testing).

### 6.2 Round 2 Review (`spec.md` v0.3.0 @ `b76c46b2e`)
In `spec.md` v0.3.0, author `c-307` adopted all of AntiGravity's round 1 points:
- Added **§4.4 (Withheld columns that the schema requires)**: Constant synthetic placeholders for `msg`, `env`, `env_sig`, and `root_pubkey` that are never read from database storage, proven by C5 canaries.
- Added explicit withholding of `ref_task_id`, `mirror_of`, and `moved_from_*` columns.
- Recorded panel positions on Owner Questions Q1 (public channel notice banner + opt-out) and Q7 (daily 3-verifier runs on production).
- Aligned §8.3 attestation schema to superset the verification requirements.

### 6.3 Round 3 Review (`spec.md` v0.4.0 @ `51b40dcaa`)
In `spec.md` v0.4.0, author `c-307` incorporated all points raised by reviewer `g-308` (`grok-opinion.md`):
- Added a `RESTRICTIVE` policy on `spool_public_export` ensuring Fence 2 holds even if the operator scope is set.
- Hardened the loader in §9.1: Each `COPY` target must be strictly in the allow-list tables (§4.1) and public column list (§4.4), rejecting any other table or statement.
- Omitted `release_notes` from the database seed file (the web interface ingests release notes from public git history).
- Excluded messages past their expiration timestamp.
- Explicitly exempted the initial deployment file from the ±50% size check.
- Specified that verifiers report examined sample counts `n`.
- Mandated that development environments run all three verifier lanes if real workspaces exist.
- Mandated that dataset-topic posts log only class and key, and that the dataset channel itself is never exported.

---

## 7. Consensus

The resulting design in `spec.md` v0.4.0 (`51b40dcaa`) represents a complete, mathematically sound, fail-closed privacy architecture for public dataset export and bootstrap seeding. It incorporates all requirements from the owner and addresses every vulnerability identified across the panel.

No points remain open between this reviewer and the author.

Owner questions remain recorded in Section 11 for executive disposition:
- Q1 (Members' notice and opt-out)
- Q1b (Display names restricted to `HUM-n`)
- Q2 (Retention periods: 30d daily, 365d stable)
- Q3 (Drop and count message scan hits under 1% threshold)
- Q4 (Workspace docs excluded from v1)
- Q5 (Issues tracker excluded from v1)
- Q6 (Historical messages carry synthetic non-replayable envelopes)
- Q7 (Daily 3-verifier lanes on production; dev lanes when real)
- Q8 (Terraform step 053 apply approval)
- Q9 (Archived channels excluded from dataset)

Consensus reached at 51b40dcaa
