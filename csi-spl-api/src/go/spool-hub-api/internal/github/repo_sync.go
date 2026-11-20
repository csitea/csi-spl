package github

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// The hub's own GitHub sync reads (spec 143 releases-projects.md row B-6b,
// spec 171 section 3.4.1, SPL-5808): one reader per workspace repo, through
// an App installation (the row's, else the hub's) or with no credential for
// a public repo (Q3). Read-only calls only: the commit list since a cursor,
// one commit's changed files, the tags and the releases. The App's
// installation tokens are cached per installation, so the repos of one
// installation share a token. No key, JWT or token byte is logged or put in
// an error, as in client.go.

// RepoCommit is one trunk commit as the sync stores it. No author name or
// email: release_notes keeps none (releases-projects.md section 5).
type RepoCommit struct {
	SHA         string
	Message     string
	CommittedAt time.Time
}

// RepoTag is one tag and the commit it points at.
type RepoTag struct {
	Name string
	SHA  string
}

// RepoRelease is one GitHub Release; a draft is not published yet.
type RepoRelease struct {
	TagName     string
	Draft       bool
	PublishedAt time.Time
}

// RepoAppConfig names the hub's App. Key may be empty: the hub then reads
// public repos only, and an installation read is refused with ErrNoAppKey.
type RepoAppConfig struct {
	API   string
	AppID string
	Key   []byte
	HTTP  *http.Client
	Log   zerolog.Logger
	Now   func() time.Time
}

// ErrNoAppKey: a repo read through the App, on a hub with no App key.
var ErrNoAppKey = errors.New("github: the hub has no App key for an installation read")

// RepoApp hands out per-repo readers. Safe for concurrent use.
type RepoApp struct {
	cfg  RepoAppConfig
	mu   sync.Mutex
	inst map[string]*Client // installation id -> its token cache
}

// NewRepoApp checks the API base. The key is parsed on the first
// installation read, and never quoted.
func NewRepoApp(cfg RepoAppConfig) (*RepoApp, error) {
	if cfg.API == "" {
		return nil, errors.New("github: the API base is required")
	}
	cfg.API = strings.TrimRight(cfg.API, "/")
	if cfg.HTTP == nil {
		cfg.HTTP = &http.Client{Timeout: defaultHTTPTimeout}
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &RepoApp{cfg: cfg, inst: map[string]*Client{}}, nil
}

// RepoReader reads one repo.
type RepoReader struct {
	c           *Client
	owner, repo string
	public      bool
}

// Reader is the reader of owner/repo through installation, or with no
// credential when installation is "" (a public repo).
func (a *RepoApp) Reader(owner, repo, installation string) (*RepoReader, error) {
	if owner == "" || repo == "" || strings.ContainsAny(owner+repo, "/?#") {
		return nil, errors.New("github: a repo reader needs an owner and a repo name")
	}
	if installation == "" {
		c := &Client{api: a.cfg.API, http: a.cfg.HTTP, log: a.cfg.Log, now: a.cfg.Now}
		return &RepoReader{c: c, owner: owner, repo: repo, public: true}, nil
	}
	if len(a.cfg.Key) == 0 || a.cfg.AppID == "" {
		return nil, ErrNoAppKey
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	c := a.inst[installation]
	if c == nil {
		key, err := parseKey(a.cfg.Key)
		if err != nil {
			return nil, err
		}
		c = &Client{api: a.cfg.API, appID: a.cfg.AppID, inst: installation, key: key,
			http: a.cfg.HTTP, log: a.cfg.Log, now: a.cfg.Now}
		a.inst[installation] = c
	}
	return &RepoReader{c: c, owner: owner, repo: repo}, nil
}

// get is one GET of the repo's API under the reader's credential.
func (r *RepoReader) get(ctx context.Context, op, rest string, out any) error {
	path := "/repos/" + url.PathEscape(r.owner) + "/" + url.PathEscape(r.repo) + rest
	if r.public {
		return r.c.do(ctx, op, http.MethodGet, path, "", nil, out)
	}
	return r.c.call(ctx, op, http.MethodGet, path, nil, out)
}

// CommitsSince lists branch's commits newer than since, newest first, at
// most max. found reports that the walk reached since; it is false on a
// first sync (since "") and when since is no longer on the branch (a
// rewrite).
func (r *RepoReader) CommitsSince(ctx context.Context, branch, since string, max int) (out []RepoCommit, found bool, err error) {
	for page := 1; len(out) < max; page++ {
		var got []struct {
			SHA    string `json:"sha"`
			Commit struct {
				Message   string `json:"message"`
				Committer struct {
					Date time.Time `json:"date"`
				} `json:"committer"`
			} `json:"commit"`
		}
		q := url.Values{"sha": {branch}, "per_page": {strconv.Itoa(commitsPage)}, "page": {strconv.Itoa(page)}}
		if err := r.get(ctx, "repo-commits", "/commits?"+q.Encode(), &got); err != nil {
			return nil, false, err
		}
		for _, g := range got {
			if since != "" && g.SHA == since {
				return out, true, nil
			}
			if len(out) < max {
				out = append(out, RepoCommit{SHA: g.SHA, Message: g.Commit.Message, CommittedAt: g.Commit.Committer.Date})
			}
		}
		if len(got) < commitsPage {
			break
		}
	}
	return out, false, nil
}

// CommitTopFolder is the top folder most of the commit's changed files sit
// in, the first one on a tie; "" when every changed file is at the root.
func (r *RepoReader) CommitTopFolder(ctx context.Context, sha string) (string, error) {
	var got struct {
		Files []struct {
			Filename string `json:"filename"`
		} `json:"files"`
	}
	if err := r.get(ctx, "repo-commit", "/commits/"+url.PathEscape(sha), &got); err != nil {
		return "", err
	}
	count, best := map[string]int{}, ""
	for _, f := range got.Files {
		top, _, nested := strings.Cut(f.Filename, "/")
		if !nested || top == "" {
			continue
		}
		count[top]++
		if count[top] > count[best] {
			best = top
		}
	}
	return best, nil
}

// tagPages caps the tag and release lists, 100 per page: 5000 of each. A
// repo with more is an error (ErrTooManyTags), never a silent cut: a cut
// list leaves the commits of the missing tags unversioned (R7 W1 of
// SPL-5808, SPL-6006).
const tagPages = 50

// ErrTooManyTags: the repo has more tags or releases than tagPages pages.
var ErrTooManyTags = errors.New("repo sync: more than 5000 tags or releases; the list is not read")

// listPages reads what, 100 per page, until a short page; one page past
// tagPages that still has items is ErrTooManyTags.
func listPages[T any](ctx context.Context, r *RepoReader, what, path string) ([]T, error) {
	var out []T
	for page := 1; ; page++ {
		var got []T
		q := url.Values{"per_page": {strconv.Itoa(commitsPage)}, "page": {strconv.Itoa(page)}}
		if err := r.get(ctx, what, path+"?"+q.Encode(), &got); err != nil {
			return nil, err
		}
		if page > tagPages && len(got) > 0 {
			return nil, ErrTooManyTags
		}
		out = append(out, got...)
		if len(got) < commitsPage {
			return out, nil
		}
	}
}

// Tags lists the repo's tags, at most tagPages pages.
func (r *RepoReader) Tags(ctx context.Context) ([]RepoTag, error) {
	got, err := listPages[struct {
		Name   string `json:"name"`
		Commit struct {
			SHA string `json:"sha"`
		} `json:"commit"`
	}](ctx, r, "repo-tags", "/tags")
	if err != nil {
		return nil, err
	}
	out := make([]RepoTag, 0, len(got))
	for _, g := range got {
		out = append(out, RepoTag{Name: g.Name, SHA: g.Commit.SHA})
	}
	return out, nil
}

// Releases lists the repo's releases, at most tagPages pages.
func (r *RepoReader) Releases(ctx context.Context) ([]RepoRelease, error) {
	got, err := listPages[struct {
		TagName     string    `json:"tag_name"`
		Draft       bool      `json:"draft"`
		PublishedAt time.Time `json:"published_at"`
	}](ctx, r, "repo-releases", "/releases")
	if err != nil {
		return nil, err
	}
	out := make([]RepoRelease, 0, len(got))
	for _, g := range got {
		out = append(out, RepoRelease{TagName: g.TagName, Draft: g.Draft, PublishedAt: g.PublishedAt})
	}
	return out, nil
}
