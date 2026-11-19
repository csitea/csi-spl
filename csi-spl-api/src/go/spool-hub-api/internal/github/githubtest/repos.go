package githubtest

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"maps"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Repos is a fake GitHub of many repos for the hub's own sync (spec 143
// releases-projects.md row B-6b): per repo a trunk history, tags and
// releases, behind the App-token exchange (an installation token per
// installation id) or with no credential for a repo marked public. It
// serves the read-only calls internal/github's RepoReader makes, pages
// included, and records each call. No test reaches the real GitHub.
type Repos struct {
	*httptest.Server
	KeyPEM []byte

	mu     sync.Mutex
	repos  map[string]*FakeRepo // "owner/name"
	tokens map[string]string    // token -> installation id
	calls  []string
}

// FakeRepo is one repo. Commits are oldest first, as they were pushed.
type FakeRepo struct {
	Installation string // "" with Public: read with no credential
	Public       bool
	Commits      []FakeCommit
	Tags         map[string]string // tag -> sha
	Releases     []FakeRelease
}

// FakeCommit is one trunk commit and the files it changed.
type FakeCommit struct {
	SHA     string
	Message string
	At      time.Time
	Files   []string
}

// FakeRelease is one GitHub Release.
type FakeRelease struct {
	Tag       string
	Draft     bool
	Published time.Time
}

// NewRepos starts an empty fake, closed at test end.
func NewRepos(t testing.TB) *Repos {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &Repos{repos: map[string]*FakeRepo{}, tokens: map[string]string{},
		KeyPEM: pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /app/installations/{id}/access_tokens", f.token)
	mux.HandleFunc("GET /repos/{owner}/{name}/commits", f.repo(f.commits))
	mux.HandleFunc("GET /repos/{owner}/{name}/commits/{sha}", f.repo(f.commit))
	mux.HandleFunc("GET /repos/{owner}/{name}/tags", f.repo(f.tags))
	mux.HandleFunc("GET /repos/{owner}/{name}/releases", f.repo(f.releases))
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.calls = append(f.calls, r.Method+" "+r.URL.Path)
		f.mu.Unlock()
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(f.Close)
	return f
}

// Put adds or replaces a repo.
func (f *Repos) Put(slug string, r *FakeRepo) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.repos[slug] = r
}

// Push appends commits to a repo's trunk.
func (f *Repos) Push(slug string, cs ...FakeCommit) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.repos[slug].Commits = append(f.repos[slug].Commits, cs...)
}

// Tag points tag at sha in a repo.
func (f *Repos) Tag(slug, tag, sha string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.repos[slug].Tags == nil {
		f.repos[slug].Tags = map[string]string{}
	}
	f.repos[slug].Tags[tag] = sha
}

// Calls is every call so far, "METHOD /path"; Reset forgets them.
func (f *Repos) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

// ResetCalls forgets the recorded calls.
func (f *Repos) ResetCalls() {
	f.mu.Lock()
	f.calls = nil
	f.mu.Unlock()
}

// token mints an installation token for a Bearer JWT of three parts.
func (f *Repos) token(w http.ResponseWriter, r *http.Request) {
	jwt, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || strings.Count(jwt, ".") != 2 {
		ghError(w, http.StatusUnauthorized, "A JSON web token could not be decoded")
		return
	}
	id := r.PathValue("id")
	tok := "ghs_fake_" + id
	f.mu.Lock()
	f.tokens[tok] = id
	f.mu.Unlock()
	wire.WriteJSON(w, http.StatusCreated, map[string]any{"token": tok, "expires_at": time.Now().Add(time.Hour)})
}

// repo resolves the repo and checks the caller may read it: its
// installation's token, or nothing for a public repo. Else 404, as GitHub
// answers a private repo it will not show.
func (f *Repos) repo(h func(http.ResponseWriter, *http.Request, *FakeRepo)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, _ := strings.CutPrefix(r.Header.Get("Authorization"), "token ")
		f.mu.Lock()
		rp := f.repos[r.PathValue("owner")+"/"+r.PathValue("name")]
		inst, known := f.tokens[tok]
		f.mu.Unlock()
		if rp == nil || !(rp.Public || (known && inst == rp.Installation)) {
			ghError(w, http.StatusNotFound, "Not Found")
			return
		}
		f.mu.Lock()
		cp := *rp
		cp.Commits, cp.Tags = slices.Clone(rp.Commits), maps.Clone(rp.Tags)
		f.mu.Unlock()
		h(w, r, &cp)
	}
}

// page cuts items to the request's per_page / page.
func page[T any](r *http.Request, items []T) []T {
	per, _ := strconv.Atoi(r.URL.Query().Get("per_page"))
	n, _ := strconv.Atoi(r.URL.Query().Get("page"))
	if per < 1 {
		per = 30
	}
	if n < 1 {
		n = 1
	}
	lo := min((n-1)*per, len(items))
	return items[lo:min(lo+per, len(items))]
}

func (f *Repos) commits(w http.ResponseWriter, r *http.Request, rp *FakeRepo) {
	out := []map[string]any{}
	for i := len(rp.Commits) - 1; i >= 0; i-- {
		c := rp.Commits[i]
		out = append(out, map[string]any{"sha": c.SHA, "commit": map[string]any{
			"message": c.Message, "committer": map[string]any{"date": c.At.UTC().Format(time.RFC3339)}}})
	}
	wire.WriteJSON(w, http.StatusOK, page(r, out))
}

func (f *Repos) commit(w http.ResponseWriter, r *http.Request, rp *FakeRepo) {
	for _, c := range rp.Commits {
		if c.SHA == r.PathValue("sha") {
			files := []map[string]string{}
			for _, p := range c.Files {
				files = append(files, map[string]string{"filename": p})
			}
			wire.WriteJSON(w, http.StatusOK, map[string]any{"sha": c.SHA, "files": files})
			return
		}
	}
	ghError(w, http.StatusNotFound, "No commit found")
}

func (f *Repos) tags(w http.ResponseWriter, r *http.Request, rp *FakeRepo) {
	names := slices.Sorted(maps.Keys(rp.Tags))
	out := []map[string]any{}
	for _, name := range names {
		out = append(out, map[string]any{"name": name, "commit": map[string]string{"sha": rp.Tags[name]}})
	}
	wire.WriteJSON(w, http.StatusOK, page(r, out))
}

func (f *Repos) releases(w http.ResponseWriter, r *http.Request, rp *FakeRepo) {
	out := []map[string]any{}
	for _, rel := range rp.Releases {
		out = append(out, map[string]any{"tag_name": rel.Tag, "draft": rel.Draft, "published_at": rel.Published.UTC().Format(time.RFC3339)})
	}
	wire.WriteJSON(w, http.StatusOK, page(r, out))
}
