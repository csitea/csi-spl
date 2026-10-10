# Box-State Backup Setup

## 1. What and Why

The box-state backup is a nightly copy of each box's **box-only state** to a Google Cloud Storage (GCS) bucket. This ensures that a new box can be restored to its last known state if the original box is lost or replaced. The backup includes:

- Agent transcripts and memory (`~/.claude/projects`)
- The spool root (`/var/spool-hub`)
- The `csi-spl` state directories (`/var/csi/csi-spl` and `~/.local/state/csi-spl`)

The backup **excludes** keys, tokens, `.env` files, the tenants store, NetVisor/bank credential files, and any `0600` file under a home's dot-directories not explicitly allow-listed.

This setup is owned by [t1 `151d85fc`](https://spool-hub.ai/m/151d85fc-fc7e-454d-bfed-1698044350e3).


## 2. What Is Saved and What Never Leaves the Box

### 2.1 Included

- **Agent transcripts and memory**: `~/.claude/projects` (read as the agent user)
- **Spool root**: `/var/spool-hub` (the spool messaging system's root directory)
- **`csi-spl` state directories**:
  - `/var/csi/csi-spl` (excluding `graft/` and `backups/`)
  - `~/.local/state/csi-spl`

### 2.2 Excluded

The following are **never** included in the backup:

- **Keys and tokens**:
  - `~/.gcp`, `~/.ssh`, key files, `.env` files, `*.pem`, `*.key`, `*.p12`, `key-*.json`
  - The tenants store (`~/.spool-hub/tenants`)
  - NetVisor and bank credential files (matched by name)
- **`0600` files under home dot-directories**: Unless explicitly allow-listed (e.g., `*/.claude/projects/*` for transcripts).
- **Unreadable files**: Any file that the backup process cannot read.

The backup is scanned for excluded paths and key material before upload. If any are found, the upload is **refused**.


## 3. Where and How Long

### 3.1 Storage Location

- **Bucket**: `<bucket from cnf>` (derived from `env.steps."056-gcs-box-state".state_bucket_name`)
- **Location**: `europe-north1` (GCP region)
- **Object name**: `<box>/<YYYY-MM-DD>/<box>-<YYYYMMDDTHHMMSSZ>.tar.zst`

### 3.2 Retention and Soft Delete

- **Retention**: 30 days (objects are deleted after this period)
- **Soft delete**: 7 days (objects can be recovered within this window after deletion)
- **Versioning**: Disabled (each night's backup is a new object)
- **Encryption**: Google-managed (no customer-managed encryption key)
- **Access control**: Uniform bucket-level access (no object ACLs)
- **Public access prevention**: Enforced (no object can be made public)

### 3.3 Writer Identity

- **Service Account**: `<bucket from cnf>-writer` (derived from `env.steps."056-gcs-box-state".writer_sa_account_id`)
- **Permissions**: `roles/storage.objectCreator` (write-only, no read/list/delete)
- **Impersonation**: The box uploads as the project's service account, impersonating the writer service account (no key is used).


## 4. When (Schedule)

- **Frequency**: Nightly (run by `box-state-backup-cron.sh`)
- **Cron job**: Installed as `# csi-spl:box-cron:box-state-backup` in the box user's crontab
- **Environment**: Defaults to `prd`; can be overridden with `BOX_STATE_ENV`
- **Dry run**: Defaults to `DRY_RUN=1` (pack and scan only). Set `DRY_RUN=0` to upload.


## 5. Restore a Lost Box

To restore a box's state from the backup:

1. **Fetch the backup**:
   ```bash
   ENV=<env> BOX=<box> DATE=<YYYY-MM-DD> ./run -a do_spl_box_state_restore
   ```
   - `<env>`: `dev` or `prd`
   - `<box>`: The box name (defaults to the current box)
   - `<DATE>`: The night to restore (e.g., `2026-10-10`)

2. **Dry run (default)**: The restore stages the backup in a temporary directory and compares it with the target root (`/`). It reports:
   - `NEW`: Files that would be created
   - `OVERWRITE`: Files that would be overwritten (content differs)

3. **Apply the restore**: Set `DRY_RUN=0` to copy the staged tree onto the target root. Runs as `root` if the target root is `/`.

4. **Scan**: The restore scans the archive for excluded paths or key material. If any are found, the restore is **refused**.


## 6. Mapped Drives

The mapped drives `SPL_BOX_STATE_RO` and `SPL_BOX_STATE_RW` are **planned** but not yet implemented. See the owner topic [t1 `151d85fc`](https://spool-hub.ai/m/151d85fc-fc7e-454d-bfed-1698044350e3) for details.


## 7. Open Items

- **Test failures**: The test `spl-box-state-backup.tst.sh` has red cases that are being fixed in lane `c-875`.
- **Mapped drives**: `SPL_BOX_STATE_RO` and `SPL_BOX_STATE_RW` are not yet on `origin/master`.
- **Key material scan**: The scan for key material in the backup is strict and may require tuning.