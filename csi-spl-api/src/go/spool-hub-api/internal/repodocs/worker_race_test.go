package repodocs_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/repodocs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// memQueue is the OTHER env's database in the dev/prd race: one queue of its
// own, as prd's is not dev's. It keeps rows and verdicts only.
type memQueue struct {
	mu   sync.Mutex
	rows map[string]*store.RepoDocEdit
}

func (q *memQueue) ClaimRepoDocEdits(_ context.Context, _ int, now time.Time) ([]store.RepoDocEdit, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	var out []store.RepoDocEdit
	for _, r := range q.rows {
		if r.Status == store.RepoDocQueued && !r.NextTryAt.After(now) {
			r.Status = store.RepoDocPushing
			out = append(out, *r)
		}
	}
	return out, nil
}

func (q *memQueue) set(id string, f func(r *store.RepoDocEdit)) (store.RepoDocEdit, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	f(q.rows[id])
	return *q.rows[id], nil
}

func (q *memQueue) PushedRepoDocEdit(_ context.Context, id, sha, merged string, _ time.Time) (store.RepoDocEdit, error) {
	return q.set(id, func(r *store.RepoDocEdit) { r.Status, r.CommitSHA, r.MergedWith = store.RepoDocPushed, sha, merged })
}

func (q *memQueue) RetryLaterRepoDocEdit(_ context.Context, id, why string, _ time.Time) (store.RepoDocEdit, error) {
	return q.set(id, func(r *store.RepoDocEdit) { r.Status, r.LastError = store.RepoDocQueued, why })
}

func (q *memQueue) FailRepoDocEdit(_ context.Context, id, why string, _ time.Time) (store.RepoDocEdit, error) {
	return q.set(id, func(r *store.RepoDocEdit) { r.Status, r.LastError = store.RepoDocFailed, why })
}

func (q *memQueue) ConflictRepoDocEdit(_ context.Context, id, why string, _ time.Time) (store.RepoDocEdit, error) {
	return q.set(id, func(r *store.RepoDocEdit) { r.Status, r.LastError = store.RepoDocConflict, why })
}

func (q *memQueue) ReclaimRepoDocEdits(context.Context, time.Time, time.Time) ([]store.RepoDocEdit, error) {
	return nil, nil
}
func (q *memQueue) PushedRepoDocEdits(context.Context) ([]store.RepoDocEdit, error) { return nil, nil }
func (q *memQueue) PublishRepoDocEdits(context.Context, []string, time.Time) (int64, error) {
	return 0, nil
}
func (q *memQueue) NextRepoDocEditDue(context.Context) (time.Time, bool, error) {
	return time.Time{}, false, nil
}
func (q *memQueue) ReplaceRepoDocKnownAuthors(context.Context, []store.RepoDocKnownAuthor, time.Time) error {
	return nil
}
func (q *memQueue) RepoDocEditStatuses(context.Context, []string) (map[string]string, error) {
	return map[string]string{}, nil
}

// barrierRepo holds each worker's FIRST head read until both workers have
// read head: both then build on the same parent, and one ref update loses.
type barrierRepo struct {
	repodocs.Repo
	wg   *sync.WaitGroup
	once sync.Once
}

func (b *barrierRepo) HeadBlob(ctx context.Context, path string) (github.Head, error) {
	h, err := b.Repo.HeadBlob(ctx, path)
	b.once.Do(func() { b.wg.Done(); b.wg.Wait() })
	return h, err
}

// TestWorkerDevPrdRace: the dev and the prd worker (two databases, two
// buckets) push one doc on one fake repo at the same moment. The loser's
// fast-forward is refused (422), it re-reads head and merges onto the
// winner: both edits land, nothing is overwritten, two commits.
func TestWorkerDevPrdRace(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	ctx := context.Background()
	b := e.baseOf(doc)
	root := e.gh.Head()
	dev := e.save("hum-a", doc, "A\nb\nc\nd\ne\nf\n", b, alice)

	prdBucket := blob.Dir{Root: t.TempDir()}
	prdText := "a\nb\nc\nd\ne\nF\n"
	sum := sha256.Sum256([]byte(prdText))
	prd := store.RepoDocEdit{EditID: uuid.NewString(), TenantID: "t-prd", HumanID: "hum-b", ActorKind: "member",
		Path: doc, BaseBlob: b, TextSHA256: hex.EncodeToString(sum[:]), AuthorName: bob.Name, AuthorEmail: bob.Email,
		Status: store.RepoDocQueued, NextTryAt: e.clk.now()}
	prd.OverlayKey = repodocs.OverlayPrefix + doc + "/" + prd.EditID + ".md"
	if err := prdBucket.Put(ctx, prd.OverlayKey, []byte(prdText)); err != nil {
		t.Fatal(err)
	}
	prdQ := &memQueue{rows: map[string]*store.RepoDocEdit{prd.EditID: &prd}}

	var wg sync.WaitGroup
	wg.Add(2)
	devW := e.worker(&barrierRepo{Repo: e.client, wg: &wg}, e.pg, e.bucket)
	prdClient, err := github.New(e.gh.Config())
	if err != nil {
		t.Fatal(err)
	}
	prdW := e.worker(&barrierRepo{Repo: prdClient, wg: &wg}, prdQ, prdBucket)
	e.clk.add(2 * time.Minute)
	var done sync.WaitGroup
	done.Add(2)
	go func() { defer done.Done(); devW.Tick(ctx) }()
	go func() { defer done.Done(); prdW.Tick(ctx) }()
	done.Wait()

	gd, gp := e.row(dev.EditID), prdQ.rows[prd.EditID]
	if gd.Status != store.RepoDocPushed || gp.Status != store.RepoDocPushed {
		t.Fatalf("dev %+v\nprd %+v", gd, gp)
	}
	if (gd.MergedWith == "") == (gp.MergedWith == "") {
		t.Fatalf("want exactly one merged push: dev merged_with %q, prd %q", gd.MergedWith, gp.MergedWith)
	}
	if e.file(doc) != "A\nb\nc\nd\ne\nF\n" || e.commitsSince(root) != 2 {
		t.Fatalf("master %q, %d commits", e.file(doc), e.commitsSince(root))
	}
}

// lockFn adapts the store's lock to the worker's.
func lockFn(pg *store.Postgres) func(context.Context) (repodocs.Session, bool, error) {
	return func(ctx context.Context) (repodocs.Session, bool, error) {
		s, ok, err := pg.LockRepoDocWorker(ctx)
		if !ok {
			return nil, ok, err
		}
		return s, ok, err
	}
}

// TestWorkerRunLockAndNotify: two instances of one env run; one holds the
// advisory lock. With an hour-long poll, a save's NOTIFY alone wakes the
// holder, and the edit is pushed exactly once.
func TestWorkerRunLockAndNotify(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	root := e.gh.Head()
	ctx, cancel := context.WithCancel(context.Background())
	var runs sync.WaitGroup
	for i := 0; i < 2; i++ {
		w, err := repodocs.NewWorker(repodocs.WorkerConfig{Env: "dev", Queue: e.pg, Repo: e.client, Bucket: e.bucket,
			Deny: deny, Now: func() time.Time { return e.clk.now().Add(5 * time.Minute) },
			Lock: lockFn(e.pg), Poll: time.Hour})
		if err != nil {
			t.Fatal(err)
		}
		runs.Add(1)
		go func() { defer runs.Done(); _ = w.Run(ctx) }()
	}
	defer func() { cancel(); runs.Wait() }()
	time.Sleep(300 * time.Millisecond) // both started: one holds the lock, both ran their first tick
	r := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	deadline := time.Now().Add(15 * time.Second)
	for e.row(r.EditID).Status != store.RepoDocPushed {
		if time.Now().After(deadline) {
			t.Fatalf("not pushed within 15 s of the NOTIFY: %+v", e.row(r.EditID))
		}
		time.Sleep(50 * time.Millisecond)
	}
	if e.commitsSince(root) != 1 {
		t.Fatalf("%d commits: two workers pushed", e.commitsSince(root))
	}
}
