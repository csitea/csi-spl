# Spec 029: hub DB health, and a daily off-instance backup

**Feature**: `specs/029-spool-db-backup-health` · **Created**: 2026-09-21 · **Lane**: CLE-3430
**Input**: the owner's two orders below, and one measured pass over both live envs (§3).

## 1. Why

Owner, 2026-09-20 (verbatim): *"check the size of the db and to report are we
having some kind of performance issues with the db, anything to refactor there
... do we need to schedule some kind of postgres maintaining jobs or anything"*.

Owner, 2026-09-20, addition (verbatim): *"the same one should update the specs
for creating a backup job on the db - for now once daily, triggered from the
github actions"*.

## 2. How this spec is auditable

Every number in §3 comes from ONE command, which is part of this feature:

```
ENV=<dev|prd> ./run -a do_spl_db_health      # csi-spl-orc, read-only
```

- **version / config**: hub image tag `0.1.16` on BOTH envs (cnf
  `env.hub.image.tag`); Postgres **16.15**; schema at
  `0024_retention_expiry_indexes.sql`, applied 2026-09-19 on both.
- **tree**: `b55280f` (the commit that adds the action).
- **n**: one pass per env, 2026-09-21T07:38Z (dev) and 07:43Z (prd). The
  Postgres counters cover **2 d 13 h** (dev, `stats_reset` 2026-09-18T18:16Z)
  and **2 d 12 h** (prd, 19:37Z). Platform metrics are n=1439 one-minute
  samples over 24 h.

**Both instances were rebuilt on 2026-09-18, so nothing here is a long-run
trend.** Any claim in §3 about what does NOT happen is bounded by 2.5 days.

## 3. What the measurement says

### 3.1 The short answer

**No performance problem. No size problem. Nothing to refactor for speed.**
The database is ~1 % full and every read is served from RAM.

The findings are about **blindness** (§3.5) and about **prd running on a
shared-core tier with no HA** (§3.6).

### 3.2 Size

| | dev | prd |
|---|---|---|
| logical DB size | 10 MB | 9 695 kB |
| disk used (platform) | 93.9 MB | 110.0 MB |
| disk quota | 10.46 GB | 10.46 GB |
| **% of disk** | **0.90 %** | **1.05 %** |
| 24 h growth | +114 KB | +82 KB |
| biggest relation | `messages` 592 kB / 177 rows | `messages` 280 kB / 52 rows |

At ~100 KB/day the 10 GB disk lasts on the order of **270 years**, and
`storageAutoResize` is on with no limit. At 10x and at 100x this is still not
a size question. WAL on disk is **not readable**: the runtime login is not
`pg_monitor` (`permission denied for function pg_ls_waldir`) — that is a
finding about our visibility, not about WAL.

### 3.3 Load

| | dev | prd |
|---|---|---|
| cache hit ratio | **100.00 %** (75 reads / 11 907 257 hits) | **100.00 %** (63 / 11 480 151) |
| CPU, 24 h | 7.6 – 11.1 % | 7.7 – 14.2 % |
| backends, 24 h max | 5 | 3 |
| `max_connections` | 25 | 25 |
| commits / rollbacks | 83 164 / 78 (0.09 %) | 71 892 / 52 (0.07 %) |
| deadlocks, temp files | 0, 0 | 0, 0 |
| blocked on a lock | 0 rows | 0 rows |
| idle-in-transaction | none | none |

`shared_buffers` is 128 MB and the database is 10 MB, so the working set is
resident; the 100 % hit ratio is structural, not luck. The hub pool ceiling of
8 (`SPOOL_HUB_DB_MAX_CONNS`, spec 027 T010) is never approached — peak 5.

### 3.4 Sequential scans: right today, the number to watch at 10x

`tenants` 94.4 % dev / 99.2 % prd seq, `roster` 91.6 %, `tenant_memberships`
86.1 %, `boxes` 82.2 %, `humans` 73.6 %. **This is the planner being correct**:
those tables are 3–12 rows in one page, where a seq scan beats an index;
`rows_per_seq_scan` is 2–10.

The number that matters is the **call count**: `tenants` was scanned **5 553
times in 2 d 13 h** on dev. At 12 tenants that is free. At the 1 500 tenants
spec 027 models, the same call pattern reads **~8.3 M tuples**. That is what
the hub's `hotCache` (027 T040) exists for. Re-measure when tenant count moves,
do not act now.

Unused indexes are **suggested, not demonstrated**: 6 on dev, 15 on prd, over
2.5 days on a near-idle prd. Dropping one on this evidence would be a mistake.
Two cases explained rather than acted on:

- `messages_expires_at` / `deliveries_queued_expires` (0024) read **1 373 / 170
  scans on dev but 0 on prd**. Not a broken sweep: prd's `messages` is 52 rows
  in one page, so the planner seq-scans it. 0024 pays off once the table grows,
  which is exactly what it was built for.
- `messages_search` (the 0020 GIN index) has **0 scans on both envs**.
  Full-text search has never been executed against either environment.

No duplicate or prefix-redundant indexes on either env.

### 3.5 What we cannot see — the real gap

- **`pg_stat_statements` is NOT installed** on either env (available: yes). So
  there are **no per-statement timings at all**. Enabling it needs the flag
  `cloudsql.enable_pg_stat_statements`, **which restarts the instance**, plus
  `CREATE EXTENSION`. → **D1**.
- **Query Insights is OFF** on both (`settings.insightsConfig` absent). This is
  the no-restart alternative. → **D2**.
- `track_io_timing = off`: `blk_read_time` / `blk_write_time` are 0, i.e. every
  I/O column in any report is meaningless.
- `log_min_duration_statement = -1`: no slow-query log.
- `statement_timeout = 0` and `idle_in_transaction_session_timeout = 0`: one
  stuck session can hold a transaction open forever. Nothing is stuck today and
  nothing stops it either. → **D3**.

### 3.6 Vacuum, wraparound, and a percentage that will lie to any alert

**Wraparound is not a risk by four orders of magnitude**: `age(datfrozenxid)`
is 46 332 (dev) / 44 502 (prd) against `autovacuum_freeze_max_age` 200 000 000
— **0.02 % of the ceiling**.

Dead tuples read alarming and are not. prd: `humans` 89.7 % dead,
`human_identities` 88.9 %, `roster` 87.8 %, `password_credentials` 85.0 %.
Ten tables have **never been autovacuumed** (`autovacuum_count` = 0).

That is correct. The trigger is `threshold 50 + 0.2 × live_rows`; for a 3-row
table that is ~51 dead tuples and `humans` has 26. The absolute waste is
**26 rows in an 8 kB heap** — one page. And `n_tup_hot_upd` equals `n_tup_upd`
on `humans` / `boxes` / `pins` / `password_credentials`: these are **HOT
updates that clean themselves on the page**.

**Do not tune autovacuum for this.** No table carries a `reloptions` override
today and none should. The consequence for §4: **any alert we add must key on
absolute dead tuples AND table size, never on `dead_pct` alone**, or it will
fire forever on a 3-row table and be muted, and then be silent when it matters.

### 3.7 Structure

Sound. Measured, not assumed:

- **RLS is complete**: every `tenant_id` table is `relrowsecurity = t` AND
  `relforcerowsecurity = t`, each with ≥ 2 policies. The global tables carry
  none, by design (CLE-3416's lane).
- **Every `tenant_id` table has an index leading on `tenant_id`** — the query
  for tables lacking one returns **0 rows** on both envs.
- 22 foreign keys, `ON DELETE CASCADE` through the tenant tree. Timestamps are
  `timestamptz` everywhere; no `text` masquerading as a time.
- **13 `text` columns that are really enums**, and **all 13 are guarded by a
  `CHECK ... = ANY (ARRAY[...])`** (10 such constraints). **Recommendation:
  leave them.** `text + CHECK` is cheaper to evolve under forward-only
  migrations than an enum type, and the constraint already gives the safety.
- **`tenant_hosts` is dead schema** since spec 026 retired per-tenant DNS
  (12 rows dev, 3 prd). A drop migration belongs to the 024/026 lane, not here.
- 4 tables carry `tenant_id` with no FK to `tenants`: `payment_checkouts`,
  `pins_history`, `tenant_hosts`, and `tenants` itself (a false positive by
  construction). For the first two this looks deliberate — financial records
  and an audit trail should outlive a deleted tenant. → **D4** (confirm, do not
  change).

**Partitioning `messages` / `deliveries`: rejected, with the number.**
`messages` is **177 rows (dev) / 52 rows (prd)**. Partitioning earns its
complexity around 10–100 M rows; we are five to six orders of magnitude away.
Revisit when `messages` passes ~10 M rows.

**Retention works**: rows past `expires_at` not yet swept = **0 on both**. No
message older than 7 days on either env. The `deliveries` queue drains
(dev 179 sent / 4 queued, prd 52 sent / 0 queued, 0 expired).

### 3.8 Cloud SQL

| | dev | prd |
|---|---|---|
| tier / edition | `db-f1-micro` / ENTERPRISE | **`db-f1-micro`** / ENTERPRISE |
| availability | **ZONAL** | **ZONAL** |
| disk | 10 GB PD_SSD, autoresize, no limit | same |
| **automated backups** | **enabled**, 01:00, 7 retained, `eu` | **enabled**, same |
| **PITR** | **on**, 7 days of logs in Cloud Storage | **on**, same |
| last 4 backup runs | all `SUCCESSFUL` | all `SUCCESSFUL` |
| maintenance window | Sunday 03:00 | Sunday 03:00 |
| deletion protection | false | true |
| Query Insights | off | off |

**`db-f1-micro` on prd is the structural finding**: a shared-core machine has
no CPU guarantee, and Google **excludes shared-core instances from the Cloud
SQL SLA**. Today's load does not need more, but prd runs without a support
commitment. ZONAL means a zone outage takes the hub's DB down with no
automatic failover. Both are owner cost decisions (→ **D5**, and spec 027 D5).

## 4. The daily backup job

### 4.1 Is it redundant? Measured: no, but not for the obvious reason

Automated backups AND point-in-time recovery are **already on and green on both
envs** (§3.8). So this job is **not** a first line of defence and **not** a
replacement. It is additive, and buys the three things the built-ins cannot:

1. a Cloud SQL backup restores **only into Cloud SQL**, and lives inside the
   instance's project — it dies with the instance, and with the project;
2. `retainedBackups` is **7**, so one bad week nobody notices loses every copy;
3. a logical dump can be **read, diffed, grepped and partially restored**. A
   Cloud SQL backup is opaque.

The owner asked for it, it is additive, and it is not harmful. Build it.

### 4.2 Cloud SQL export, not pg_dump through the proxy

`gcloud sql export sql` runs **inside Google**: the instance streams straight
to the bucket. Three consequences, each of which is why it was chosen:

1. **no row of tenant data transits a GitHub-hosted runner**;
2. the runner **never sees a database password** — only the env SA key;
3. the export runs as the instance's **own superuser**, so rdb 0014 FORCE
   row-level security cannot silently empty a table in the dump. A proxied
   `pg_dump` as the RUNTIME login needs both `--enable-row-security` and the
   operator scope, and is **one forgotten flag away from a dump full of
   zero-row tables that still looks like a backup**.

### 4.3 Where the dumps land, and for how long

iac step **`045-gcs-db-backups`**: `gs://csi-spl-<env>-db-backups`, its own
bucket, uniform bucket-level access, public access prevention enforced, no
versioning (each object is uniquely named), 7-day soft delete, and a
**lifecycle rule deleting objects older than `backup_max_age_days` = 30**
(validation floor 7: below the instance's own retention the bucket is
pointless). Unlike 050's, this rule is **not optional** — a backup bucket with
no expiry grows forever and is noticed as the biggest line on the bill.

**Its own bucket, deliberately.** Cloud SQL's export documentation requires
`roles/storage.objectAdmin` for the instance's service agent, which is wider
than "create an object". A separate bucket is what stops that width reaching
the 020 relay bucket, the 050 files bucket or the state bucket. The agent is
**read from the live instance with a data source**, never written into the cnf.

### 4.4 A dump is not a backup until something restores it

Every run proves itself: it downloads what it just wrote, restores it into a
**throwaway postgres container** on the runner, and compares every table
against the live database read-only (`do_spl_db_backup_verify`).

The comparison is deliberately **not** "the counts are equal" — the dump and
the live read are minutes apart and dev takes writes in between, so equality
would be red for the wrong reason. It asserts instead what a broken dump
actually looks like:

- **no live table is missing from the restore**, and
- **no table restored empty while the live one has rows** (the RLS-blanked dump
  of §4.2).

The full per-table comparison is printed either way, so drift is visible.

### 4.5 Failure is the alert

A red scheduled workflow is the notification, exactly as `00_deploy-lag-watch`
works. There is no separate alerting path to forget to wire.

### 4.6 Schedule and overlap

`17 5 * * *` (daily, ~05:17 UTC). **Not near 01:00**: that is the instance's
own backup window, an export and a backup cannot overlap, and the window
**drifts** — measured 2026-09-21, a 01:00 window enqueued at 02:17Z on dev and
01:54Z on prd. `spl_db_backup_export` also retries a busy instance six times at
120 s, so a collision costs time, not a missed backup. A `concurrency` group
per env (`db-backup-<env>`, `cancel-in-progress: false`) means two runs never
overlap and an export is never cancelled mid-flight.

## 5. Requirements

- **FR-001** The health report is READ-ONLY three ways over: `PGOPTIONS`
  `default_transaction_read_only=on`, `BEGIN READ ONLY`, closing `ROLLBACK`.
  The gcloud half only describes and lists.
- **FR-002** A catalog read the runtime login may not run prints its ERROR and
  the report continues (`ON_ERROR_ROLLBACK=on`, a savepoint per statement).
  "Not permitted" is a finding, so it is printed, not hidden.
- **FR-003** Nothing ad hoc: every step is a named action
  (`do_spl_db_health`, `do_spl_db_backup`, `do_spl_db_backup_verify`) or
  terraform (045) run through the make / tf-runner path.
- **FR-004** Every gcloud call is pinned with `--account` to the per-env
  project SA, resolved by `do_gcp_pin_account`. Never the owner account.
- **FR-005** `do_spl_db_backup` defaults to `DRY_RUN=1` and exports nothing.
- **FR-006** The export is verified by the object's existence and size; an
  export that "succeeds" into a 0-byte object is a failure (exit 4).
- **FR-007** Every scheduled run proves the restore (§4.4), or the run is red.
- **FR-008** No secret is ever printed: no DSN, no key, no token in a log.
- **FR-009** Any bloat or dead-tuple alert keys on absolute dead tuples AND
  table size, never on `dead_pct` alone (§3.6).
- **FR-010** Every claim about the live DB states version/config, tree and n.

## 6. Owner decisions

| id | decision | recommendation |
|---|---|---|
| **D1** | Turn on Query Insights (no restart) | **TAKEN 2026-09-21, both envs** — see §6.2 |
| **D2** | Turn on `pg_stat_statements` (flag `cloudsql.enable_pg_stat_statements`, **restarts the instance**) | **NOT now** (ORC, 2026-09-21): do not spend a restart while D1 is unmeasured. Sequencing in §6.3 when it is wanted |
| **D3** | Set `statement_timeout` / `idle_in_transaction_session_timeout` | yes, a generous ceiling (e.g. 60 s / 5 min) beats "forever" |
| **D4** | Confirm `payment_checkouts` / `pins_history` are meant to outlive a deleted tenant | confirm as is; no change |
| **D5** | prd tier `db-f1-micro` (no SLA, shared core) and ZONAL (no HA) | raise the tier before the pool (see 027 D5); HA is a separate cost call |
| **D6** | Drop the dead `tenant_hosts` schema (spec 026 retired it) | 024/026 lane's call, not this one |

## 6.1 Proven, 2026-09-21 (ORC gave the go for the 045 apply at 08:07Z)

Plans were `2 to add, 0 to change, 0 to destroy` on each env; applies were
`2 added, 0 changed, 0 destroyed`.

| | dev | prd |
|---|---|---|
| bucket | `csi-spl-dev-db-backups` | `csi-spl-prd-db-backups` |
| instance service agent granted | `p436311356630-pavt4a@gcp-sa-cloud-sql…` | `p351721145894-firmcx@gcp-sa-cloud-sql…` |
| first dump | `dev/spool-20260921T080842Z.sql.gz`, **93 796 B** | `prd/spool-20260921T081331Z.sql.gz`, **33 274 B** |
| restored | 428 656 B of SQL | 156 676 B of SQL |
| **verdict** | **26 tables, 735 rows, every count identical** | **26 tables, 255 rows, every count identical** |

Three defects surfaced only by running it for real — one action per file, a
`pg_isready` that answers YES during `initdb`, and a restore that could not
report its own failure. All three are fixed and described in `tasks.md`. The
second one is worth carrying forward: **on the first prd verify it produced a
verdict accusing a dump that was perfectly good**, which is the worst thing a
backup verifier can do.

## 6.2 D1 taken: Query Insights, dev and prd (2026-09-21)

Owner decision relayed by ORC: take the cheaper step first. Implemented as iac
040 `insights_config`, driven by three cnf knobs with validations
(`query_insights_enabled`, `query_insights_string_length` 256–4500,
`query_insights_plans_per_minute` 0–20), rendered through tpl-gen like every
other step. The block is `dynamic` on `query_insights_enabled`, so an env that
has not opted in renders no `insights_config` and nothing changes for it.

**`record_client_address` and `record_application_tags` stay OFF.** Neither is
needed to find a slow query and both widen what the panel stores about callers.
Cloud SQL normalises query text before storing it (literals are replaced),
which is why `query_string_length` is a *shape* budget, not a data budget —
worth stating out loud in a database whose rows are tenant messages.

Plans were `0 to add, 1 to change, 0 to destroy` on each env, the change being
exactly the one added `insights_config` block; applies were `0 added, 1
changed, 0 destroyed`.

**"No restart" is measured here, not cited.** After each apply:

```
SELECT pg_postmaster_start_time(), now() - pg_postmaster_start_time()
dev ->  2026-09-18 18:11:00.676294+00 | 2 days 14:17:04
prd ->  2026-09-18 19:36:14.143791+00 | 2 days 12:57:38
```

Both postmaster start times are the ones from before the applies, so Postgres
did not restart on either env and no connection was dropped. Both instances
stayed `RUNNABLE` throughout. The dev modification took 1 m 37 s, prd 3 m 45 s
— that is the Cloud SQL control plane updating instance settings, not a
database outage, and the uptime above is what proves the difference.

`gcloud sql instances describe` now reports, on both:
`insightsConfig: {queryInsightsEnabled: true, queryPlansPerMinute: 5,
queryStringLength: 1024}` — and no `recordClientAddress` /
`recordApplicationTags`, because both are false.

## 6.3 D2 deferred: what `pg_stat_statements` will cost when it is wanted

Two changes, in this order:

1. the flag `cloudsql.enable_pg_stat_statements=on` in
   `settings.databaseFlags`. **This restarts the instance.** 040 does not
   manage `database_flags` at all today, so it also needs a new variable, a
   cnf entry and a rendered tfvar — a real iac change, never a console toggle.
2. `CREATE EXTENSION pg_stat_statements;` in `spool`, as the owner login. That
   is DDL and belongs in an rdb migration, not an ad hoc psql.

**Sequencing**: dev at any time (a restart there costs a few failed requests);
**prd only in the Sunday 03:00 maintenance window**, which 040 already
declares. The hub's pool reconnects by itself, but requests in flight during
the restart fail, so prd is not a casual change.

## 6.4 `pg_monitor` is not ours to grant — measured, not reasoned

Read-only catalog query on dev (`do_spl_db_query`, PG 16.15, n=1):

```
grantees of pg_monitor:  cloudsqlobservability | cloudsqladmin | admin_option = f
                         cloudsqlreplica       | cloudsqladmin | admin_option = f
                         cloudsqlsuperuser     | cloudsqladmin | admin_option = f
spool_hub is a member of cloudsqlsuperuser     | admin_option = f
```

**Every holder has `admin_option = f`**, so no role we control can re-grant it.
Only `cloudsqladmin` can, and that is Cloud SQL's own superuser. The
owner/runtime split (CLE-3421) is therefore neither the blocker nor the fix:
the grant is simply not available to us. WAL size and true bloat stay
unreadable by this route (`permission denied for function pg_ls_waldir`).

**And it should not go on the runtime login even if it could.** `pg_monitor`
carries `pg_read_all_stats`, which exposes other sessions' **query text** — in
this database that is a path for tenant data to leak through query strings.

**The shape any future observability identity must take**, and the split gives
exactly the right precedent: a THIRD login, created by the owner in SQL, with
its own DSN secret slot that 030 never injects, read-only, used only by
`do_spl_db_health` — the way `spool_hub_rt` was created. **Never** a widening
of the login the hub itself runs as.

## 6.5 The workflow itself is proven, not just the actions

Run **35578876785**, dispatched 2026-09-21T08:37Z at trunk, `environment=all`,
`dry_run=false`, `verify=true`. **Both jobs succeeded on GitHub runners, with
no operator involved** — which is the thing an operator-run action cannot
demonstrate:

```
dev  gs://csi-spl-dev-db-backups/dev/spool-20260921T083818Z.sql.gz  95 773 B
     -> 440 930 B of SQL -> 26 table(s), 756 row(s), every live table present
prd  gs://csi-spl-prd-db-backups/prd/spool-20260921T083954Z.sql.gz  33 270 B
     -> 156 675 B of SQL -> 26 table(s), 255 row(s), every live table present
```

The whole path ran on the runner: the env key from
`GCP_KEY_CSI_SPL_<ENV>`, the Cloud SQL export, the download, the throwaway
postgres container, the per-table comparison against the live database, and
the key removal. The daily schedule exercises exactly this, so the first
unattended 05:17 UTC run has already been rehearsed with a real dispatch.

## 7. Out of scope

Anything that changes the schema, the instance flags, the tier or the
availability type. This lane measures, reports, and adds the backup job the
owner asked for. Every change to the running database above is a D-row in §6.

<!-- last-edit: 2026-09-21T08:05:00Z -->
