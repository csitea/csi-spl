package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
)

// Spec 113 T006 follow-up: DocRename and the typed items (code, image) on
// testkit Postgres. CONTROLS: SPOOL_TEST_WSDOC_KINDS_PLANT plants the old
// code's gap back; the run must then go red.
//   renamenobump  a rename that moves no doc rev   (TestWorkspaceDocRename)
//   attrsnocheck  attrs written unchecked          (TestWorkspaceDocTypedItems)
//   deletenorev   a doc delete without its rev check (TestWorkspaceDocDelete)

func wsKindsPG(t *testing.T) (*Postgres, string) {
	t.Helper()
	pg, tid := wsDocPG(t)
	switch p := os.Getenv("SPOOL_TEST_WSDOC_KINDS_PLANT"); p {
	case "":
		return pg, tid
	case "renamenobump":
		wsDocKindsPlant.renameNoBump = true
	case "attrsnocheck":
		wsDocKindsPlant.attrsNoCheck = true
	case "deletenorev":
		wsDocKindsPlant.deleteNoRev = true
	default:
		t.Fatalf("SPOOL_TEST_WSDOC_KINDS_PLANT=%q: want renamenobump, attrsnocheck or deletenorev", p)
	}
	t.Logf("CONTROL plant=%s is on: this run must go red", os.Getenv("SPOOL_TEST_WSDOC_KINDS_PLANT"))
	t.Cleanup(func() {
		wsDocKindsPlant.renameNoBump, wsDocKindsPlant.attrsNoCheck, wsDocKindsPlant.deleteNoRev = false, false, false
	})
	return pg, tid
}

// TestWorkspaceDocRename: a rename's four outcomes, the title read back, the
// default title for a cleared one, and the rev-log entry.
func TestWorkspaceDocRename(t *testing.T) {
	pg, tid := wsKindsPG(t)
	ctx := context.Background()
	doc, _, err := pg.DocCreate(ctx, tid, "first", "", "t")
	if err != nil {
		t.Fatal(err)
	}
	title := func() string {
		t.Helper()
		h, err := pg.DocHeadOf(ctx, tid, doc)
		if err != nil {
			t.Fatal(err)
		}
		return h.Title
	}
	r, err := pg.DocRename(ctx, tid, doc, 1, "  second  ", "t")
	if err != nil || r.Rev != 2 || title() != "second" {
		t.Fatalf("rename: rev %d title %q %v, want rev 2 and \"second\"", r.Rev, title(), err)
	}
	if _, err := pg.DocRename(ctx, tid, doc, 1, "stale", "t"); !errors.Is(err, ErrDocStale) {
		t.Fatalf("rename at a stale rev: %v, want 412 (title now %q)", err, title())
	}
	r, err = pg.DocRename(ctx, tid, doc, 2, " \t ", "t")
	if err != nil || r.Rev != 3 || title() != DocUntitled {
		t.Fatalf("clear the title: rev %d title %q %v, want rev 3 and %q", r.Rev, title(), err, DocUntitled)
	}
	if _, err := pg.DocRename(ctx, tid, doc, 3, strings.Repeat("x", DocTitleMax+1), "t"); !errors.Is(err, ErrDocRefused) {
		t.Fatalf("a 501-char title: %v, want refused", err)
	}
	if _, err := pg.DocRename(ctx, tid, uuid4(), 0, "x", "t"); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("an unknown doc: %v, want 404", err)
	}
	if _, err := pg.DocRename(ctx, newTenant(t, pg), doc, 0, "theirs", "x"); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("another tenant's rename: %v, want the lock's 404", err)
	}
	revs, ops, err := wsRevLog(ctx, pg, tid, doc)
	if err != nil || len(revs) != 3 || ops[1]["kind"] != "rename" || ops[1]["from"] != "first" || ops[2]["to"] != DocUntitled {
		t.Fatalf("rev log: %v %v %v", revs, ops, err)
	}
	if msg := wsCheck(ctx, pg, tid, doc); msg != "" || title() != DocUntitled {
		t.Fatalf("after the refusals: %s title %q", msg, title())
	}
	t.Logf("rename: revs %v, title %q, refused stale / too long / unknown / foreign", revs, title())
}

// TestWorkspaceDocDelete: a whole-document delete's outcomes. Another
// tenant's delete, a stale rev and an unknown doc are refused and leave the
// doc whole; the delete at its rev removes the doc, every item and the rev
// log, and leaves a second doc of the tenant untouched; again is a 404.
// CONTROL: SPOOL_TEST_WSDOC_KINDS_PLANT=deletenorev must turn it red.
func TestWorkspaceDocDelete(t *testing.T) {
	pg, tid := wsKindsPG(t)
	ctx := context.Background()
	mk := func(title string) (string, int64) {
		t.Helper()
		doc, root, err := pg.DocCreate(ctx, tid, title, "", "t")
		if err != nil {
			t.Fatal(err)
		}
		r, err := pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Rev: 1, Anchor: root, Where: DocChild, Title: "A", Actor: "t"})
		if err == nil {
			r, err = pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Rev: r.Rev, Anchor: r.ItemID, Where: DocChild, Title: "A.1", Actor: "t"})
		}
		if err != nil {
			t.Fatal(err)
		}
		return doc, r.Rev
	}
	rows := func(doc string) string {
		t.Helper()
		var docs, items, revs int
		if err := pg.queryRowTenant(ctx, tid, `SELECT (SELECT count(*) FROM workspace_doc WHERE id = $1),
			(SELECT count(*) FROM workspace_doc_item WHERE doc_id = $1),
			(SELECT count(*) FROM workspace_doc_rev_log WHERE doc_id = $1)`, []any{doc}, &docs, &items, &revs); err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("%d %d %d", docs, items, revs)
	}
	doc, rev := mk("gone")
	keep, _ := mk("kept")
	whole := rows(doc)
	if whole != "1 3 3" {
		t.Fatalf("fixture doc rows (doc items revlog) = %s, want 1 3 3", whole)
	}
	if _, err := pg.DocDelete(ctx, newTenant(t, pg), doc, 0); !errors.Is(err, ErrDocNotFound) || rows(doc) != whole {
		t.Fatalf("another tenant's delete: %v, rows %s, want 404 and the doc whole", err, rows(doc))
	}
	if _, err := pg.DocDelete(ctx, tid, doc, rev-1); !errors.Is(err, ErrDocStale) || rows(doc) != whole {
		t.Fatalf("a delete at a stale rev: %v, rows %s, want 412 and the doc whole", err, rows(doc))
	}
	for _, bad := range []string{uuid4(), "not-a-uuid"} {
		if _, err := pg.DocDelete(ctx, tid, bad, 0); !errors.Is(err, ErrDocNotFound) {
			t.Fatalf("delete %q: %v, want 404", bad, err)
		}
	}
	r, err := pg.DocDelete(ctx, tid, doc, rev)
	if err != nil || r.Rev != rev || rows(doc) != "0 0 0" {
		t.Fatalf("delete at rev %d: rev %d %v, rows %s, want 0 0 0", rev, r.Rev, err, rows(doc))
	}
	if _, err := pg.DocHeadOf(ctx, tid, doc); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("head after the delete: %v, want 404", err)
	}
	if msg := wsCheck(ctx, pg, tid, keep); msg != "" || rows(keep) != "1 3 3" {
		t.Fatalf("the other doc: %s rows %s, want clean and 1 3 3", msg, rows(keep))
	}
	if _, err := pg.DocDelete(ctx, tid, doc, 0); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("delete again: %v, want 404", err)
	}
	t.Logf("delete: refused foreign / stale / unknown with the doc whole (%s), deleted at rev %d -> 0 0 0, other doc %s", whole, rev, rows(keep))
}

// TestWorkspaceDocTypedItems: a code block and an image are added and edited
// with their attrs in the same op; a bad kind, a non-string key and an image
// src of another scheme are refused and write nothing.
func TestWorkspaceDocTypedItems(t *testing.T) {
	pg, tid := wsKindsPG(t)
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, "typed", "", "t")
	if err != nil {
		t.Fatal(err)
	}
	add := func(rev int64, attrs string) (DocOpResult, error) {
		return pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Rev: rev, Anchor: root, Where: DocChild,
			Title: "t", Attrs: attrs, Actor: "t"})
	}
	code, err := add(1, `{"kind":"code","src":"fmt.Println(1)","lang":"go"}`)
	img, err2 := add(code.Rev, `{"kind":"image","img_http_path":"`+DocImagePathPrefix+doc+`/images/a.png","img_name":"a"}`)
	plain, err3 := add(img.Rev, "")
	if err := errors.Join(err, err2, err3); err != nil || plain.Rev != 4 {
		t.Fatalf("adds: %v rev %d", err, plain.Rev)
	}
	bad := []string{`{"kind":"video"}`, `{"kind":"code","src":7}`, `[1]`, `{"img_http_path":"javascript:alert(1)"}`,
		`{"kind":"image","img_http_path":"data:image/png;base64,AA"}`, `{"kind":"image","img_http_path":"http://x/a.png"}`}
	refused := 0
	for _, a := range bad {
		if _, err := add(4, a); errors.Is(err, ErrDocRefused) {
			refused++
		} else {
			t.Errorf("add attrs %s: %v, want refused", a, err)
		}
		if _, err := pg.DocItemUpdateField(ctx, tid, doc, img.ItemID, "attrs", a, 1); !errors.Is(err, ErrDocRefused) {
			t.Errorf("edit attrs %s: %v, want refused", a, err)
		}
	}
	ir, err := pg.DocItemUpdateField(ctx, tid, doc, code.ItemID, "attrs", `{"kind":"code","src":"fmt.Println(2)","lang":"go"}`, 1)
	if err != nil || ir != 2 {
		t.Fatalf("edit the code: rev %d %v", ir, err)
	}
	items, err := pg.DocSubtree(ctx, tid, doc, "")
	if err != nil || len(items) != 4 {
		t.Fatalf("read back: %d items %v, want root + 3 (nothing from the refusals)", len(items), err)
	}
	got := map[string]map[string]any{}
	for _, it := range items {
		var m map[string]any
		_ = json.Unmarshal(it.Attrs, &m)
		got[it.ID] = m
	}
	if got[code.ItemID]["src"] != "fmt.Println(2)" || got[img.ItemID]["img_name"] != "a" || len(got[plain.ItemID]) != 0 {
		t.Fatalf("attrs read back: %v", got)
	}
	if rev, _ := wsDocRev(ctx, pg, tid, doc); rev != 4 || wsCheck(ctx, pg, tid, doc) != "" {
		t.Fatalf("doc rev %d after refusals, want 4 (%s)", rev, wsCheck(ctx, pg, tid, doc))
	}
	t.Logf("typed items: code + image added and edited, %d of %d bad attrs refused on add and on edit", refused, len(bad))
}
