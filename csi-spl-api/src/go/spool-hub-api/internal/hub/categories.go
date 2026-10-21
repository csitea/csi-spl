package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Activity categories (spec 143 sections 4.4, 4.5, rdb 0204, SPL-2790): the
// tree every member reads, the operator's edits of it, the token rollup by
// category, and the spawn placer's record of a request's category.
//
//	GET  /v1/reporting/categories          any member (topics.read): {categories: [categoryTreeNode]},
//	                                        the active nodes as a tree
//	POST /v1/operator/categories           the operator admin / service account (fleetLoadCaller):
//	                                        {category_path, title, description?, dimensions?, is_active?}
//	                                        -> 201 the node; its parent must exist
//	PUT  /v1/operator/categories/{path...} the same door: {title?, description?, dimensions?, is_active?},
//	                                        an absent field kept -> the node
//	GET  /v1/reporting/tokens/by-category?from=&to=&depth=
//	                                        the same door (owner poll 4 answer A: the token burn is
//	                                        the operator's) -> store.CategoryTokensResponse
//	ask frame, ask_op "category"           a box of the tenant: {ask_id, by, work_kind, category_path}
//	                                        on its spawn request (do_spl_spawn_place)

// categoryBodyMax bounds one node's body (a 500-character description and
// its dimensions).
const categoryBodyMax = 16 << 10

// categoryDepthMax is the deepest depth= a rollup takes.
const categoryDepthMax = 10

// categoryEdit is the fields a caller sets; the hub derives parent_path.
type categoryEdit struct {
	Path        string         `json:"category_path"`
	Title       string         `json:"title"`
	Description string         `json:"description"`
	Dimensions  map[string]any `json:"dimensions"`
	IsActive    *bool          `json:"is_active"`
}

// categoryTreeNode is one node of the members' tree read.
type categoryTreeNode struct {
	Path        string              `json:"category_path"`
	Title       string              `json:"title"`
	Description string              `json:"description"`
	Dimensions  map[string]any      `json:"dimensions"`
	Children    []*categoryTreeNode `json:"children"`
}

// askCategoryReq is an ask frame's Ask object for ask_op "category".
type askCategoryReq struct {
	AskID        string `json:"ask_id"`
	By           string `json:"by"`
	WorkKind     string `json:"work_kind"`
	CategoryPath string `json:"category_path"`
}

// AskCategoryRow is what a category op recorded, in its answer.
type AskCategoryRow struct {
	AskID        string `json:"ask_id"`
	WorkKind     string `json:"work_kind"`
	CategoryPath string `json:"category_path"`
}

func (s *Server) routeCategories(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/reporting/categories", s.handleCategoryTree)
	mux.HandleFunc("OPTIONS /v1/reporting/categories", s.preflight)
	mux.HandleFunc("POST /v1/operator/categories", s.handleCategoryCreate)
	mux.HandleFunc("PUT /v1/operator/categories/{path...}", s.handleCategoryUpdate)
	mux.HandleFunc("OPTIONS /v1/operator/categories", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/categories/{path...}", s.operatorWorkspacesPreflight)
	mux.HandleFunc("GET /v1/reporting/tokens/by-category", s.handleCategoryTokens)
	mux.HandleFunc("OPTIONS /v1/reporting/tokens/by-category", s.operatorWorkspacesPreflight)
}

// categoryStore is the store's CategoryStore; false = answered.
func (s *Server) categoryStore(w http.ResponseWriter) (store.CategoryStore, bool) {
	cs, ok := s.o.Store.(store.CategoryStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no activity categories")
	}
	return cs, ok
}

// GET /v1/reporting/categories
func (s *Server) handleCategoryTree(w http.ResponseWriter, r *http.Request) {
	if _, _, _, _, ok := s.membersActor(w, r, rbac.TopicsRead); !ok {
		return
	}
	cs, ok := s.categoryStore(w)
	if !ok {
		return
	}
	cats, err := cs.ListCategories(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("category tree")
		writeErr(w, http.StatusInternalServerError, "internal", "categories unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"categories": categoryTree(cats)})
}

// categoryTree nests the active nodes of cats (path order: a parent before
// its children); a node under an inactive one is left out with it.
func categoryTree(cats []store.Category) []*categoryTreeNode {
	roots, byPath := []*categoryTreeNode{}, map[string]*categoryTreeNode{}
	for _, c := range cats {
		if !c.IsActive {
			continue
		}
		n := &categoryTreeNode{Path: c.Path, Title: c.Title, Description: c.Description, Dimensions: c.Dimensions, Children: []*categoryTreeNode{}}
		switch p := byPath[c.ParentPath]; {
		case c.ParentPath == "":
			roots = append(roots, n)
		case p != nil:
			p.Children = append(p.Children, n)
		default:
			continue
		}
		byPath[c.Path] = n
	}
	return roots
}

// decodeCategory reads the body onto e (its absent fields keep e's values);
// false = answered.
func decodeCategory(w http.ResponseWriter, r *http.Request, e *categoryEdit) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, categoryBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(e)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {category_path, title, description, dimensions, is_active}: "+err.Error())
		return false
	}
	return true
}

func (e categoryEdit) category() store.Category {
	c := store.Category{Path: e.Path, ParentPath: store.CategoryParent(e.Path), Title: e.Title, Description: e.Description,
		Dimensions: e.Dimensions, IsActive: e.IsActive == nil || *e.IsActive}
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	return c
}

// POST /v1/operator/categories
func (s *Server) handleCategoryCreate(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	cs, ok := s.categoryStore(w)
	if !ok {
		return
	}
	var e categoryEdit
	if !decodeCategory(w, r, &e) {
		return
	}
	c := e.category()
	if why := store.CheckCategory(c); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_category", why)
		return
	}
	out, err := cs.CreateCategory(r.Context(), c)
	switch {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "category_exists", "category "+c.Path+" exists; change it with PUT")
		return
	case errors.Is(err, store.ErrUnknownCategory):
		writeErr(w, http.StatusBadRequest, "unknown_parent", "no category "+c.ParentPath+": add the parent first")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("category create")
		writeErr(w, http.StatusInternalServerError, "internal", "category not stored")
		return
	}
	s.o.Log.Info().Str("category", out.Path).Str("by", who).Msg("category created")
	writeJSON(w, http.StatusCreated, out)
}

// PUT /v1/operator/categories/{path...}
func (s *Server) handleCategoryUpdate(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	cs, ok := s.categoryStore(w)
	if !ok {
		return
	}
	old, ok := s.categoryByPath(w, r, cs, r.PathValue("path"))
	if !ok {
		return
	}
	active := old.IsActive
	e := categoryEdit{Path: old.Path, Title: old.Title, Description: old.Description, Dimensions: old.Dimensions, IsActive: &active}
	if !decodeCategory(w, r, &e) {
		return
	}
	if e.Path != old.Path {
		writeErr(w, http.StatusBadRequest, "bad_category", "category_path is the URL's; a node is never moved")
		return
	}
	c := e.category()
	if why := store.CheckCategory(c); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_category", why)
		return
	}
	out, err := cs.UpdateCategory(r.Context(), c)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no category "+c.Path)
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("category update")
		writeErr(w, http.StatusInternalServerError, "internal", "category not stored")
		return
	}
	s.o.Log.Info().Str("category", out.Path).Str("by", who).Msg("category updated")
	writeJSON(w, http.StatusOK, out)
}

// categoryByPath is node path; false = answered (404 when there is none).
func (s *Server) categoryByPath(w http.ResponseWriter, r *http.Request, cs store.CategoryStore, path string) (store.Category, bool) {
	cats, err := cs.ListCategories(r.Context())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("category read")
		writeErr(w, http.StatusInternalServerError, "internal", "categories unavailable")
		return store.Category{}, false
	}
	for _, c := range cats {
		if c.Path == path {
			return c, true
		}
	}
	writeErr(w, http.StatusNotFound, "not_found", "no category "+path)
	return store.Category{}, false
}

// GET /v1/reporting/tokens/by-category?from=&to=&depth=
func (s *Server) handleCategoryTokens(w http.ResponseWriter, r *http.Request) {
	op, _, _, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	cs, ok := s.categoryStore(w)
	if !ok {
		return
	}
	q := r.URL.Query()
	depth, why := categoryDepth(q.Get("depth"))
	from, to, whyWindow := store.CategoryTokensWindow(q.Get("from"), q.Get("to"), s.o.Now())
	if why == "" {
		why = whyWindow
	}
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_query", why)
		return
	}
	cats, err := cs.ListCategories(r.Context())
	var leaves []store.CategoryLaneTokens
	if err == nil {
		leaves, err = cs.CategoryTokens(r.Context(), op, from, to)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("category tokens")
		writeErr(w, http.StatusInternalServerError, "internal", "token rollup unavailable")
		return
	}
	writeJSON(w, http.StatusOK, store.CategoryRollup(cats, leaves, from, to, depth))
}

// categoryDepth is depth= as a number: "" or "leaf" = 0 (every level),
// else 1..categoryDepthMax; a non-empty second value says why not.
func categoryDepth(v string) (int, string) {
	if v == "" || v == "leaf" {
		return 0, ""
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > categoryDepthMax {
		return 0, "depth must be 1.." + strconv.Itoa(categoryDepthMax) + " or leaf"
	}
	return n, ""
}

// askCategory is ask_op "category": the work kind and category of a spawn
// request, from its brief's header (do_spl_spawn_place). It changes no state
// and no stamp of the request.
func (s *Server) askCategory(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askCategoryReq
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {ask_id, by, work_kind, category_path}"}
	}
	var ae *issueErr
	if in.By, ae = s.resolveAgent(ctx, x.tenant, in.By, ""); ae != nil {
		return askAnswer{}, ae
	}
	switch {
	case !store.ValidAskAgent(in.By) || in.By == "":
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "by must be the acting agent, <ID> or <ID>@<box>"}
	case !store.AskIDRe.MatchString(in.AskID):
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask_id must be a lowercase UUID"}
	}
	if why := store.CheckAskCategory(in.WorkKind, in.CategoryPath); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	cs, ok := s.o.Store.(store.CategoryStore)
	if !ok {
		return askAnswer{}, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no activity categories"}
	}
	err := cs.SetAskCategory(ctx, x.tenant, f.Fleet, in.AskID, in.WorkKind, in.CategoryPath)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return askAnswer{}, &issueErr{http.StatusNotFound, "unknown_ask", "no such ask in this fleet"}
	case errors.Is(err, store.ErrUnknownCategory):
		return askAnswer{}, &issueErr{http.StatusBadRequest, "unknown_category",
			"no category " + in.CategoryPath + " (GET /v1/reporting/categories lists them)"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", in.AskID).Msg("fleet ask category")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", in.AskID).Str("by", in.By).
		Str("work_kind", in.WorkKind).Str("category", in.CategoryPath).Msg("fleet ask category")
	return askAnswer{Fleet: f.Fleet, Asks: []AskRow{}, Category: &AskCategoryRow{AskID: in.AskID, WorkKind: in.WorkKind, CategoryPath: in.CategoryPath}}, nil
}
