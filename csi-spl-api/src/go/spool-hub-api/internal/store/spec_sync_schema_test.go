package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 145 work group 1, the schema (rdb 0207, 0208, SPL-2452). Postgres
// only (hub-pg.tst.sh). Each test is red before its migration: the column
// or table it reads does not exist.

const specTasksPath = "csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md"

// seedSpecSync writes one ledger row for tenant in its own scope, linked to
// issue number and Qto doc (crosstenant_test.go seedTenantAll).
func seedSpecSync(ctx context.Context, pg *Postgres, tenant string, number int, doc string) error {
	_, err := pg.execTenant(ctx, tenant, `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, issue_number, qto_doc_id, qto_item_id, last_git_sha)
		VALUES ($1, $2, 'T002', $3, $4::uuid, $5::uuid, $6)`, tenant, specTasksPath, number, doc, uuid4(), strings.Repeat("ab", 20))
	return err
}

// specIssue is one fresh issue of tenant, made through the store.
func specIssue(t *testing.T, pg *Postgres, tenant string) int {
	t.Helper()
	iss, err := pg.CreateIssue(context.Background(), Issue{Discussions: []string{uuid4()}, TenantID: tenant, Title: "spec 145",
		TaskID: uuid4(), CreatedBy: "HUM-1"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	return iss.Number
}

// specDoc is one fresh Qto doc of tenant with its root item, raw rows
// (I1: a doc ends its transaction with a root).
func specDoc(t *testing.T, pg *Postgres, tenant string) string {
	t.Helper()
	var doc string
	if err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		if err := tx.QueryRow(context.Background(), `INSERT INTO workspace_doc (tenant_id, title, rev) VALUES ($1, 'spec 145', 1) RETURNING id::text`,
			tenant).Scan(&doc); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ($1, $2, NULL, 1)`, tenant, doc)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return doc
}

// T001: issues.spec_path, issues.spec_task_id. GATE: a fresh issue reads
// both as empty string, a valid spec path and task id are stored, and the
// reverse-lookup index exists. RED CONTROL: a path outside
// csi-spl-doc/specs/<NNN>-<slug>/<file>.md ('bad/path.txt' first) and a task
// id with a symbol or over 32 characters are each the check violation.
func TestIssueSpecAttributes0207(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	n := specIssue(t, pg, tn)
	read := func() (string, string) {
		var p, id string
		if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT spec_path, spec_task_id FROM issues WHERE tenant_id = $1 AND number = $2`, tn, n).Scan(&p, &id)
		}); err != nil {
			t.Fatal(err)
		}
		return p, id
	}
	if p, id := read(); p != "" || id != "" {
		t.Fatalf("a fresh issue reads spec (%q, %q), want both empty", p, id)
	}
	set := func(p, id string) error {
		_, err := pg.execTenant(ctx, tn, `UPDATE issues SET spec_path = $3, spec_task_id = $4 WHERE tenant_id = $1 AND number = $2`, tn, n, p, id)
		return err
	}
	for _, ok := range [][2]string{{specTasksPath, "T001"}, {"csi-spl-doc/specs/000-quick-fixes/spec.md", ""},
		{"csi-spl-doc/specs/061-agent-id-rename/plan_v2.md", "T012.s1"}, {specTasksPath, "B4"}} {
		if err := set(ok[0], ok[1]); err != nil {
			t.Errorf("valid spec %v: %v", ok, err)
		}
	}
	if p, id := read(); p != specTasksPath || id != "B4" {
		t.Fatalf("stored spec (%q, %q), want (%q, B4)", p, id, specTasksPath)
	}
	for _, bad := range [][2]string{{"bad/path.txt", ""}, {"csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.txt", ""},
		{"csi-spl-doc/specs/14-x/tasks.md", ""}, {"csi-spl-doc/specs/145-Issue/tasks.md", ""},
		{"csi-spl-doc/specs/145-x/sub/tasks.md", ""}, {"csi-spl-doc/specs/145-" + strings.Repeat("x", 240) + "/tasks.md", ""},
		{specTasksPath, "T 001"}, {specTasksPath, "T001;"}, {specTasksPath, strings.Repeat("T", 33)}} {
		if err := set(bad[0], bad[1]); err == nil || !strings.Contains(err.Error(), "check constraint") {
			t.Errorf("spec %v: %v, want a check violation", bad, err)
		}
	}
	var idx int64
	if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE tablename = 'issues' AND indexname = 'issues_spec_task_idx'
		AND indexdef LIKE '%(tenant_id, spec_path, spec_task_id)%'`).Scan(&idx); err != nil || idx != 1 {
		t.Fatalf("issues_spec_task_idx: %d %v, want the (tenant_id, spec_path, spec_task_id) index", idx, err)
	}
}

// T002: spec_sync_map. GATE: a workspace writes and reads its own row, the
// operator reads it, deleting the issue or the doc clears only that link.
// RED CONTROL: with no workspace set a read sees 0 rows and an insert is
// refused (fail-closed RLS); another workspace reads 0 of the rows and
// cannot write one stamped with them, nor link its row to the other
// workspace's issue or doc; a bad spec path, task id, sha or status is a
// check violation.
func TestSpecSyncMap0208(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	na, docA := specIssue(t, pg, a), specDoc(t, pg, a)
	nb, docB := specIssue(t, pg, b), specDoc(t, pg, b)
	if err := seedSpecSync(ctx, pg, a, na, docA); err != nil {
		t.Fatalf("A writes its own ledger row: %v", err)
	}
	count := func(run func(func(pgx.Tx) error) error) (int, error) {
		var n int
		err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM spec_sync_map WHERE tenant_id = $1`, a).Scan(&n)
		})
		return n, err
	}
	scopesA, scopesB := reportingScopes(pg, a), reportingScopes(pg, b)
	if n, err := count(scopesA["workspace"]); err != nil || n != 1 {
		t.Fatalf("CONTROL: A reads %d of its rows (%v), want 1", n, err)
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM spec_sync_map WHERE tenant_id = $1 AND sync_status = 'in_sync'`, a); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator reads %d (%v), want the in_sync row", n, err)
	}
	insert := `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id) VALUES ($1, $2, $3)`
	for name, run := range map[string]func(func(pgx.Tx) error) error{"no workspace": scopesA["none"], "workspace B": scopesB["workspace"]} {
		if n, err := count(run); err != nil || n != 0 {
			t.Errorf("%s reads %d of A's ledger rows (%v), want 0", name, n, err)
		}
		if err := execIn(run, insert, a, specTasksPath, "T009"); err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s writes an A-stamped row: %v, want the RLS refusal", name, err)
		}
		if err := execIn(run, `UPDATE spec_sync_map SET sync_status = 'conflict' WHERE tenant_id = $1`, a); err != nil {
			t.Errorf("%s update: %v", name, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM spec_sync_map WHERE tenant_id = $1 AND sync_status = 'in_sync'`, a); err != nil || n != 1 {
		t.Fatalf("a foreign-scope UPDATE changed A's row: %d %v", n, err)
	}
	if err := execIn(scopesA["workspace"], insert, a, specTasksPath, "T002"); err == nil || !strings.Contains(err.Error(), "spec_sync_map_pkey") {
		t.Fatalf("duplicate (spec_path, spec_task_id): %v, want the unique violation", err)
	}
	if err := execIn(scopesA["workspace"], insert, a, specTasksPath, ""); err != nil {
		t.Fatalf("the whole-spec row (empty task id): %v", err)
	}
	// B links its row to A's issue / doc: the FK carries tenant_id, so it is
	// refused. A's second issue has a number B does not have.
	for col, v := range map[string]any{"issue_number": specIssue(t, pg, a), "qto_doc_id": docA} {
		if err := execIn(scopesB["workspace"], `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, `+col+`) VALUES ($1, $2, 'T001', $3)`,
			b, specTasksPath, v); err == nil || !strings.Contains(err.Error(), "foreign key") {
			t.Errorf("B links %s to A's: %v, want the FK violation", col, err)
		}
	}
	for _, bad := range []string{
		`INSERT INTO spec_sync_map (tenant_id, spec_path) VALUES ($1, 'bad/path.txt')`,
		`INSERT INTO spec_sync_map (tenant_id, spec_path) VALUES ($1, '')`,
		`INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id) VALUES ($1, '` + specTasksPath + `', 'T 1')`,
		`INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, last_git_sha) VALUES ($1, '` + specTasksPath + `', 'T3', 'ABC')`,
		`INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, sync_status) VALUES ($1, '` + specTasksPath + `', 'T4', 'stale')`,
	} {
		if err := execIn(scopesB["workspace"], bad, b); err == nil || !strings.Contains(err.Error(), "check constraint") {
			t.Errorf("%s: %v, want a check violation", bad, err)
		}
	}
	// Deleting the issue, then the doc, clears only that link; the row stays.
	if err := seedSpecSync(ctx, pg, b, nb, docB); err != nil {
		t.Fatalf("B writes its own ledger row: %v", err)
	}
	if _, err := pg.asOperator2(ctx, `DELETE FROM issues WHERE tenant_id = $1 AND number = $2`, b, nb); err != nil {
		t.Fatal(err)
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM spec_sync_map WHERE tenant_id = $1 AND spec_task_id = 'T002'
		AND issue_number IS NULL AND qto_doc_id = $2::uuid`, b, docB); err != nil || n != 1 {
		t.Fatalf("after the issue delete: %d %v, want the row with issue_number NULL and the doc kept", n, err)
	}
	if _, err := pg.asOperator2(ctx, `DELETE FROM workspace_doc WHERE tenant_id = $1 AND id = $2::uuid`, b, docB); err != nil {
		t.Fatal(err)
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM spec_sync_map WHERE tenant_id = $1 AND spec_task_id = 'T002'
		AND issue_number IS NULL AND qto_doc_id IS NULL`, b); err != nil || n != 1 {
		t.Fatalf("after the doc delete: %d %v, want the row with both links NULL", n, err)
	}
}
