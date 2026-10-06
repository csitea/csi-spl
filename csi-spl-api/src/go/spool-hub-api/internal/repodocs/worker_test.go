package repodocs_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
	"github.com/csitea/csi-spl/spool-hub-api/internal/repodocs"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The worker of spec 075 repo-edit T10 against the T09 fake GitHub and the
// T06 store on Postgres (hub-pg.tst.sh gives this package its own
// database), one test per case of spec §12 "worker". No test reaches GitHub.

const doc = "csi-spl-doc/doc/md/example.md"

const base6 = "a\nb\nc\nd\ne\nf\n"

var (
	alice = github.Identity{Name: "FirstName LastName", Email: "alice@example.com"}
	bob   = github.Identity{Name: "FirstName LastName", Email: "bob@example.com"}
	deny  = []string{"**/CLAUDE.md", "csi-spl-wui/**"}
)

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

// message is the commit message the worker writes on dev (T07's
// CommitMessage); it names the edit_id, as the reclaim check needs.
func message(e store.RepoDocEdit) string {
	return "docs(dev): edit " + e.Path + "\n\nEdited in the Docs section of workspace " + e.TenantID +
		" (dev). Edit " + e.EditID + "."
}

type env struct {
	t      *testing.T
	pg     *store.Postgres
	gh     *githubtest.Server
	client *github.Client
	bucket blob.Dir
	clk    *clock
	tenant string
	w      *repodocs.Worker
}

func pgOnly(t *testing.T) *store.Postgres {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatalf("postgres: %v", err)
	}
	t.Cleanup(pg.Close)
	if dir := os.Getenv("SPOOL_TEST_SQL_DIR"); dir != "" {
		if _, err := store.Migrate(ctx, pg.Pool(), dir); err != nil {
			t.Fatalf("migrate: %v", err)
		}
	}
	wipe(t, pg)
	t.Cleanup(func() { wipe(t, pg) })
	return pg
}

// wipe empties the queue: the worker's claim is global, so no row of one
// test may be left for the next.
func wipe(t *testing.T, pg *store.Postgres) {
	err := pgx.BeginFunc(context.Background(), pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `DELETE FROM repo_doc_edits; DELETE FROM repo_doc_known_authors`)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func newEnv(t *testing.T, files map[string]string) *env {
	t.Helper()
	e := &env{t: t, pg: pgOnly(t), gh: githubtest.New(t, files), bucket: blob.Dir{Root: t.TempDir()},
		clk: &clock{t: time.Date(2001, 1, 1, 12, 0, 0, 0, time.UTC)}, tenant: "t-" + uuid.NewString()[:8]}
	var err error
	if e.client, err = github.New(e.gh.Config()); err != nil {
		t.Fatal(err)
	}
	e.w = e.worker(e.client, e.pg, e.bucket)
	return e
}

func (e *env) worker(repo repodocs.Repo, q repodocs.Queue, bucket blob.Store) *repodocs.Worker {
	e.t.Helper()
	w, err := repodocs.NewWorker(repodocs.WorkerConfig{Env: "dev", Queue: q, Repo: repo, Bucket: bucket, Deny: deny,
		Now: e.clk.now})
	if err != nil {
		e.t.Fatal(err)
	}
	return w
}

func (e *env) tick() { e.w.Tick(context.Background()) }

func (e *env) baseOf(path string) string {
	e.t.Helper()
	h, err := e.client.HeadBlob(context.Background(), path)
	if err != nil {
		e.t.Fatal(err)
	}
	return h.Blob
}

// save is what PUT /v1/docs/{path} does (T08): the overlay into the bucket,
// then the queued row.
func (e *env) save(human, path, text, base string, author github.Identity) store.RepoDocEdit {
	e.t.Helper()
	ctx := context.Background()
	id := uuid.NewString()
	key := repodocs.OverlayPrefix + path + "/" + id + ".md"
	if err := e.bucket.Put(ctx, key, []byte(text)); err != nil {
		e.t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(text))
	row, _, err := e.pg.InsertRepoDocEdit(ctx, store.RepoDocEdit{EditID: id, TenantID: e.tenant, HumanID: human,
		ActorKind: "member", Path: path, BaseBlob: base, OverlayKey: key, TextSHA256: hex.EncodeToString(sum[:]),
		AuthorName: author.Name, AuthorEmail: author.Email, AuthorSource: "signin"}, 2*time.Minute, 10*time.Minute, e.clk.now())
	if err != nil {
		e.t.Fatal(err)
	}
	return row
}

func (e *env) row(id string) store.RepoDocEdit {
	e.t.Helper()
	r, err := e.pg.GetRepoDocEdit(context.Background(), e.tenant, id)
	if err != nil {
		e.t.Fatal(err)
	}
	return r
}

func (e *env) file(path string) string {
	s, _ := e.gh.File(path)
	return s
}

func (e *env) commitsSince(root string) int {
	n := 0
	for sha := e.gh.Head(); sha != root && sha != ""; n++ {
		c, _ := e.gh.Commit(sha)
		if len(c.Parents) == 0 {
			break
		}
		sha = c.Parents[0]
	}
	return n
}

// TestWorkerPushesUnchangedBase: head still holds the base -> one commit of
// the saved text, authored by the editor and committed by the App, once
// the coalescing window has passed.
func TestWorkerPushesUnchangedBase(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	r := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	root := e.gh.Head()
	e.tick()
	if got := e.row(r.EditID); got.Status != store.RepoDocQueued || e.gh.Head() != root {
		t.Fatalf("pushed inside the coalescing window: %s", got.Status)
	}
	e.clk.add(2 * time.Minute)
	e.tick()
	got := e.row(r.EditID)
	if got.Status != store.RepoDocPushed || got.CommitSHA != e.gh.Head() || got.MergedWith != "" {
		t.Fatalf("row = %+v, head %s", got, e.gh.Head())
	}
	c, _ := e.gh.Commit(got.CommitSHA)
	if c.Author != alice || c.Committer.Name != githubtest.BotName || c.Message != message(r) {
		t.Fatalf("commit = %+v", c)
	}
	if e.file(doc) != "a\nB\nc\nd\ne\nf\n" || e.commitsSince(root) != 1 {
		t.Fatalf("master: %q, %d commits", e.file(doc), e.commitsSince(root))
	}
}

// TestWorkerMergesMovedHead: master moved on other lines -> the merged text
// is committed on the new head and the row records merged_with.
func TestWorkerMergesMovedHead(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	r := e.save("hum-a", doc, "A\nb\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	moved := e.gh.Push(doc, "a\nb\nc\nd\ne\nF\n", "docs: a lane's edit")
	e.clk.add(2 * time.Minute)
	e.tick()
	got := e.row(r.EditID)
	if got.Status != store.RepoDocPushed || got.MergedWith != moved || e.file(doc) != "A\nb\nc\nd\ne\nF\n" {
		t.Fatalf("row %+v, master %q", got, e.file(doc))
	}
	if c, _ := e.gh.Commit(got.CommitSHA); len(c.Parents) != 1 || c.Parents[0] != moved {
		t.Fatalf("not committed on the moved head: %+v", c)
	}
}

// TestWorkerConflictNoRefUpdate: master changed the same lines -> conflict,
// the ref does not move, the overlay stays.
func TestWorkerConflictNoRefUpdate(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	r := e.save("hum-a", doc, "a\nMINE\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	moved := e.gh.Push(doc, "a\nTHEIRS\nc\nd\ne\nf\n", "docs: a lane's edit")
	e.clk.add(2 * time.Minute)
	e.tick()
	got := e.row(r.EditID)
	if got.Status != store.RepoDocConflict || !strings.Contains(got.LastError, "same lines") || e.gh.Head() != moved {
		t.Fatalf("row %+v, head moved: %v", got, e.gh.Head() != moved)
	}
	if ok, _ := e.bucket.Exists(context.Background(), r.OverlayKey); !ok {
		t.Fatal("conflict dropped the overlay")
	}
}

// TestWorkerGatesMergedText: a clean merge whose bytes hit a text gate is a
// conflict, and the ref does not move.
func TestWorkerGatesMergedText(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	pem := "-----BEGIN RSA " + "PRIVATE KEY-----\n"
	r := e.save("hum-a", doc, "a\nb\nc\n"+pem+"d\ne\nf\n", e.baseOf(doc), alice)
	moved := e.gh.Push(doc, "A\nb\nc\nd\ne\nf\n", "docs: a lane's edit")
	e.clk.add(2 * time.Minute)
	e.tick()
	got := e.row(r.EditID)
	if got.Status != store.RepoDocConflict || !strings.Contains(got.LastError, "secret") || e.gh.Head() != moved {
		t.Fatalf("row %+v", got)
	}
}

// TestWorkerBacksOffOn5xx: a GitHub 5xx keeps the row queued for the first
// backoff step; the next try lands.
func TestWorkerBacksOffOn5xx(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	r := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	e.clk.add(2 * time.Minute)
	e.gh.FailNext("GET /repos/"+githubtest.Owner+"/"+githubtest.Repo+"/git/ref/", 503)
	e.tick()
	got := e.row(r.EditID)
	if got.Status != store.RepoDocQueued || got.Tries != 1 || !got.NextTryAt.Equal(e.clk.now().Add(30*time.Second)) ||
		!strings.Contains(got.LastError, "503") {
		t.Fatalf("after 503: %+v", got)
	}
	e.tick()
	if st := e.row(r.EditID).Status; st != store.RepoDocQueued {
		t.Fatalf("retried before its backoff: %s", st)
	}
	e.clk.add(30 * time.Second)
	e.tick()
	if got := e.row(r.EditID); got.Status != store.RepoDocPushed || got.CommitSHA != e.gh.Head() {
		t.Fatalf("after backoff: %+v", got)
	}
}

// TestWorkerFailsOn401: a revoked or missing App key is permanent: failed at
// once, nothing pushed.
func TestWorkerFailsOn401(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	r := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	root := e.gh.Head()
	e.clk.add(2 * time.Minute)
	e.gh.FailNext("GET /repos/"+githubtest.Owner+"/"+githubtest.Repo+"/git/ref/", 401)
	e.tick()
	if got := e.row(r.EditID); got.Status != store.RepoDocFailed || !strings.Contains(got.LastError, "401") || e.gh.Head() != root {
		t.Fatalf("after 401: %+v", got)
	}
}

// TestWorkerCoalesces: one author's saves inside coalesce_after are one
// commit of the newest text; a run of saves is capped at coalesce_max.
func TestWorkerCoalesces(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	b := e.baseOf(doc)
	root := e.gh.Head()
	first := e.save("hum-a", doc, "a\nB1\nc\nd\ne\nf\n", b, alice)
	var last store.RepoDocEdit
	// a save every 100 s: each restarts the 120 s window
	for i := 1; i <= 5; i++ {
		e.clk.add(100 * time.Second)
		e.tick()
		if e.gh.Head() != root {
			t.Fatalf("pushed mid-run after %d saves", i)
		}
		last = e.save("hum-a", doc, "a\nB"+string(rune('1'+i))+"\nc\nd\ne\nf\n", b, alice)
	}
	if st := e.row(first.EditID).Status; st != store.RepoDocSuperseded {
		t.Fatalf("first save is %s", st)
	}
	e.clk.add(99 * time.Second)
	e.tick()
	if e.gh.Head() != root {
		t.Fatal("pushed before the 10 min cap")
	}
	// 600 s after the first save: due at the cap, not 120 s after the last save
	e.clk.add(time.Second)
	e.tick()
	if got := e.row(last.EditID); got.Status != store.RepoDocPushed || e.commitsSince(root) != 1 ||
		e.file(doc) != "a\nB6\nc\nd\ne\nf\n" {
		t.Fatalf("at the cap: %+v, %d commits, %q", got, e.commitsSince(root), e.file(doc))
	}
}

// TestWorkerNeverCoalescesTwoAuthors: two authors' saves of one path are two
// commits, FIFO, each under its own author; the second merges onto the first.
func TestWorkerNeverCoalescesTwoAuthors(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	b := e.baseOf(doc)
	root := e.gh.Head()
	ra := e.save("hum-a", doc, "A\nb\nc\nd\ne\nf\n", b, alice)
	e.clk.add(time.Second)
	rb := e.save("hum-b", doc, "a\nb\nc\nd\ne\nF\n", b, bob)
	e.clk.add(2 * time.Minute)
	e.tick()
	e.tick()
	ga, gb := e.row(ra.EditID), e.row(rb.EditID)
	if ga.Status != store.RepoDocPushed || gb.Status != store.RepoDocPushed || gb.MergedWith != ga.CommitSHA {
		t.Fatalf("a %+v\nb %+v", ga, gb)
	}
	ca, _ := e.gh.Commit(ga.CommitSHA)
	cb, _ := e.gh.Commit(gb.CommitSHA)
	if ca.Author != alice || cb.Author != bob || e.commitsSince(root) != 2 || e.file(doc) != "A\nb\nc\nd\ne\nF\n" {
		t.Fatalf("authors %v %v, %d commits, %q", ca.Author, cb.Author, e.commitsSince(root), e.file(doc))
	}
}

// TestWorkerRefusesDeniedPathAndMissingOverlay: a path denied since the save,
// and an overlay gone from the bucket, are permanent failures.
func TestWorkerRefusesDeniedPathAndMissingOverlay(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6, "csi-spl-wui/x.md": "x\n"})
	denied := e.save("hum-a", "csi-spl-wui/x.md", "y\n", e.baseOf("csi-spl-wui/x.md"), alice)
	gone := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	if err := e.bucket.Delete(context.Background(), gone.OverlayKey); err != nil {
		t.Fatal(err)
	}
	root := e.gh.Head()
	e.clk.add(2 * time.Minute)
	e.tick()
	if got := e.row(denied.EditID); got.Status != store.RepoDocFailed || !strings.Contains(got.LastError, "path_denied") {
		t.Fatalf("denied: %+v", got)
	}
	if got := e.row(gone.EditID); got.Status != store.RepoDocFailed || !strings.Contains(got.LastError, "overlay missing") {
		t.Fatalf("missing overlay: %+v", got)
	}
	if e.gh.Head() != root {
		t.Fatal("a refused edit moved master")
	}
}

// TestWorkerReclaimNoDoubleCommit: a worker died holding a row. When its
// commit had landed, the reclaimed row is marked pushed with that commit and
// nothing is committed again; when it had not, the row is pushed once.
func TestWorkerReclaimNoDoubleCommit(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6, "csi-spl-doc/other.md": base6})
	ctx := context.Background()
	landed := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	lost := e.save("hum-b", "csi-spl-doc/other.md", "a\nb\nC\nd\ne\nf\n", e.baseOf("csi-spl-doc/other.md"), bob)
	e.clk.add(2 * time.Minute)
	claimed, err := e.pg.ClaimRepoDocEdits(ctx, 10, e.clk.now()) // the worker that dies
	if err != nil || len(claimed) != 2 {
		t.Fatalf("dead worker's claim: %d %v", len(claimed), err)
	}
	h, _ := e.client.HeadBlob(ctx, doc)
	sha, err := e.client.Commit(ctx, doc, []byte("a\nB\nc\nd\ne\nf\n"), alice, message(landed), h.Commit)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.add(5 * time.Minute)
	e.tick()
	if st := e.row(landed.EditID).Status; st != store.RepoDocPushing {
		t.Fatalf("reclaimed before 10 min: %s", st)
	}
	e.clk.add(6 * time.Minute)
	e.tick()
	gl, go2 := e.row(landed.EditID), e.row(lost.EditID)
	if gl.Status != store.RepoDocPushed || gl.CommitSHA != sha {
		t.Fatalf("landed: %+v (want commit %s)", gl, sha)
	}
	if go2.Status != store.RepoDocPushed || go2.CommitSHA != e.gh.Head() || e.commitsSince(sha) != 1 {
		t.Fatalf("lost: %+v, %d commits after the landed one", go2, e.commitsSince(sha))
	}
}

// TestWorkerPublishedSweep: a pushed row goes published once tree.json's sha
// contains its commit; each commit is compared once per tree.json sha.
func TestWorkerPublishedSweep(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6})
	ctx := context.Background()
	stale := e.gh.Head()
	r := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	e.clk.add(2 * time.Minute)
	e.tick()
	compares := func() int {
		n := 0
		for _, c := range e.gh.Calls() {
			if strings.Contains(c, "/compare/") {
				n++
			}
		}
		return n
	}
	putTree := func(sha string) {
		if err := e.bucket.Put(ctx, "tree.json", []byte(`{"v":1,"sha":"`+sha+`","files":[]}`)); err != nil {
			t.Fatal(err)
		}
	}
	putTree(stale)
	e.tick()
	e.tick()
	if st := e.row(r.EditID).Status; st != store.RepoDocPushed || compares() != 1 {
		t.Fatalf("stale tree: %s, %d compares", st, compares())
	}
	putTree(e.gh.Push("csi-spl-doc/later.md", "x\n", "docs: later"))
	e.tick()
	if st := e.row(r.EditID).Status; st != store.RepoDocPublished || compares() != 2 {
		t.Fatalf("newer tree: %s, %d compares", st, compares())
	}
}

// TestWorkerRefreshesKnownAuthors: the daily refresh reads master's authors
// through .mailmap; bots are left out.
func TestWorkerRefreshesKnownAuthors(t *testing.T) {
	mm := "FirstName LastName <canon@example.com> <alias@example.com>\n"
	e := newEnv(t, map[string]string{doc: base6, ".mailmap": mm})
	ctx := context.Background()
	h, _ := e.client.HeadBlob(ctx, doc)
	if _, err := e.client.Commit(ctx, doc, []byte("x\n"), github.Identity{Name: "Old Name", Email: "alias@example.com"},
		"docs: x", h.Commit); err != nil {
		t.Fatal(err)
	}
	e.tick()
	got, err := e.pg.LookupRepoDocKnownAuthor(ctx, "CANON@example.com")
	if err != nil || got.GitName != "FirstName LastName" || got.GitEmail != "canon@example.com" {
		t.Fatalf("canonical author: %+v %v", got, err)
	}
	if _, err := e.pg.LookupRepoDocKnownAuthor(ctx, "alias@example.com"); err == nil {
		t.Fatal("the alias address is known; .mailmap maps it away")
	}
	if _, err := e.pg.LookupRepoDocKnownAuthor(ctx, githubtest.BotEmail); err == nil {
		t.Fatal("the bot is a known author")
	}
}

// TestWorkerSweepsOldOverlays: after 30 days an overlay with no row, or of a
// published row, is deleted; one a row still needs (failed) and a fresh
// orphan are kept.
func TestWorkerSweepsOldOverlays(t *testing.T) {
	e := newEnv(t, map[string]string{doc: base6, "csi-spl-wui/x.md": "x\n"})
	ctx := context.Background()
	pub := e.save("hum-a", doc, "a\nB\nc\nd\ne\nf\n", e.baseOf(doc), alice)
	failed := e.save("hum-a", "csi-spl-wui/x.md", "y\n", e.baseOf("csi-spl-wui/x.md"), alice)
	e.clk.add(2 * time.Minute)
	e.tick()
	_ = e.bucket.Put(ctx, "tree.json", []byte(`{"sha":"`+e.gh.Head()+`"}`))
	e.tick()
	if e.row(pub.EditID).Status != store.RepoDocPublished || e.row(failed.EditID).Status != store.RepoDocFailed {
		t.Fatal("setup: rows not published / failed")
	}
	orphan := repodocs.OverlayPrefix + doc + "/" + uuid.NewString() + ".md"
	fresh := repodocs.OverlayPrefix + doc + "/" + uuid.NewString() + ".md"
	for _, k := range []string{orphan, fresh} {
		_ = e.bucket.Put(ctx, k, []byte("t\n"))
	}
	old := e.clk.now().Add(-31 * 24 * time.Hour)
	for _, k := range []string{orphan, pub.OverlayKey, failed.OverlayKey} {
		if err := os.Chtimes(e.bucket.Root+"/"+k, old, old); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.Chtimes(e.bucket.Root+"/"+fresh, e.clk.now(), e.clk.now())
	e.clk.add(25 * time.Hour)
	e.tick()
	for k, want := range map[string]bool{orphan: false, pub.OverlayKey: false, failed.OverlayKey: true, fresh: true} {
		if ok, _ := e.bucket.Exists(ctx, k); ok != want {
			t.Errorf("%s exists=%v, want %v", k, ok, want)
		}
	}
}
