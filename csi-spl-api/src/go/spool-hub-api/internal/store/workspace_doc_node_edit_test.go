package store

import (
	"context"
	"errors"
	"testing"
)

// Spec 120 section 5 "edit folder" and "delete folder" (the folder row's
// right-click menu, owner t1 ed2e3583 msg 407fc16f), on testkit Postgres
// (PRE_PUSH_TIER=full):
//
//	go test ./internal/store -run WorkspaceDocFolder -v
//
// After every delete the bounds are 1..2n and agree with parent_id
// (nodeTreeCheck), the root's counters equal the real counts, and a
// recursive delete leaves no row of its documents' items or rev logs.
// CONTROL: SPOOL_TEST_WSDOC_NODE_PLANT=delnogap deletes the subtree without
// closing its gap; the commit check refuses it and the run goes red.

// TestWorkspaceDocFolderEdit: a rename, a title, the refusals.
func TestWorkspaceDocFolderEdit(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	str := func(s string) *string { return &s }
	a, _ := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "plans"})
	if _, err := pg.DocFolderCreate(ctx, tid, DocFolder{Name: "notes"}); err != nil {
		t.Fatal(err)
	}
	if err := pg.DocFolderEdit(ctx, tid, a, DocFolderPatch{Name: str("  2026 plans "), Title: str("The plans")}); err != nil {
		t.Fatalf("rename: %v", err)
	}
	_, ns, _ := pg.DocNodes(ctx, tid, "")
	if got := nodeNames(ns); got != "2026 plans(0), notes(0)" || ns[0].Title != "The plans" {
		t.Fatalf("after the rename: %q, title %q", got, ns[0].Title)
	}
	_, _, _ = pg.DocCreateIn(ctx, tid, "", "a doc", "", "t")
	_, ns, _ = pg.DocNodes(ctx, tid, "")
	var doc string
	for _, n := range ns {
		if n.Kind == "doc" {
			doc = n.ID
		}
	}
	root, _, _ := pg.DocNodes(ctx, tid, "")
	for _, c := range []struct {
		what   string
		folder string
		p      DocFolderPatch
		want   error
	}{
		{"a sibling's name, other case", a, DocFolderPatch{Name: str("NOTES")}, ErrDocFolderNameTaken},
		{"an empty name", a, DocFolderPatch{Name: str("  ")}, ErrDocRefused},
		{"nothing to change", a, DocFolderPatch{}, ErrDocRefused},
		{"a document node", doc, DocFolderPatch{Name: str("x")}, ErrDocRefused},
		{"the root", root, DocFolderPatch{Name: str("x")}, ErrDocRefused},
		{"no such node", "00000000-0000-0000-0000-000000000000", DocFolderPatch{Name: str("x")}, ErrDocNodeNotFound},
		{"another workspace's folder", a, DocFolderPatch{Name: str("x")}, ErrDocNodeNotFound},
	} {
		tenant := tid
		if c.what == "another workspace's folder" {
			tenant = newTenant(t, pg)
		}
		if err := pg.DocFolderEdit(ctx, tenant, c.folder, c.p); !errors.Is(err, c.want) {
			t.Fatalf("%s: err = %v, want %v", c.what, err, c.want)
		}
	}
	t.Logf("renamed with a title; 7 refusals named")
}

// TestWorkspaceDocFolderDelete: an empty folder, a refused non-empty one
// with its counts, then the recursive delete of a subtree with nodes on
// both sides of it.
func TestWorkspaceDocFolderDelete(t *testing.T) {
	pg, tid := wsNodesPG(t)
	ctx := context.Background()
	mk := func(parent, name string) string {
		t.Helper()
		id, err := pg.DocFolderCreate(ctx, tid, DocFolder{Parent: parent, Name: name})
		if err != nil {
			t.Fatalf("folder %s: %v", name, err)
		}
		return id
	}
	doc := func(parent, title string) string {
		t.Helper()
		id, root, err := pg.DocCreateIn(ctx, tid, parent, title, "", "t")
		if err == nil {
			_, err = pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: id, Rev: 1, Anchor: root, Where: DocChild, Title: "A", Actor: "t"})
		}
		if err != nil {
			t.Fatalf("doc %s: %v", title, err)
		}
		return id
	}
	counts := func() (docs, folders, rows int) {
		t.Helper()
		if err := pg.queryRowTenant(ctx, tid, `SELECT doc_count, folder_count,
				(SELECT count(*) FROM workspace_doc_item WHERE tenant_id = $1)::integer
					+ (SELECT count(*) FROM workspace_doc_rev_log WHERE tenant_id = $1)::integer
			FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'root'`, []any{tid}, &docs, &folders, &rows); err != nil {
			t.Fatal(err)
		}
		return
	}
	doc("", "before")
	empty := mk("", "empty")
	arch := mk("", "arch")
	inner := mk(arch, "inner")
	gone1, gone2 := doc(arch, "old"), doc(inner, "older")
	doc("", "after")
	if got := nodeTreeCheck(t, pg, tid); got != "root(doc:before empty arch(inner(doc:older) doc:old) doc:after)" {
		t.Fatalf("start = %s", got)
	}
	if _, err := pg.DocFolderDelete(ctx, tid, empty, false); err != nil {
		t.Fatalf("empty folder: %v", err)
	}
	if got := nodeTreeCheck(t, pg, tid); got != "root(doc:before arch(inner(doc:older) doc:old) doc:after)" {
		t.Fatalf("after the empty delete: %s", got)
	}
	_, err := pg.DocFolderDelete(ctx, tid, arch, false)
	var ne *DocFolderNotEmptyError
	if !errors.As(err, &ne) || !errors.Is(err, ErrDocNodeConflict) || ne.Folders != 1 || ne.Documents != 2 {
		t.Fatalf("non-empty without recursive: %v %+v, want folder_not_empty {1 folder, 2 documents}", err, ne)
	}
	if _, err := pg.DocFolderDelete(ctx, newTenant(t, pg), arch, true); !errors.Is(err, ErrDocNodeNotFound) {
		t.Fatalf("another workspace's delete: %v, want not found", err)
	}
	docs0, folders0, rows0 := counts()
	got, err := pg.DocFolderDelete(ctx, tid, arch, true)
	if err != nil || got != (DocFolderDeleted{Folders: 2, Documents: 2}) {
		t.Fatalf("recursive: %+v %v, want 2 folders 2 documents", got, err)
	}
	if tree := nodeTreeCheck(t, pg, tid); tree != "root(doc:before doc:after)" {
		t.Fatalf("after the recursive delete: %s", tree)
	}
	docs1, folders1, rows1 := counts()
	if docs0-docs1 != 2 || folders0-folders1 != 2 || rows1 >= rows0 {
		t.Fatalf("counters %d/%d -> %d/%d, item+revlog rows %d -> %d", docs0, folders0, docs1, folders1, rows0, rows1)
	}
	for _, d := range []string{gone1, gone2} {
		if _, err := pg.DocHeadOf(ctx, tid, d); !errors.Is(err, ErrNotFound) {
			t.Fatalf("doc %s still reads: %v", d, err)
		}
	}
	t.Logf("empty, refused {1, 2}, recursive {2, 2}; bounds 1..2n after each; counters %d/%d", docs1, folders1)
}
