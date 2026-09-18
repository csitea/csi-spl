# csi-spl-rdb

The spool hub's Postgres schema, as plain SQL. The data shape is described in
`csi-spl-doc/specs/003-spool-message-bus/data-model.md`; this directory is its
DDL, and `internal/store` in `csi-spl-api` queries exactly these tables.

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

## Tests

`csi-spl-api/src/bash/tests/hub-pg.tst.sh` starts a throwaway Postgres
(`initdb` into a temp dir), runs the migrator twice (the second run must be a
no-op), then runs the `internal/store` contract suite against it. It skips
cleanly when no Postgres server binaries are installed.
