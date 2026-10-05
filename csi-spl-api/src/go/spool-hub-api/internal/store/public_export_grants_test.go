package store

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Fence 1 of the public dataset export (specs/091 T004, spec §5.1, §9.3
// "grants equal allow-list"). spool-hub-roles/public-export-grants.sql is
// GENERATED from csi-spl-orc/cnf/public-dataset/allow-list.v<N>.yaml by
// do_spl_public_export_grants_gen. The file test runs everywhere; the live
// tests need hub-pg.tst.sh, which applies the three role files as the owner
// and hands the two logins' DSNs in SPOOL_TEST_PG_PUBLIC_EXPORT_DSN and
// SPOOL_TEST_PG_PUBLIC_NAMES_DSN.

const publicExportRole = "spool_public_export"

// repoRoot is the checkout root, relative to this file.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, f, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..")
}

// allowList is the part of an allow-list file fence 1 reads.
type allowList struct {
	path   string
	tables []string            // in file order
	public map[string][]string // table -> public columns
	never  []string
}

// latestAllowList finds the highest allow-list.v<N>.yaml.
func latestAllowList(t *testing.T) string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(repoRoot(t), "csi-spl-orc", "cnf", "public-dataset", "allow-list.v*.yaml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no allow-list file: %v", err)
	}
	ver := regexp.MustCompile(`allow-list\.v([0-9]+)\.yaml$`)
	best, bestN := "", -1
	for _, f := range files {
		m := ver.FindStringSubmatch(f)
		if m == nil {
			continue
		}
		if n, err := strconv.Atoi(m[1]); err == nil && n > bestN {
			best, bestN = f, n
		}
	}
	return best
}

var (
	alTable      = regexp.MustCompile(`^  ([a-z_][a-z0-9_]*):\s*$`)
	alPublicLine = regexp.MustCompile(`^    public:\s*\[(.*)\]\s*$`)
	alPublicHead = regexp.MustCompile(`^    public:\s*$`)
	alItem6      = regexp.MustCompile(`^      - ([a-z_][a-z0-9_]*)\s*$`)
	alItem2      = regexp.MustCompile(`^  - ([a-z_][a-z0-9_]*)\s*$`)
)

// parseAllowList reads the tables' public columns and the never list. It is a
// line reader for the file's own layout (no YAML library in this module); a
// file it reads nothing from fails the test, so a layout change cannot make
// the comparison vacuous.
func parseAllowList(t *testing.T, path string) allowList {
	t.Helper()
	fh, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	al := allowList{path: path, public: map[string][]string{}}
	section, table, inPublic := "", "", false
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), " ")
		if line == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") {
			section, table, inPublic = strings.TrimSuffix(strings.Fields(line)[0], ":"), "", false
			continue
		}
		switch section {
		case "tables":
			if m := alTable.FindStringSubmatch(line); m != nil {
				table, inPublic = m[1], false
				al.tables = append(al.tables, table)
				continue
			}
			if m := alPublicLine.FindStringSubmatch(line); m != nil {
				for _, c := range strings.Split(m[1], ",") {
					al.public[table] = append(al.public[table], strings.TrimSpace(c))
				}
				inPublic = false
				continue
			}
			if alPublicHead.MatchString(line) {
				inPublic = true
				continue
			}
			if m := alItem6.FindStringSubmatch(line); m != nil && inPublic {
				al.public[table] = append(al.public[table], m[1])
				continue
			}
			inPublic = false
		case "never":
			if m := alItem2.FindStringSubmatch(line); m != nil {
				al.never = append(al.never, m[1])
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if len(al.tables) == 0 || len(al.never) == 0 {
		t.Fatalf("%s: read %d table(s) and %d never table(s): the reader no longer matches the file", path, len(al.tables), len(al.never))
	}
	for _, tb := range al.tables {
		if len(al.public[tb]) == 0 {
			t.Fatalf("%s: table %s has no public column", path, tb)
		}
	}
	return al
}

// columnSet is "table.column" for every public column of the allow-list.
func (al allowList) columnSet() map[string]bool {
	out := map[string]bool{}
	for tb, cols := range al.public {
		for _, c := range cols {
			out[tb+"."+c] = true
		}
	}
	return out
}

func grantsFile(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "csi-spl-rdb", "src", "sql", "postgres", "spool-hub-roles", "public-export-grants.sql")
}

var grantLine = regexp.MustCompile(`(?m)^GRANT SELECT \(([^)]*)\) ON ([a-z_][a-z0-9_]*) TO ` + publicExportRole + `;$`)

// TestPublicExportGrantsEqualAllowList: the committed grants file names
// exactly the allow-list's public columns, table by table in file order, and
// records the sha256 of the allow-list it was generated from (an allow-list
// edit without a regenerated grants file fails here). Every statement in it
// is one the generator writes.
func TestPublicExportGrantsEqualAllowList(t *testing.T) {
	al := parseAllowList(t, latestAllowList(t))
	raw, err := os.ReadFile(grantsFile(t))
	if err != nil {
		t.Fatal(err)
	}
	src, _ := os.ReadFile(al.path)
	sum := sha256.Sum256(src)
	if hdr := "csi-spl-orc/cnf/public-dataset/" + filepath.Base(al.path) + " (sha256 " + hex.EncodeToString(sum[:]) + ")"; !strings.Contains(string(raw), hdr) {
		t.Errorf("grants file was not generated from the current allow-list (want %q in its header): run ./run -a do_spl_public_export_grants_gen", hdr)
	}
	var order []string
	got := map[string]bool{}
	for _, m := range grantLine.FindAllStringSubmatch(string(raw), -1) {
		order = append(order, m[2])
		for _, c := range strings.Split(m[1], ",") {
			got[m[2]+"."+strings.TrimSpace(c)] = true
		}
	}
	if strings.Join(order, ",") != strings.Join(al.tables, ",") {
		t.Errorf("grants file tables %v, allow-list tables %v", order, al.tables)
	}
	want := al.columnSet()
	for c := range want {
		if !got[c] {
			t.Errorf("allow-list public column %s has no grant", c)
		}
	}
	for c := range got {
		if !want[c] {
			t.Errorf("grant on %s, which the allow-list does not make public", c)
		}
	}
	allowed := regexp.MustCompile(`^(REVOKE ALL ON ALL (TABLES|SEQUENCES) IN SCHEMA public FROM ` + publicExportRole +
		`|GRANT USAGE ON SCHEMA public TO ` + publicExportRole +
		`|GRANT SELECT \([a-z0-9_, ]+\) ON [a-z_][a-z0-9_]* TO ` + publicExportRole +
		`|GRANT SELECT ON public_export_workspace TO ` + publicExportRole + `);$`)
	n := 0
	for _, line := range strings.Split(string(raw), "\n") {
		if line == "" || strings.HasPrefix(line, "--") {
			continue
		}
		n++
		if !allowed.MatchString(line) {
			t.Errorf("grants file holds a statement the generator does not write: %q", line)
		}
	}
	if n != len(al.tables)+4 {
		t.Errorf("grants file has %d statement(s), want %d (3 revoke/usage + one per table + public_export_workspace)", n, len(al.tables)+4)
	}
}

// loginConn connects as one of the public dataset logins, or skips when
// hub-pg.tst.sh did not provide it.
func loginConn(t *testing.T, env string) *pgx.Conn {
	t.Helper()
	dsn := os.Getenv(env)
	if dsn == "" {
		t.Skipf("%s unset (run hub-pg.tst.sh)", env)
	}
	c, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatalf("%s: %v", env, err)
	}
	t.Cleanup(func() { c.Close(context.Background()) })
	return c
}

// denied runs q in a rolled-back transaction and reports whether Postgres
// refused it with insufficient_privilege (42501). Any other error fails.
func denied(t *testing.T, c *pgx.Conn, q string) bool {
	t.Helper()
	ctx := context.Background()
	tx, err := c.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	rows, err := tx.Query(ctx, q)
	if err == nil {
		for rows.Next() { //nolint:revive
		}
		rows.Close()
		err = rows.Err()
	}
	if err == nil {
		return false
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "42501" {
		return true
	}
	t.Fatalf("%s: failed for another reason: %v", q, err)
	return false
}

// liveColumnGrants is "table.column" for every column privilege role holds
// in schema public, read by the owner from the catalog (never information_schema,
// which hides grants the reader neither made nor holds).
func liveColumnGrants(t *testing.T, pg *Postgres, role string) (cols, other []string) {
	t.Helper()
	rows, err := pg.pool.Query(context.Background(), `
		SELECT c.relname || '.' || a.attname, x.privilege_type
		  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
		  JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(a.attacl) x
		 WHERE n.nspname = 'public' AND NOT a.attisdropped AND x.grantee = $1::regrole
		UNION ALL
		SELECT c.relname, 'TABLE ' || x.privilege_type
		  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) x
		 WHERE n.nspname = 'public' AND x.grantee = $1::regrole`, role)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name, priv string
		if err := rows.Scan(&name, &priv); err != nil {
			t.Fatal(err)
		}
		if priv == "SELECT" {
			cols = append(cols, name)
		} else {
			other = append(other, name+":"+priv)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	sort.Strings(cols)
	sort.Strings(other)
	return cols, other
}

// TestPublicExportGrantsLive: on the database the role files were applied
// to, spool_public_export holds SELECT on exactly the allow-list columns plus
// public_export_workspace; as that login, every public column reads, a
// withheld column (messages.msg, humans.email) and every §4.2 table that
// exists are refused by Postgres.
func TestPublicExportGrantsLive(t *testing.T) {
	c := loginConn(t, "SPOOL_TEST_PG_PUBLIC_EXPORT_DSN")
	pg := rlsStore(t)
	al := parseAllowList(t, latestAllowList(t))

	cols, other := liveColumnGrants(t, pg, publicExportRole)
	var want []string
	for col := range al.columnSet() {
		want = append(want, col)
	}
	sort.Strings(want)
	if strings.Join(cols, ",") != strings.Join(want, ",") {
		t.Errorf("live column grants of %s:\n got %v\nwant %v", publicExportRole, cols, want)
	}
	if strings.Join(other, ",") != "public_export_workspace:TABLE SELECT" {
		t.Errorf("live table grants of %s: %v, want only SELECT on public_export_workspace", publicExportRole, other)
	}

	for _, tb := range al.tables {
		q := "SELECT " + strings.Join(al.public[tb], ", ") + " FROM " + pgx.Identifier{tb}.Sanitize() + " LIMIT 1"
		if denied(t, c, q) {
			t.Errorf("%s cannot read its public columns: %s", publicExportRole, q)
		}
	}
	for _, q := range []string{
		"SELECT msg FROM messages LIMIT 1",
		"SELECT email FROM humans LIMIT 1",
		"SELECT root_pubkey FROM tenants LIMIT 1",
		"SELECT * FROM channels LIMIT 1",
	} {
		if !denied(t, c, q) {
			t.Errorf("%s ran a withheld read: %s", publicExportRole, q)
		}
	}
	n := 0
	for _, tb := range al.never {
		var exists bool
		if err := pg.pool.QueryRow(context.Background(), `SELECT to_regclass($1) IS NOT NULL`, "public."+tb).Scan(&exists); err != nil {
			t.Fatal(err)
		}
		if !exists {
			continue
		}
		n++
		q := "SELECT 1 FROM " + pgx.Identifier{tb}.Sanitize() + " LIMIT 1"
		if !denied(t, c, q) {
			t.Errorf("%s reads a never-exported table: %s", publicExportRole, q)
		}
	}
	if n == 0 {
		t.Error("control is void: no never-exported table exists in the test database")
	}
}

// TestPublicNamesLoginReadsNamesOnly: spool_public_names reads tenants
// (tenant_id, display_name) of EVERY workspace under the operator scope, and
// nothing else: no other tenants column, no other exported table.
func TestPublicNamesLoginReadsNamesOnly(t *testing.T) {
	c := loginConn(t, "SPOOL_TEST_PG_PUBLIC_NAMES_DSN")
	pg := rlsStore(t)
	seedTenantAll(t, pg)
	seedTenantAll(t, pg)
	al := parseAllowList(t, latestAllowList(t))

	cols, other := liveColumnGrants(t, pg, "spool_public_names")
	if strings.Join(cols, ",") != "tenants.display_name,tenants.tenant_id" || len(other) != 0 {
		t.Errorf("live grants of spool_public_names: columns %v, other %v", cols, other)
	}

	ctx := context.Background()
	tx, err := c.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
		t.Fatal(err)
	}
	var seen, all int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM (SELECT tenant_id, display_name FROM tenants) t`).Scan(&seen); err != nil {
		t.Fatalf("spool_public_names cannot read the names: %v", err)
	}
	tx.Rollback(ctx) //nolint:errcheck
	if err := pg.asOperator(ctx, func(otx pgx.Tx) error {
		return otx.QueryRow(ctx, `SELECT count(*) FROM tenants`).Scan(&all)
	}); err != nil {
		t.Fatal(err)
	}
	if seen < 2 || seen != all {
		t.Errorf("spool_public_names sees %d workspace name(s) as operator, the owner sees %d (want every one, at least 2)", seen, all)
	}

	qs := []string{"SELECT root_pubkey FROM tenants LIMIT 1", "SELECT * FROM public_export_workspace"}
	for _, tb := range al.tables {
		if tb != "tenants" {
			qs = append(qs, "SELECT 1 FROM "+pgx.Identifier{tb}.Sanitize()+" LIMIT 1")
		}
	}
	for _, q := range qs {
		if !denied(t, c, q) {
			t.Errorf("spool_public_names ran: %s", q)
		}
	}
}
