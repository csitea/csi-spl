# Tasks 029: hub DB health, and a daily off-instance backup

Lane **CLE-3430**. Every claim carries version/config, tree and n (spec §2,
FR-010). Numbers come from `ENV=<env> ./run -a do_spl_db_health` unless a row
says otherwise.

| id | item | status | evidence |
|---|---|---|---|
| T001 | `do_spl_db_health` — one read-only pass: size, load, vacuum, structure, cloudsql | **done, on trunk `b55280f`** | 5 sections, one proxy session; read-only three ways over (FR-001); `ON_ERROR_ROLLBACK=on` per statement (FR-002) |
| T002 | its offline test | **done** | `spl-db-health.tst.sh`, 21 checks; orc suite **37/37 files** before the push |
| T003 | measure dev + prd, both envs, and write §3 | **done** | dev 2026-09-21T07:38Z, prd 07:43Z; hub `0.1.16` both, PG 16.15, schema at 0024 |
| T004 | report to ORC, ranked, with "no problem" said plainly | **done** | outbox `20260921T074642Z--CLE-3430--db-health-findings.md` |
| T010 | iac **045-gcs-db-backups**: bucket, 30-day lifecycle, instance agent as the only writer | **done, on trunk `802e26f`** | `terraform fmt` clean; **PASS: validate 045-gcs-db-backups**; whole tf suite **87 PASS, 0 FAIL, 0 SKIP** |
| T011 | cnf 045 block for dev + prd, tpl templates, rendered tfvars | **done** | rendered by `do_tpl_gen` at the pinned tpl-gen; the render-sync test is part of the 87 |
| T020 | `do_spl_db_backup` — Cloud SQL export to the 045 bucket, `DRY_RUN=1` default, busy-instance retry, size floor | **done** | spec §4.2 for why export and not a proxied `pg_dump` |
| T021 | `do_spl_db_backup_verify` — restore into a throwaway container, compare every table against the live DB read-only | **done** | spec §4.4 for why the test is not "counts are equal" |
| T022 | their offline test | **done** | `spl-db-backup.tst.sh`, 29 checks (`grep -c '^PASS'`), with controls (DRY_RUN=0 *does* reach gcloud; a 999999-byte object *does* pass) |
| T030 | workflow **45 ops: hub db daily backup**, `17 5 * * *`, dev then prd, per-env concurrency, key from `GCP_KEY_CSI_SPL_<ENV>` | **done** | spec §4.5 (red run = the alert), §4.6 (why not near 01:00) |
| T040 | spec 029 + these tasks | **done** | this file |
| T050 | apply 045 on dev and prd (`make do-provision`, step 045) | **done, both envs** | ORC gave the go 2026-09-21T08:07Z. Plan was `2 to add, 0 to change, 0 to destroy` on each; apply `2 added, 0 changed, 0 destroyed` on each. Buckets `csi-spl-dev-db-backups` / `csi-spl-prd-db-backups`; the IAM grant went to the instance service agent `p436311356630-pavt4a@` (dev) / `p351721145894-firmcx@` (prd) |
| T051 | one real backup per env, `DRY_RUN=0` | **done, both envs** | dev `gs://csi-spl-dev-db-backups/dev/spool-20260921T080842Z.sql.gz` **93 796 B**; prd `gs://csi-spl-prd-db-backups/prd/spool-20260921T081331Z.sql.gz` **33 274 B** |
| T052 | prove one restore per env (`do_spl_db_backup_verify`) | **done, both envs, with the fixed code** | dev: 428 656 B of SQL, **26 tables, 735 rows, every count identical**. prd: 156 676 B, **26 tables, 255 rows, every count identical** |
| T060 | D1 Query Insights (spec §6.2) | **done, dev + prd** | iac 040 `insights_config` + 3 cnf knobs; plan `0 add / 1 change / 0 destroy` each, apply `0 added / 1 changed / 0 destroyed` each. **No restart, measured on BOTH**: `pg_postmaster_start_time()` unchanged — dev 2026-09-18 18:11Z (uptime 2 d 14 h), prd 2026-09-18 19:36Z (2 d 13 h). Modify took 1 m 37 s dev / 3 m 45 s prd, both `RUNNABLE` throughout. `insightsConfig.queryInsightsEnabled: true` on both |
| T061 | D2 `pg_stat_statements` | **deferred by ORC 2026-09-21** | not while D1 is unmeasured; the restart + sequencing is written up in spec §6.3 |
| T062 | `pg_monitor` for the health action | **closed: not ours to grant** | measured — every holder of `pg_monitor` has `admin_option = f`, and `spool_hub` is only a non-admin member of `cloudsqlsuperuser`. Spec §6.4 records the shape a future observability login must take |
| T063 | D3–D6 (spec §6) | **owner decisions, none taken** | sent to ORC with T004 |

## Three defects the REAL runs found, which no offline test could

The offline suites were green before any of this. Every one of these came out
of running the thing against dev and prd.

1. **One action per file.** `do_load_functions` derives `do_<snake>` from
   `<kebab>.func.sh`, so a second `do_*` function in `spl-db-backup.func.sh`
   was sourced but never registered — `actions_found=0`. The verify now has
   its own file.
2. **`pg_isready` lies during `initdb`.** The postgres image runs a temporary
   server while it initialises, on the unix socket only, so `pg_isready`
   answers YES before the real server exists; the restore then runs into the
   restart. On the first prd verify that produced *"ready after 2s"*, psql
   exit 2, **zero tables restored**, and a verdict reading *"26 live table(s)
   missing from the restore"* — **accusing a dump that was perfectly good.**
   That is the worst failure a verifier can have. The probe is now a real
   `SELECT 1` over **TCP**, which the temporary server never listens on. The
   same race is why dev's first verify died 3 s in while its second run of the
   SAME dump passed with every count identical.
3. **An empty restore could not speak.** psql's output went to `/dev/null`, so
   a restore that landed nothing could only be reported as "every table is
   missing". It is captured now, and an empty restore fails as a **restore**
   fault carrying psql's own last 20 lines.

Also added: a missing 045 bucket is exit 2 naming the step and the two
commands that create it, instead of a raw gcloud "bucket does not exist" that
reads like a broken backup job.

## What is left

**Nothing inside this lane's scope.** T001–T052 are done and proven on both
envs. What remains is not mine to take:

- the owner decisions **D1–D6** (spec §6), sent to ORC;
- the **daily 05:17 UTC schedule**. It is no longer an unrehearsed unknown:
  run **35578876785** dispatched the same workflow at trunk on 2026-09-21 and
  **both jobs succeeded on GitHub runners** (dev 95 773 B -> 26 tables /
  756 rows; prd 33 270 B -> 26 tables / 255 rows), so the schedule exercises a
  path that has already run green unattended. Spec §6.5.

## Controls this lane relied on

- the offline suites use a stub log as the CONTROL: a test that asserts "no
  gcloud call" is worthless unless another asserts the stub records one when a
  call IS made. Both suites carry that pair.
- the `--account` audit joins backslash continuations before grepping: the
  export spans two lines and its `--account` sits on the second, so a per-line
  grep reads it as unpinned. Measured while writing the test.
- the write-verb scan on the health SQL anchors with a word boundary: the
  report SELECTs columns called `vacuum_count` and `last_analyze`, and an
  anchor without the boundary reads those as a `VACUUM`. Measured.

<!-- last-edit: 2026-09-21T08:10:00Z -->
