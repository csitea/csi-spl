package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The OUTPUT of the public dataset fences (specs/091 section 4, SPL-3808).
// Owner HUM-10, t1 e2c0e6b4: the export holds only the t1, spool and demo
// workspaces (msg c72b919b, poll answer afb3d81d) and no data of any user but
// his admin account, which appears like every member (msg c68e6073). Postgres
// only (hub-pg.tst.sh): the real spool_public_export login, with the real
// column grants (public-export-grants.sql) and the RESTRICTIVE policy of rdb
// 0126 / 0233, reads EVERY column it holds SELECT on, in every table (the
// catalog as the login sees it, not the allow-list), once per listed workspace (the export's own path) and once with the
// operator scope set and no workspace (a query that forgot its filter). The
// test asserts on that text, not on the allow-list: a fourth workspace's
// rows, every e-mail, real name and password hash are absent.

// person is a human with what spec 4.2 never exports.
type person struct{ humanID, email, name, hash string }

// seedPerson writes a human with an e-mail, a real name and an argon2id
// password credential, a member of tenant.
func seedPerson(t *testing.T, pg *Postgres, tenant, tag string) person {
	t.Helper()
	ctx := context.Background()
	p := person{email: "plant-" + tag + "@example.org", name: "Plantina " + strings.ToUpper(tag[:1]) + tag[1:] + " Personsdottir",
		hash: "$argon2id$v=19$m=65536,t=3,p=4$cGxhbnQt" + tag + "$aGFzaC1wbGFudC0" + tag}
	if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (display_name, email) VALUES ($1, $2) RETURNING human_id`,
		p.name, p.email).Scan(&p.humanID); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `INSERT INTO password_credentials (subject, password_hash, display_name) VALUES ($1, $2, $3)`,
		p.email, p.hash, p.name); err != nil {
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ($1, $2, 'developer', 'seed')`,
			tenant, p.humanID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return p
}

// setExportWorkspaces makes public_export_workspace hold exactly ids, the
// statements do_spl_public_export_role runs, and empties it at cleanup.
func setExportWorkspaces(t *testing.T, pg *Postgres, ids []string) {
	t.Helper()
	ctx := context.Background()
	list := strings.Join(ids, ",")
	for _, q := range []string{
		`DELETE FROM public_export_workspace WHERE workspace_id <> ALL (string_to_array($1, ','))`,
		`INSERT INTO public_export_workspace (workspace_id) SELECT unnest(string_to_array($1, ',')) ON CONFLICT DO NOTHING`,
	} {
		if _, err := pg.pool.Exec(ctx, q, list); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	t.Cleanup(func() { pg.pool.Exec(context.Background(), `DELETE FROM public_export_workspace`) }) //nolint:errcheck
}

// exportDump is what the login emitted: every cell as text, and the
// workspace ids of the tenant_id columns it saw, per table.
type exportDump struct {
	text string
	seen map[string]map[string]int // table -> tenant_id -> rows
}

// grantedColumns is every column of schema public the login holds SELECT
// on, per table, read as the login itself.
func grantedColumns(t *testing.T, c *pgx.Conn) map[string][]string {
	t.Helper()
	rows, err := c.Query(context.Background(), `SELECT c.relname, a.attname
		  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm') AND a.attnum > 0 AND NOT a.attisdropped
		   AND has_column_privilege(c.oid, a.attnum, 'SELECT')
		 ORDER BY c.relname, a.attnum`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var tb, col string
		if err := rows.Scan(&tb, &col); err != nil {
			t.Fatal(err)
		}
		out[tb] = append(out[tb], col)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// dumpAsExportLogin reads every granted column of every table as the export
// login, under each scope: {tenant, rls_scope}. humans has no RLS: it is
// read through the memberships the login can see (spec 5.2).
func dumpAsExportLogin(t *testing.T, c *pgx.Conn, al allowList, scopes [][2]string) exportDump {
	t.Helper()
	ctx := context.Background()
	var b strings.Builder
	d := exportDump{seen: map[string]map[string]int{}}
	granted := grantedColumns(t, c)
	for _, tb := range al.tables {
		if len(granted[tb]) == 0 {
			t.Fatalf("control is void: %s holds no column of allow-list table %s", publicExportRole, tb)
		}
	}
	tables := make([]string, 0, len(granted))
	for tb := range granted {
		tables = append(tables, tb)
	}
	sort.Strings(tables)
	for _, sc := range scopes {
		tx, err := c.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true), set_config('app.rls_scope', $2, true)`, sc[0], sc[1]); err != nil {
			t.Fatal(err)
		}
		for _, tb := range tables {
			dumpTable(t, tx, tb, granted[tb], &b, d.seen)
		}
		tx.Rollback(ctx) //nolint:errcheck
	}
	d.text = b.String()
	return d
}

func dumpTable(t *testing.T, tx pgx.Tx, tb string, cols []string, b *strings.Builder, seen map[string]map[string]int) {
	t.Helper()
	sel := make([]string, len(cols))
	for i, col := range cols { // as text: what a COPY would write, a uuid included
		sel[i] = col + "::text"
	}
	q := "SELECT " + strings.Join(sel, ", ") + " FROM " + pgx.Identifier{tb}.Sanitize()
	if tb == "humans" {
		q += " WHERE human_id IN (SELECT human_id FROM tenant_memberships)"
	}
	rows, err := tx.Query(context.Background(), q)
	if err != nil {
		t.Fatalf("%s as %s: %v", q, publicExportRole, err)
	}
	defer rows.Close()
	ti := -1
	for i, col := range cols {
		if col == "tenant_id" {
			ti = i
		}
	}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			t.Fatal(err)
		}
		for i, v := range vals {
			fmt.Fprintf(b, "%s\t", textOf(v))
			if i == ti {
				if seen[tb] == nil {
					seen[tb] = map[string]int{}
				}
				seen[tb][textOf(v)]++
			}
		}
		b.WriteString("\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
}

// TestPublicExportOutputListedWorkspacesOnly: three listed workspaces and a
// fourth, a member of a listed one and one of the fourth, each with an
// e-mail, a real name and a password hash. CONTROLS: the fourth's rows and
// both people's secrets exist (the owner reads them), and the output holds
// rows of every listed workspace and the listed member's HUM-n id, so an
// empty read cannot pass.
func TestPublicExportOutputListedWorkspacesOnly(t *testing.T) {
	c := loginConn(t, "SPOOL_TEST_PG_PUBLIC_EXPORT_DSN")
	pg := rlsStore(t)
	al := parseAllowList(t, latestAllowList(t))
	listed := []crossSeed{seedTenantAll(t, pg), seedTenantAll(t, pg), seedTenantAll(t, pg)}
	fourth := seedTenantAll(t, pg)
	admin, outsider := seedPerson(t, pg, listed[0].tenant, "admin"), seedPerson(t, pg, fourth.tenant, "outsider")
	ids := []string{listed[0].tenant, listed[1].tenant, listed[2].tenant}
	exportOutputControls(t, pg, fourth, admin, outsider)
	setExportWorkspaces(t, pg, ids)

	scopes := [][2]string{{"", "operator"}, {fourth.tenant, "operator"}, {fourth.tenant, ""}}
	for _, id := range ids {
		scopes = append(scopes, [2]string{id, ""})
	}
	d := dumpAsExportLogin(t, c, al, scopes)

	for _, tb := range exportScopeTables {
		for _, id := range ids {
			if d.seen[tb][id] == 0 && tb != "channels" && tb != "messages" {
				t.Errorf("control is void: the output holds no %s row of listed workspace %s", tb, id)
			}
		}
	}
	if got := exportSeenIDs(d.seen["tenants"]); strings.Join(got, ",") != strings.Join(sortedCopy(ids), ",") {
		t.Errorf("the output's workspaces are %v, want exactly the listed %v", got, sortedCopy(ids))
	}
	for _, id := range ids {
		if !strings.Contains(d.text, listedMsgID(listed, id)) {
			t.Errorf("control is void: the output holds no message of listed workspace %s", id)
		}
	}
	if !strings.Contains(d.text, admin.humanID+"\t") {
		t.Errorf("control is void: the listed member %s is not in the output", admin.humanID)
	}
	for what, s := range map[string]string{
		"the fourth workspace's id": fourth.tenant, "its message id": fourth.msgID,
		"its message body marker": fourth.marker, "the outsider's HUM-n id": outsider.humanID + "\t",
		"an e-mail (admin)": admin.email, "a real name (admin)": admin.name, "a password hash (admin)": admin.hash,
		"an e-mail (outsider)": outsider.email, "a real name (outsider)": outsider.name, "a password hash (outsider)": outsider.hash,
		"any argon2id hash": "$argon2id$", "any e-mail domain": "@example.",
	} {
		if strings.Contains(d.text, s) {
			t.Errorf("the export output holds %s", what)
		}
	}
}

// exportOutputControls: what the output must not hold does exist in the
// database, read by the owner as the operator.
func exportOutputControls(t *testing.T, pg *Postgres, fourth crossSeed, people ...person) {
	t.Helper()
	ctx := context.Background()
	for _, tb := range exportScopeTables {
		if countOf(t, pg, tb, fourth.tenant) == 0 {
			t.Fatalf("control is void: the fourth workspace has no %s row", tb)
		}
	}
	for _, p := range people {
		var n int
		if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM humans h JOIN password_credentials c ON c.subject = h.email
			WHERE h.human_id = $1 AND h.display_name = $2 AND c.password_hash = $3`, p.humanID, p.name, p.hash).Scan(&n); err != nil || n != 1 {
			t.Fatalf("control is void: %s has no e-mail, name and hash in the database (%d, %v)", p.humanID, n, err)
		}
	}
}

func listedMsgID(listed []crossSeed, id string) string {
	for _, s := range listed {
		if s.tenant == id {
			return s.msgID
		}
	}
	return id
}

func exportSeenIDs(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// textOf is a ::text cell, \N for NULL like a COPY.
func textOf(v any) string {
	if v == nil {
		return `\N`
	}
	return fmt.Sprint(v)
}
