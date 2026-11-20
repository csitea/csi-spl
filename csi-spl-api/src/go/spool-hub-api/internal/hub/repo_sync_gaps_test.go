package hub_test

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6006, the R7 findings of SPL-5808's part 1. N1: a cursor gone from
// trunk (a rewrite) or more than repoSyncBackfill commits behind is written
// back as an error, never ok; the rows read are stored and the cursor
// moves. RED CONTROL: drop the gap check in syncRepo (internal/hub/
// repo_sync.go, `!found`) and both cases read sync_status ok here.
func TestRepoSyncGapIsAnError(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	a, b := repoOf(tid, "api"), repoOf(tid, "big")
	registerRepo(t, e, tid, a, false)
	registerRepo(t, e, tid, b, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("g1", "feat(api): one", 1, "api/a.go"), fakeCommit("g2", "feat(api): two", 2, "api/b.go"),
	}})
	syncRepo(t, e, tid, a)

	// A force push: g2 is no longer on trunk.
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("g1", "feat(api): one", 1, "api/a.go"), fakeCommit("h2", "feat(api): two again", 3, "api/b.go"),
	}})
	res, err := e.srv.SyncRepo(context.Background(), tid, a)
	if err == nil || !strings.Contains(err.Error(), "not in the newest") || res.Stored != 2 {
		t.Fatalf("sync after a rewrite: %+v %v, want the 2 rows stored and the gap error (its text is sync_error)", res, err)
	}
	if st := syncTarget(t, e, tid, a); st.SyncStatus != "error" || st.LastSyncedSHA != syncSHA("h2") {
		t.Errorf("state after a rewrite: %+v, want error, cursor h2", st)
	}
	if r := syncRepo(t, e, tid, a); r.Stored != 0 || syncTarget(t, e, tid, a).SyncStatus != "ok" {
		t.Errorf("the next sync: %+v, want 0 stored and ok again", r)
	}

	// More than 2000 commits behind the cursor.
	fake.Put(b, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("k0", "feat(api): first", 0, "api/a.go")}})
	syncRepo(t, e, tid, b)
	for i := 1; i <= 2001; i++ {
		fake.Push(b, fakeCommit(fmt.Sprintf("k%d", i), fmt.Sprintf("feat(api): n%d", i), i, "api/a.go"))
	}
	if _, err := e.srv.SyncRepo(context.Background(), tid, b); err == nil {
		t.Errorf("a 2001-commit gap: no error")
	}
	if st := syncTarget(t, e, tid, b); st.SyncStatus != "error" || st.LastSyncedSHA != syncSHA("k2001") {
		t.Errorf("state after a 2001-commit gap: %+v, want error, cursor k2001", st)
	}
}

// countTargets counts the RepoSyncTargets reads of the memory store.
type countTargets struct {
	*store.Memory
	n atomic.Int64
}

func (c *countTargets) RepoSyncTargets(ctx context.Context) ([]store.RepoSyncTarget, error) {
	c.n.Add(1)
	return c.Memory.RepoSyncTargets(ctx)
}

// N2: one tick reads the targets once, not once more per repo. RED
// CONTROL: part 1's RepoSyncOnce (SyncRepo per target) reads 1 + 3 here.
func TestRepoSyncOnceReadsTargetsOnce(t *testing.T) {
	var cs *countTargets
	fake := githubtest.NewRepos(t)
	app, err := github.NewRepoApp(github.RepoAppConfig{API: fake.URL, AppID: githubtest.AppID, Key: fake.KeyPEM})
	if err != nil {
		t.Fatal(err)
	}
	e, tid, _ := releaseEnv(t, func(o *hub.Options) {
		if m, ok := o.Store.(*store.Memory); ok {
			cs = &countTargets{Memory: m}
			o.Store = cs
		}
		o.RepoSync = hub.GitHubRepoSync(app, githubtest.InstallationID)
	})
	if cs == nil {
		t.Skip("memory store only")
	}
	for _, n := range []string{"api", "wui"} {
		registerRepo(t, e, tid, repoOf(tid, n), false)
	}
	cs.n.Store(0)
	if err := e.srv.RepoSyncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := cs.n.Load(); got != 1 {
		t.Errorf("one tick over 3 repos read the targets %d times, want 1", got)
	}
}
