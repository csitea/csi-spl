package githubtest

import (
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// listCommits is GET /repos/{o}/{r}/commits?sha=&per_page=&page=: the first
// parent chain from the ref, newest first, paginated like GitHub.
func (s *Server) listCommits(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	per, _ := strconv.Atoi(q.Get("per_page"))
	if per <= 0 || per > 100 {
		per = 30
	}
	page, _ := strconv.Atoi(q.Get("page"))
	if page <= 0 {
		page = 1
	}
	s.mu.Lock()
	sha, ok := s.resolve(q.Get("sha"))
	var chain []CommitObj
	for ok && sha != "" {
		c := s.commits[sha]
		chain = append(chain, c)
		sha = ""
		if len(c.Parents) > 0 {
			sha = c.Parents[0]
		}
	}
	s.mu.Unlock()
	if !ok {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	out := []map[string]any{}
	for i := (page - 1) * per; i < len(chain) && i < page*per; i++ {
		c := chain[i]
		full := s.commitJSON(c)
		commit := map[string]any{"message": c.Message, "author": full["author"], "committer": full["committer"],
			"tree": full["tree"], "url": full["url"], "comment_count": 0, "verification": full["verification"]}
		out = append(out, map[string]any{"sha": c.SHA, "node_id": full["node_id"], "commit": commit,
			"url": s.apiURL("/commits/" + c.SHA), "html_url": full["html_url"], "author": nil, "committer": nil, "parents": full["parents"]})
	}
	wire.WriteJSON(w, http.StatusOK, out)
}
