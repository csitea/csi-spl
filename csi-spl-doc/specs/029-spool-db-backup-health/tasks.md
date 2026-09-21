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
| T022 | their offline test | **done** | `spl-db-backup.tst.sh`, 25 checks, with controls (DRY_RUN=0 *does* reach gcloud; a 999999-byte object *does* pass) |
| T030 | workflow **45 ops: hub db daily backup**, `17 5 * * *`, dev then prd, per-env concurrency, key from `GCP_KEY_CSI_SPL_<ENV>` | **done** | spec §4.5 (red run = the alert), §4.6 (why not near 01:00) |
| T040 | spec 029 + these tasks | **done** | this file |
| T050 | apply 045 on dev and prd (`make do-provision`, step 045) | **waits on the owner** | repo rule: nothing mutates GCP without the owner's go for that call. Plan first, then apply |
| T051 | one real backup per env, `DRY_RUN=0` | **blocked by T050** | the bucket must exist first |
| T052 | prove one restore per env (`do_spl_db_backup_verify`) | **blocked by T051** | this is the §4.4 proof the owner asked for |
| T060 | D1–D6 (spec §6) | **owner decisions, none taken** | sent to ORC with T004 |

## What is NOT done, and why

**T050–T052 need the owner's go**, and nothing here works around that. The
repo rule is explicit: `terraform apply` needs an explicit go for that call.
So the bucket does not exist yet on either env, and therefore no real dump has
been taken and no restore has been proven against a live object.

Everything that does not need the go is landed and green: the action, the
verify, the terraform, the cnf, the workflow and the tests. The moment 045 is
applied, the sequence is three commands per env:

```
cd csi-spl-orc && ENV=<env> STEP=045-gcs-db-backups make do-tf-plan   # then do-provision with the go
ENV=<env> DRY_RUN=0 ./run -a do_spl_db_backup
ENV=<env>           ./run -a do_spl_db_backup_verify
```

The scheduled workflow is committed and will fire daily, but **its first runs
will fail on a missing bucket until T050 is done** — which is the correct
failure: a red run is the alert (spec §4.5), and a backup job that silently
did nothing would be worse.

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
