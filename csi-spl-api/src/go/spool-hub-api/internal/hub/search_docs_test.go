package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 100 section 14 (SPL-3337; owner HUM-10 t1 4e06a219: search must
// include the Qto documents) on testkit Postgres: GET /v1/view/search finds
// a document's words, by a plain search and by type:doc, and an edited
// section by its new words. A hit is only for a reader who may open the
// document: a member whose role grants docs.read, in its own workspace.
// CONTROLS: a member without docs.read gets no doc hit (drop the docs.read
// check in docSection and this test fails, commit body); another
// workspace's document with the same word never shows; no reader (the door
// off) gets no doc hit.
//
//	go test ./internal/hub -run SearchDocs -v   (SPOOL_TEST_PG_DSN)

// docsAuthz is the developer role for every member but deny, whose role
// lacks docs.read (a workspace that took it away, spec 152 role grants).
type docsAuthz struct{ deny string }

func (a docsAuthz) Access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	acc, err := rbac.Fixed(rbac.Developer).Access(ctx, hum, tenant)
	if err == nil && hum == a.deny {
		delete(acc.Perms, rbac.DocsRead)
	}
	return acc, err
}

func (a docsAuthz) Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return rbac.Fixed(rbac.Developer).Roles(ctx, tenant)
}

func TestSearchDocs(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = docsAuthz{deny: "HUM-9"}
		o.SessionID = func(r *http.Request, _ string) (string, error) { // search: X-Test-Human; call(): memberHeader
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return r.Header.Get("X-Test-Human"), nil
		}
	})
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		t.Skip("the doc section is Postgres only (SPOOL_TEST_PG_DSN)")
	}
	ctx := context.Background()
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	w := "zq" + strings.ReplaceAll(uuidV4()[:8], "-", "")
	seed := func(tn, title, body string) (string, string, string) {
		t.Helper()
		doc, root, err := pg.DocCreateIn(ctx, tn, "", title, "", "HUM-1")
		if err != nil {
			t.Fatal(err)
		}
		res, err := pg.DocItemAdd(ctx, tn, store.DocItemAddReq{DocID: doc, Anchor: root, Where: store.DocChild,
			Title: "Deploy steps", Body: body, Actor: "HUM-1"})
		if err != nil {
			t.Fatal(err)
		}
		return doc, root, res.ItemID
	}
	doc, root, item := seed(ta, "Runbook", "rotate the "+w+" keys")
	docB, _, _ := seed(tb, "Other", "the "+w+" keys of B")
	putMsg(t, e.st, ta, uuidV4(), "lobby", "HUM-1", "box-a", "CLE-07", "a message, no doc word", time.Now().UTC(), "")

	docs := func(q, who string) []map[string]any {
		t.Helper()
		code, _, r, _ := searchGet(t, e, ta, q, "", "X-Test-Human", who)
		if code != http.StatusOK {
			t.Fatalf("%q as %q: %d", q, who, code)
		}
		return r.Groups["docs"].Results
	}
	for _, q := range []string{w, "type:doc " + w, "type:qto " + w} {
		got := docs(q, "HUM-1")
		if len(got) != 1 || got[0]["doc_id"] != doc || got[0]["item_id"] != item || got[0]["top"] != false {
			t.Fatalf("%q: %v, want the section %s of %s", q, got, item, doc)
		}
		sn, _ := got[0]["snippet"].(map[string]any)
		if txt, _ := sn["text"].(string); !strings.Contains(txt, w) || len(sn["highlights"].([]any)) == 0 {
			t.Fatalf("%q: snippet %v does not mark %s", q, sn, w)
		}
		dt, _ := got[0]["doc_title"].(map[string]any)
		if dt["text"] != "Runbook" {
			t.Fatalf("%q: doc_title %v", q, dt)
		}
	}
	// the title finds the document itself: its root, marked top
	if got := docs("type:doc runbook", "HUM-1"); len(got) != 1 || got[0]["item_id"] != root || got[0]["top"] != true {
		t.Fatalf("the title: %v, want the root %s", got, root)
	}
	// CONTROL: another workspace's doc with the same word never shows
	for _, row := range docs(w, "HUM-1") {
		if row["doc_id"] == docB {
			t.Fatalf("tenant %s found tenant %s's doc %s", ta, tb, docB)
		}
	}
	// CONTROL: a member whose role lacks docs.read cannot open the doc, so
	// search shows no hit of it; no reader (the door off) none either
	if got := docs(w, "HUM-9"); len(got) != 0 {
		t.Fatalf("a member without docs.read found %v", got)
	}
	if got := docs(w, ""); len(got) != 0 {
		t.Fatalf("no reader found %v", got)
	}
	// an edit through the doctree route: found by the new word, not the old
	nw := w + "new"
	code, out := call(t, e, ta, http.MethodPatch, docTreeAPI+"/"+doc+"/items/"+item, "HUM-1",
		map[string]any{"field": "body", "value": "the " + nw + " text", "rev": 1})
	if code != http.StatusOK {
		t.Fatalf("edit: %d %v", code, out)
	}
	if got := docs(nw, "HUM-1"); len(got) != 1 || got[0]["item_id"] != item {
		t.Fatalf("the edited word %s: %v", nw, got)
	}
	if got := docs("rotate", "HUM-1"); len(got) != 0 {
		t.Fatalf("the old word still finds the edited section: %v", got)
	}
}
