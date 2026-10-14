package hub

import (
	"context"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Qto explorer's folders (spec 120 section 7, the subset the + New
// folder button needs; owner t1 3b8891e0): one folder's children, a
// folder create, a node move (gap topic t1 b67d5dc7), and a folder's rename
// and delete (its right-click menu, owner t1 ed2e3583). The store ops are workspace_doc_nodes.go's; the caller rule
// and the outcomes are wsdoc_tree.go's (docTreeCaller, docTreeFail).

// docTreeNode is one listed node on the wire. id is "" for a document an
// older hub made without a node (it lists at the top); doc is a document's
// id, "" for a folder.
type docTreeNode struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Doc         string `json:"doc"`
	ChildCount  int    `json:"child_count"`
}

// handleDocTreeNodes lists ?parent= (none = the workspace's root): the
// folders first, then the documents, each by name, at most 200.
func (s *Server) handleDocTreeNodes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsRead)
	if !ok {
		return
	}
	parent, nodes, err := c.st.DocNodes(r.Context(), c.tenant, r.URL.Query().Get("parent"))
	if err != nil {
		docTreeFail(w, err)
		return
	}
	out := make([]docTreeNode, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, docTreeNode{ID: n.ID, Kind: n.Kind, Name: n.Name, Title: n.Title,
			Description: n.Description, Doc: n.DocID, ChildCount: n.Children})
	}
	writeJSON(w, http.StatusOK, map[string]any{"parent": parent, "nodes": out})
}

// handleDocTreeFolderCreate makes a folder as parent's last child ("" = the
// root): 201 with its node id.
func (s *Server) handleDocTreeFolderCreate(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Parent      string `json:"parent"`
		Name        string `json:"name"`
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only parent, name, title, description)") {
		return
	}
	f, err := store.DocFolderCheck(store.DocFolder{Parent: in.Parent, Name: in.Name, Title: in.Title,
		Description: in.Description, Actor: c.who})
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	id, err := c.st.DocFolderCreate(r.Context(), c.tenant, f)
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "kind": "folder", "name": f.Name, "parent": in.Parent})
}

// docNodeMoverAt is the store's placed move (store.DocNodeMoveAt), apart
// from docTreeStore so a store without it keeps the plain move.
type docNodeMoverAt interface {
	DocNodeMoveAt(ctx context.Context, tenant string, m store.DocNodeMoveReq) error
}

// handleDocTreeNodeMove makes a folder (with its subtree) or a document the
// last child of parent ("" = the root), or with before / after (a child of
// parent) lands it next to that child, a re-order within its own folder too
// (owner t1 1a9a14b6, msg 32d5ea87): 200, or 409 move_into_own_subtree /
// name_taken / depth / not_a_sibling, 400 parent_is_document or both
// before and after, 404 for no such node.
func (s *Server) handleDocTreeNodeMove(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Parent string `json:"parent"`
		Before string `json:"before"`
		After  string `json:"after"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only parent, before, after)") {
		return
	}
	node := r.PathValue("node")
	out := map[string]any{"id": node, "parent": in.Parent}
	mv, placed := c.st.(docNodeMoverAt)
	var err error
	switch {
	case in.Before == "" && in.After == "":
		err = c.st.DocNodeMove(r.Context(), c.tenant, node, in.Parent)
	case in.Before != "" && in.After != "":
		writeErr(w, http.StatusBadRequest, "bad_request", "before or after, not both")
		return
	case !placed:
		writeErr(w, http.StatusNotImplemented, "not_implemented", "this store has no placed move")
		return
	default:
		err = mv.DocNodeMoveAt(r.Context(), c.tenant, store.DocNodeMoveReq{Node: node, Parent: in.Parent, Before: in.Before, After: in.After})
		out["before"], out["after"] = in.Before, in.After
	}
	if err != nil {
		docTreeFail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleDocTreeFolderEdit renames a folder, or sets its title or
// description (the folder row's menu, owner t1 ed2e3583): 200, 409
// name_taken, 400 over a length limit, 422 for a node that is no folder.
func (s *Server) handleDocTreeFolderEdit(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	var in struct {
		Name        *string `json:"name"`
		Title       *string `json:"title"`
		Description *string `json:"description"`
	}
	if !readJSONStrict(w, r, &in, docTreeMaxBody, "invalid JSON body (only name, title, description)") {
		return
	}
	p, err := store.DocFolderPatchCheck(store.DocFolderPatch{Name: in.Name, Title: in.Title, Description: in.Description})
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	folder := r.PathValue("folder")
	if err := c.st.DocFolderEdit(r.Context(), c.tenant, folder, p); err != nil {
		docTreeFail(w, err)
		return
	}
	out := map[string]any{"id": folder}
	if p.Name != nil {
		out["name"] = *p.Name
	}
	writeJSON(w, http.StatusOK, out)
}

// handleDocTreeFolderDelete deletes a folder: 200 with what went, 409
// folder_not_empty {folders, documents} for one that holds anything unless
// ?recursive=1, which takes its whole subtree (one log line, actor and
// counts).
func (s *Server) handleDocTreeFolderDelete(w http.ResponseWriter, r *http.Request) {
	c, ok := s.docTreeCaller(w, r, rbac.DocsWrite)
	if !ok {
		return
	}
	folder := r.PathValue("folder")
	recursive := r.URL.Query().Get("recursive") == "1"
	res, err := c.st.DocFolderDelete(r.Context(), c.tenant, folder, recursive)
	var ne *store.DocFolderNotEmptyError
	if errors.As(err, &ne) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "folder_not_empty",
			"detail": "the folder is not empty: delete it with recursive=1", "folders": ne.Folders, "documents": ne.Documents})
		return
	}
	if err != nil {
		docTreeFail(w, err)
		return
	}
	s.o.Log.Info().Str("tenant", c.tenant).Str("actor", c.who).Str("folder", folder).
		Int("folders", res.Folders).Int("documents", res.Documents).Msg("doc tree folder delete")
	writeJSON(w, http.StatusOK, map[string]any{"id": folder, "deleted": true, "folders": res.Folders, "documents": res.Documents})
}
