# Disaster recovery guide: data redundancy, restore procedures, and recovery time objectives

This guide establishes the disaster recovery (DR) procedures, data redundancy architecture, and recovery time objectives (RTO) for the spool platform and hosted estate (Cloud Run, Cloud SQL, Cloud Storage, and agent runner boxes). It resolves outside robustness review gap 5 (SPL-2137, Refs: SPL-2129).

For operational incident triage, escalation ladders, and first-response remediation commands, see the [incident runbook](guides/incident-runbook.md). For deployment setup and rollbacks, see [DEPLOY.md](../../../DEPLOY.md).

---

## 1. Overview and principles

The platform maintains tenant data, signed messages, agent memory transcripts, and operational state. Disaster recovery is governed by three fundamental rules:

1. **A backup that has never been restored is not a backup**: Taking a dump or copying an archive is not evidence of recoverability. Every automated backup must be continuously verified via restore drills (review item 6, spec 029).
2. **Nothing mutates GCP without the owner**: In accordance with the repository [CLAUDE.md](../../../CLAUDE.md), production restores that touch live databases or buckets require explicit human owner approval (`ALLOW_PRD_RESTORE=1`). Drills and verification runs MUST target isolated, throwaway containers or temporary scratch directories.
3. **Defense in depth (off-instance and off-project redundancy)**: Built-in cloud provider snapshots protect against transient node failures; off-instance and off-project backups protect against infrastructure deletion, cloud project compromise, or catastrophic service corruption.

---

## 2. State inventory: what holds state

The system state is partitioned across five distinct stores:

| State item | Technology / Location | State contents | Criticality |
|---|---|---|---|
| **Hub Relational Database** | Google Cloud SQL (PostgreSQL 16) | Tenants, memberships, roster, topics, messages, deliveries, human user accounts, and schema migration ledgers. | **Critical** (core messaging & identity ledger) |
| **User File Storage** | Google Cloud Storage (Bucket `050-gcs-files`) | Encrypted user attachments and files uploaded by humans and agents (`t/<tenant>/files/<sha256>`). | **High** (message attachment persistence) |
| **Fleet Box State** | Local disk on runner hosts (`/var/spool-hub`, `~/.claude/projects`, `/var/csi/csi-spl`) | Local spool messaging directories (inboxes, outboxes, archives, leases, workdirs table), agent conversation transcripts and memory, daemon state. | **Medium** (box operational context & transcripts) |
| **Cryptographic Credentials** | Local disk (`~/.gcp/.csi/`, `~/.ssh/`, `tenant-root.key`) | Service account private keys, tenant root signing keys, box SSH host and client keys. | **Critical** (authentication & signing authority) |
| **Configuration & Secrets** | `csi-spl-cnf` repo overlay, GitHub Actions secrets, cloud secrets | Environment configuration (`<env>.env.yaml`), Terraform variables (`*.tfvars`), billing IDs, API keys. | **High** (infrastructure reproducibility) |

---

## 3. Current backup mechanisms and redundancy

Each state store is backed up through dedicated, automated mechanisms:

### 3.1 Hub database backups (Cloud SQL)

Database backups operate at three independent tiers (see [spec 029](../../specs/029-spool-db-backup-health/spec.md)):

1. **Cloud SQL automated backups & Point-In-Time Recovery (PITR)**:
   - Configured in Terraform step `025-cloudsql`.
   - Frequency: Daily automated backup window (01:00 UTC, subject to provider drift) plus continuous WAL transaction logging.
   - Retention: 7 days.
   - Scope: Intra-instance recovery within the GCP project.
2. **Daily off-instance logical exports (Workflow 45)**:
   - Workflow: `.github/workflows/45_db-backup.yml` (cron `17 3 * * *`, daily at 03:17 UTC).
   - Mechanism: Native `gcloud sql export sql` streaming directly from Cloud SQL to GCS bucket `gs://csi-spl-<env>-db-backups` (iac step `045-gcs-db-backups`). Superuser export bypasses row-level security (RLS) truncation without exposing database passwords or tenant data to CI runners.
   - Retention: 30-day lifecycle rule; 7-day soft-delete.
   - Verification: Every run automatically downloads the export, restores it into a throwaway PostgreSQL container on the runner, and compares table counts read-only against live (`do_spl_db_backup_verify`).
3. **Off-project disaster replica (iac 046)**:
   - Bucket: `gs://csi-spl-bkp-<env>/<env>/db` in isolated backup project `csi-spl-bkp`.
   - Action: `do_spl_backup_offsite` replicates dumps to survive catastrophic loss or deletion of the primary GCP project.

### 3.2 User files backup (GCS)

- **Primary Bucket**: `gs://csi-spl-<env>-files` (iac step `050-gcs-files`).
- **Bucket Protections**: Uniform bucket-level access (UBLA), public access prevention, and 7-day soft delete retention (protects against accidental deletion or overwrite).
- **Off-project replica**: Synchronized via `do_spl_backup_offsite` to `gs://csi-spl-bkp-<env>/<env>/files` in the independent backup project `csi-spl-bkp`.

### 3.3 Box state backup

- **Documentation**: [box-state-backup.md](box-state-backup.md).
- **Mechanism**: Nightly cron job (`box-state-backup-cron.sh`) running `do_spl_box_state_backup`.
- **Target Bucket**: `gs://csi-spl-<env>-box-state/<box>/<YYYY-MM-DD>/<box>-<stamp>.tar.zst` (iac step `056-gcs-box-state`).
- **Retention**: 30 days retention, 7 days soft delete.
- **Key exclusion rule**: Private keys (`*.key`, `*.pem`, `key-*.json`), `~/.gcp`, `~/.ssh`, `.env` files, and bank credentials are **strictly excluded** by `box-state-pack.sh`. The archive is scanned prior to upload; any detected key material aborts the backup.

### 3.4 Cryptographic credentials and private overlay

- **Credential policy**: In compliance with the owner rule, service account keys and root keys NEVER leave the local host or get uploaded to cloud storage buckets.
- **Storage**: Master credentials reside in the off-repo operator vault and GitHub Actions repository secrets (`GCP_KEY_CSI_SPL_<ENV>`).
- **Public configuration**: Version-controlled in `csi-spl-cnf/csi-spl/`.

---

## 4. Restore procedures and authority

### 4.1 Authority matrix: who may run restores

| Restore scope | Target environment | Allowed operators | Owner gate required? |
|---|---|---|---|
| **Restore Drill / Verification** | Local throwaway container (`TARGET=local`) | Any agent or developer | No |
| **Scratch Box-State Staging** | Local scratch directory (`BOX_STATE_RESTORE_ROOT=<dir>`) | Any agent or developer | No |
| **Dev Database Restore** | Dev Cloud SQL instance (`ENV=dev TARGET=database:<name>` or `TARGET=env`) | DevOps / Orchestrator | Recommended |
| **Prd Database Restore** | Production Cloud SQL instance (`ENV=prd TARGET=env`) | Human owner / Designated operator | **YES (`ALLOW_PRD_RESTORE=1`)** |
| **Prd Files Restore** | Production GCS bucket (`ENV=prd TARGET=env`) | Human owner / Designated operator | **YES (`ALLOW_PRD_RESTORE=1`)** |
| **Live Box Root Restore** | Live runner filesystem (`/`) | Machine `root` / Human operator | **YES** |

---

### 4.2 Restoring the hub database

#### Procedure A: Automated restore drill (safe, read-only to live)
Validates that the newest database export downloads, decompresses, restores into an isolated throwaway PostgreSQL container, applies pending migrations via `spool migrate`, and passes data sanity checks:
```bash
cd csi-spl-orc && ENV=dev ./run -a do_spl_db_restore_drill
```
*Action file*: `csi-spl-orc/src/bash/run/spl-db-restore-drill.func.sh`

#### Procedure B: Restore into a throwaway Cloud SQL database
Restores a dump into an isolated database `spool_restore_<name>` on the active Cloud SQL instance and compares row counts:
```bash
cd csi-spl-orc && ENV=dev TARGET=database:spool_restore_drill DRY_RUN=0 ./run -a do_spl_db_restore
```
*Action file*: `csi-spl-orc/src/bash/run/spl-db-restore.func.sh`

#### Procedure C: Full disaster recovery into a re-created instance
When the primary database instance is destroyed or replaced:
1. Provision the clean Cloud SQL instance via Terraform (`make do-provision` in `csi-spl-orc` for step `025-cloudsql`).
2. Run the restore action against the empty database:
   ```bash
   # Preview first
   cd csi-spl-orc && ENV=prd TARGET=env DRY_RUN=1 ./run -a do_spl_db_restore

   # Apply restore (owner authorization required)
   cd csi-spl-orc && ENV=prd TARGET=env ALLOW_PRD_RESTORE=1 DRY_RUN=0 ./run -a do_spl_db_restore
   ```
3. Rebuild topic heads (spec 099):
   ```bash
   cd csi-spl-orc && ENV=prd REBUILD=all DRY_RUN=0 ./run -a do_spl_topic_head_backfill
   ```

---

### 4.3 Restoring user files (GCS)

#### Procedure A: Restore files to a local staging directory
Restores files from the environment bucket or offsite backup to a local path without touching cloud storage:
```bash
cd csi-spl-orc && ENV=dev SOURCE=env TARGET=local DRY_RUN=0 ./run -a do_spl_files_restore
```
*Action file*: `csi-spl-orc/src/bash/run/spl-files-restore.func.sh`

#### Procedure B: Disaster recovery restore to production bucket
Restores user files from offsite backup `gs://csi-spl-bkp-prd/prd/files` into `gs://csi-spl-prd-files` with non-clobber synchronization:
```bash
cd csi-spl-orc && ENV=prd SOURCE=bkp TARGET=env ALLOW_PRD_RESTORE=1 DRY_RUN=0 ./run -a do_spl_files_restore
```

#### Procedure C: Undeleting soft-deleted objects
For objects deleted within the 7-day soft-delete window:
```bash
gcloud storage objects restore gs://csi-spl-<env>-files/<path/to/object>#<generation> --account="<project-sa>@<project>.iam.gserviceaccount.com"
```

---

### 4.4 Restoring an agent runner box

When an agent runner box suffers catastrophic hardware or OS failure:

1. **Provision a new host** with OS base packages:
   ```bash
   bash csi-spl-orc/src/bash/features/spool-install/install.sh --env self --tenant <tenant>
   ```
2. **Restore box state from GCS backup**:
   - Preview staging and plan in a scratch directory:
     ```bash
     cd csi-spl-orc && ENV=prd BOX=<box> DATE=<YYYY-MM-DD> BOX_STATE_RESTORE_ROOT=/tmp/scratch-restore DRY_RUN=1 ./run -a do_spl_box_state_restore
     ```
   - Apply onto root (executed as `root`):
     ```bash
     cd csi-spl-orc && ENV=prd BOX=<box> DATE=<YYYY-MM-DD> DRY_RUN=0 ./run -a do_spl_box_state_restore
     ```
   *Action file*: `csi-spl-orc/src/bash/run/spl-box-state-restore.func.sh`
3. **Re-provision credentials**:
   - Install service account keys (`~/.gcp/.csi/key-csi-spl-<env>.json`) from the secure operator vault with mode `0600`.
   - Install tenant root signing keys (`tenant-root.key`).
4. **Restart desk daemon**:
   ```bash
   cd csi-spl-orc && ENV=prd TENANT_ID=<tenant> DESK_AGENT=<agent> DRY_RUN=0 ./run -a do_spl_desk_up
   ```

---

## 5. Recovery time objectives and measured timings

In compliance with the project rule, restore timings must be **measured empirically** under real conditions, not guessed. Destructive operations that cannot be safely run against live production or development systems are marked "Not measured" with the rationale specified.

### 5.1 Measured restore benchmark table

| State item | Source | Target | Measured RTO (Restore time) | Recovery Point (Dump age / RPO) | Tree / Commit SHA | Measurement date | Sample size (n) | Authority | Status & Notes |
|---|---|---|---|---|---|---|---|---|---|
| **Hub Relational DB (Drill)** | `gs://csi-spl-dev-db-backups` | Local throwaway container (`postgres:16-alpine`) | **51 s** (1s download, 48s DB import, 0s migration) | 14.7 h (53,106 s) | `a1f6e107` | 2026-10-19 | n=1 | Developer / CI | **MEASURED**. 88 MB SQL, 117 tables, 77,805 rows restored, schema verified, core sanity passed. |
| **User File Storage** | `gs://csi-spl-dev-files` | Local throwaway directory | **4 s** | Continuous (live sync) | `a1f6e107` | 2026-10-19 | n=1 | Developer / Operator | **MEASURED**. 105 objects (4.4 MB) downloaded and checksummed. |
| **Box State Staging & Diff** | `gs://csi-spl-prd-box-state` | Local scratch staging directory | **1 m 50 s** (110 s) | 48 h (nightly backup) | `a1f6e107` | 2026-10-19 | n=1 | Operator | **MEASURED**. 159,037 files unpacked, credential-scanned clean, and diff-planned. |
| **Hub Database In-Place Restore** | GCS 045 / 046 bucket | Live Cloud SQL (`TARGET=env`) | *Not measured* | 1–24 h (daily export / PITR) | — | — | — | Owner only (`ALLOW_PRD_RESTORE=1`) | **NOT MEASURED**. Destructive to live operational database; requires clean, re-created Cloud SQL instance. |
| **Hub DB Cloud SQL Throwaway DB** | GCS 045 bucket | Cloud SQL `database:spool_restore_*` | *Not measured* | 1–24 h | — | — | — | Operator | **NOT MEASURED**. Avoided during active operations to prevent load or connection spikes on shared instance; covered by container drill. |
| **User Files Live Bucket Restore** | `gs://csi-spl-bkp-<env>` | Live bucket `050-gcs-files` | *Not measured* | Continuous | — | — | — | Owner only (`ALLOW_PRD_RESTORE=1`) | **NOT MEASURED**. Destructive to live bucket state; safe path verified by local target restore. |
| **Box State Root Filesystem Apply** | GCS 056 bucket | Live host root (`/`) | *Not measured* | 1–24 h (nightly) | — | — | — | Host root / Operator | **NOT MEASURED**. Destructive to running agent sessions and local processes; safe path verified by scratch staging. |
| **Cryptographic Key Re-issuance** | Operator Vault | Local host `~/.gcp/.csi` | *Not measured* | N/A (static keys) | — | — | — | Security Officer / Owner | **NOT MEASURED**. Manual administrative procedure governed by security protocol. |

---

## 6. Continuous verification and automated drills

To prevent recovery drift ("a backup that has never been restored is not a backup"):

1. **Daily CI Verification (`45_db-backup.yml`)**:
   Every execution of the daily database export workflow automatically triggers `do_spl_db_backup_verify`, creating a local Postgres container on the runner, restoring the export, and verifying table presence against the live instance.
   The live read goes through a fresh Cloud SQL proxy and is tried twice, 20 s apart (`SPL_DB_BACKUP_LIVE_TRIES`, `SPL_DB_BACKUP_LIVE_WAIT`). Each failed try logs psql's own last lines as `WARN`. "cannot read the live counts" after two tries is a failed read of the live database, not a bad dump: restore that dump on its own (`ENV=<env> OBJECT=<gs uri> ./run -a do_spl_db_backup_verify` from `csi-spl-orc`) before you call the backup broken (SPL-2797; the 2026-10-21 prd run failed this way while its dump restored 118 tables).
2. **Automated Restore Drill (`do_spl_db_restore_drill`)**:
   Can be run on-demand or as a scheduled health check to prove that current repo schema migrations apply cleanly on top of the newest backup dump without schema corruption.
3. **Key and Credential Leak Guards (`box-state-pack.sh scan`)**:
   Both backup packaging and restore unpacking enforce strict credential scanners refusing any archive that contains private keys or forbidden tokens.
4. **Offline Unit Test Coverage (`spl-box-state-restore.tst.sh`)**:
   Regression tests verify staging directory isolation, diff planning (`NEW`/`OVERWRITE`), non-clobber deletion semantics, and key-scan rejection logic.

---

## 7. Related documentation

- [DEPLOY.md](../../../DEPLOY.md) — Deployment paths, configuration, and application rollback procedures.
- [Incident runbook](guides/incident-runbook.md) — Incident severity levels, on-call roles, and first-response remediation actions.
- [Spec 029: DB health and off-instance backup](../../specs/029-spool-db-backup-health/spec.md) — Architectural specification for database backup and health monitoring.
- [Box-state backup setup](box-state-backup.md) — Architecture and specification for box-only state backups.
- [Developer guide](developer-guide.md) — Trunk workflow, pre-push verification gates, and branch lifecycle.
