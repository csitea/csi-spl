package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// dryRunDB opens the test Postgres, migrated to the source tree.
func dryRunDB(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	return pg
}

// dryRunDir is a copy of the source migrations plus the extra files given.
func dryRunDir(t *testing.T, extra map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	files, _ := filepath.Glob(filepath.Join(sqlDir(t), "*.sql"))
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(f)), raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for name, sql := range extra {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(sql), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// schemaPrint is the ledger and the public schema's columns, as one string.
func schemaPrint(t *testing.T, pg *Postgres) string {
	t.Helper()
	var ledger, cols string
	ctx := context.Background()
	if err := pg.Pool().QueryRow(ctx, `SELECT count(*)::text || ':' || coalesce(md5(string_agg(filename || sha256, ',' ORDER BY filename)), '')
		FROM spool_schema_migrations`).Scan(&ledger); err != nil {
		t.Fatal(err)
	}
	if err := pg.Pool().QueryRow(ctx, `SELECT coalesce(md5(string_agg(table_name || '.' || column_name || ':' || data_type, ',' ORDER BY table_name, column_name)), '')
		FROM information_schema.columns WHERE table_schema = 'public'`).Scan(&cols); err != nil {
		t.Fatal(err)
	}
	return ledger + " " + cols
}

// SPL-2166: Migrate(..., DryRun) reports the pending files, runs them (the second sees
// the first), and leaves the schema and the ledger as they were.
func TestMigrateDryRunAppliesNothing(t *testing.T) {
	pg := dryRunDB(t)
	ctx := context.Background()
	probe := uid("dryrun_probe_")
	dir := dryRunDir(t, map[string]string{
		"9990_" + probe + ".sql": "CREATE TABLE " + probe + " (id int);\nINSERT INTO " + probe + " VALUES (1);\n",
		"9991_" + probe + ".sql": "ALTER TABLE " + probe + " ADD COLUMN note text;\n",
	})
	before := schemaPrint(t, pg)

	res, err := Migrate(ctx, pg.Pool(), dir, DryRun)
	if err != nil {
		t.Fatalf("dry run: %v", err)
	}
	var pending []string
	for _, a := range res {
		if !a.Skipped {
			pending = append(pending, a.File)
		}
		if len(a.SHA256) != 64 {
			t.Fatalf("%s: sha256 %q", a.File, a.SHA256)
		}
	}
	if want := "9990_" + probe + ".sql,9991_" + probe + ".sql"; strings.Join(pending, ",") != want {
		t.Fatalf("pending = %v, want %s", pending, want)
	}
	if after := schemaPrint(t, pg); after != before {
		t.Fatalf("dry run changed the schema or the ledger:\n before %s\n after  %s", before, after)
	}
	var reg *string
	if err := pg.Pool().QueryRow(ctx, `SELECT to_regclass($1)::text`, probe).Scan(&reg); err != nil {
		t.Fatal(err)
	}
	if reg != nil {
		t.Fatalf("dry run left table %s behind", *reg)
	}
	var got bool
	if err := pg.Pool().QueryRow(ctx, `SELECT pg_try_advisory_lock($1) AND pg_advisory_unlock($1)`, migrateLockKey).Scan(&got); err != nil || !got {
		t.Fatalf("advisory lock not released after the dry run (got %v, err %v)", got, err)
	}
}

// A dry run refuses what a real run would: a file that does not parse, an
// empty file, and an applied file whose bytes changed. Nothing is recorded.
func TestMigrateDryRunRefuses(t *testing.T) {
	pg := dryRunDB(t)
	ctx := context.Background()
	probe := uid("dryrun_bad_")
	before := schemaPrint(t, pg)

	cases := map[string]struct {
		extra map[string]string
		edit  bool
		want  string
	}{
		"syntax": {extra: map[string]string{
			"9990_" + probe + ".sql": "CREATE TABLE " + probe + " (id int);\n",
			"9991_" + probe + ".sql": "CREAT TABLE nope (id int);\n",
		}, want: "9991_" + probe + ".sql does not apply"},
		"empty":  {extra: map[string]string{"9990_" + probe + ".sql": "  \n"}, want: "is empty"},
		"edited": {edit: true, want: "forward-only"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			dir := dryRunDir(t, c.extra)
			if c.edit {
				f := filepath.Join(dir, "0001_hub_core.sql")
				raw, _ := os.ReadFile(f)
				if err := os.WriteFile(f, append(raw, []byte("\n-- edited\n")...), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			_, err := Migrate(ctx, pg.Pool(), dir, DryRun)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err = %v, want it to contain %q", err, c.want)
			}
		})
	}
	if after := schemaPrint(t, pg); after != before {
		t.Fatalf("a refused dry run changed the schema or the ledger:\n before %s\n after  %s", before, after)
	}
}

// A dry run waits on the same advisory lock as a real migrator.
func TestMigrateDryRunTakesTheLock(t *testing.T) {
	pg := dryRunDB(t)
	ctx := context.Background()
	holder, err := pg.Pool().Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Release()
	if _, err := holder.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrateLockKey); err != nil {
		t.Fatal(err)
	}
	short, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	_, err = Migrate(short, pg.Pool(), sqlDir(t), DryRun)
	if _, uerr := holder.Exec(ctx, `SELECT pg_advisory_unlock($1)`, migrateLockKey); uerr != nil {
		t.Fatal(uerr)
	}
	if err == nil {
		t.Fatal("dry run ran while another migrator held the lock")
	}
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t), DryRun); err != nil {
		t.Fatalf("dry run after the lock was released: %v", err)
	}
}
