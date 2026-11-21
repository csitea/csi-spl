package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// Spec 190 row D1 (rdb 0306, SPL-6152): the media index on testkit Postgres.
// Red on origin/master before rdb 0306: the table does not exist, so every
// call fails. Red control of the row: rdb 0306 without its ENABLE / FORCE
// ROW LEVEL SECURITY lines fails TestRLSCoversEveryTenantTable on
// workspace_doc_media (the commit body holds the run).
//
//	go test ./internal/store -run 'DocMedia' -v

const docMediaGrace = 7 * 24 * time.Hour

func mediaRow(doc string, fill byte, ext, kind string) DocMedia {
	return DocMedia{Doc: doc, SHA256: strings.Repeat(string(rune('a'+fill%6)), 64), Ext: ext, Kind: kind, Bytes: 10, Name: "clip." + ext, CreatedBy: "HUM-1"}
}

// mediaToken is the C6 token of m in its doc.
func mediaToken(m DocMedia) string {
	return "![clip](/v1/workspace/doctree/" + m.Doc + "/media/" + m.FileName() + ")"
}

func TestDocMediaPutNamed(t *testing.T) {
	pg, tid := wsDocPG(t)
	ctx := context.Background()
	doc, _, err := pg.DocCreate(ctx, tid, "media", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	v := mediaRow(doc, 0, "mp4", "video")
	got, created, err := pg.DocMediaPut(ctx, tid, v)
	if err != nil || !created || got.FileName() != v.FileName() || got.Kind != "video" || got.Name != "clip.mp4" {
		t.Fatalf("put: %+v created=%v err=%v", got, created, err)
	}
	again := v
	again.Ext, again.Name = "bin", "other.bin"
	if got, created, err = pg.DocMediaPut(ctx, tid, again); err != nil || created || got.Ext != "mp4" {
		t.Fatalf("the same bytes again: %+v created=%v err=%v, want the first row", got, created, err)
	}
	if m, err := pg.DocMediaNamed(ctx, tid, doc, v.FileName()); err != nil || m.Bytes != 10 {
		t.Fatalf("named: %+v %v", m, err)
	}
	for _, c := range []struct{ doc, name string }{
		{doc, v.SHA256 + ".webm"},               // indexed under another ext
		{doc, strings.Repeat("f", 64) + ".mp4"}, // not indexed
		{doc, "../x.mp4"},                       // not a name
		{"not-a-uuid", v.FileName()},
	} {
		if _, err := pg.DocMediaNamed(ctx, tid, c.doc, c.name); !errors.Is(err, ErrDocNotFound) {
			t.Fatalf("named(%s, %s): %v, want ErrDocNotFound", c.doc, c.name, err)
		}
	}
	other := newTenant(t, pg)
	if _, err := pg.DocMediaNamed(ctx, other, doc, v.FileName()); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("another workspace reads the row: %v", err)
	}
	if _, _, err := pg.DocMediaPut(ctx, other, v); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("another workspace indexes into this doc: %v, want ErrDocNotFound", err)
	}
	if _, _, err := pg.DocMediaPut(ctx, tid, mediaRow(uuidV4ForTest(), 1, "mp3", "audio")); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("put under a doc that does not exist: %v, want ErrDocNotFound", err)
	}
	t.Logf("put, the same bytes again keep the first row, named, 4 refusals, another workspace 404 both ways")
}

// TestDocMediaHumanLock: a locked doc's row is visible to its human only
// (spec 190 row D1 done test; rdb 0306 human_lock), and the sweep, which
// carries no human, neither marks nor drops it.
func TestDocMediaHumanLock(t *testing.T) {
	pg, tid := wsDocPG(t)
	ctx := context.Background()
	mine := WithHuman(ctx, "HUM-71")
	doc, _, err := pg.DocCreateRestricted(mine, tid, "", "locked", "", "HUM-71")
	if err != nil {
		t.Fatal(err)
	}
	v := mediaRow(doc, 2, "mp3", "audio")
	if _, _, err := pg.DocMediaPut(ctx, tid, v); !errors.Is(err, ErrDocNotFound) {
		t.Fatalf("an unmarked reader indexes into a locked doc: %v", err)
	}
	if _, _, err := pg.DocMediaPut(mine, tid, v); err != nil {
		t.Fatalf("the doc's human indexes: %v", err)
	}
	if _, err := pg.DocMediaNamed(mine, tid, doc, v.FileName()); err != nil {
		t.Fatalf("the doc's human reads the row: %v", err)
	}
	for _, c := range []context.Context{ctx, WithHuman(ctx, "HUM-72")} {
		if _, err := pg.DocMediaNamed(c, tid, doc, v.FileName()); !errors.Is(err, ErrDocNotFound) {
			t.Fatalf("human %q reads a locked doc's media row: %v", HumanOf(c), err)
		}
	}
	h, err := pg.DocMediaHold(ctx, tid, doc, v.FileName())
	if err != nil || !h.Hidden() {
		t.Fatalf("hold of a locked doc's object for the sweep: %+v %v, want hidden", h, err)
	}
	later := time.Now().Add(2 * docMediaGrace)
	for _, at := range []time.Time{time.Now(), later} {
		if gone, err := pg.DocMediaSweep(ctx, tid, at, docMediaGrace); err != nil || len(gone) != 0 {
			t.Fatalf("sweep at %v dropped a locked doc's row: %v %v", at, gone, err)
		}
	}
	if _, err := pg.DocMediaNamed(mine, tid, doc, v.FileName()); err != nil {
		t.Fatalf("the locked doc's row is gone after the sweep: %v", err)
	}
	t.Logf("locked doc: its human indexes and reads, an unmarked reader and HUM-72 get 404, the sweep sees it hidden and keeps it")
}

// TestDocMediaSweepGrace: a row no body names is marked, dropped only after
// the grace, kept while named; a deleted doc is recorded gone.
func TestDocMediaSweepGrace(t *testing.T) {
	pg, tid := wsDocPG(t)
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, "media", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	named, loose := mediaRow(doc, 3, "webm", "video"), mediaRow(doc, 4, "pdf", "file")
	for _, m := range []DocMedia{named, loose} {
		if _, _, err := pg.DocMediaPut(ctx, tid, m); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Anchor: root, Where: DocChild, Title: "s",
		Body: "see " + mediaToken(named), Actor: "HUM-1"}); err != nil {
		t.Fatal(err)
	}
	t0 := time.Now()
	sweep := func(at time.Time) []DocMedia {
		t.Helper()
		gone, err := pg.DocMediaSweep(ctx, tid, at, docMediaGrace)
		if err != nil {
			t.Fatal(err)
		}
		return gone
	}
	if g := sweep(t0); len(g) != 0 {
		t.Fatalf("first pass dropped %v: it only marks", g)
	}
	if g := sweep(t0.Add(docMediaGrace - time.Second)); len(g) != 0 {
		t.Fatalf("dropped before the grace: %v", g)
	}
	g := sweep(t0.Add(docMediaGrace + time.Second))
	if len(g) != 1 || g[0].FileName() != loose.FileName() {
		t.Fatalf("after the grace: dropped %v, want only the unnamed %s", g, loose.FileName())
	}
	if _, err := pg.DocMediaNamed(ctx, tid, doc, named.FileName()); err != nil {
		t.Fatalf("CONTROL: the named row is gone: %v", err)
	}
	if h, err := pg.DocMediaHold(ctx, tid, doc, named.FileName()); err != nil || !h.Live || !h.Index || !h.Named {
		t.Fatalf("hold of the named object: %+v %v", h, err)
	}
	if _, err := pg.DocDelete(ctx, tid, doc, 0); err != nil {
		t.Fatal(err)
	}
	ids, err := pg.DocGoneBefore(ctx, tid, time.Now().Add(time.Minute), 10)
	if err != nil || len(ids) != 1 || ids[0] != doc {
		t.Fatalf("gone after the delete: %v %v, want [%s]", ids, err, doc)
	}
	if ids, _ := pg.DocGoneBefore(ctx, tid, t0.Add(-time.Hour), 10); len(ids) != 0 {
		t.Fatalf("gone before the delete happened: %v", ids)
	}
	if h, err := pg.DocMediaHold(ctx, tid, doc, named.FileName()); err != nil || !h.Gone || h.Live || h.Hidden() {
		t.Fatalf("hold after the delete: %+v %v, want gone", h, err)
	}
	if err := pg.DocGoneDrop(ctx, tid, doc); err != nil {
		t.Fatal(err)
	}
	if ids, _ := pg.DocGoneBefore(ctx, tid, time.Now().Add(time.Minute), 10); len(ids) != 0 {
		t.Fatalf("gone row kept after the drop: %v", ids)
	}
	t.Logf("sweep: mark at t0, nothing at grace-1s, the unnamed row at grace+1s, the named one kept; delete -> gone row -> dropped")
}

func uuidV4ForTest() string { return "6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b" }
