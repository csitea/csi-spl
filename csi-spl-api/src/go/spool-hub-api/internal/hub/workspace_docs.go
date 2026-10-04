package hub

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Workspace docs (specs/075 Phase 2, T007 + T008): markdown any member or
// agent of a workspace writes, in that workspace's own docs store (one
// bucket per workspace, owner 9431127d).
//
//	GET    /v1/workspace/docs/tree.json   every doc: {files:[{path, updated}]}
//	GET    /v1/workspace/docs/{path}.md   one doc
//	PUT    /v1/workspace/docs/{path}.md   create or replace: the last save wins
//	DELETE /v1/workspace/docs/{path}.md   remove
//
// No lock and no precondition (owner 15134701: "no need for ultra high level
// ACID Like doc locking mechanisms"): every PUT and DELETE also writes
// .history/<path>/<UTC>--<author>--<put|del>.md (the bytes written, or the
// bytes deleted), so an overwritten or deleted version is never lost. Who: a signed-in member whose role grants docs.read /
// docs.write, or an agent (a box upload token; owner b60bf417: "people and
// agents, or people via agents"). The store is resolved from the caller's
// verified tenant only, never from the request. Options.WorkspaceDocs nil =
// the routes are off: 404 workspace_docs_off.

// MaxWorkspaceDoc caps one doc's body.
const MaxWorkspaceDoc = 1 << 20

// WorkspaceDocsHistory is the prefix of the per-write history records.
const WorkspaceDocsHistory = ".history/"

// WorkspaceDocs resolves a workspace's docs store (T007). Pattern holds
// "{tenant}", replaced by the caller's tenant id to name the store's
// location (a bucket, or a directory); Open opens one location. Stores are
// opened once per tenant and kept.
type WorkspaceDocs struct {
	pattern string
	open    func(ctx context.Context, location string) (blob.Store, error)

	mu     sync.Mutex
	stores map[string]blob.Store
}

// NewWorkspaceDocs is the resolver of pattern, or an error when pattern does
// not name "{tenant}" (every workspace would share one store).
func NewWorkspaceDocs(pattern string, open func(ctx context.Context, location string) (blob.Store, error)) (*WorkspaceDocs, error) {
	if strings.Count(pattern, "{tenant}") != 1 {
		return nil, fmt.Errorf("workspace docs location %q must contain {tenant} exactly once", pattern)
	}
	return &WorkspaceDocs{pattern: pattern, open: open, stores: map[string]blob.Store{}}, nil
}

// Location is tenant's store location.
func (d *WorkspaceDocs) Location(tenant string) (string, error) {
	if !msg.ValidTenantID(tenant) {
		return "", fmt.Errorf("workspace docs: %q is not a tenant id", tenant)
	}
	return strings.Replace(d.pattern, "{tenant}", tenant, 1), nil
}

// Store is tenant's docs store.
func (d *WorkspaceDocs) Store(ctx context.Context, tenant string) (blob.Store, error) {
	loc, err := d.Location(tenant)
	if err != nil {
		return nil, err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if s, ok := d.stores[tenant]; ok {
		return s, nil
	}
	s, err := d.open(ctx, loc)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, fmt.Errorf("workspace docs: no store at %q", loc)
	}
	d.stores[tenant] = s
	return s, nil
}

// Close closes every opened store.
func (d *WorkspaceDocs) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	var errs []error
	for k, s := range d.stores {
		errs = append(errs, s.Close())
		delete(d.stores, k)
	}
	return errors.Join(errs...)
}

// ValidWorkspaceDocPath reports whether p is a doc key a caller may name:
// ValidDocsPath's .md paths (no "..", no absolute path, no hidden segment,
// so never .history/), not the index.
func ValidWorkspaceDocPath(p string) bool { return p != DocsIndex && ValidDocsPath(p) }

// agentDocs reports whether an agent may perm: the pure_agent role's grant.
func agentDocs(perm string) bool {
	for _, p := range rbac.DefaultRoles()[rbac.PureAgent].Perms {
		if p == perm {
			return true
		}
	}
	return false
}

func (s *Server) routeWorkspaceDocs(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/workspace/docs/{path...}", s.handleGetWorkspaceDoc)
	mux.HandleFunc("PUT /v1/workspace/docs/{path...}", s.handlePutWorkspaceDoc)
	mux.HandleFunc("DELETE /v1/workspace/docs/{path...}", s.handleDeleteWorkspaceDoc)
	mux.HandleFunc("OPTIONS /v1/workspace/docs/{path...}", s.workspaceDocsPreflight)
}

func (s *Server) workspaceDocsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// docsCaller resolves who calls and their tenant's docs store, or writes the
// refusal. An upload token of a box (not the WUI's own) is an agent; anyone
// else goes through the member-session door and must hold perm.
func (s *Server) docsCaller(w http.ResponseWriter, r *http.Request, perm string) (store.Tenant, string, blob.Store, bool) {
	s.allowOrigin(w, r)
	var t store.Tenant
	var who string
	// off first: that the section is off is no secret, and an anonymous
	// probe proves a deploy keeps it off
	if s.o.WorkspaceDocs == nil {
		writeErr(w, http.StatusNotFound, "workspace_docs_off", "this hub has no workspace docs store")
		return t, "", nil, false
	}
	if _, box, _, ok := s.bearerAny(r); ok && box != WUIBox {
		if t, _, ok = s.tokenTenant(w, r); !ok {
			return t, "", nil, false
		}
		if !agentDocs(perm) {
			writeForbidden(w, perm, "agents are not granted "+perm)
			return t, "", nil, false
		}
		who = box
	} else {
		var hum string
		if t, hum, ok = s.humanTenant(w, r); !ok {
			return t, "", nil, false
		}
		if hum == "" {
			writeForbidden(w, perm, "workspace docs need a signed-in member session or an agent token")
			return t, "", nil, false
		}
		if !s.permit(w, r, t.ID, hum, perm) {
			return t, "", nil, false
		}
		who = hum
	}
	st, err := s.o.WorkspaceDocs.Store(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("workspace docs store")
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return t, "", nil, false
	}
	return t, who, st, true
}

func docHeaders(h http.Header, contentType string) {
	h.Set("Content-Type", contentType)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "sandbox; default-src 'none'")
	h.Set("Cache-Control", "private, no-cache")
	h.Add("Vary", "Cookie")
	h.Add("Vary", "Authorization")
}

// WorkspaceDocEntry is one doc of tree.json.
type WorkspaceDocEntry struct {
	Path    string    `json:"path"`
	Updated time.Time `json:"updated"`
}

// WorkspaceDocsTree is GET tree.json.
type WorkspaceDocsTree struct {
	Files []WorkspaceDocEntry `json:"files"`
}

func (s *Server) handleGetWorkspaceDoc(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("path")
	_, _, st, ok := s.docsCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	if p == DocsIndex {
		tree := WorkspaceDocsTree{Files: []WorkspaceDocEntry{}}
		err := st.List(r.Context(), "", func(key string, up time.Time) error {
			if ValidWorkspaceDocPath(key) {
				tree.Files = append(tree.Files, WorkspaceDocEntry{Path: key, Updated: up.UTC()})
			}
			return nil
		})
		if err != nil {
			writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
			return
		}
		sort.Slice(tree.Files, func(i, j int) bool { return tree.Files[i].Path < tree.Files[j].Path })
		docHeaders(w.Header(), "application/json; charset=utf-8")
		writeJSON(w, http.StatusOK, tree)
		return
	}
	if !ValidWorkspaceDocPath(p) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	rc, err := st.Get(r.Context(), p)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	defer rc.Close()
	docHeaders(w.Header(), "text/markdown; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}

// WorkspaceDocWritten is the PUT / DELETE answer.
type WorkspaceDocWritten struct {
	Path    string `json:"path"`
	History string `json:"history"` // the .history/ record of this write
}

// historyKey is the record of one write of p by who.
func (s *Server) historyKey(p, who, op string) string {
	ts := s.o.Now().UTC().Format("20060102T150405.000000000Z")
	return WorkspaceDocsHistory + p + "/" + ts + "--" + who + "--" + op + ".md"
}

// putDoc overwrites key with data: PutReader has no content-address
// precondition, so the last save wins on every store.
func putDoc(ctx context.Context, st blob.Store, key string, data []byte) error {
	_, err := st.PutReader(ctx, key, bytes.NewReader(data))
	return err
}

func (s *Server) handlePutWorkspaceDoc(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("path")
	_, who, st, ok := s.docsCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	if !ValidWorkspaceDocPath(p) {
		writeErr(w, http.StatusBadRequest, "bad_path", "a doc path is segments of [A-Za-z0-9._-], none starting with a dot, ending in .md")
		return
	}
	data, err := readAllCapped(w, r, MaxWorkspaceDoc)
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("a doc is at most %d bytes", MaxWorkspaceDoc))
		return
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_body", "the doc body did not arrive")
		return
	}
	ctx := context.WithoutCancel(r.Context()) // a write the client left still lands whole
	hist := s.historyKey(p, who, "put")
	if err := putDoc(ctx, st, hist, data); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	if err := putDoc(ctx, st, p, data); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	writeJSON(w, http.StatusOK, WorkspaceDocWritten{Path: p, History: hist})
}

func (s *Server) handleDeleteWorkspaceDoc(w http.ResponseWriter, r *http.Request) {
	p := r.PathValue("path")
	_, who, st, ok := s.docsCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	if !ValidWorkspaceDocPath(p) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	ctx := context.WithoutCancel(r.Context())
	rc, err := st.Get(ctx, p)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	old, err := io.ReadAll(rc)
	rc.Close()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	hist := s.historyKey(p, who, "del")
	if err := putDoc(ctx, st, hist, old); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	if err := st.Delete(ctx, p); err != nil && !errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusServiceUnavailable, "internal", "workspace docs store unavailable")
		return
	}
	writeJSON(w, http.StatusOK, WorkspaceDocWritten{Path: p, History: hist})
}
