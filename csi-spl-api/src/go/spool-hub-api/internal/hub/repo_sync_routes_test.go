package hub_test

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 releases-projects.md row B-6b part 2 (SPL-6006): "Sync now" and
// the GitHub webhook. RED CONTROLS: a non-admin's "Sync now", another
// workspace's slug and an unregistered one reach no GitHub call
// (TestRepoSyncNowRoute); a bad signature and a body over 1 MiB start no
// sync (TestGitHubWebhook, C2: raise repoSyncWebhookMax and the 413 case
// fails); a second webhook while one sync is in flight, or while the repo's
// lock is held, starts none (TestGitHubWebhookBounded, C1: drop the
// LoadOrStore check in startHookSync and it fails); off by default
// (TestRepoSyncOffByDefault).

const hookSecret = "test-hook-secret"

func syncNowPath(slug string) string { return "/v1/repos/" + slug + "/sync" }

func TestRepoSyncNowRoute(t *testing.T) {
	e, tid, fake := repoSyncEnv(t)
	dev := seat(t, e, tid, rbac.Developer)
	admin := seat(t, e, tid, rbac.Admin)
	a := repoOf(tid, "api")
	registerRepo(t, e, tid, a, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("n1", "feat(api): now", 1, "api/a.go")}})
	other, _ := e.tenant()
	theirs := repoOf(other, "api")
	registerRepo(t, e, other, theirs, true)

	fake.ResetCalls()
	if code, body := call(t, e, tid, http.MethodPost, syncNowPath(a), dev, nil); code != http.StatusForbidden {
		t.Errorf("a developer's Sync now: %d %v, want 403", code, body)
	}
	for _, slug := range []string{theirs, "csitea/nosuch"} {
		if code, body := call(t, e, tid, http.MethodPost, syncNowPath(slug), admin, nil); code != http.StatusNotFound || body["error"] != "not_registered" {
			t.Errorf("Sync now of %s: %d %v, want 404 not_registered", slug, code, body)
		}
	}
	if calls := fake.Calls(); len(calls) != 0 {
		t.Errorf("a refused Sync now called GitHub: %v", calls)
	}
	code, body := call(t, e, tid, http.MethodPost, syncNowPath(a), admin, nil)
	if code != http.StatusOK || body["stored"] != float64(1) || body["sync_status"] != "ok" {
		t.Fatalf("the admin's Sync now: %d %v, want 200, 1 stored, ok", code, body)
	}
	release, held, err := e.st.(store.RepoSync).TryRepoSyncLock(context.Background(), a)
	if err != nil || !held {
		t.Fatalf("lock: %v %v", held, err)
	}
	defer release()
	if code, body := call(t, e, tid, http.MethodPost, syncNowPath(a), admin, nil); code != http.StatusConflict || body["error"] != "sync_busy" {
		t.Errorf("Sync now while the lock is held: %d %v, want 409 sync_busy", code, body)
	}
}

// hook posts a signed (or not) webhook event.
func hook(t *testing.T, e *env, tid, event string, body []byte, secret string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/webhooks/github", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", event)
	if secret != "" {
		m := hmac.New(sha256.New, []byte(secret))
		m.Write(body)
		req.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(m.Sum(nil)))
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func ghHookBody(slug, ref string) []byte {
	b, _ := json.Marshal(map[string]any{"ref": ref, "repository": map[string]string{"full_name": slug}})
	return b
}

// waitState waits for the row's sync_status to become want.
func waitState(t *testing.T, e *env, tid, slug, want string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if syncTarget(t, e, tid, slug).SyncStatus == want {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%s: sync_status never %s", slug, want)
}

func hookEnv(t *testing.T, rs func(app *github.RepoApp) *hub.RepoSync) (*env, string, *githubtest.Repos) {
	t.Helper()
	fake := githubtest.NewRepos(t)
	app, err := github.NewRepoApp(github.RepoAppConfig{API: fake.URL, AppID: githubtest.AppID, Key: fake.KeyPEM})
	if err != nil {
		t.Fatal(err)
	}
	e, tid, _ := releaseEnv(t, func(o *hub.Options) {
		o.RepoSync = rs(app)
		o.RepoSyncWebhookSecret = hookSecret
	})
	return e, tid, fake
}

func TestGitHubWebhook(t *testing.T) {
	e, tid, fake := hookEnv(t, func(app *github.RepoApp) *hub.RepoSync { return hub.GitHubRepoSync(app, githubtest.InstallationID) })
	a := repoOf(tid, "api")
	registerRepo(t, e, tid, a, false)
	fake.Put(a, &githubtest.FakeRepo{Installation: githubtest.InstallationID, Commits: []githubtest.FakeCommit{
		fakeCommit("w1", "feat(api): hooked", 1, "api/a.go")}})
	fake.ResetCalls()

	if code, _ := hook(t, e, tid, "ping", []byte(`{"zen":"x"}`), hookSecret); code != http.StatusNoContent {
		t.Errorf("ping: %d, want 204", code)
	}
	if code, body := hook(t, e, tid, "push", ghHookBody(a, "refs/heads/main"), "wrong-secret"); code != http.StatusUnauthorized || body["error"] != "bad_signature" {
		t.Errorf("a wrong signature: %d %v, want 401 bad_signature", code, body)
	}
	if code, _ := hook(t, e, tid, "push", ghHookBody(a, "refs/heads/main"), ""); code != http.StatusUnauthorized {
		t.Errorf("no signature: %d, want 401", code)
	}
	big := ghHookBody(a, "refs/heads/main")
	big = append(big[:len(big)-1], []byte(`,"pad":"`+strings.Repeat("x", 1<<20)+`"}`)...)
	if code, body := hook(t, e, tid, "push", big, hookSecret); code != http.StatusRequestEntityTooLarge {
		t.Errorf("a body over 1 MiB: %d %v, want 413", code, body)
	}
	if code, body := hook(t, e, tid, "push", ghHookBody("csitea/nosuch", "refs/heads/main"), hookSecret); code != http.StatusAccepted || body["started"] != float64(0) {
		t.Errorf("an unregistered repo: %d %v, want 202 started 0", code, body)
	}
	if code, body := hook(t, e, tid, "push", ghHookBody(a, "refs/heads/feature"), hookSecret); code != http.StatusAccepted || body["started"] != float64(0) {
		t.Errorf("a push off trunk: %d %v, want 202 started 0", code, body)
	}
	if calls := fake.Calls(); len(calls) != 0 {
		t.Errorf("refused or ignored webhooks called GitHub: %v", calls)
	}
	if code, body := hook(t, e, tid, "push", ghHookBody(strings.ToUpper(a), "refs/heads/main"), hookSecret); code != http.StatusAccepted || body["started"] != float64(1) {
		t.Fatalf("a push to trunk: %d %v, want 202 started 1", code, body)
	}
	waitState(t, e, tid, a, "ok")
	if st := syncTarget(t, e, tid, a); st.LastSyncedSHA != syncSHA("w1") {
		t.Errorf("after the webhook: %+v, want cursor w1", st)
	}
}

// blockReader is a reader whose Tags waits for gate: a sync in flight.
type blockReader struct{ gate chan struct{} }

func (b blockReader) CommitsSince(context.Context, string, string, int) ([]github.RepoCommit, bool, error) {
	return nil, false, nil
}
func (b blockReader) CommitTopFolder(context.Context, string) (string, error) { return "", nil }
func (b blockReader) Tags(ctx context.Context) ([]github.RepoTag, error) {
	select {
	case <-b.gate:
	case <-ctx.Done():
	}
	return nil, nil
}
func (b blockReader) Releases(context.Context) ([]github.RepoRelease, error) { return nil, nil }

// C1: one webhook sync in flight per (workspace, repo); a held repo lock
// drops the trigger with no read.
func TestGitHubWebhookBounded(t *testing.T) {
	gate := make(chan struct{})
	var opens atomic.Int64
	e, tid, _ := hookEnv(t, func(*github.RepoApp) *hub.RepoSync {
		return &hub.RepoSync{Open: func(store.RepoSyncTarget) (hub.RepoSyncReader, error) {
			opens.Add(1)
			return blockReader{gate: gate}, nil
		}}
	})
	a, b := repoOf(tid, "api"), repoOf(tid, "wui")
	registerRepo(t, e, tid, a, false)
	registerRepo(t, e, tid, b, false)

	if _, body := hook(t, e, tid, "release", ghHookBody(a, ""), hookSecret); body["started"] != float64(1) {
		t.Fatalf("the first webhook: %v, want started 1", body)
	}
	for i := 0; i < 100 && opens.Load() == 0; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	if _, body := hook(t, e, tid, "release", ghHookBody(a, ""), hookSecret); body["started"] != float64(0) {
		t.Errorf("a second webhook while the first is in flight: %v, want started 0", body)
	}
	close(gate)
	waitState(t, e, tid, a, "ok")

	release, held, err := e.st.(store.RepoSync).TryRepoSyncLock(context.Background(), b)
	if err != nil || !held {
		t.Fatalf("lock: %v %v", held, err)
	}
	before := opens.Load()
	hook(t, e, tid, "release", ghHookBody(b, ""), hookSecret)
	time.Sleep(200 * time.Millisecond)
	release()
	if got := opens.Load(); got != before {
		t.Errorf("a webhook while the repo's lock is held read the repo (%d opens), want it dropped", got-before)
	}
	if st := syncTarget(t, e, tid, b); st.SyncStatus != "pending" {
		t.Errorf("the dropped trigger wrote state: %+v", st)
	}
}

// N3 (R7 of SPL-5808): with no RepoSync (the default: cnf
// SPOOL_HUB_REPO_SYNC_ENABLED false, internal/config TestRepoSyncOffByDefault)
// the loop returns at once, "Sync now" is 503 and the webhook is not
// mounted, even with a secret.
func TestRepoSyncOffByDefault(t *testing.T) {
	e, tid, _ := releaseEnv(t, func(o *hub.Options) { o.RepoSyncWebhookSecret = hookSecret })
	admin := seat(t, e, tid, rbac.Admin)
	done := make(chan struct{})
	go func() { e.srv.RunRepoSync(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunRepoSync with the sync off did not return")
	}
	if code, body := call(t, e, tid, http.MethodPost, syncNowPath(repoOf(tid, "main")), admin, nil); code != http.StatusServiceUnavailable || body["error"] != "repo_sync_off" {
		t.Errorf("Sync now with the sync off: %d %v, want 503 repo_sync_off", code, body)
	}
	if code, _ := hook(t, e, tid, "push", ghHookBody(repoOf(tid, "main"), "refs/heads/main"), hookSecret); code != http.StatusNotFound && code != http.StatusMethodNotAllowed {
		t.Errorf("the webhook with the sync off: %d, want not mounted (404/405)", code)
	}
}
