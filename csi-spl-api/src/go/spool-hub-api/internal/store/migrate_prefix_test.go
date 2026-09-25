package store

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// migrationPrefix is the four-digit migration number at the start of a
// spool-hub *.sql filename (0021_name.sql or 0021.sql). The migrator applies
// every file and records the filename, so two files may share that number
// only when they are the already-applied exception below. A rename of either
// applied file would look like a new migration.
var migrationPrefix = regexp.MustCompile(`^(\d{4})[_.]`)

// knownSharedMigrationPrefixes are the pairs the ledger already has.
// Both names of each pair stay; do not add another file under 0021 or 0040,
// and do not add a second file under any other number.
//
// 0040 collided on 2026-09-25 (1e438b7 and 1482b0c landed ten minutes apart).
// Both files were already in spool_schema_migrations on dev AND prd before
// the collision was caught (typed_by 16:29Z/16:32Z, display_name
// 16:21Z/16:22Z), so renaming either would re-run an ALTER TABLE ADD COLUMN
// and break the next do_spl_db_bootstrap. The next migration is 0041.
var knownSharedMigrationPrefixes = map[string][]string{
	"0021": {
		"0021_rls_fail_closed.sql",
		"0021_tenant_rbac.sql",
	},
	"0040": {
		"0040_messages_typed_by_box_operators.sql",
		"0040_tenants_display_name.sql",
	},
}

// spoolHubSQLDir is csi-spl-rdb/src/sql/postgres/spool-hub next to this
// module. It ignores SPOOL_TEST_SQL_DIR so a scratch fixture cannot hide a
// collision in the source tree.
func spoolHubSQLDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "..", "..",
		"csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
}

// sharedMigrationPrefixes groups *.sql names that share a four-digit prefix.
// A prefix used by one file is not returned.
func sharedMigrationPrefixes(dir string) (map[string][]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return nil, err
	}
	by := map[string][]string{}
	for _, path := range matches {
		name := filepath.Base(path)
		m := migrationPrefix.FindStringSubmatch(name)
		if m == nil {
			continue
		}
		by[m[1]] = append(by[m[1]], name)
	}
	shared := map[string][]string{}
	for prefix, names := range by {
		if len(names) < 2 {
			continue
		}
		sort.Strings(names)
		shared[prefix] = names
	}
	return shared, nil
}

func prefixSetsEqual(got, want map[string][]string) bool {
	if len(got) != len(want) {
		return false
	}
	for prefix, names := range want {
		have := got[prefix]
		sortedWant := append([]string(nil), names...)
		sort.Strings(sortedWant)
		if len(have) != len(sortedWant) {
			return false
		}
		for i := range sortedWant {
			if have[i] != sortedWant[i] {
				return false
			}
		}
	}
	return true
}

func formatPrefixSets(sets map[string][]string) string {
	if len(sets) == 0 {
		return "(none)"
	}
	prefixes := make([]string, 0, len(sets))
	for prefix := range sets {
		prefixes = append(prefixes, prefix)
	}
	sort.Strings(prefixes)
	parts := make([]string, 0, len(prefixes))
	for _, prefix := range prefixes {
		parts = append(parts, prefix+":["+strings.Join(sets[prefix], ", ")+"]")
	}
	return strings.Join(parts, "; ")
}

func TestSpoolHubMigrationPrefixes(t *testing.T) {
	dir := spoolHubSQLDir(t)
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		t.Fatalf("spool-hub sql dir %s: %v", dir, err)
	}
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) == 0 {
		t.Fatalf("no *.sql migrations in %s", dir)
	}
	got, err := sharedMigrationPrefixes(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !prefixSetsEqual(got, knownSharedMigrationPrefixes) {
		t.Fatalf("shared four-digit migration prefixes = %s, want only %s",
			formatPrefixSets(got), formatPrefixSets(knownSharedMigrationPrefixes))
	}
}

func TestMigrationPrefixGuardRejectsANewPair(t *testing.T) {
	write := func(t *testing.T, dir string, names ...string) {
		t.Helper()
		for _, name := range names {
			if err := os.WriteFile(filepath.Join(dir, name), []byte("-- fixture\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	// every file of every excused pair, read from the map so a new
	// exception is covered here without editing this fixture
	var known []string
	for _, names := range knownSharedMigrationPrefixes {
		known = append(known, names...)
	}

	t.Run("known pair is the only excused collision", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, append(known, "0001_ok.sql")...)
		got, err := sharedMigrationPrefixes(dir)
		if err != nil {
			t.Fatal(err)
		}
		if !prefixSetsEqual(got, knownSharedMigrationPrefixes) {
			t.Fatalf("got %s", formatPrefixSets(got))
		}
	})

	t.Run("a new prefix pair fails", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, append(known, "0099_new_a.sql", "0099_new_b.sql")...)
		got, err := sharedMigrationPrefixes(dir)
		if err != nil {
			t.Fatal(err)
		}
		if prefixSetsEqual(got, knownSharedMigrationPrefixes) {
			t.Fatal("a new shared prefix was accepted")
		}
		if _, ok := got["0099"]; !ok {
			t.Fatalf("0099 was not reported: %s", formatPrefixSets(got))
		}
	})

	t.Run("a third file on 0021 fails", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, append(known, "0021_extra.sql")...)
		got, err := sharedMigrationPrefixes(dir)
		if err != nil {
			t.Fatal(err)
		}
		if prefixSetsEqual(got, knownSharedMigrationPrefixes) {
			t.Fatal("a third file on 0021 was accepted")
		}
		if len(got["0021"]) != 3 {
			t.Fatalf("0021 set = %v", got["0021"])
		}
	})

	t.Run("a pair with no exception fails", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, "0008_one.sql", "0008_two.sql")
		got, err := sharedMigrationPrefixes(dir)
		if err != nil {
			t.Fatal(err)
		}
		if prefixSetsEqual(got, knownSharedMigrationPrefixes) {
			t.Fatal("an unexcused pair was accepted")
		}
		if len(got["0008"]) != 2 {
			t.Fatalf("0008 was not reported: %s", formatPrefixSets(got))
		}
	})
}
