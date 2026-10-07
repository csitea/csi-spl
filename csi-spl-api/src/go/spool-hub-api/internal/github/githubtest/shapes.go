package githubtest

import (
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
)

// The answers below follow GitHub's REST shapes (api version 2022-11-28),
// extra fields included, so a client that decodes an answer into the wrong
// shape fails here as it would on GitHub. The live defect this pins:
// POST /git/trees answers "tree" as an ARRAY of entries, while a commit's
// "tree" is an object (spec 075, hub 2.6.6 "github tree: 201 undecodable
// answer").

// apiURL is the API url of one repo object, as GitHub puts it in "url".
func (s *Server) apiURL(rest string) string { return s.URL + repoPrefix + rest }

// signature is a commit's author or committer: name, email and date.
func (s *Server) signature(id github.Identity) map[string]string {
	return map[string]string{"name": id.Name, "email": id.Email, "date": s.now().UTC().Format(time.RFC3339)}
}

// commitJSON is the GET and POST /git/commits answer.
func (s *Server) commitJSON(c CommitObj) map[string]any {
	parents := make([]map[string]string, 0, len(c.Parents))
	for _, p := range c.Parents {
		parents = append(parents, map[string]string{"sha": p, "url": s.apiURL("/git/commits/" + p), "html_url": s.URL + "/commit/" + p})
	}
	return map[string]any{
		"sha": c.SHA, "node_id": "C_" + c.SHA, "url": s.apiURL("/git/commits/" + c.SHA), "html_url": s.URL + "/commit/" + c.SHA,
		"author": s.signature(c.Author), "committer": s.signature(c.Committer), "message": c.Message,
		"tree":         map[string]string{"sha": c.Tree, "url": s.apiURL("/git/trees/" + c.Tree)},
		"parents":      parents,
		"verification": map[string]any{"verified": false, "reason": "unsigned", "signature": nil, "payload": nil},
	}
}

// treeJSON is the POST /git/trees answer: sha, url, the entries as an
// array, truncated. Caller holds mu.
func (s *Server) treeJSON(sha string) map[string]any {
	t := s.trees[sha]
	paths := make([]string, 0, len(t))
	for p := range t {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	entries := make([]map[string]any, 0, len(paths))
	for _, p := range paths {
		entries = append(entries, map[string]any{
			"path": p, "mode": "100644", "type": "blob", "sha": t[p],
			"size": len(s.blobs[t[p]]), "url": s.apiURL("/git/blobs/" + t[p]),
		})
	}
	return map[string]any{"sha": sha, "url": s.apiURL("/git/trees/" + sha), "tree": entries, "truncated": false}
}

// refJSON is the GET and PATCH /git/refs/heads/{branch} answer.
func (s *Server) refJSON(sha string) map[string]any {
	ref := "refs/heads/" + Branch
	return map[string]any{
		"ref": ref, "node_id": "REF_" + Branch, "url": s.apiURL("/git/" + ref),
		"object": map[string]string{"type": "commit", "sha": sha, "url": s.apiURL("/git/commits/" + sha)},
	}
}

// dirJSON is GET /contents/{path} of a directory: GitHub answers an ARRAY
// of entries, not an object. ok is false when nothing lies below path.
// Caller holds mu.
func (s *Server) dirJSON(tree map[string]string, dir string) ([]map[string]any, bool) {
	var out []map[string]any
	seen := map[string]bool{}
	prefix := strings.Trim(dir, "/") + "/"
	for p, blob := range tree {
		rest, ok := strings.CutPrefix(p, prefix)
		if !ok {
			continue
		}
		name, _, sub := strings.Cut(rest, "/")
		if seen[name] {
			continue
		}
		seen[name] = true
		e := map[string]any{"type": "file", "name": name, "path": prefix + name, "sha": blob, "size": len(s.blobs[blob])}
		if sub {
			e = map[string]any{"type": "dir", "name": name, "path": prefix + name}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i]["name"].(string) < out[j]["name"].(string) })
	return out, len(out) > 0
}
