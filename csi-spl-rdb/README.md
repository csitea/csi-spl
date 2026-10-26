# csi-spl-rdb

> Generated from qto doc `012201ea-0eb5-4d4a-bc03-e663bcd313e5`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The spool hub's Postgres schema, as plain SQL. The data shape is described in
`csi-spl-doc/specs/003-spool-message-bus/data-model.md`; this directory is its
DDL, and `internal/store` in `csi-spl-api` queries exactly these tables.

<a id="ws-doc-98273c2e-299e-4e94-b7f1-21db2643f2b8"></a>
## Layout

| path | holds |
|---|---|
| `src/sql/postgres/spool-hub/NNNN_<name>.sql` | ordered, forward-only Postgres DDL |

Rules for a new file:

- Next free four-digit prefix; the migrator applies files in **filename order**.
- **Forward-only.** Never edit a file that has been applied anywhere: the
  migrator records each file's sha256 and refuses to run when an applied file
  has changed. Fix a mistake with a new file.
- No data that identifies a person, box or tenant; no keys, tokens or URLs.

<a id="ws-doc-a7e14e2f-f1bc-4e91-87c0-88bae627ccda"></a>
## Applying

The `spool` binary carries the runner:

```bash
spool migrate --db "$SPOOL_HUB_DB_DSN" --sql-dir csi-spl-rdb/src/sql/postgres/spool-hub
```

- `--db` defaults to `$SPOOL_HUB_DB_DSN`, `--sql-dir` to `$SPOOL_HUB_MIGRATIONS_DIR`.
- One transaction per file, serialised by a Postgres advisory lock, tracked in
  `spool_schema_migrations (filename, sha256, applied_at)`. A re-run is a no-op.
- The hub image bundles this directory at `/opt/spool/sql/postgres/spool-hub`;
  the infra lane's `do_setup_app_inf` runs `spool migrate` and then `spool serve`.

<a id="ws-doc-3bfb1d2c-791d-4dfc-8b19-69a5368dd9f4"></a>
## Tests

`csi-spl-api/src/bash/tests/hub-pg.tst.sh` starts a throwaway Postgres
(`initdb` into a temp dir), runs the migrator twice (the second run must be a
no-op), then runs the `internal/store` contract suite against it. It skips
cleanly when no Postgres server binaries are installed.
