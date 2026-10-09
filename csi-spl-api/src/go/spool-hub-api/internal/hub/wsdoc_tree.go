package hub

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Workspace documents, the outline and grid views over one tree (spec 113
// T004, sections 3.3 and 6): the hub API over T002's store ops (rdb 0157).
// It ports the sibling project's doc-view, grid and hierarchy controllers;
// every structural write is one of T002's ops, so no route can break the tree.
//
//	GET    /v1/workspace/doctree                  the documents (?topic= linked to one topic)
//	POST   /v1/workspace/doctree                  create {title}
//	GET    /v1/workspace/doctree/search           ?q= [&doc=]: items matching q (spec 100's words)
//	GET    /v1/workspace/doctree/{doc}            one document's head: rev, items, root, topic
//	PATCH  /v1/workspace/doctree/{doc}            rename {title, rev} ("" = "Untitled document")
//	GET    /v1/workspace/doctree/{doc}/children   ?parent= (none = top level): the lazy unit
//	GET    /v1/workspace/doctree/{doc}/subtree    ?item= (none = whole doc): print branch
//	GET    /v1/workspace/doctree/{doc}/grid       ?q= &sort= &desc=1: the whole doc, filtered and sorted
//	POST   /v1/workspace/doctree/{doc}/items      add {rev, anchor, where, ord, title, body, attrs}
//	POST   /v1/workspace/doctree/{doc}/items/{item}/move   {rev, parent, ord}
//	DELETE /v1/workspace/doctree/{doc}/items/{item}        ?rev= : delete the subtree
//	PATCH  /v1/workspace/doctree/{doc}/items/{item}        {field, value, rev}: a text edit
//	PUT    /v1/workspace/doctree/{doc}/topic      {topic_id} ("" unlinks): the discussion topic
//	POST   /v1/workspace/doctree/{doc}/images     an image's bytes: its img_http_path (wsdoc_media.go)
//	GET    /v1/workspace/doctree/{doc}/images/{name}  one uploaded image
//
// A code block or an image is an item whose attrs carry kind "code" (src,
// lang) or "image" (img_http_path, img_name); the store checks them on every
// write (store.docAttrsCheck).
//
// The four outcomes (spec 3.3): committed (200 with the rev it produced), 412
// stale_rev (the doc rev on a structural op, the item rev on a text edit),
// 404 not_found (gone, or another tenant's: RLS reads it as 0 rows) and 422
// refused (a move into its own subtree, a delete of the root, a field off
// the list). A whole-document read (the grid, a whole subtree) is served up
// to DocTreeMaxItems items and answers 413 above it (spec 2.1, 6).
//
// Who: a signed-in member whose role grants docs.read / docs.write, or an
// agent (a box upload token), as the 075 workspace docs. The tenant is the
// caller's verified one, never the request's. A store without these ops (the
// memory store) answers 404 workspace_doc_tree_off.

// DocTreeMaxItems is the whole-document read limit (spec 113 section 2.1).
const DocTreeMaxItems = 20000

const (
	docTreeMaxBody  = 2 << 20 // one item's body is <= 1,000,000 chars (rdb 0157)
	docTreeListMax  = 200
	docTreeHitsMax  = 100
	docTreeTitleMax = 1000
	docTreeBodyMax  = 1000000
	docTreeDocTitle = 500
	docTreeQueryMax = 200
)

// docTreeStore is the store side: T002's ops plus the reads of wsdoc_hub.go.
type docTreeStore interface {
	DocCreate(ctx context.Context, tenant, title, actor string) (string, string, error)
	DocRename(ctx context.Context, tenant, doc string, rev int64, title, actor string) (store.DocOpResult, error)
	DocItemAdd(ctx context.Context, tenant string, r store.DocItemAddReq) (store.DocOpResult, error)
	DocItemMove(ctx context.Context, tenant string, r store.DocItemMoveReq) (store.DocOpResult, error)
	DocItemDeleteSubtree(ctx context.Context, tenant, doc string, rev int64, item, actor string) (store.DocOpResult, error)
	DocItemUpdateField(ctx context.Context, tenant, doc, item, field, value string, rev int64) (int64, error)
	DocSubtree(ctx context.Context, tenant, doc, item string) ([]store.DocItem, error)
	DocChildren(ctx context.Context, tenant, doc, parent string) (store.DocChildrenResult, error)
	DocList(ctx context.Context, tenant, topic string, limit int) ([]store.DocHead, error)
	DocHeadOf(ctx context.Context, tenant, doc string) (store.DocHead, error)
	DocSearch(ctx context.Context, tenant, doc, q string, limit int) ([]store.DocHit, error)
}

var _ docTreeStore = (*store.Postgres)(nil)

func (s *Server) routeDocTree(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/workspace/doctree", s.handleDocTreeList)
	mux.HandleFunc("POST /v1/workspace/doctree", s.handleDocTreeCreate)
	mux.HandleFunc("GET /v1/workspace/doctree/search", s.handleDocTreeSearch)
	mux.HandleFunc("GET /v1/workspace/doctree/{doc}", s.handleDocTreeHead)
	mux.HandleFunc("PATCH /v1/workspace/doctree/{doc}", s.handleDocTreeRename)
	mux.HandleFunc("GET /v1/workspace/doctree/{doc}/children", s.handleDocTreeChildren)
	mux.HandleFunc("GET /v1/workspace/doctree/{doc}/subtree", s.handleDocTreeSubtree)
	mux.HandleFunc("GET /v1/workspace/doctree/{doc}/grid", s.handleDocTreeGrid)
	mux.HandleFunc("POST /v1/workspace/doctree/{doc}/items", s.handleDocTreeAdd)
	mux.HandleFunc("POST /v1/workspace/doctree/{doc}/items/{item}/move", s.handleDocTreeMove)
	mux.HandleFunc("DELETE /v1/workspace/doctree/{doc}/items/{item}", s.handleDocTreeDelete)
	mux.HandleFunc("PATCH /v1/workspace/doctree/{doc}/items/{item}", s.handleDocTreeEdit)
	mux.HandleFunc("PUT /v1/workspace/doctree/{doc}/topic", s.handleDocTreeTopic)
	mux.HandleFunc("POST /v1/workspace/doctree/{doc}/images", s.handleDocTreeImagePut)
	mux.HandleFunc("GET /v1/workspace/doctree/{doc}/images/{name}", s.handleDocTreeImageGet)
	mux.HandleFunc("OPTIONS /v1/workspace/doctree", s.docTreePreflight)
	mux.HandleFunc("OPTIONS /v1/workspace/doctree/{rest...}", s.docTreePreflight)
}

func (s *Server) docTreePreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// docTreeCall is one resolved caller: tenant, who (member or box id) and
// the store.
type docTreeCall struct {
	tenant string
	who    string
	st     docTreeStore
}

// docTreeCaller resolves the caller as docsCaller does (an agent token, or a
// member holding perm), then the DB store, or writes the refusal. Who comes
// first: a demo visitor gets its 403 whatever the store.
func (s *Server) docTreeCaller(w http.ResponseWriter, r *http.Request, perm string) (docTreeCall, bool) {
	s.allowOrigin(w, r)
	tenant, who, ok := s.docTreeWho(w, r, perm)
	if !ok {
		return docTreeCall{}, false
	}
	st, on := s.o.Store.(docTreeStore)
	if !on {
		writeErr(w, http.StatusNotFound, "workspace_doc_tree_off", "this hub's store has no workspace documents")
		return docTreeCall{}, false
	}
	return docTreeCall{tenant: tenant, who: who, st: st}, true
}

// docTreeWho is the caller's verified tenant and id (a box, or a member).
func (s *Server) docTreeWho(w http.ResponseWriter, r *http.Request, perm string) (string, string, bool) {
	if _, box, _, ok := s.bearerAny(r); ok && box != WUIBox {
		t, _, ok := s.tokenTenant(w, r)
		if !ok {
			return "", "", false
		}
		if !agentDocs(perm) {
			writeForbidden(w, perm, "agents are not granted "+perm)
			return "", "", false
		}
		return t.ID, box, true
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return "", "", false
	}
	if hum == "" {
		writeForbidden(w, perm, "workspace documents need a signed-in member session or an agent token")
		return "", "", false
	}
	if !s.permit(w, r, t.ID, hum, perm) {
		return "", "", false
	}
	return t.ID, hum, true
}

// docTreeFail answers err as its outcome: 412, 404, 422, else 500.
func docTreeFail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrDocStale):
		writeErr(w, http.StatusPreconditionFailed, "stale_rev", "the document changed since you read it: reload")
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such document or item")
	case errors.Is(err, store.ErrDocRefused):
		writeErr(w, http.StatusUnprocessableEntity, "refused", err.Error())
	default:
		writeErrCause(w, http.StatusInternalServerError, "internal", "workspace document store failed", err)
	}
}

// docTreeItem is one item on the wire. Outline is derived (1 / 1.1 / 1.1.1),
// never stored; the hidden root has "".
type docTreeItem struct {
	ID      string          `json:"id"`
	Parent  string          `json:"parent"`
	Ord     int             `json:"ord"`
	Outline string          `json:"outline"`
	Depth   int             `json:"depth"`
	Title   string          `json:"title"`
	Body    string          `json:"body"`
	Attrs   json.RawMessage `json:"attrs"`
	Rev     int64           `json:"rev"`
}

func docTreeItems(in []store.DocItem) []docTreeItem {
	out := make([]docTreeItem, 0, len(in))
	for _, it := range in {
		attrs := it.Attrs
		if len(attrs) == 0 {
			attrs = json.RawMessage("{}")
		}
		out = append(out, docTreeItem{ID: it.ID, Parent: it.ParentID, Ord: it.Ord, Outline: it.Outline,
			Depth: it.Depth, Title: it.Title, Body: it.Body, Attrs: attrs, Rev: it.Rev})
	}
	return out
}

// docTreeHead is one document on the wire.
type docTreeHead struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Rev       int64  `json:"rev"`
	Items     int    `json:"items"` // the visible items: the hidden root is not counted
	Root      string `json:"root"`
	TopicID   string `json:"topic_id"`
	UpdatedAt string `json:"updated_at"`
}

func docTreeHeadOf(h store.DocHead) docTreeHead {
	return docTreeHead{ID: h.ID, Title: h.Title, Rev: h.Rev, Items: max(h.Items-1, 0), Root: h.RootID,
		TopicID: h.TopicID, UpdatedAt: h.UpdatedAt.UTC().Format("2006-01-02T15:04:05.000Z")}
}

var docTreeUUIDRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (s *Server) handleDocTreeList(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	topic := strings.TrimSpace(r.URL.Query().Get("topic"))
	if topic != "" && !docTreeUUIDRe.MatchString(topic) {
		writeErr(w, http.StatusBadRequest, "bad_query", "topic is a topic id")
		return
	}
	hs, err := c.st.DocList(r.Context(), c.tenant, topic, docTreeListMax)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	out := make([]docTreeHead, 0, len(hs))
	for _, h := range hs {
		out = append(out, docTreeHeadOf(h))
	}
	writeJSON(w, http.StatusOK, map[string]any{"docs": out})
}

func (s *Server) handleDocTreeCreate(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Title string `json:"title"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only title)") {
		return
	}
	in.Title = store.DocTitle(in.Title)
	if utf8.RuneCountInString(in.Title) > docTreeDocTitle {
		writeErr(w, http.StatusBadRequest, "bad_request", "title is at most 500 characters")
		return
	}
	doc, root, err := c.st.DocCreate(r.Context(), c.tenant, in.Title, c.who)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": doc, "root": root, "rev": 1})
}

// handleDocTreeRename renames the document under the doc lock: rev is the
// doc rev read (0 = none), "" or blanks give store.DocUntitled.
func (s *Server) handleDocTreeRename(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Title string `json:"title"`
		Rev   int64  `json:"rev"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only title, rev)") {
		return
	}
	title := store.DocTitle(in.Title)
	if utf8.RuneCountInString(title) > docTreeDocTitle {
		writeErr(w, http.StatusBadRequest, "bad_request", "title is at most 500 characters")
		return
	}
	res, err := c.st.DocRename(r.Context(), c.tenant, r.PathValue("doc"), in.Rev, title, c.who)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"rev": res.Rev, "title": title})
}

func (s *Server) handleDocTreeHead(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, r.PathValue("doc"))
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, docTreeHeadOf(h))
}

// handleDocTreeChildren is the lazy unit (spec 6): one node's children and
// its ancestors' ord path, never an offset page over the whole document. The
// doc rev is read first, so a write in between makes the next op a 412.
func (s *Server) handleDocTreeChildren(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	doc := r.PathValue("doc")
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, doc)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	parent := r.URL.Query().Get("parent")
	res, err := c.st.DocChildren(r.Context(), c.tenant, doc, parent)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	if parent == "" {
		parent = h.RootID
	}
	path := res.Path
	if path == nil {
		path = []int{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"doc": doc, "rev": h.Rev, "parent": parent,
		"path": path, "outline": outlineOfPath(path), "items": docTreeItems(res.Items)})
}

func outlineOfPath(p []int) string {
	parts := make([]string, len(p))
	for i, v := range p {
		parts[i] = strconv.Itoa(v)
	}
	return strings.Join(parts, ".")
}

func docTreeTooLarge(w http.ResponseWriter) {
	writeErr(w, http.StatusRequestEntityTooLarge, "doc_too_large",
		"more than 20000 items: open it by section (children, subtree of an item)")
}

// docTreeWhole reads item's subtree ("" = the whole document, without the
// hidden root) under the size gate, 413 above DocTreeMaxItems: a whole
// document is gated on its count before the read. ok false = answered.
func docTreeWhole(w http.ResponseWriter, r *http.Request, c docTreeCall, item string) (store.DocHead, []store.DocItem, bool) {
	doc := r.PathValue("doc")
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, doc)
	if err != nil {
		docTreeFail(w, err)
		return h, nil, false
	}
	if item == "" && h.Items-1 > DocTreeMaxItems {
		docTreeTooLarge(w)
		return h, nil, false
	}
	items, err := c.st.DocSubtree(r.Context(), c.tenant, doc, item)
	if err != nil {
		docTreeFail(w, err)
		return h, nil, false
	}
	if len(items) > DocTreeMaxItems+1 { // a section: its root plus 20,000 under it
		docTreeTooLarge(w)
		return h, nil, false
	}
	if item == "" && len(items) > 0 && items[0].ParentID == "" {
		items = items[1:]
	}
	return h, items, true
}

func (s *Server) handleDocTreeSubtree(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	h, items, ok := docTreeWhole(w, r, c, r.URL.Query().Get("item"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"doc": h.ID, "rev": h.Rev, "items": docTreeItems(items)})
}

// docTreeSortKeys are the grid's sort columns; "outline" (the default) is
// document order. attr:<key> sorts on one attrs value, as text.
var docTreeSortKeys = map[string]func(a, b *store.DocItem) int{
	"title": func(a, b *store.DocItem) int {
		return strings.Compare(strings.ToLower(a.Title), strings.ToLower(b.Title))
	},
	"body": func(a, b *store.DocItem) int {
		return strings.Compare(strings.ToLower(a.Body), strings.ToLower(b.Body))
	},
	"rev":   func(a, b *store.DocItem) int { return cmp.Compare(a.Rev, b.Rev) },
	"depth": func(a, b *store.DocItem) int { return a.Depth - b.Depth },
}

// docTreeAttr is one attrs value as text ("" when absent).
func docTreeAttr(it *store.DocItem, key string) string {
	var m map[string]any
	if json.Unmarshal(it.Attrs, &m) != nil {
		return ""
	}
	switch v := m[key].(type) {
	case nil:
		return ""
	case string:
		return v
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

// docTreeSorter is the comparison of sort, nil = document order, or false
// when sort names no column.
func docTreeSorter(sortKey string) (func(a, b *store.DocItem) int, bool) {
	if sortKey == "" || sortKey == "outline" {
		return nil, true
	}
	if key, ok := strings.CutPrefix(sortKey, "attr:"); ok && key != "" {
		return func(a, b *store.DocItem) int {
			return strings.Compare(docTreeAttr(a, key), docTreeAttr(b, key))
		}, true
	}
	f, ok := docTreeSortKeys[sortKey]
	return f, ok
}

// docTreeFilter keeps the items whose title, body or outline contains q
// (case-insensitive); the order is kept.
func docTreeFilter(items []store.DocItem, q string) []store.DocItem {
	q = strings.ToLower(strings.TrimSpace(q))
	if q == "" {
		return items
	}
	out := items[:0:0]
	for _, it := range items {
		if strings.Contains(strings.ToLower(it.Title), q) || strings.Contains(strings.ToLower(it.Body), q) ||
			strings.HasPrefix(it.Outline, q) {
			out = append(out, it)
		}
	}
	return out
}

// handleDocTreeGrid is the grid view: the whole document in document order
// (the outline), filtered by q and sorted by one column, ties kept in
// document order. 413 above DocTreeMaxItems.
func (s *Server) handleDocTreeGrid(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	v := r.URL.Query()
	less, ok := docTreeSorter(v.Get("sort"))
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_query", "sort is outline, title, body, rev, depth or attr:<key>")
		return
	}
	if utf8.RuneCountInString(v.Get("q")) > docTreeQueryMax {
		writeErr(w, http.StatusBadRequest, "bad_query", "q is at most 200 characters")
		return
	}
	h, items, ok := docTreeWhole(w, r, c, "")
	if !ok {
		return
	}
	items = docTreeFilter(items, v.Get("q"))
	desc := v.Get("desc") == "1"
	switch {
	case less != nil && desc:
		sort.SliceStable(items, func(i, j int) bool { return less(&items[j], &items[i]) < 0 })
	case less != nil:
		sort.SliceStable(items, func(i, j int) bool { return less(&items[i], &items[j]) < 0 })
	case desc:
		slices.Reverse(items)
	}
	writeJSON(w, http.StatusOK, map[string]any{"doc": h.ID, "rev": h.Rev, "total": len(items),
		"items": docTreeItems(items)})
}

func (s *Server) handleDocTreeSearch(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	v := r.URL.Query()
	q := strings.TrimSpace(v.Get("q"))
	if q == "" || utf8.RuneCountInString(q) > docTreeQueryMax {
		writeErr(w, http.StatusBadRequest, "bad_query", "q is 1..200 characters")
		return
	}
	hits, err := c.st.DocSearch(r.Context(), c.tenant, v.Get("doc"), q, docTreeHitsMax)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	out := make([]map[string]any, 0, len(hits))
	for _, h := range hits {
		out = append(out, map[string]any{"doc": h.DocID, "item": h.ItemID, "title": h.Title, "rank": h.Rank})
	}
	writeJSON(w, http.StatusOK, map[string]any{"hits": out})
}

// docTreeTextOK refuses a title or body over rdb 0157's limits (400, not a
// constraint error from the DB).
func docTreeTextOK(w http.ResponseWriter, title, body string) bool {
	if utf8.RuneCountInString(title) > docTreeTitleMax || utf8.RuneCountInString(body) > docTreeBodyMax {
		writeErr(w, http.StatusBadRequest, "bad_request", "title is at most 1000 characters, body at most 1000000")
		return false
	}
	return true
}

// docTreeRoot is the doc's root id when id is "" (the top level), else id.
func docTreeRoot(ctx context.Context, c docTreeCall, doc, id string) (string, error) {
	if id != "" {
		return id, nil
	}
	h, err := c.st.DocHeadOf(ctx, c.tenant, doc)
	return h.RootID, err
}

func (s *Server) handleDocTreeAdd(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Rev    int64           `json:"rev"`
		Anchor string          `json:"anchor"`
		Where  string          `json:"where"`
		Ord    int             `json:"ord"`
		Title  string          `json:"title"`
		Body   string          `json:"body"`
		Attrs  json.RawMessage `json:"attrs"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only rev, anchor, where, ord, title, body, attrs)") ||
		!docTreeTextOK(w, in.Title, in.Body) {
		return
	}
	doc := r.PathValue("doc")
	anchor, err := docTreeRoot(r.Context(), c, doc, in.Anchor)
	if err == nil {
		var res store.DocOpResult
		res, err = c.st.DocItemAdd(r.Context(), c.tenant, store.DocItemAddReq{DocID: doc, Rev: in.Rev, Anchor: anchor,
			Where: store.DocWhere(in.Where), Ord: in.Ord, Title: in.Title, Body: in.Body, Attrs: docTreeAttrsArg(in.Attrs), Actor: c.who})
		if err == nil {
			writeJSON(w, http.StatusOK, map[string]any{"rev": res.Rev, "item": res.ItemID})
			return
		}
	}
	docTreeFail(w, err)
}

// docTreeAttrsArg is the add's attrs as the store takes them: "" when absent
// or null, else the raw JSON (the store refuses anything but an object).
func docTreeAttrsArg(raw json.RawMessage) string {
	if t := strings.TrimSpace(string(raw)); t != "null" {
		return t
	}
	return ""
}

func (s *Server) handleDocTreeMove(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Rev    int64  `json:"rev"`
		Parent string `json:"parent"`
		Ord    int    `json:"ord"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only rev, parent, ord)") {
		return
	}
	doc := r.PathValue("doc")
	parent, err := docTreeRoot(r.Context(), c, doc, in.Parent)
	if err == nil {
		var res store.DocOpResult
		res, err = c.st.DocItemMove(r.Context(), c.tenant, store.DocItemMoveReq{DocID: doc, Rev: in.Rev,
			ItemID: r.PathValue("item"), Parent: parent, Ord: in.Ord, Actor: c.who})
		if err == nil {
			writeJSON(w, http.StatusOK, map[string]any{"rev": res.Rev, "item": res.ItemID})
			return
		}
	}
	docTreeFail(w, err)
}

func (s *Server) handleDocTreeDelete(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var rev int64
	if v := r.URL.Query().Get("rev"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			writeErr(w, http.StatusBadRequest, "bad_query", "rev is the doc rev you read")
			return
		}
		rev = n
	}
	res, err := c.st.DocItemDeleteSubtree(r.Context(), c.tenant, r.PathValue("doc"), rev, r.PathValue("item"), c.who)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"rev": res.Rev, "item": res.ItemID})
}

// handleDocTreeEdit is a text edit (one grid cell, a title, a body): the
// item rev is the precondition, the doc rev does not move.
func (s *Server) handleDocTreeEdit(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Field string `json:"field"`
		Value string `json:"value"`
		Rev   int64  `json:"rev"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only field, value, rev)") {
		return
	}
	if (in.Field == "title" && !docTreeTextOK(w, in.Value, "")) || (in.Field != "title" && !docTreeTextOK(w, "", in.Value)) {
		return
	}
	rev, err := c.st.DocItemUpdateField(r.Context(), c.tenant, r.PathValue("doc"), r.PathValue("item"), in.Field, in.Value, in.Rev)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"item_rev": rev})
}

// handleDocTreeTopic links the document to its discussion topic (spec 6,
// the 075 T015/T016 link): the topic id lives in the hidden root's
// attrs.topic_id, written by T002's text edit under the root's rev, so two
// concurrent links end as one 200 and one 412.
func (s *Server) handleDocTreeTopic(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		TopicID string `json:"topic_id"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only topic_id)") {
		return
	}
	if in.TopicID != "" && !docTreeUUIDRe.MatchString(in.TopicID) {
		writeErr(w, http.StatusBadRequest, "bad_request", "topic_id is a topic id, or \"\" to unlink")
		return
	}
	doc := r.PathValue("doc")
	h, err := c.st.DocHeadOf(r.Context(), c.tenant, doc)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	attrs := map[string]any{}
	_ = json.Unmarshal(h.RootAttrs, &attrs)
	if in.TopicID == "" {
		delete(attrs, "topic_id")
	} else {
		attrs["topic_id"] = in.TopicID
	}
	raw, _ := json.Marshal(attrs)
	if _, err := c.st.DocItemUpdateField(r.Context(), c.tenant, doc, h.RootID, "attrs", string(raw), h.RootRev); err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"doc": doc, "topic_id": in.TopicID})
}
