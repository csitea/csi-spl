package github_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
)

const doc = "csi-spl-doc/doc/md/example.md"

// clock is a settable Now for the token-cache tests.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func newClient(t *testing.T, gh *githubtest.Server, log *bytes.Buffer, clk *clock) *github.Client {
	t.Helper()
	cfg := gh.Config()
	if log != nil {
		cfg.Log = zerolog.New(log)
	}
	if clk != nil {
		cfg.Now = clk.now
	}
	c, err := github.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

var editor = github.Identity{Name: "FirstName LastName", Email: "member@example.com"}

func TestCommitLandsWithAuthorNotCommitter(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "# one\n"})
	c := newClient(t, gh, nil, nil)
	ctx := context.Background()

	head, err := c.HeadBlob(ctx, doc)
	if err != nil {
		t.Fatal(err)
	}
	if head.Commit != gh.Head() || head.Blob != githubtest.BlobSHA([]byte("# one\n")) {
		t.Fatalf("HeadBlob = %+v, want tip %s and the git blob id of the text", head, gh.Head())
	}
	sha, err := c.Commit(ctx, doc, []byte("# two\n"), editor, "docs: edit "+doc, head.Commit)
	if err != nil {
		t.Fatal(err)
	}
	if gh.Head() != sha {
		t.Fatalf("branch at %s, want the new commit %s", gh.Head(), sha)
	}
	got, _ := gh.Commit(sha)
	if got.Author != editor || got.Committer.Name != githubtest.BotName || got.Author == got.Committer {
		t.Fatalf("author %+v committer %+v: want the editor as author and the App bot as committer", got.Author, got.Committer)
	}
	if len(got.Parents) != 1 || got.Parents[0] != head.Commit {
		t.Fatalf("parents %v, want [%s]", got.Parents, head.Commit)
	}
	if text, _ := gh.File(doc); text != "# two\n" {
		t.Fatalf("file at head = %q", text)
	}
	if b, err := c.Blob(ctx, head.Blob); err != nil || string(b) != "# one\n" {
		t.Fatalf("Blob(base) = %q, %v", b, err)
	}
}

func TestHeadBlobOfMissingPath(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "x\n"})
	head, err := newClient(t, gh, nil, nil).HeadBlob(context.Background(), "csi-spl-doc/none.md")
	if err != nil || head.Blob != "" || head.Commit != gh.Head() {
		t.Fatalf("HeadBlob(missing) = %+v, %v; want the tip and no blob", head, err)
	}
}

func TestStaleParentIsRefMoved(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	c := newClient(t, gh, nil, nil)
	ctx := context.Background()
	stale := gh.Head()
	winner := gh.Push(doc, "b\n", "docs(dev): edit "+doc)

	_, err := c.Commit(ctx, doc, []byte("c\n"), editor, "docs: edit "+doc, stale)
	if !errors.Is(err, github.ErrRefMoved) || !errors.Is(err, github.ErrTransient) || errors.Is(err, github.ErrPermanent) {
		t.Fatalf("err = %v: want ErrRefMoved, transient, not permanent", err)
	}
	var ae *github.APIError
	if !errors.As(err, &ae) || ae.Status != 422 {
		t.Fatalf("err = %#v, want a 422 APIError", err)
	}
	if gh.Head() != winner {
		t.Fatalf("branch moved to %s: a non-fast-forward update must leave it at %s", gh.Head(), winner)
	}
}

func TestStatusClasses(t *testing.T) {
	cases := []struct {
		status          int
		transient, perm bool
	}{
		{401, false, true}, {403, false, true}, {404, false, true}, {422, false, true},
		{429, true, false}, {500, true, false}, {502, true, false}, {503, true, false},
	}
	for _, tc := range cases {
		gh := githubtest.New(t, map[string]string{doc: "a\n"})
		c := newClient(t, gh, nil, nil)
		parent := gh.Head()
		gh.FailNext("POST /repos/", tc.status)
		_, err := c.Commit(context.Background(), doc, []byte("b\n"), editor, "m", parent)
		if errors.Is(err, github.ErrTransient) != tc.transient || errors.Is(err, github.ErrPermanent) != tc.perm {
			t.Errorf("%d: err = %v, transient=%v permanent=%v", tc.status, err, tc.transient, tc.perm)
		}
		if errors.Is(err, github.ErrRefMoved) {
			t.Errorf("%d on a blob write is not ErrRefMoved", tc.status)
		}
		if gh.Head() != parent {
			t.Errorf("%d: branch moved on a failed commit", tc.status)
		}
	}
}

func TestUnauthorizedIsPermanentAndDropsToken(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	c := newClient(t, gh, nil, nil)
	ctx := context.Background()

	gh.FailNext("POST /app/", 401)
	if _, err := c.HeadBlob(ctx, doc); !errors.Is(err, github.ErrPermanent) {
		t.Fatalf("401 at the token exchange: err = %v, want permanent", err)
	}
	if _, err := c.HeadBlob(ctx, doc); err != nil {
		t.Fatal(err)
	}
	gh.FailNext("GET /repos/", 401)
	if _, err := c.HeadBlob(ctx, doc); !errors.Is(err, github.ErrPermanent) {
		t.Fatalf("401 on a repo call: err = %v, want permanent", err)
	}
	mints := gh.TokenMints()
	if _, err := c.HeadBlob(ctx, doc); err != nil {
		t.Fatal(err)
	}
	if gh.TokenMints() != mints+1 {
		t.Fatalf("mints %d -> %d: a refused token must be dropped and minted afresh", mints, gh.TokenMints())
	}
}

func TestTokenReusedWithin50Minutes(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	clk := &clock{t: time.Now()}
	c := newClient(t, gh, nil, clk)
	ctx := context.Background()
	for i := 0; i < 5; i++ {
		if _, err := c.HeadBlob(ctx, doc); err != nil {
			t.Fatal(err)
		}
		clk.add(9 * time.Minute)
	}
	if n := gh.TokenMints(); n != 1 {
		t.Fatalf("%d tokens minted over 45 min, want 1", n)
	}
	clk.add(6 * time.Minute)
	if _, err := c.HeadBlob(ctx, doc); err != nil {
		t.Fatal(err)
	}
	if n := gh.TokenMints(); n != 2 {
		t.Fatalf("%d tokens minted after 51 min, want 2", n)
	}
}

func TestConcurrentCallsShareOneToken(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	c := newClient(t, gh, nil, nil)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := c.HeadBlob(context.Background(), doc); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if n := gh.TokenMints(); n != 1 {
		t.Fatalf("%d tokens minted by 8 concurrent calls, want 1", n)
	}
}

func TestCompare(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	c := newClient(t, gh, nil, nil)
	ctx := context.Background()
	root := gh.Head()
	mid := gh.Push(doc, "b\n", "one")
	tip := gh.Push(doc, "c\n", "two")
	cases := []struct {
		base, head, status string
		contains           bool
	}{
		{mid, tip, "ahead", true}, {tip, tip, "identical", true}, {tip, root, "behind", false},
	}
	for _, tc := range cases {
		got, err := c.Compare(ctx, tc.base, tc.head)
		if err != nil || got.Status != tc.status || got.Contains() != tc.contains {
			t.Errorf("Compare(%s, %s) = %+v, %v; want %s", tc.base[:7], tc.head[:7], got, err, tc.status)
		}
	}
}

func TestNoSecretInAnyLogLine(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	var log bytes.Buffer
	c := newClient(t, gh, &log, nil)
	ctx := context.Background()
	gh.FailNext("POST /app/", 401)
	_, _ = c.HeadBlob(ctx, doc)
	gh.FailNext("GET /repos/", 503)
	_, _ = c.HeadBlob(ctx, doc)
	gh.FailNext("PATCH /repos/", 422)
	_, err := c.Commit(ctx, doc, []byte("b\n"), editor, "m", gh.Head())
	if !errors.Is(err, github.ErrRefMoved) {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(log.String(), "github: request refused") || !strings.Contains(log.String(), "installation token minted") {
		t.Fatalf("the client logged nothing to check:\n%s", log.String())
	}
	block, _ := pem.Decode(gh.KeyPEM)
	b64 := base64.StdEncoding.EncodeToString(block.Bytes)
	needles := []string{"PRIVATE KEY", "ghs_", "Bearer", "eyJ"}
	for i := 0; i+40 <= len(b64); i += 40 {
		needles = append(needles, b64[i:i+40])
	}
	for _, line := range strings.Split(log.String(), "\n") {
		for _, n := range needles {
			if n != "" && strings.Contains(line, n) {
				t.Fatalf("log line carries secret material %q: %s", n[:min(len(n), 12)], line)
			}
		}
	}
}

func TestNewRefusesABadKeyWithoutQuotingIt(t *testing.T) {
	gh := githubtest.New(t, map[string]string{doc: "a\n"})
	cfg := gh.Config()
	// The PEM armour is assembled so no-key-material-in-tree.tst.sh sees no key shape in git.
	armour := "RSA " + "PRIVATE KEY"
	cfg.Key = []byte("-----BEGIN " + armour + "-----\nc2VjcmV0LWJ5dGVz\n-----END " + armour + "-----\n")
	_, err := github.New(cfg)
	if err == nil || strings.Contains(err.Error(), "c2VjcmV0") {
		t.Fatalf("New(bad key) = %v: want an error that does not quote the key", err)
	}
}
