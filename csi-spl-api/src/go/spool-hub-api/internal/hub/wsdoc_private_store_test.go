package hub_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 114 section 9.4.1 (tasks R7): the catalogue of the workspace-doc
// write routes. Every mutating route under /v1/workspace/docs/ and
// /v1/workspace/doctree that the hub registers (read from its source, as
// TestDemoRouteWalk does) must have a step below; each step is driven for a
// non-system workspace against RECORDING shared stores (the 050 files store
// and the 051 docs store) and a recording resolver for the workspace's own
// store. The walk asserts 0 writes to either shared store, and every byte a
// blob route takes in that workspace's own store, none in another
// workspace's. A new write route with no step fails the catalogue, so it
// cannot reach a shared store unseen (an allow list proves absence, a ban
// list cannot). Red control: on the tree before R3 (a99ec608e~1) the asset
// PUT writes t/<tenant>/files/<sha256> to the 050 store and the walk fails.
//
//	go test ./internal/hub -run WorkspaceDocPrivateStore -v   (SPOOL_TEST_PG_DSN)

// recBlob is a store that records every write it takes: the op, the key
// and the bytes.
type recBlob struct {
	blob.Store
	mu     sync.Mutex
	writes []string
	bytes  int64
}

func (b *recBlob) note(op, key string, n int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.writes = append(b.writes, fmt.Sprintf("%s %s (%d bytes)", op, key, n))
	b.bytes += n
}

func (b *recBlob) Put(ctx context.Context, key string, data []byte) error {
	b.note("put", key, int64(len(data)))
	return b.Store.Put(ctx, key, data)
}

func (b *recBlob) PutReader(ctx context.Context, key string, r io.Reader) (int64, error) {
	n, err := b.Store.PutReader(ctx, key, r)
	b.note("put-reader", key, n)
	return n, err
}

func (b *recBlob) Promote(ctx context.Context, src, dst string) (bool, error) {
	b.note("promote", src+" -> "+dst, 0)
	return b.Store.Promote(ctx, src, dst)
}

func (b *recBlob) Delete(ctx context.Context, key string) error {
	b.note("delete", key, 0)
	return b.Store.Delete(ctx, key)
}

func (b *recBlob) Touch(ctx context.Context, key string) error {
	b.note("touch", key, 0)
	return b.Store.Touch(ctx, key)
}

// snapshot is the count of writes and the bytes so far, and the writes.
func (b *recBlob) snapshot() (int, int64, []string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.writes), b.bytes, append([]string(nil), b.writes...)
}

// recResolver is a workspace docs resolver over one local root whose every
// opened store records; own[tenant] is that tenant's store.
type recResolver struct {
	mu  sync.Mutex
	own map[string]*recBlob
}

// store is tid's recording store; one never opened has recorded nothing.
func (r *recResolver) store(tid string) *recBlob {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.own[tid] == nil {
		return &recBlob{}
	}
	return r.own[tid]
}

func recWsDocs(t *testing.T, root string) (*hub.WorkspaceDocs, *recResolver) {
	t.Helper()
	rr := &recResolver{own: map[string]*recBlob{}}
	d, err := hub.NewWorkspaceDocs(filepath.Join(root, "{tenant}"), func(_ context.Context, dir string) (blob.Store, error) {
		st := &recBlob{Store: blob.Dir{Root: dir}}
		rr.mu.Lock()
		rr.own[filepath.Base(dir)] = st
		rr.mu.Unlock()
		return st, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return d, rr
}

// wsDocWriteRoutes is every mutating workspace-doc route the hub registers.
func wsDocWriteRoutes(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, r := range mutatingRoutes(t) {
		if strings.Contains(r, " /v1/workspace/docs/") || strings.Contains(r, " /v1/workspace/doctree") {
			out = append(out, r)
		}
	}
	return out
}

// pvWalk is the state the catalogue's steps share.
type pvWalk struct {
	t                       *testing.T
	e                       *env
	tid, as                 string
	doc, folder, node, a, b string
	png                     []byte
}

func (w *pvWalk) docRev() int64 {
	return dtNum(mustCall(w.t, w.e, w.tid, http.MethodGet, docTreeAPI+"/"+w.doc, w.as, nil, 200), "rev")
}

// pvStep drives one route; blob = it must put bytes in the own store.
type pvStep struct {
	route string
	blob  bool
	run   func(w *pvWalk)
}

// pvSteps is the catalogue, in walk order: each step's route is the
// registered pattern it drives.
var pvSteps = []pvStep{
	{"POST /v1/workspace/doctree", false, func(w *pvWalk) {
		w.doc = dtStr(mustCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI, w.as, map[string]any{"title": "priv"}, 200), "id")
	}},
	{"POST /v1/workspace/doctree/folders", false, func(w *pvWalk) {
		w.folder = dtStr(mustCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI+"/folders", w.as, map[string]any{"name": "plans"}, 201), "id")
	}},
	{"PATCH /v1/workspace/doctree/folders/{folder}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPatch, docTreeAPI+"/folders/"+w.folder, w.as, map[string]any{"name": "plans2"}, 200)
	}},
	{"POST /v1/workspace/doctree/nodes/{node}/move", false, func(w *pvWalk) {
		for _, n := range dtList(mustCall(w.t, w.e, w.tid, http.MethodGet, docTreeAPI+"/nodes", w.as, nil, 200), "nodes") {
			if dtStr(n, "kind") == "doc" {
				w.node = dtStr(n, "id")
			}
		}
		mustCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI+"/nodes/"+w.node+"/move", w.as, map[string]any{"parent": w.folder}, 200)
	}},
	{"PATCH /v1/workspace/doctree/{doc}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPatch, docTreeAPI+"/"+w.doc, w.as, map[string]any{"title": "private", "rev": w.docRev()}, 200)
	}},
	{"POST /v1/workspace/doctree/{doc}/items", false, func(w *pvWalk) {
		add := func(title string) string {
			return dtStr(mustCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI+"/"+w.doc+"/items", w.as,
				map[string]any{"rev": w.docRev(), "anchor": "", "where": "child", "title": title, "body": "body " + title}, 200), "item")
		}
		w.a, w.b = add("A"), add("B")
	}},
	{"PATCH /v1/workspace/doctree/{doc}/items/{item}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPatch, docTreeAPI+"/"+w.doc+"/items/"+w.a, w.as, map[string]any{"field": "title", "value": "A2", "rev": 1}, 200)
	}},
	{"POST /v1/workspace/doctree/{doc}/items/{item}/move", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI+"/"+w.doc+"/items/"+w.a+"/move", w.as, map[string]any{"rev": w.docRev(), "parent": "", "ord": 2}, 200)
	}},
	{"PUT /v1/workspace/doctree/{doc}/topic", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPut, docTreeAPI+"/"+w.doc+"/topic", w.as, map[string]any{"topic_id": uuidV4()}, 200)
	}},
	{"POST /v1/workspace/doctree/{doc}/images", true, func(w *pvWalk) {
		if code, out, _ := rawCall(w.t, w.e, w.tid, http.MethodPost, docTreeAPI+"/"+w.doc+"/images", w.as, "image/png", w.png); code != 200 {
			w.t.Fatalf("image post: %d %s", code, out)
		}
	}},
	{"PUT /v1/workspace/doctree/{doc}/assets/{path...}", true, func(w *pvWalk) {
		if code, out, _ := rawCall(w.t, w.e, w.tid, http.MethodPut, docTreeAPI+"/"+w.doc+"/assets/priv.assets/01-a.png", w.as, "image/png", w.png); code != 200 {
			w.t.Fatalf("asset put: %d %s", code, out)
		}
	}},
	{"PUT /v1/workspace/doctree/{doc}/goal", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodPut, docTreeAPI+"/"+w.doc+"/goal", w.as, map[string]any{"goal": goalOf("G01-private", "", "start")}, 200)
	}},
	{"DELETE /v1/workspace/doctree/{doc}/items/{item}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodDelete, fmt.Sprintf("%s/%s/items/%s?rev=%d", docTreeAPI, w.doc, w.b, w.docRev()), w.as, nil, 200)
	}},
	{"DELETE /v1/workspace/doctree/{doc}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodDelete, fmt.Sprintf("%s/%s?rev=%d", docTreeAPI, w.doc, w.docRev()), w.as, nil, 200)
	}},
	{"DELETE /v1/workspace/doctree/folders/{folder}", false, func(w *pvWalk) {
		mustCall(w.t, w.e, w.tid, http.MethodDelete, docTreeAPI+"/folders/"+w.folder+"?recursive=1", w.as, nil, 200)
	}},
	{"PUT /v1/workspace/docs/{path...}", true, func(w *pvWalk) {
		if code, body := wsDoc(w.t, w.e, w.tid, http.MethodPut, "runbooks/private.md", w.as, "", "# private\n"); code != 200 {
			w.t.Fatalf("doc put: %d %s", code, body)
		}
	}},
	{"DELETE /v1/workspace/docs/{path...}", true, func(w *pvWalk) {
		if code, body := wsDoc(w.t, w.e, w.tid, http.MethodDelete, "runbooks/private.md", w.as, "", ""); code != 200 {
			w.t.Fatalf("doc delete: %d %s", code, body)
		}
	}},
}

// pvCatalogue fails on a registered write route with no step, or a step
// naming no registered route, and returns the routes.
func pvCatalogue(t *testing.T) []string {
	t.Helper()
	steps := map[string]bool{}
	for _, s := range pvSteps {
		steps[s.route] = true
	}
	routes := wsDocWriteRoutes(t)
	var missing, stale []string
	for _, r := range routes {
		if !steps[r] {
			missing = append(missing, r)
		}
		delete(steps, r)
	}
	for r := range steps {
		stale = append(stale, r)
	}
	sort.Strings(stale)
	if len(missing) > 0 || len(stale) > 0 {
		t.Fatalf("workspace-doc write routes with no step (add one: where does it write?): %v; steps naming no registered route: %v", missing, stale)
	}
	return routes
}

func TestWorkspaceDocPrivateStore(t *testing.T) {
	routes := pvCatalogue(t)
	files, docs := &recBlob{}, &recBlob{}
	d, own := recWsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) {
		files.Store, docs.Store = o.Blob, blob.Dir{Root: t.TempDir()}
		o.Blob, o.Docs, o.WorkspaceDocs = files, docs, d
	})
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	other, _ := e.tenant()
	w := &pvWalk{t: t, e: e, tid: tid, as: seat(t, e, tid, "developer"), png: pngOf(t, 99)}
	blobRoutes := 0
	for _, s := range pvSteps {
		_, before, _ := own.store(tid).snapshot()
		s.run(w)
		_, after, _ := own.store(tid).snapshot()
		if n, _, ws := files.snapshot(); n != 0 {
			t.Fatalf("%s: the shared files store (050) took %d writes: %v", s.route, n, ws)
		}
		if n, _, ws := docs.snapshot(); n != 0 {
			t.Fatalf("%s: the shared docs store (051) took %d writes: %v", s.route, n, ws)
		}
		if s.blob {
			blobRoutes++
			if after <= before {
				t.Fatalf("%s: the workspace's own store took 0 bytes, want the route's bytes there", s.route)
			}
		}
	}
	if n, _, _ := own.store(other).snapshot(); n != 0 {
		t.Fatalf("another workspace's own store took %d writes", n)
	}
	n, b, _ := own.store(tid).snapshot()
	t.Logf("catalogue: %d write routes walked; shared stores 050 + 051: 0 writes; own store: %d writes, %d bytes from %d blob routes; another workspace: 0",
		len(routes), n, b, blobRoutes)
}

// TestWorkspaceDocPrivateStoreCatalogue runs on every store (no Postgres
// needed): a write route added without a step fails here first.
func TestWorkspaceDocPrivateStoreCatalogue(t *testing.T) {
	routes := pvCatalogue(t)
	if len(routes) != len(pvSteps) {
		t.Fatalf("%d routes, %d steps", len(routes), len(pvSteps))
	}
	t.Logf("catalogue: %d workspace-doc write routes, each with a step", len(routes))
}
