package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 120 step 3 (owner t1 3b8891e0, + New folder): folders and documents
// as rdb 0165 nodes, on testkit Postgres (PRE_PUSH_TIER=full).
//
//	go test ./internal/store -run WorkspaceDocNodes -v
//
// CONTROL: SPOOL_TEST_WSDOC_NODE_PLANT=noshift appends a node without its
// shift; the commit check refuses it and the run must go red.

func wsNodesPG(t *testing.T) (*Postgres, string) {
	t.Helper()
	pg, tid := wsDocPG(t)
	var has bool
	if err := pg.queryRowTenant(context.Background(), tid, `SELECT to_regclass('workspace_doc_node') IS NOT NULL`, nil, &has); err != nil || !has {
		t.Skipf("no workspace_doc_node (rdb 0165) in this database: %v", err)
	}
	switch p := os.Getenv("SPOOL_TEST_WSDOC_NODE_PLANT"); p {
	case "":
	case "noshift":
		docNodePlant.noShift = true
		t.Logf("CONTROL plant=%s is on: this run must go red", p)
		t.Cleanup(func() { docNodePlant.noShift = false })
	default:
		t.Fatalf("SPOOL_TEST_WSDOC_NODE_PLANT=%q: want noshift", p)
	}
	return pg, tid
}

// nodeNames is "name/title (children)" of a listing, in its order.
func nodeNames(ns []DocNode) string {
	var out []string
	for _, n := range ns {
		label := n.Name
		if n.Kind == "doc" {
			label = "doc:" + n.Title
		}
		out = append(out, fmt.Sprintf("%s(%d)", label, n.Children))
	}
	return strings.Join(out, ", ")
}

// TestWorkspaceDocNodesCreateAndList: folders and documents land where they
// were created, listed folders first; a document made by an older hub (no
// node) still lists at the top; the refusals carry their own errors.
func TestWorkspaceDocNodesCreateAndList(t *testing.T) {
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
	doc := func(parent, title string) string {
		t.Helper()
		id, _, err := pg.DocCreateIn(ctx, tid, parent, title, "", "t")
		if err != nil {
			t.Fatalf("doc %s: %v", title, err)
		}
		return id
	}
	plans := mk("", "plans")
	doc("", "readme")
	archive := mk("", "Archive")
	mk(plans, "2026")
	doc(plans, "roadmap")
	// a document of an older hub: workspace_doc and its root item, no node
	err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `WITH d AS (INSERT INTO workspace_doc (tenant_id, title, rev) VALUES ($1, 'legacy', 1) RETURNING tenant_id, id)
			INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) SELECT tenant_id, id, NULL, 1 FROM d`, tid)
		return err
	})
	if err != nil {
		t.Fatalf("legacy doc: %v", err)
	}
	root, top, err := pg.DocNodes(ctx, tid, "")
	if err != nil || root == "" {
		t.Fatalf("root listing: root=%q %v", root, err)
	}
	if got := nodeNames(top); got != "Archive(0), plans(2), doc:legacy(0), doc:readme(0)" {
		t.Fatalf("root = %q", got)
	}
	_, in, err := pg.DocNodes(ctx, tid, plans)
	if got := nodeNames(in); err != nil || got != "2026(0), doc:roadmap(0)" {
		t.Fatalf("plans = %q %v", got, err)
	}
	var docNode string
	for _, n := range in {
		if n.Kind == "doc" {
			docNode = n.ID
		}
	}
	for _, c := range []struct {
		what string
		err  error
		want error
	}{
		{"same name, other case, same folder", errOf(pg.DocFolderCreate(ctx, tid, DocFolder{Name: "ARCHIVE"})), ErrDocFolderNameTaken},
		{"under a document", errOf(pg.DocFolderCreate(ctx, tid, DocFolder{Parent: docNode, Name: "x"})), ErrDocNodeParentDoc},
		{"a doc under a document", errOf3(pg.DocCreateIn(ctx, tid, docNode, "x", "", "t")), ErrDocNodeParentDoc},
		{"no such parent", errOf(pg.DocFolderCreate(ctx, tid, DocFolder{Parent: "00000000-0000-0000-0000-000000000000", Name: "x"})), ErrDocNodeNotFound},
		{"a blank name", errOf(pg.DocFolderCreate(ctx, tid, DocFolder{Name: "  "})), ErrDocRefused},
		{"list under a document", errOf3(pg.DocNodes(ctx, tid, docNode)), ErrDocNodeParentDoc},
	} {
		if !errors.Is(c.err, c.want) {
			t.Fatalf("%s: err = %v, want %v", c.what, c.err, c.want)
		}
	}
	if _, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: archive, Name: "plans"}); err != nil {
		t.Fatalf("the same name in another folder: %v", err)
	}
	t.Logf("root: %s; plans: %s; six refusals named", nodeNames(top), nodeNames(in))
}

// TestWorkspaceDocNodesCrossTenant: another workspace sees none of the
// nodes and cannot create into or list a folder of this one (RLS: 0 rows).
func TestWorkspaceDocNodesCrossTenant(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	f, err := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "mine"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := pg.DocCreateIn(ctx, tid, f, "inside", "", "t"); err != nil {
		t.Fatal(err)
	}
	other := newTenant(t, pg)
	_, top, err := pg.DocNodes(ctx, other, "")
	if err != nil || len(top) != 0 {
		t.Fatalf("other workspace root: %d rows %v, want 0", len(top), err)
	}
	for what, err := range map[string]error{
		"list":   errOf3(pg.DocNodes(ctx, other, f)),
		"folder": errOf(pg.DocFolderCreate(ctx, other, DocFolder{Parent: f, Name: "x"})),
		"doc":    errOf3(pg.DocCreateIn(ctx, other, f, "x", "", "t")),
	} {
		if !errors.Is(err, ErrDocNodeNotFound) {
			t.Fatalf("other workspace %s into ours: %v, want not found", what, err)
		}
	}
	_, own, _ := pg.DocNodes(ctx, tid, f)
	if len(own) != 1 {
		t.Fatalf("own folder lists %d rows, want 1 (control)", len(own))
	}
	t.Logf("cross-workspace: 0 rows, 3 writes/reads refused; own folder %d row", len(own))
}

// TestWorkspaceDocNodesDepth: 32 folder levels under the root fit, the 33rd
// is refused before the commit check would raise it.
func TestWorkspaceDocNodesDepth(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	parent := ""
	for i := 1; i <= 32; i++ {
		id, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: parent, Name: fmt.Sprint("L", i)})
		if err != nil {
			t.Fatalf("level %d: %v", i, err)
		}
		parent = id
	}
	if _, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: parent, Name: "L33"}); !errors.Is(err, ErrDocNodeTooDeep) {
		t.Fatalf("level 33: %v, want depth", err)
	}
}

func errOf[T any](_ T, err error) error { return err }

func errOf3[A, B any](_ A, _ B, err error) error { return err }
