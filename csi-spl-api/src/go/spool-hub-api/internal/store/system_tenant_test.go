package store

import (
	"context"
	"errors"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 137 T020 and T021 on testkit Postgres (PRE_PUSH_TIER=full):
// the system tenant of the repo docs (rdb 0191) and the doc ACL (rdb 0192).
//
//	go test ./internal/store -run 'SystemTenant|DocACL' -v

// sysDocPG is a migrated Postgres with rdb 0191, two fresh workspaces and a
// document in each plus one in the system tenant (written in its own scope,
// as the operator CI import does), with one item each.
type sysDocFix struct {
	pg                 *Postgres
	t1, t2             string
	doc1, doc2, docSys string
}

func sysDocPG(t *testing.T) sysDocFix {
	t.Helper()
	pg := pgOnly(t)
	ctx := context.Background()
	var n int
	if err := pg.asOperatorQuery(ctx, `SELECT count(*) FROM tenants WHERE tenant_id = $1`, []any{SystemTenant},
		func(r pgx.Rows) error { return r.Scan(&n) }); err != nil || n != 1 {
		t.Fatalf("rdb 0191: want the %q tenant row, got %d (%v)", SystemTenant, n, err)
	}
	f := sysDocFix{pg: pg, t1: newTenant(t, pg), t2: newTenant(t, pg)}
	mk := func(tenant, title string) string {
		doc, root, err := pg.DocCreateIn(ctx, tenant, "", title, "", "t")
		if err != nil {
			t.Fatalf("create %s in %s: %v", title, tenant, err)
		}
		if _, err := pg.DocItemAdd(ctx, tenant, DocItemAddReq{DocID: doc, Anchor: root, Where: DocChild,
			Title: "zebrafinch " + title, Body: "zebrafinch body", Actor: "t"}); err != nil {
			t.Fatalf("item in %s: %v", tenant, err)
		}
		return doc
	}
	f.doc1, f.doc2, f.docSys = mk(f.t1, "one"), mk(f.t2, "two"), mk(SystemTenant, "repo "+f.t1)
	return f
}

// countIn is one count(*) in tenant's scope.
func countIn(t *testing.T, pg *Postgres, tenant, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := pg.queryRowTenant(context.Background(), tenant, sql, args, &n); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return n
}

// TestSystemTenantRLS: I1 (a workspace never sees another's rows), the
// system rows readable from any workspace, and I2 (no workspace writes one).
func TestSystemTenantRLS(t *testing.T) {
	f := sysDocPG(t)
	ctx := context.Background()
	tables := map[string]string{
		"workspace_doc":         `SELECT count(*) FROM workspace_doc WHERE tenant_id = $1`,
		"workspace_doc_item":    `SELECT count(*) FROM workspace_doc_item WHERE tenant_id = $1`,
		"workspace_doc_node":    `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1`,
		"workspace_doc_rev_log": `SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = $1`,
	}
	for name, q := range tables {
		if n := countIn(t, f.pg, f.t2, q, f.t1); n != 0 {
			t.Errorf("I1 %s: workspace %s reads %d rows of %s, want 0", name, f.t2, n, f.t1)
		}
		if n := countIn(t, f.pg, f.t2, q, f.t2); n == 0 {
			t.Errorf("%s: workspace %s reads none of its own rows", name, f.t2)
		}
		if n := countIn(t, f.pg, f.t2, q, SystemTenant); n == 0 {
			t.Errorf("%s: workspace %s reads no system row, want the repo docs readable", name, f.t2)
		}
	}

	// I2: a workspace session inserts no system row (RLS WITH CHECK, 42501)
	// and its UPDATE / DELETE / FOR UPDATE see none.
	err := f.pg.inTenant(ctx, f.t2, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO workspace_doc (tenant_id, title) VALUES ($1, 'planted')`, SystemTenant)
		return err
	})
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || pe.Code != "42501" {
		t.Errorf("I2 insert: a workspace session wrote a system doc, err %v (want 42501)", err)
	}
	for _, q := range []string{
		`UPDATE workspace_doc SET title = 'x' WHERE tenant_id = $1`,
		`UPDATE workspace_doc_item SET body = 'x' WHERE tenant_id = $1`,
		`UPDATE workspace_doc_node SET title = title WHERE tenant_id = $1`,
		`DELETE FROM workspace_doc_item WHERE tenant_id = $1 AND parent_id IS NOT NULL`,
		`DELETE FROM workspace_doc_rev_log WHERE tenant_id = $1`,
		`DELETE FROM workspace_doc WHERE tenant_id = $1`,
	} {
		err := f.pg.inTenant(ctx, f.t2, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, q, SystemTenant)
			if err == nil && tag.RowsAffected() != 0 {
				t.Errorf("I2: %q touched %d system rows from workspace %s", q, tag.RowsAffected(), f.t2)
			}
			return err
		})
		if err != nil && !(errors.As(err, &pe) && pe.Code == "42501") {
			t.Errorf("I2: %q: %v", q, err)
		}
	}
	var locked int
	if err := f.pg.inTenant(ctx, f.t2, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT id FROM workspace_doc WHERE id = $1 FOR UPDATE`, f.docSys)
		if err != nil {
			return err
		}
		for rows.Next() {
			locked++
		}
		return rows.Err()
	}); err != nil {
		t.Errorf("FOR UPDATE: %v", err)
	}
	if locked != 0 {
		t.Errorf("I2: workspace %s locked the system doc FOR UPDATE", f.t2)
	}
	if n := countIn(t, f.pg, SystemTenant, `SELECT count(*) FROM workspace_doc WHERE id = $1 AND title LIKE 'repo %'`, f.docSys); n != 1 {
		t.Errorf("I2: the system doc changed under a workspace session")
	}
}

// TestSystemTenantStoreIsolation: the store's workspace reads list their own
// tenant only, so the system docs RLS now admits never enter a workspace's
// list, head, search or writes; the operator lists and sweeps leave the
// system tenant out.
func TestSystemTenantStoreIsolation(t *testing.T) {
	f := sysDocPG(t)
	ctx := context.Background()
	heads, err := f.pg.DocList(ctx, f.t2, "", 1000)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range heads {
		if h.ID != f.doc2 {
			t.Errorf("DocList(%s) lists doc %s %q, want only its own %s", f.t2, h.ID, h.Title, f.doc2)
		}
	}
	if _, err := f.pg.DocHeadOf(ctx, f.t2, f.docSys); !errors.Is(err, ErrDocNotFound) {
		t.Errorf("DocHeadOf(%s, system doc) = %v, want ErrDocNotFound", f.t2, err)
	}
	hits, err := f.pg.DocSearch(ctx, f.t2, "", "zebrafinch", 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hits {
		if h.DocID != f.doc2 {
			t.Errorf("DocSearch(%s) hit doc %s, want only %s", f.t2, h.DocID, f.doc2)
		}
	}
	if len(hits) == 0 {
		t.Errorf("DocSearch(%s) found nothing in its own doc", f.t2)
	}
	if _, err := f.pg.DocRename(ctx, f.t2, f.docSys, 0, "taken", "t"); err == nil {
		t.Errorf("DocRename(%s, system doc) committed", f.t2)
	}
	if _, err := f.pg.DocItemAdd(ctx, f.t2, DocItemAddReq{DocID: f.docSys, Where: DocChild, Title: "x", Actor: "t"}); err == nil {
		t.Errorf("DocItemAdd(%s, system doc) committed", f.t2)
	}
	// The system tenant's own scope (the read path of the hub's fs=repo)
	// lists it.
	sys, err := f.pg.DocList(ctx, SystemTenant, "", 1000)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(sys, func(h DocHead) bool { return h.ID == f.docSys }) {
		t.Errorf("DocList(system) misses %s", f.docSys)
	}

	ws, err := f.pg.ListWorkspaces(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(ws, func(w Workspace) bool { return w.ID == SystemTenant }) {
		t.Errorf("ListWorkspaces lists the system tenant")
	}
	if !slices.ContainsFunc(ws, func(w Workspace) bool { return w.ID == f.t1 }) {
		t.Errorf("ListWorkspaces misses %s", f.t1)
	}
	sweep, err := f.pg.hoursSweepTenants(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(sweep, SystemTenant) || !slices.Contains(sweep, f.t1) {
		t.Errorf("hours sweep tenants: system in=%v, %s in=%v", slices.Contains(sweep, SystemTenant), f.t1, slices.Contains(sweep, f.t1))
	}
	missing, err := f.pg.TenantsMissingPublicNotice(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(missing, SystemTenant) {
		t.Errorf("TenantsMissingPublicNotice lists the system tenant: the hub would post a notice into it")
	}
}

// TestDocACLEffect: rdb 0192's rule over the nested set. Tree:
// root > A > B > doc D, and A > doc C.
func TestDocACLEffect(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	a, err := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "a", Actor: "t"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: a, Name: "b", Actor: "t"})
	if err != nil {
		t.Fatal(err)
	}
	node := func(folder, title string) string {
		doc, _, err := pg.DocCreateIn(ctx, tid, folder, title, "", "t")
		if err != nil {
			t.Fatal(err)
		}
		var id string
		if err := pg.queryRowTenant(ctx, tid, `SELECT id::text FROM workspace_doc_node WHERE doc_id = $1`, []any{doc}, &id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	d, c := node(b, "d"), node(a, "c")
	grant := func(tenant, nodeID, subject, action, effect string) error {
		return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO workspace_doc_acl (tenant_id, node_id, subject, action, effect)
				VALUES ($1, $2, $3, $4, $5)`, tenant, nodeID, subject, action, effect)
			return err
		})
	}
	me := []string{"user:h1", "role:developer"}
	effect := func(tenant, nodeID string, subjects []string, action string) string {
		var e *string
		if err := pg.queryRowTenant(ctx, tenant, `SELECT workspace_doc_acl_effect($1, $2, $3, $4)`,
			[]any{tid, nodeID, subjects, action}, &e); err != nil {
			t.Fatal(err)
		}
		if e == nil {
			return "fallback"
		}
		return *e
	}
	check := func(step, nodeName, nodeID, action, want string) {
		t.Helper()
		if got := effect(tid, nodeID, me, action); got != want {
			t.Errorf("%s: %s %s = %s, want %s", step, nodeName, action, got, want)
		}
	}

	check("no grant", "D", d, "edit", "fallback")
	if err := grant(tid, a, "role:developer", "edit", "allow"); err != nil {
		t.Fatal(err)
	}
	check("allow on A", "A", a, "edit", "allow")
	check("allow on A, inherited", "D", d, "edit", "allow")
	check("allow on A, inherited", "C", c, "edit", "allow")
	check("allow on A, other action", "D", d, "read", "fallback")
	if got := effect(tid, d, []string{"user:h2"}, "edit"); got != "fallback" {
		t.Errorf("another subject: D edit = %s, want fallback", got)
	}
	if err := grant(tid, b, "user:h1", "edit", "deny"); err != nil {
		t.Fatal(err)
	}
	check("deny on B", "D", d, "edit", "deny")
	check("deny on B", "B", b, "edit", "deny")
	check("deny on B, not above it", "A", a, "edit", "allow")
	check("deny on B, not beside it", "C", c, "edit", "allow")
	if err := grant(tid, b, "user:h1", "edit", "allow"); err == nil {
		t.Errorf("a second grant of the same (node, subject, action) was accepted")
	}
	if err := grant(tid, d, "user:h1", "fly", "allow"); err == nil {
		t.Errorf("action fly was accepted")
	}
	if err := grant(tid, d, "nobody", "read", "allow"); err == nil {
		t.Errorf("subject 'nobody' was accepted")
	}

	// Another workspace neither reads nor writes these grants.
	other := newTenant(t, pg)
	if got := effect(other, d, me, "edit"); got != "fallback" {
		t.Errorf("workspace %s evaluates %s's grants: %s", other, tid, got)
	}
	if err := grant(other, d, "user:h1", "read", "allow"); err == nil {
		t.Errorf("workspace %s granted on %s's node", other, tid)
	}
	if err := pg.inTenant(ctx, other, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO workspace_doc_acl (tenant_id, node_id, subject, action)
			VALUES ($1, $2, 'user:h1', 'read')`, other, d)
		return err
	}); err == nil {
		t.Errorf("a grant of workspace %s on a node of %s passed the tenant FK", other, tid)
	}

	// A subtree delete drops its grants.
	if _, err := pg.DocFolderDelete(ctx, tid, b, true); err != nil {
		t.Fatal(err)
	}
	if n := countIn(t, pg, tid, `SELECT count(*) FROM workspace_doc_acl WHERE node_id = $1`, b); n != 0 {
		t.Errorf("folder B deleted, %d grants on it remain", n)
	}
	check("B gone", "A", a, "edit", "allow")
}
