package hub_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 releases-projects.md row B-6b (SPL-5808): the hub's own GitHub
// sync. Test: two repos of one workspace served by a fake GitHub, both
// tagged v1.0.0 on different commits: the versions stay per repo; a second
// sync sends only the new commits; a later tag versions the stored ones.
// RED CONTROLS: a row stored around buildRows keeps a banned word
// (TestRepoSyncEveryRowFiltered fails); a slug registered for another
// workspace is refused before any GitHub call (TestRepoSyncRefusesAnotherWorkspace).

// syncSHA is a fixture commit id, unique per test (the hub tests share one
// Postgres database).
func syncSHA(name string) string {
	h := sha256.Sum256([]byte(releaseSalt + "/" + name))
	return hex.EncodeToString(h[:20])
}

// repoSyncEnv is releaseEnv with the sync on, reading the fake through the App
// installation githubtest.InstallationID.
func repoSyncEnv(t *testing.T) (*env, string, *githubtest.Repos) {
	t.Helper()
	fake := githubtest.NewRepos(t)
	app, err := github.NewRepoApp(github.RepoAppConfig{API: fake.URL, AppID: githubtest.AppID, Key: fake.KeyPEM})
	if err != nil {
		t.Fatal(err)
	}
	e, tid, _ := releaseEnv(t, func(o *hub.Options) { o.RepoSync = hub.GitHubRepoSync(app, githubtest.InstallationID) })
	return e, tid, fake
}

// fakeCommit is a trunk commit at minute m of a fixed day.
func fakeCommit(name, msg string, m int, files ...string) githubtest.FakeCommit {
	return githubtest.FakeCommit{SHA: syncSHA(name), Message: msg, Files: files,
		At: time.Date(2026, 11, 19, 8, m, 0, 0, time.UTC)}
}

func syncRepo(t *testing.T, e *env, tid, slug string) hub.RepoSyncResult {
	t.Helper()
	res, err := e.srv.SyncRepo(context.Background(), tid, slug)
	if err != nil {
		t.Fatalf("sync %s: %v", slug, err)
	}
	return res
}

// syncTarget is the row the sync reads, with its written-back state.
func syncTarget(t *testing.T, e *env, tid, slug string) store.RepoSyncTarget {
	t.Helper()
	ts, err := e.st.(store.RepoSync).RepoSyncTargets(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range ts {
		if x.Tenant == tid && x.Slug == slug {
			return x
		}
	}
	t.Fatalf("no sync target %s/%s", tid, slug)
	return store.RepoSyncTarget{}
}

// listShas is the shas the repo's release note list answers, per version.
func listShas(t *testing.T, e *env, tid, repo string) map[string][]string {
	t.Helper()
	rows, err := e.st.(store.ReleaseNotes).ListReleaseNotes(context.Background(), tid, repo, "", store.ReleaseVersionsMax)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for _, n := range rows {
		out[n.Version] = append(out[n.Version], n.SHA)
	}
	for _, v := range out {
		slices.Sort(v)
	}
	return out
}

func shaSet(v ...string) []string { slices.Sort(v); return v }

func TestRepoSyncTwoReposVersionsPerRepo(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	a, b := repoOf(tid, "api"), repoOf(tid, "wui")
	registerRepo(t, e, tid, a, false)
	registerRepo(t, e, tid, b, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("a1", "feat(api): the cart", 1, "api/cart.go"),
		fakeCommit("a2", "fix: the total", 2, "svc/total.go", "svc/sum.go", "README.md"),
		fakeCommit("a3", "chore(api): tidy", 3, "api/x.go"),
	}})
	fake.Tag(a, "v1.0.0", syncSHA("a2"))
	fake.Tag(a, "not-a-version", syncSHA("a3"))
	fake.Put(b, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("b1", "feat(wui): the page", 4, "wui/page.vue"),
		fakeCommit("b2", "feat(wui): the menu", 5, "wui/menu.vue"),
	}})
	fake.Tag(b, "v1.0.0", syncSHA("b1"))

	if r := syncRepo(t, e, tid, a); r.Stored != 3 || r.Rejected != 0 {
		t.Fatalf("first sync of %s: %+v, want 3 stored", a, r)
	}
	if r := syncRepo(t, e, tid, b); r.Stored != 2 {
		t.Fatalf("first sync of %s: %+v, want 2 stored", b, r)
	}
	want := map[string]map[string][]string{
		a: {"v1.0.0": shaSet(syncSHA("a1"), syncSHA("a2"))},
		b: {"v1.0.0": {syncSHA("b1")}},
	}
	for repo, w := range want {
		if got := listShas(t, e, tid, repo); !mapsEqual(got, w) {
			t.Errorf("versions of %s: %v, want %v (versions stay per repo)", repo, got, w)
		}
	}
	if n := storedNote(t, e, tid, a, syncSHA("a3")); n.Version != "" {
		t.Errorf("a3 after the last tag: version %q, want none", n.Version)
	}
	if n := storedNote(t, e, tid, a, syncSHA("a2")); n.Area != "svc" {
		t.Errorf("a2 has no scope: area %q, want its top folder svc", n.Area)
	}
	if st := syncTarget(t, e, tid, a); st.LastSyncedSHA != syncSHA("a3") || st.SyncStatus != "ok" {
		t.Errorf("state of %s: %+v, want cursor a3 and ok", a, st)
	}

	// The second sync sends only the new commit.
	fake.Push(a, fakeCommit("a4", "perf: faster", 6, "svc/fast.go"))
	fake.ResetCalls()
	if r := syncRepo(t, e, tid, a); r.Stored != 1 || r.Cursor != syncSHA("a4") {
		t.Fatalf("second sync of %s: %+v, want 1 stored, cursor a4", a, r)
	}
	if r := syncRepo(t, e, tid, b); r.Stored != 0 {
		t.Fatalf("second sync of %s: %+v, want 0 stored", b, r)
	}
	for _, c := range fake.Calls() {
		for _, old := range []string{"a1", "a2", "a3"} {
			if strings.HasSuffix(c, "/commits/"+syncSHA(old)) {
				t.Errorf("the second sync read old commit %s again: %s", old, c)
			}
		}
	}

	// A tag pushed later versions the stored commits it covers.
	fake.Tag(a, "v1.1.0", syncSHA("a4"))
	if r := syncRepo(t, e, tid, a); r.Stored != 0 || r.Versioned != 2 {
		t.Fatalf("sync after the tag: %+v, want 0 stored and 2 versioned", r)
	}
	if got := listShas(t, e, tid, a)["v1.1.0"]; !slices.Equal(got, shaSet(syncSHA("a3"), syncSHA("a4"))) {
		t.Errorf("v1.1.0 of %s: %v, want a3 and a4", a, got)
	}
}

func mapsEqual(a, b map[string][]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if !slices.Equal(v, b[k]) {
			return false
		}
	}
	return true
}

// Every synced row passes buildRows: a banned word is redacted.
func TestRepoSyncEveryRowFiltered(t *testing.T) {
	t.Setenv(hub.ReleaseNoteBansEnv, "forbiddenword")
	e, tid, fake := repoSyncEnv(t)
	a := repoOf(tid, "api")
	registerRepo(t, e, tid, a, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("f1", "feat(api): adds forbiddenword support", 1, "api/x.go"),
	}})
	if r := syncRepo(t, e, tid, a); r.Stored != 1 || r.Redacted != 1 {
		t.Fatalf("sync: %+v, want 1 stored and 1 redacted", r)
	}
	if n := storedNote(t, e, tid, a, syncSHA("f1")); strings.Contains(n.Subject, "forbiddenword") || !strings.Contains(n.Subject, "[redacted]") {
		t.Fatalf("stored subject %q keeps the banned word", n.Subject)
	}
}

// A slug registered for another workspace, or none, is refused before any
// GitHub call, and nothing is stored.
func TestRepoSyncRefusesAnotherWorkspace(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	other, _ := e.tenant()
	theirs := repoOf(other, "api")
	registerRepo(t, e, other, theirs, true)
	fake.Put(theirs, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("o1", "feat(api): theirs", 1, "api/x.go"),
	}})
	for _, slug := range []string{theirs, "csitea/nosuch", ""} {
		if _, err := e.srv.SyncRepo(context.Background(), tid, slug); !errors.Is(err, hub.ErrRepoSyncRefused) {
			t.Errorf("sync of %q as %s: %v, want ErrRepoSyncRefused", slug, tid, err)
		}
	}
	if calls := fake.Calls(); len(calls) != 0 {
		t.Errorf("a refused sync called GitHub: %v", calls)
	}
	if _, err := e.st.(store.ReleaseNotes).ReleaseNote(context.Background(), tid, theirs, syncSHA("o1")); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("their commit in %s: %v, want not found", tid, err)
	}
	if st := syncTarget(t, e, other, theirs); st.SyncStatus != "pending" {
		t.Errorf("their row's state moved: %+v", st)
	}
}

// setAuthMode sets a registered repo's auth_mode, the way each store allows.
func setAuthMode(t *testing.T, e *env, tid, slug, mode string) {
	t.Helper()
	switch s := e.st.(type) {
	case *store.Memory:
		s.SeedRepoSync(store.RepoSyncTarget{Tenant: tid, Slug: slug, AuthMode: mode})
	case *store.Postgres:
		ctx := context.Background()
		if err := pgx.BeginFunc(ctx, s.Pool(), func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE workspace_repos SET auth_mode = $3 WHERE tenant_id = $1 AND repo_slug = $2`, tid, slug, mode)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
}

// pat_kms has no sealed-token store yet: written back as an error; a public
// repo reads with no credential; an ingest_only repo is not the sync's.
func TestRepoSyncAuthModes(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	pat, pub, box := repoOf(tid, "pat"), repoOf(tid, "pub"), repoOf(tid, "box")
	for _, r := range []string{pat, pub, box} {
		registerRepo(t, e, tid, r, false)
	}
	setAuthMode(t, e, tid, pat, "pat_kms")
	setAuthMode(t, e, tid, pub, "public")
	setAuthMode(t, e, tid, box, "ingest_only")
	fake.Put(pub, &githubtest.FakeRepo{Public: true, Commits: []githubtest.FakeCommit{fakeCommit("p1", "feat(x): open", 1, "x/a.go")}})
	if _, err := e.srv.SyncRepo(context.Background(), tid, pat); err == nil || !strings.Contains(err.Error(), "pat_kms") {
		t.Errorf("pat_kms sync: %v, want the pat_kms error", err)
	}
	if st := syncTarget(t, e, tid, pat); st.SyncStatus != "error" {
		t.Errorf("pat_kms state: %+v, want error", st)
	}
	if r := syncRepo(t, e, tid, pub); r.Stored != 1 {
		t.Errorf("public sync: %+v, want 1 stored", r)
	}
	if _, err := e.srv.SyncRepo(context.Background(), tid, box); !errors.Is(err, hub.ErrRepoSyncRefused) {
		t.Errorf("ingest_only sync: %v, want ErrRepoSyncRefused", err)
	}
}

// RepoSyncOnce walks every synced repo; one repo's failure stops none
// (memory only: on the shared test database it would walk other tests' rows).
func TestRepoSyncOnceWalksEveryRepo(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	if _, ok := e.st.(*store.Memory); !ok {
		t.Skip("memory store only")
	}
	a := repoOf(tid, "api")
	registerRepo(t, e, tid, a, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{fakeCommit("w1", "feat(api): one", 1, "api/a.go")}})
	if err := e.srv.RepoSyncOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if st := syncTarget(t, e, tid, a); st.SyncStatus != "ok" || st.LastSyncedSHA != syncSHA("w1") {
		t.Errorf("%s after the tick: %+v, want ok at w1", a, st)
	}
	if st := syncTarget(t, e, tid, repoOf(tid, "main")); st.SyncStatus != "error" {
		t.Errorf("the repo the fake lacks: %+v, want error", st)
	}
}
