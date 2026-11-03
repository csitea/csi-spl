package hub

import (
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A Qto document only one person can read (spec 125 row B8, section 5.3;
// owner HUM-10 C7, C8, C9; rdb 0256; store/workspace_doc_lock.go). A locked
// document is visible ONLY to its human: not to another member, not to any
// admin role, not to an agent seat, not through act-as. The hub never filters
// it itself: it marks the request's context with the reader's human
// (docTreeHuman -> store.WithHuman) and the database's human_lock policies
// decide every read path (read, tree, list, search, export), so a path that
// forgets the mark shows the document to nobody.
//
//	POST /v1/workspace/doctree            {..., restricted: true}: created locked to the caller
//	PUT  /v1/workspace/doctree/{doc}/lock {restricted, rev}: lock to the caller, or lift it
//
// Who may set it: a signed-in member holding docs.write, for themselves only;
// an agent token or an act-as clone answers 403 restricted_needs_human, and a
// repo doc (fs=repo) 403 repo_docs_unlockable. Who may lift it: its human,
// the only caller who can see it (anyone else gets 404).

// docTreeHuman marks r's context with the caller's human when the caller is
// a signed-in member of tenant who is not an act-as clone, and returns it;
// "" (and r untouched) for an agent token or a clone. The handlers read
// r.Context() after docTreeCaller, so every store call of the route runs
// with app.doc_human_id set (store.humanScope).
func (s *Server) docTreeHuman(r *http.Request, tenant, who string, agent bool) string {
	if agent || who == "" || s.readerIsActAsClone(r.Context(), tenant, who) {
		return ""
	}
	ctx := store.WithHuman(r.Context(), who)
	if store.HumanOf(ctx) == "" {
		return ""
	}
	*r = *r.WithContext(ctx)
	return who
}

// docTreeLockable writes the refusal when c may not lock a document.
func docTreeLockable(w http.ResponseWriter, c docTreeCall) bool {
	switch {
	case c.tenant == store.SystemTenant:
		writeErr(w, http.StatusForbidden, "repo_docs_unlockable", "a repo doc is every workspace's: it cannot be locked")
	case c.human == "":
		writeErr(w, http.StatusForbidden, "restricted_needs_human",
			"only a signed-in member can lock a document, to themselves; never an agent or an act-as clone")
	default:
		return true
	}
	return false
}

// handleDocTreeLock locks the document to the caller (restricted true) or
// lifts the lock (false), under the doc lock and rev like a rename: 200 with
// the new rev, 412 stale_rev, 404 when gone or another human's.
func (s *Server) handleDocTreeLock(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok || !docTreeLockable(w, c) {
		return
	}
	var in struct {
		Restricted *bool `json:"restricted"`
		Rev        int64 `json:"rev"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only restricted, rev)") {
		return
	}
	if in.Restricted == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "restricted is true (lock to you) or false (lift)")
		return
	}
	doc := r.PathValue("doc")
	res, err := c.st.DocLock(r.Context(), c.tenant, doc, in.Rev, *in.Restricted, c.who)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	to := ""
	if *in.Restricted {
		to = c.human
	}
	writeJSON(w, http.StatusOK, map[string]any{"doc": doc, "rev": res.Rev, "restricted_to_human": to})
}
