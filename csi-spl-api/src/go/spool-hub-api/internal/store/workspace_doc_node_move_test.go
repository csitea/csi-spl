package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 120 section 5 "move" (gap topic t1 b67d5dc7: no route moved a
// document into a folder), on testkit Postgres (PRE_PUSH_TIER=full):
//
//	go test ./internal/store -run WorkspaceDocNodeMove -v
//
// After every move the workspace's bounds are 1..2n and each node's
// parent_id is its enclosing interval (spec 9 T1), checked here and again by
// the deferred workspace_doc_node_ns at commit.
// CONTROL: SPOOL_TEST_WSDOC_NODE_PLANT=movekeepparent shifts the bounds but
// keeps X's old parent_id; the commit check refuses it and the run goes red.

// nodeTreeCheck walks the workspace's bounds in order and returns its shape
// as "name(child, child)" from the root down, or the first broken bound.
func nodeTreeCheck(t *testing.T, pg *Postgres, tid string) string {
	t.Helper()
	type row struct {
		id, parent, label string
		lft, rgt          int
	}
	var rows []row
	err := pg.inTenant(context.Background(), tid, func(tx pgx.Tx) error {
		r, err := tx.Query(context.Background(), `SELECT n.id::text, coalesce(n.parent_id::text, ''),
				CASE n.kind WHEN 'root' THEN 'root' WHEN 'folder' THEN n.name ELSE 'doc:' || d.title END, n.lft, n.rgt
			FROM workspace_doc_node n LEFT JOIN workspace_doc d ON d.id = n.doc_id
			WHERE n.tenant_id = $1 ORDER BY n.lft`, tid)
		if err != nil {
			return err
		}
		rows, err = pgx.CollectRows(r, func(c pgx.CollectableRow) (row, error) {
			var x row
			return x, c.Scan(&x.id, &x.parent, &x.label, &x.lft, &x.rgt)
		})
		return err
	})
	if err != nil {
		t.Fatalf("read nodes: %v", err)
	}
	seen := map[int]bool{}
	for _, x := range rows {
		seen[x.lft], seen[x.rgt] = true, true
	}
	for b := 1; b <= 2*len(rows); b++ {
		if !seen[b] {
			t.Fatalf("bound %d missing of 1..%d", b, 2*len(rows))
		}
	}
	byID := map[string]row{}
	kids := map[string][]string{}
	for _, x := range rows {
		byID[x.id] = x
		if x.parent != "" {
			p := byID[x.parent]
			if !(p.lft < x.lft && x.rgt < p.rgt) {
				t.Fatalf("%s(%d,%d) is not inside its parent %s(%d,%d)", x.label, x.lft, x.rgt, p.label, p.lft, p.rgt)
			}
			kids[x.parent] = append(kids[x.parent], x.id)
		}
	}
	var shape func(id string) string
	shape = func(id string) string {
		var in []string
		for _, k := range kids[id] {
			in = append(in, shape(k))
		}
		if len(in) == 0 {
			return byID[id].label
		}
		return byID[id].label + "(" + strings.Join(in, " ") + ")"
	}
	return shape(rows[0].id)
}

// TestWorkspaceDocNodeMove: a document right and left, a folder with its
// children, back to the root, a no-op; the refusals carry their own errors.
func TestWorkspaceDocNodeMove(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	mk := func(parent, name string) string {
		t.Helper()
		id, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: parent, Name: name, Actor: "t"})
		if err != nil {
			t.Fatalf("folder %s: %v", name, err)
		}
		return id
	}
	docNode := func(parent, title string) string {
		t.Helper()
		if _, _, err := pg.DocCreateIn(ctx, tid, parent, title, "", "t"); err != nil {
			t.Fatalf("doc %s: %v", title, err)
		}
		_, ns, err := pg.DocNodes(ctx, tid, parent)
		for _, n := range ns {
			if n.Kind == "doc" && n.Title == title {
				return n.ID
			}
		}
		t.Fatalf("doc %s has no node in its listing: %v", title, err)
		return ""
	}
	sys := mk("", "sys")
	guide := docNode(sys, "install")
	ops := docNode("", "ops")
	arch := mk("", "arch")
	old := docNode(arch, "old")
	if got := nodeTreeCheck(t, pg, tid); got != "root(sys(doc:install) doc:ops arch(doc:old))" {
		t.Fatalf("start = %s", got)
	}
	steps := []struct {
		what, node, parent, want string
	}{
		{"a document left, into a folder before it (the gap)", ops, sys, "root(sys(doc:install doc:ops) arch(doc:old))"},
		{"a document right, into a folder after it", guide, arch, "root(sys(doc:ops) arch(doc:old doc:install))"},
		{"a folder with two documents, under another folder", arch, sys, "root(sys(doc:ops arch(doc:old doc:install)))"},
		{"that folder back to the root", arch, "", "root(sys(doc:ops) arch(doc:old doc:install))"},
		{"under its current parent: a no-op", old, arch, "root(sys(doc:ops) arch(doc:old doc:install))"},
	}
	for _, s := range steps {
		if err := pg.DocNodeMove(ctx, tid, s.node, s.parent); err != nil {
			t.Fatalf("%s: %v", s.what, err)
		}
		if got := nodeTreeCheck(t, pg, tid); got != s.want {
			t.Fatalf("%s: tree = %s, want %s", s.what, got, s.want)
		}
	}
	inner := mk(arch, "inner")
	mk(sys, "inner")
	root, _, _ := pg.DocNodes(ctx, tid, "")
	for _, c := range []struct {
		what string
		err  error
		want error
	}{
		{"into itself", pg.DocNodeMove(ctx, tid, arch, arch), ErrDocNodeMoveIntoSelf},
		{"into its own subtree", pg.DocNodeMove(ctx, tid, arch, inner), ErrDocNodeMoveIntoSelf},
		{"under a document", pg.DocNodeMove(ctx, tid, old, ops), ErrDocNodeParentDoc},
		{"a sibling folder of the same name", pg.DocNodeMove(ctx, tid, inner, sys), ErrDocFolderNameTaken},
		{"the root", pg.DocNodeMove(ctx, tid, root, sys), ErrDocRefused},
		{"no such node", pg.DocNodeMove(ctx, tid, "00000000-0000-0000-0000-000000000000", sys), ErrDocNodeNotFound},
		{"another workspace's node", pg.DocNodeMove(ctx, newTenant(t, pg), old, ""), ErrDocNodeNotFound},
	} {
		if !errors.Is(c.err, c.want) {
			t.Fatalf("%s: err = %v, want %v", c.what, c.err, c.want)
		}
	}
	t.Logf("5 moves, bounds 1..2n after each: %s; 7 refusals named", nodeTreeCheck(t, pg, tid))
}

// TestWorkspaceDocNodeMoveDepth: a folder whose subtree is 2 levels high
// does not fit under a folder at level 32, a leaf at level 31 does.
func TestWorkspaceDocNodeMoveDepth(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	parent, deep := "", ""
	for i := 1; i <= 31; i++ {
		id, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: parent, Name: fmt.Sprint("L", i)})
		if err != nil {
			t.Fatalf("level %d: %v", i, err)
		}
		parent, deep = id, id
	}
	tall, _ := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "tall"})
	if _, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: tall, Name: "child"}); err != nil {
		t.Fatal(err)
	}
	if err := pg.DocNodeMove(ctx, tid, tall, deep); !errors.Is(err, ErrDocNodeTooDeep) {
		t.Fatalf("a 2-high subtree under level 32: %v, want depth", err)
	}
	leaf, _ := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "leaf"})
	if err := pg.DocNodeMove(ctx, tid, leaf, deep); err != nil {
		t.Fatalf("a leaf to level 33 of the set (32 under the root): %v", err)
	}
	nodeTreeCheck(t, pg, tid)
}
