// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"testing"
)

// Spec 169 row T5c, case C3c: a Qto doc, its rows and its place in the tree.

func seedMoveDoc(t *testing.T, f mvFix, title string) string {
	t.Helper()
	doc, _, err := f.pg.DocCreate(context.Background(), f.src, title, "", f.both)
	if err != nil {
		t.Fatal(err)
	}
	mvExec(t, f.pg, `INSERT INTO workspace_doc_acl (tenant_id, node_id, subject, action)
		SELECT $1, id, 'role:tester', 'read' FROM workspace_doc_node WHERE tenant_id = $1 AND doc_id = $2::uuid`, f.src, doc)
	return doc
}

func (f mvFix) docRows(t *testing.T, table, pred, tn, doc string) int {
	t.Helper()
	return mvCount(t, f.pg, `SELECT count(*) FROM `+table+` WHERE tenant_id = $1 AND `+pred, tn, doc)
}

func TestApplyChannelMoveC3cDocs(t *testing.T) {
	f := seedMove(t)
	stayFirst := seedMoveDoc(t, f, "stays, left of the moved one")
	doc := seedMoveDoc(t, f, "moves")
	stayLast := seedMoveDoc(t, f, "stays, right of the moved one")
	revs := f.docRows(t, "workspace_doc_rev_log", "doc_id = $2::uuid", f.src, doc)
	items := f.docRows(t, "workspace_doc_item", "doc_id = $2::uuid", f.src, doc)
	if items == 0 {
		t.Fatal("seed: the doc has no items")
	}
	mvExec(t, f.pg, `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, qto_doc_id) VALUES ($1, 'csi-spl-doc/specs/001-x/spec.md', '', $2::uuid)`, f.src, doc)
	req := f.req()
	req.RuleDoc = doc
	res := f.apply(t, req)
	if len(res.Binds.Docs) != 1 || res.Binds.Docs[0] != doc {
		t.Fatalf("the set's docs %v", res.Binds.Docs)
	}
	for _, c := range []struct {
		table, pred string
		want        int
	}{
		{"workspace_doc", "id = $2::uuid", 1},
		{"workspace_doc_item", "doc_id = $2::uuid", items},
		{"workspace_doc_rev_log", "doc_id = $2::uuid", revs},
		{"workspace_doc_node", "doc_id = $2::uuid", 1},
		{"spec_sync_map", "qto_doc_id = $2::uuid", 1},
		{"workspace_doc_acl", "node_id IN (SELECT id FROM workspace_doc_node WHERE doc_id = $2::uuid)", 1},
	} {
		if n := f.docRows(t, c.table, c.pred, f.dst, doc); n != c.want {
			t.Errorf("%s in <DST>: %d, want %d", c.table, n, c.want)
		}
		if n := f.docRows(t, c.table, c.pred, f.src, doc); n != 0 {
			t.Errorf("%s in <SRC>: %d left", c.table, n)
		}
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM spec_sync_map WHERE tenant_id = $1`, f.src); n != 0 {
		t.Errorf("a spec link found only by its doc stayed in <SRC>, %d", n)
	}
	f.checkDocTrees(t, doc, stayFirst, stayLast)
	if c, ok := res.Copied["workspace_doc_rev_log"]; !ok || c != revs {
		t.Errorf("Copied rev log %d, want %d", c, revs)
	}
}

// checkDocTrees: <DST>'s doc sits under a folder named for the channel, and
// <SRC>'s tree closed around it: both commits passed the deferred nested-set
// check, and the root counters say so too.
func (f mvFix) checkDocTrees(t *testing.T, doc, stayFirst, stayLast string) {
	t.Helper()
	pg := f.pg
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_doc_node d JOIN workspace_doc_node p ON p.id = d.parent_id
		WHERE d.tenant_id = $1 AND d.doc_id = $2::uuid AND p.kind = 'folder' AND p.name = $3 AND p.lft < d.lft AND p.rgt > d.rgt`, f.dst, doc, f.ch); n != 1 {
		t.Error("the doc is not under the folder named for the channel")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'root' AND doc_count = 1 AND folder_count = 1`, f.dst); n != 1 {
		t.Error("<DST>'s root counters are wrong")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'root' AND doc_count = 2 AND rgt = 6`, f.src); n != 1 {
		t.Error("<SRC>'s root must hold two docs, with its gap closed")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1 AND doc_id = ANY($2::uuid[])`, f.src, []string{stayFirst, stayLast}); n != 2 {
		t.Error("<SRC>'s staying docs lost their nodes")
	}
}

// A second doc into a <DST> folder that already exists: reused, not a second one.
func TestApplyChannelMoveC3cFolderReused(t *testing.T) {
	f := seedMove(t)
	doc := seedMoveDoc(t, f, "moves")
	if _, err := f.pg.DocFolderCreate(context.Background(), f.dst, DocFolder{Name: f.ch, Actor: f.both}); err != nil {
		t.Fatal(err)
	}
	req := f.req()
	req.RuleDoc = doc
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM workspace_doc_node WHERE tenant_id = $1 AND kind = 'folder'`, f.dst); n != 1 {
		t.Errorf("%d folders in <DST>, want the one already there", n)
	}
}

// CONTROL of C3c: skip the rev log copy, and the cascade has lost it, so the
// <DST> count differs.
func TestApplyChannelMoveC3cControl(t *testing.T) {
	f := seedMove(t)
	doc := seedMoveDoc(t, f, "moves")
	revs := f.docRows(t, "workspace_doc_rev_log", "doc_id = $2::uuid", f.src, doc)
	if revs == 0 {
		t.Fatal("seed: no rev log rows, so the control proves nothing")
	}
	req := f.req()
	req.RuleDoc = doc
	req.skipCopy = map[string]bool{"workspace_doc_rev_log": true}
	f.apply(t, req)
	if n := f.docRows(t, "workspace_doc_rev_log", "doc_id = $2::uuid", f.dst, doc); n == revs {
		t.Fatalf("CONTROL: skipped, yet <DST> holds all %d", n)
	}
	if n := f.docRows(t, "workspace_doc_rev_log", "doc_id = $2::uuid", f.src, doc); n != 0 {
		t.Fatalf("CONTROL: <SRC> kept %d", n)
	}
}
