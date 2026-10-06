package githubtest

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// resolve turns a branch name or a commit sha into a commit sha; caller holds mu.
func (s *Server) resolve(ref string) (string, bool) {
	if ref == "" || ref == Branch {
		return s.ref, true
	}
	_, ok := s.commits[ref]
	return ref, ok
}

func (s *Server) getContents(w http.ResponseWriter, r *http.Request) {
	path := r.PathValue("path")
	s.mu.Lock()
	sha, ok := s.resolve(r.URL.Query().Get("ref"))
	blob, found := s.trees[s.commits[sha].Tree][path]
	body := s.blobs[blob]
	s.mu.Unlock()
	if !ok || !found {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	wire.WriteJSON(w, http.StatusOK, map[string]any{
		"type": "file", "path": path, "sha": blob, "encoding": "base64",
		"content": base64.StdEncoding.EncodeToString(body),
	})
}

func (s *Server) getBlob(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	body, ok := s.blobs[r.PathValue("sha")]
	s.mu.Unlock()
	if !ok {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	wire.WriteJSON(w, http.StatusOK, map[string]any{
		"sha": r.PathValue("sha"), "encoding": "base64", "content": base64.StdEncoding.EncodeToString(body),
	})
}

func (s *Server) postBlob(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Content  string `json:"content"`
		Encoding string `json:"encoding"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		ghError(w, http.StatusUnprocessableEntity, "Invalid request")
		return
	}
	body := []byte(in.Content)
	if in.Encoding == "base64" {
		b, err := base64.StdEncoding.DecodeString(in.Content)
		if err != nil {
			ghError(w, http.StatusUnprocessableEntity, "Invalid base64")
			return
		}
		body = b
	}
	s.mu.Lock()
	sha := s.putBlob(body)
	s.mu.Unlock()
	wire.WriteJSON(w, http.StatusCreated, map[string]string{"sha": sha})
}

func (s *Server) getCommit(w http.ResponseWriter, r *http.Request) {
	c, ok := s.Commit(r.PathValue("sha"))
	if !ok {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	parents := make([]map[string]string, 0, len(c.Parents))
	for _, p := range c.Parents {
		parents = append(parents, map[string]string{"sha": p})
	}
	wire.WriteJSON(w, http.StatusOK, map[string]any{
		"sha": c.SHA, "tree": map[string]string{"sha": c.Tree}, "parents": parents,
		"author": c.Author, "committer": c.Committer, "message": c.Message,
	})
}

type treeEntry struct {
	Path string  `json:"path"`
	Mode string  `json:"mode"`
	Type string  `json:"type"`
	SHA  *string `json:"sha"`
}

func (s *Server) postTree(w http.ResponseWriter, r *http.Request) {
	var in struct {
		BaseTree string      `json:"base_tree"`
		Tree     []treeEntry `json:"tree"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		ghError(w, http.StatusUnprocessableEntity, "Invalid request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	base, ok := s.trees[in.BaseTree]
	if !ok && in.BaseTree != "" {
		ghError(w, http.StatusUnprocessableEntity, "base_tree does not exist")
		return
	}
	tree, msg := s.applyEntries(copyTree(base), in.Tree)
	if msg != "" {
		ghError(w, http.StatusUnprocessableEntity, msg)
		return
	}
	wire.WriteJSON(w, http.StatusCreated, map[string]string{"sha": s.putTree(tree)})
}

// applyEntries writes blob entries into tree (a nil sha deletes the path);
// caller holds mu.
func (s *Server) applyEntries(tree map[string]string, entries []treeEntry) (map[string]string, string) {
	for _, e := range entries {
		if e.Type != "blob" || strings.HasPrefix(e.Path, "/") {
			return nil, "tree entry must be a relative blob path"
		}
		if e.SHA == nil {
			delete(tree, e.Path)
			continue
		}
		if _, ok := s.blobs[*e.SHA]; !ok {
			return nil, "blob " + *e.SHA + " does not exist"
		}
		tree[e.Path] = *e.SHA
	}
	return tree, ""
}

// postCommit stores a commit. The committer is always the App's bot, as on
// GitHub for an installation token without an explicit committer.
func (s *Server) postCommit(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Message string           `json:"message"`
		Tree    string           `json:"tree"`
		Parents []string         `json:"parents"`
		Author  *github.Identity `json:"author"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		ghError(w, http.StatusUnprocessableEntity, "Invalid request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if msg := s.checkCommit(in.Tree, in.Parents); msg != "" {
		ghError(w, http.StatusUnprocessableEntity, msg)
		return
	}
	author := botID()
	if in.Author != nil {
		author = *in.Author
	}
	sha := s.putCommit(CommitObj{Tree: in.Tree, Parents: in.Parents, Author: author, Committer: botID(), Message: in.Message})
	wire.WriteJSON(w, http.StatusCreated, map[string]any{"sha": sha, "tree": map[string]string{"sha": in.Tree}})
}

func (s *Server) checkCommit(tree string, parents []string) string {
	if _, ok := s.trees[tree]; !ok {
		return "tree does not exist"
	}
	for _, p := range parents {
		if _, ok := s.commits[p]; !ok {
			return "parent " + p + " does not exist"
		}
	}
	return ""
}

// compare answers base...head with GitHub's status words.
func (s *Server) compare(w http.ResponseWriter, r *http.Request) {
	base, head, ok := strings.Cut(r.PathValue("spec"), "...")
	s.mu.Lock()
	defer s.mu.Unlock()
	b, okB := s.resolve(base)
	h, okH := s.resolve(head)
	if !ok || !okB || !okH {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	out := map[string]any{"status": "diverged", "ahead_by": 0, "behind_by": 0}
	if ahead, behind := s.distance(h, b), s.distance(b, h); ahead == 0 {
		out["status"] = "identical"
	} else if ahead > 0 {
		out["status"], out["ahead_by"] = "ahead", ahead
	} else if behind > 0 {
		out["status"], out["behind_by"] = "behind", behind
	}
	wire.WriteJSON(w, http.StatusOK, out)
}
