// Package githubtest is a fake GitHub (httptest) for the Repo Docs edit
// path (spec 075 repo-edit T09): an in-memory repo behind the App-token
// exchange and the Git Data, contents and compare calls internal/github
// makes. It refuses a non-fast-forward ref update with 422, like GitHub, and
// can inject 5xx / 401 / any status. No test reaches the real GitHub.
package githubtest

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1" //nolint:gosec // git object ids are sha1 by definition
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
)

// Fixed names of the fake's App, installation and repo.
const (
	AppID          = "4242"
	InstallationID = "77"
	Owner          = "example-org"
	Repo           = "example-repo"
	Branch         = "master"
	BotSlug        = "example-docs"
	BotName        = BotSlug + "[bot]"
	BotUserID      = 4242
	Noreply        = "users.noreply.example.com"
	BotEmail       = "4242+" + BotName + "@" + Noreply
)

// CommitObj is one commit in the fake repo.
type CommitObj struct {
	SHA       string
	Tree      string
	Parents   []string
	Author    github.Identity
	Committer github.Identity
	Message   string
}

// Server is the fake. Every exported method is safe while requests run.
type Server struct {
	*httptest.Server
	KeyPEM []byte

	key *rsa.PrivateKey
	now func() time.Time

	mu      sync.Mutex
	blobs   map[string][]byte
	trees   map[string]map[string]string // tree sha -> path -> blob sha (flat)
	commits map[string]CommitObj
	ref     string
	tokens  map[string]time.Time
	mints   int
	faults  []fault
	calls   []string
}

type fault struct {
	match  string // "METHOD /path-prefix" or "" for any request
	status int
}

// New starts a fake holding one root commit with files, closed at test end.
func New(t testing.TB, files map[string]string) *Server {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{
		key:    key,
		KeyPEM: pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}),
		now:    time.Now,
		blobs:  map[string][]byte{}, trees: map[string]map[string]string{},
		commits: map[string]CommitObj{}, tokens: map[string]time.Time{},
	}
	tree := map[string]string{}
	for p, body := range files {
		tree[p] = s.putBlob([]byte(body))
	}
	s.ref = s.putCommit(CommitObj{Tree: s.putTree(tree), Message: "root", Author: botID(), Committer: botID()})
	s.Server = httptest.NewServer(s.routes())
	t.Cleanup(s.Close)
	return s
}

func botID() github.Identity { return github.Identity{Name: BotName, Email: BotEmail} }

// Config is a client config pointed at this fake.
func (s *Server) Config() github.Config {
	return github.Config{
		API: s.URL, AppID: AppID, InstallationID: InstallationID,
		Owner: Owner, Repo: Repo, Branch: Branch, Key: s.KeyPEM, Noreply: Noreply, HTTP: s.Client(),
	}
}

// FailNext makes the next request matching "METHOD /path-prefix" (or every
// request when match is "") answer status, once per call.
func (s *Server) FailNext(match string, status int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.faults = append(s.faults, fault{match: match, status: status})
}

// Push lands a commit of path straight on the branch, as another pusher
// (a lane, or the other env's worker) would, and returns its sha.
func (s *Server) Push(path, body, message string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	head := s.commits[s.ref]
	tree := copyTree(s.trees[head.Tree])
	tree[path] = s.putBlob([]byte(body))
	s.ref = s.putCommit(CommitObj{Tree: s.putTree(tree), Parents: []string{s.ref}, Message: message, Author: botID(), Committer: botID()})
	return s.ref
}

// Head is the branch tip.
func (s *Server) Head() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ref
}

// Commit returns one commit object.
func (s *Server) Commit(sha string) (CommitObj, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.commits[sha]
	return c, ok
}

// File is path's text at the branch tip.
func (s *Server) File(path string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.trees[s.commits[s.ref].Tree][path]
	return string(s.blobs[b]), ok
}

// TokenMints counts installation tokens issued.
func (s *Server) TokenMints() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mints
}

// Calls lists every request as "METHOD /path", oldest first.
func (s *Server) Calls() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.calls...)
}

// BlobSHA is git's blob id of body, as `git hash-object` prints it.
func BlobSHA(body []byte) string {
	// nosemgrep: go.lang.security.audit.crypto.use_of_weak_crypto.use-of-sha1 -- a git object id is sha1 by definition; it names test objects, it protects nothing.
	h := sha1.New() //nolint:gosec // git object id
	_, _ = fmt.Fprintf(h, "blob %d\x00", len(body))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

// putBlob, putTree, putCommit store an object; callers hold mu (or own s).
func (s *Server) putBlob(body []byte) string {
	sha := BlobSHA(body)
	s.blobs[sha] = append([]byte(nil), body...)
	return sha
}

func (s *Server) putTree(t map[string]string) string {
	paths := make([]string, 0, len(t))
	for p := range t {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	var b strings.Builder
	for _, p := range paths {
		b.WriteString(p + "\x00" + t[p] + "\n")
	}
	sha := objectID("tree", b.String())
	s.trees[sha] = t
	return sha
}

func (s *Server) putCommit(c CommitObj) string {
	c.SHA = objectID("commit", fmt.Sprintf("%s|%v|%v|%v|%s|%d", c.Tree, c.Parents, c.Author, c.Committer, c.Message, len(s.commits)))
	s.commits[c.SHA] = c
	return c.SHA
}

func objectID(kind, body string) string {
	// nosemgrep: go.lang.security.audit.crypto.use_of_weak_crypto.use-of-sha1 -- a git object id is sha1 by definition; it names test objects, it protects nothing.
	h := sha1.New() //nolint:gosec // git object id
	_, _ = fmt.Fprintf(h, "%s %d\x00%s", kind, len(body), body)
	return hex.EncodeToString(h.Sum(nil))
}

func copyTree(t map[string]string) map[string]string {
	out := make(map[string]string, len(t)+1)
	for k, v := range t {
		out[k] = v
	}
	return out
}

func (s *Server) newToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	tok := "ghs_fake" + hex.EncodeToString(b)
	s.mu.Lock()
	s.tokens[tok] = s.now().Add(time.Hour)
	s.mints++
	s.mu.Unlock()
	return tok
}
