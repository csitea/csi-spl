package hub

import (
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The Docs section (owner, prd t1 9f0d751c): the repo's markdown, published
// to the env's docs bucket by the WUI deploy (do_publish_docs), read here.
//
//	GET /v1/docs/tree.json            the index the publish wrote: every path
//	GET /v1/docs/{repo path}.md       one doc, its repo path as the object key
//
// Every signed-in member reads (the repo is public, spec 044; the door only
// keeps the bucket off the open web). Options.Docs nil = the section is off:
// 404 docs_off, so a hub without a docs bucket still starts.

// DocsIndex is the object key of the publish's index.
const DocsIndex = "tree.json"

// docsPathRe is a repo path the publish writes: segments of [A-Za-z0-9._-],
// none starting with a dot (no "..", no hidden file), ending in .md.
var docsPathRe = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$`)

// ValidDocsPath reports whether p is a key this route may serve.
func ValidDocsPath(p string) bool {
	return p == DocsIndex || (len(p) <= 512 && docsPathRe.MatchString(p))
}

func (s *Server) routeDocs(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/docs/{path...}", s.handleGetDoc)
	mux.HandleFunc("OPTIONS /v1/docs/{path...}", s.docsPreflight)
	s.routeRepoDocsEdit(mux) // spec 075 repo-edit T08: PUT + the edits routes
}

func (s *Server) handleGetDoc(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "docs need a signed-in member session")
		return
	}
	if s.o.Docs == nil {
		writeErr(w, http.StatusNotFound, "docs_off", "this hub has no docs bucket")
		return
	}
	p := r.PathValue("path")
	if !ValidDocsPath(p) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	if st, on := s.repoEdit(); on { // spec 075 repo-edit: overlays and the editable flags
		s.getRepoDoc(w, r, st, t.ID, hum, p)
		return
	}
	rc, err := s.o.Docs.Get(r.Context(), p)
	if errors.Is(err, blob.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
		return
	}
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "internal", "docs store unavailable")
		return
	}
	defer rc.Close()
	h := w.Header()
	if strings.HasSuffix(p, ".json") {
		h.Set("Content-Type", "application/json; charset=utf-8")
	} else {
		h.Set("Content-Type", "text/markdown; charset=utf-8")
	}
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "sandbox; default-src 'none'")
	// a deploy republishes: revalidate, and never a shared cache
	h.Set("Cache-Control", "private, no-cache")
	h.Add("Vary", "Cookie")
	h.Add("Vary", "Authorization")
	w.WriteHeader(http.StatusOK)
	io.Copy(w, rc) //nolint:errcheck
}

// getRepoDoc is the read with repo editing on: tree.json merged with the
// overlays, a doc from its newest live overlay (repo_docs_edit.go).
func (s *Server) getRepoDoc(w http.ResponseWriter, r *http.Request, st repoDocStore, tenant, hum, p string) {
	if p == DocsIndex {
		if err := s.serveRepoDocsTree(w, r, st, tenant, hum); err != nil {
			writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
		}
		return
	}
	found, err := s.serveRepoDoc(w, r, st, tenant, hum, p)
	switch {
	case err != nil:
		writeErrCause(w, http.StatusServiceUnavailable, "internal", "docs store unavailable", err)
	case !found:
		writeErr(w, http.StatusNotFound, "not_found", "no such doc")
	}
}
