package githubtest

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const repoPrefix = "/repos/" + Owner + "/" + Repo

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /app/installations/{id}/access_tokens", s.accessToken)
	mux.HandleFunc("GET "+repoPrefix+"/git/ref/heads/{branch}", s.authed(s.getRef))
	mux.HandleFunc("PATCH "+repoPrefix+"/git/refs/heads/{branch}", s.authed(s.patchRef))
	mux.HandleFunc("GET "+repoPrefix+"/contents/{path...}", s.authed(s.getContents))
	mux.HandleFunc("GET "+repoPrefix+"/git/blobs/{sha}", s.authed(s.getBlob))
	mux.HandleFunc("POST "+repoPrefix+"/git/blobs", s.authed(s.postBlob))
	mux.HandleFunc("GET "+repoPrefix+"/git/commits/{sha}", s.authed(s.getCommit))
	mux.HandleFunc("POST "+repoPrefix+"/git/trees", s.authed(s.postTree))
	mux.HandleFunc("POST "+repoPrefix+"/git/commits", s.authed(s.postCommit))
	mux.HandleFunc("GET "+repoPrefix+"/compare/{spec}", s.authed(s.compare))
	mux.HandleFunc("GET "+repoPrefix+"/commits", s.authed(s.listCommits))
	return s.recordAndFault(mux)
}

func ghError(w http.ResponseWriter, status int, msg string) {
	wire.WriteJSON(w, status, map[string]string{"message": msg})
}

// recordAndFault logs each call and answers the first matching injected
// fault instead of the real handler.
func (s *Server) recordAndFault(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := r.Method + " " + r.URL.Path
		s.mu.Lock()
		s.calls = append(s.calls, call)
		status := 0
		for i, f := range s.faults {
			if f.match == "" || strings.HasPrefix(call, f.match) {
				status = f.status
				s.faults = append(s.faults[:i], s.faults[i+1:]...)
				break
			}
		}
		s.mu.Unlock()
		if status != 0 {
			ghError(w, status, "injected fault")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// authed accepts only a live installation token ("token <t>").
func (s *Server) authed(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "token ")
		s.mu.Lock()
		exp, known := s.tokens[tok]
		s.mu.Unlock()
		if !ok || !known || !s.now().Before(exp) {
			ghError(w, http.StatusUnauthorized, "Bad credentials")
			return
		}
		h(w, r)
	}
}

func (s *Server) accessToken(w http.ResponseWriter, r *http.Request) {
	jwt, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || r.PathValue("id") != InstallationID || !s.validJWT(jwt) {
		ghError(w, http.StatusUnauthorized, "A JSON web token could not be decoded")
		return
	}
	wire.WriteJSON(w, http.StatusCreated, map[string]any{
		"token": s.newToken(), "expires_at": s.now().Add(time.Hour).UTC().Format(time.RFC3339),
	})
}

// validJWT checks the RS256 signature against the App key, iss and exp.
func (s *Server) validJWT(jwt string) bool {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(&s.key.PublicKey, crypto.SHA256, sum[:], sig) != nil {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var c struct {
		Iss string `json:"iss"`
		Exp int64  `json:"exp"`
	}
	return json.Unmarshal(raw, &c) == nil && c.Iss == AppID && c.Exp > s.now().Unix()
}

func (s *Server) getRef(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("branch") != Branch {
		ghError(w, http.StatusNotFound, "Not Found")
		return
	}
	wire.WriteJSON(w, http.StatusOK, map[string]any{"ref": "refs/heads/" + Branch, "object": map[string]string{"sha": s.Head(), "type": "commit"}})
}

// patchRef moves the branch only when the new commit descends from the tip
// (force:false), else 422 "Update is not a fast forward", like GitHub.
func (s *Server) patchRef(w http.ResponseWriter, r *http.Request) {
	var in struct {
		SHA   string `json:"sha"`
		Force bool   `json:"force"`
	}
	if r.PathValue("branch") != Branch || json.NewDecoder(r.Body).Decode(&in) != nil {
		ghError(w, http.StatusUnprocessableEntity, "Invalid request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.commits[in.SHA]; !ok {
		ghError(w, http.StatusUnprocessableEntity, "Object does not exist")
		return
	}
	if !in.Force && !s.descends(in.SHA, s.ref) {
		ghError(w, http.StatusUnprocessableEntity, "Update is not a fast forward")
		return
	}
	s.ref = in.SHA
	wire.WriteJSON(w, http.StatusOK, map[string]any{"ref": "refs/heads/" + Branch, "object": map[string]string{"sha": in.SHA}})
}

// descends reports whether ancestor is sha or one of its ancestors; caller holds mu.
func (s *Server) descends(sha, ancestor string) bool {
	return s.distance(sha, ancestor) >= 0
}

// distance is the number of commits from ancestor to sha along first parents and
// merges (breadth first), or -1 when ancestor is not an ancestor; caller holds mu.
func (s *Server) distance(sha, ancestor string) int {
	seen := map[string]bool{sha: true}
	level, d := []string{sha}, 0
	for len(level) > 0 {
		var next []string
		for _, c := range level {
			if c == ancestor {
				return d
			}
			next = s.unseenParents(c, seen, next)
		}
		level, d = next, d+1
	}
	return -1
}

func (s *Server) unseenParents(sha string, seen map[string]bool, acc []string) []string {
	for _, p := range s.commits[sha].Parents {
		if !seen[p] {
			seen[p] = true
			acc = append(acc, p)
		}
	}
	return acc
}
