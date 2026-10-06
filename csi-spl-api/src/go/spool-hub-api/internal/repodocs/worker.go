package repodocs

import (
	"context"
	"crypto/sha1" //nolint:gosec // git object ids are sha1 by definition
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The repo-edit worker (spec 075 repo-edit §3, §6-§8, §11; task T10): the
// env's one pusher. It holds the env's advisory lock, wakes on NOTIFY or a
// 30 s poll, and per tick: returns stuck pushing rows to the queue, claims
// due rows (the coalescing window is their next_try_at), pushes each one to
// master fast-forward only (3-way merging onto a moved head, gating the
// merged bytes again), marks pushed rows published once the env's
// tree.json holds them, refreshes the history's authors daily and sweeps
// overlays nothing serves any more after 30 days.

// Queue is the worker's half of the store (asOperator: every workspace).
type Queue interface {
	ClaimRepoDocEdits(ctx context.Context, limit int, now time.Time) ([]store.RepoDocEdit, error)
	PushedRepoDocEdit(ctx context.Context, editID, commitSHA, mergedWith string, now time.Time) (store.RepoDocEdit, error)
	RetryLaterRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (store.RepoDocEdit, error)
	FailRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (store.RepoDocEdit, error)
	ConflictRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (store.RepoDocEdit, error)
	ReclaimRepoDocEdits(ctx context.Context, staleBefore, now time.Time) ([]store.RepoDocEdit, error)
	PushedRepoDocEdits(ctx context.Context) ([]store.RepoDocEdit, error)
	PublishRepoDocEdits(ctx context.Context, commitSHAs []string, now time.Time) (int64, error)
	ReplaceRepoDocKnownAuthors(ctx context.Context, authors []store.RepoDocKnownAuthor, now time.Time) error
	RepoDocEditStatuses(ctx context.Context, ids []string) (map[string]string, error)
}

// Repo is the GitHub side (internal/github.Client; githubtest in tests).
type Repo interface {
	HeadBlob(ctx context.Context, path string) (github.Head, error)
	Blob(ctx context.Context, sha string) ([]byte, error)
	Commit(ctx context.Context, path string, content []byte, author github.Identity, message, parent string) (string, error)
	Compare(ctx context.Context, base, head string) (github.Comparison, error)
	Commits(ctx context.Context, n int) ([]github.CommitInfo, error)
}

// The production wiring satisfies both.
var (
	_ Queue = (*store.Postgres)(nil)
	_ Repo  = (*github.Client)(nil)
)

// Session is a held env lock (store.RepoDocWorkerSession): Wait returns on a
// wake-up or after d; an error means the lock is lost.
type Session interface {
	Wait(ctx context.Context, d time.Duration) error
	Close() error
}

// Defaults of WorkerConfig (spec §3, §5.1, §11).
const (
	DefaultPoll         = 30 * time.Second
	DefaultStale        = 10 * time.Minute
	DefaultOverlayKeep  = 30 * 24 * time.Hour
	DefaultRefreshEvery = 24 * time.Hour
	DefaultClaim        = 10
	// historyDepth is how many commits the daily author refresh and the
	// reclaim check read.
	historyDepth = 500
	reclaimDepth = 100
	// refMoveTries is how often one claim re-reads head after losing the
	// ref race (the other env's worker, a lane) before backing off.
	refMoveTries = 3
)

// WorkerConfig wires the worker. Env is dev or prd (the commit subject).
// Message builds an edit's commit message; nil is CommitMessage (T07). It
// must name the edit_id: the reclaim check looks for it on master.
type WorkerConfig struct {
	Env     string
	Queue   Queue
	Repo    Repo
	Bucket  blob.Store // the env's docs bucket: overlays and tree.json
	Lock    func(ctx context.Context) (Session, bool, error)
	Deny    []string
	Message func(e store.RepoDocEdit) string
	Log     zerolog.Logger
	Now     func() time.Time

	Poll, Stale, OverlayKeep, RefreshEvery time.Duration
	Claim                                  int
}

// Worker is one env's pusher. Tick is not safe for concurrent use; Run
// drives it.
type Worker struct {
	c WorkerConfig

	treeSHA     string          // the tree.json sha last swept
	checked     map[string]bool // pushed commits compared against treeSHA, not contained
	lastRefresh time.Time
	lastSweep   time.Time
}

// NewWorker checks the wiring and fills the defaults.
func NewWorker(c WorkerConfig) (*Worker, error) {
	if c.Queue == nil || c.Repo == nil || c.Bucket == nil {
		return nil, errors.New("repodocs: worker needs Queue, Repo and Bucket")
	}
	if c.Message == nil {
		if c.Env == "" {
			return nil, errors.New("repodocs: worker needs Env for its commit messages")
		}
		c.Message = func(e store.RepoDocEdit) string { return rowMessage(c.Env, e) }
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	def := func(d *time.Duration, v time.Duration) {
		if *d <= 0 {
			*d = v
		}
	}
	def(&c.Poll, DefaultPoll)
	def(&c.Stale, DefaultStale)
	def(&c.OverlayKeep, DefaultOverlayKeep)
	def(&c.RefreshEvery, DefaultRefreshEvery)
	if c.Claim <= 0 {
		c.Claim = DefaultClaim
	}
	return &Worker{c: c, checked: map[string]bool{}}, nil
}

// Run takes the env lock and ticks until ctx ends; without the lock (another
// instance pushes) it retries every Poll.
func (w *Worker) Run(ctx context.Context) error {
	if w.c.Lock == nil {
		return errors.New("repodocs: worker needs Lock")
	}
	for ctx.Err() == nil {
		sess, ok, err := w.c.Lock(ctx)
		if err != nil {
			w.c.Log.Warn().Err(err).Msg("repo-edit worker: lock")
		}
		if ok {
			w.lead(ctx, sess)
			_ = sess.Close()
		}
		select {
		case <-ctx.Done():
		case <-time.After(w.c.Poll):
		}
	}
	return nil
}

// lead ticks while the session holds the lock.
func (w *Worker) lead(ctx context.Context, sess Session) {
	w.c.Log.Info().Msg("repo-edit worker: holds the env lock")
	for {
		w.Tick(ctx)
		if err := sess.Wait(ctx, w.c.Poll); err != nil {
			if ctx.Err() == nil {
				w.c.Log.Warn().Err(err).Msg("repo-edit worker: lock lost")
			}
			return
		}
	}
}

// Tick is one pass: reclaim, push the due rows, the published sweep, and the
// daily author refresh and overlay sweep. Each step logs its own failure and
// the next still runs.
func (w *Worker) Tick(ctx context.Context) {
	now := w.c.Now()
	if rs, err := w.c.Queue.ReclaimRepoDocEdits(ctx, now.Add(-w.c.Stale), now); err != nil {
		w.c.Log.Warn().Err(err).Msg("repo-edit worker: reclaim")
	} else if len(rs) > 0 {
		w.c.Log.Warn().Int("n", len(rs)).Msg("repo-edit worker: reclaimed edits stuck in pushing")
	}
	rows, err := w.c.Queue.ClaimRepoDocEdits(ctx, w.c.Claim, now)
	if err != nil {
		w.c.Log.Warn().Err(err).Msg("repo-edit worker: claim")
	}
	for _, e := range rows {
		w.push(ctx, e)
	}
	if err := w.sweepPublished(ctx); err != nil {
		w.c.Log.Warn().Err(err).Msg("repo-edit worker: published sweep")
	}
	if now.Sub(w.lastRefresh) >= w.c.RefreshEvery {
		if err := w.refreshAuthors(ctx); err != nil {
			w.c.Log.Warn().Err(err).Msg("repo-edit worker: known authors refresh")
		} else {
			w.lastRefresh = now
		}
	}
	if now.Sub(w.lastSweep) >= w.c.RefreshEvery {
		if err := w.sweepOverlays(ctx); err != nil {
			w.c.Log.Warn().Err(err).Msg("repo-edit worker: overlay sweep")
		} else {
			w.lastSweep = now
		}
	}
}

// verdict is what one push attempt decided for its row.
type verdict struct {
	kind             string // pushed | retry | failed | conflict
	sha, merged, why string
}

// push takes one claimed row to its verdict and records it.
func (w *Worker) push(ctx context.Context, e store.RepoDocEdit) {
	v := w.attempt(ctx, e)
	for i := 1; v.kind == "refmoved" && i < refMoveTries; i++ {
		v = w.attempt(ctx, e)
	}
	now := w.c.Now()
	var err error
	switch v.kind {
	case "pushed":
		_, err = w.c.Queue.PushedRepoDocEdit(ctx, e.EditID, v.sha, v.merged, now)
	case "conflict":
		_, err = w.c.Queue.ConflictRepoDocEdit(ctx, e.EditID, v.why, now)
	case "failed":
		_, err = w.c.Queue.FailRepoDocEdit(ctx, e.EditID, v.why, now)
	default: // retry, refmoved
		_, err = w.c.Queue.RetryLaterRepoDocEdit(ctx, e.EditID, v.why, now)
	}
	ev := w.c.Log.Info()
	if err != nil {
		ev = w.c.Log.Warn().Err(err)
	}
	ev.Str("edit_id", e.EditID).Str("path", e.Path).Str("verdict", v.kind).Str("commit", v.sha).
		Str("reason", v.why).Msg("repo-edit worker: push")
}

// attempt is one try: the gates of the path and the text, the landed check,
// the head read, the merge and the fast-forward commit.
func (w *Worker) attempt(ctx context.Context, e store.RepoDocEdit) verdict {
	if !validPath(e.Path) {
		return verdict{kind: "failed", why: "path_denied: " + ReasonInvalidPath}
	}
	if g := deniedBy(e.Path, w.c.Deny); g != "" {
		return verdict{kind: "failed", why: "path_denied: " + ReasonDeniedBy + g}
	}
	mine, v, ok := w.overlay(ctx, e)
	if !ok {
		return v
	}
	if e.Tries > 0 || e.LastError != "" {
		if sha, err := w.landed(ctx, e.EditID); err != nil {
			return classify(err)
		} else if sha != "" {
			return verdict{kind: "pushed", sha: sha, why: "already on master"}
		}
	}
	head, err := w.c.Repo.HeadBlob(ctx, e.Path)
	if err != nil {
		return classify(err)
	}
	text, merged, v, ok := w.mergeOnto(ctx, e, head, mine)
	if !ok {
		return v
	}
	if text == nil { // master already holds exactly this text
		return verdict{kind: "pushed", sha: head.Commit, merged: merged, why: "no change on master"}
	}
	author := github.Identity{Name: e.AuthorName, Email: e.AuthorEmail}
	sha, err := w.c.Repo.Commit(ctx, e.Path, text, author, w.c.Message(e), head.Commit)
	if err != nil {
		return classify(err)
	}
	return verdict{kind: "pushed", sha: sha, merged: merged}
}

// overlay reads the saved text and checks it is the text the row recorded.
func (w *Worker) overlay(ctx context.Context, e store.RepoDocEdit) ([]byte, verdict, bool) {
	rc, err := w.c.Bucket.Get(ctx, e.OverlayKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, verdict{kind: "failed", why: "overlay missing: " + e.OverlayKey}, false
	}
	if err != nil {
		return nil, verdict{kind: "retry", why: "bucket: " + err.Error()}, false
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, 2<<20))
	if err != nil {
		return nil, verdict{kind: "retry", why: "bucket: " + err.Error()}, false
	}
	sum := sha256.Sum256(b)
	if e.TextSHA256 != "" && !strings.EqualFold(hex.EncodeToString(sum[:]), e.TextSHA256) {
		return nil, verdict{kind: "failed", why: "overlay does not match the saved text (text_sha256)"}, false
	}
	return b, verdict{}, true
}

// mergeOnto is the bytes to commit on head: the save as is when head still
// holds its base, else the 3-way merge of base, head and the save, gated
// again (two clean halves can join into a banned string). nil text with ok:
// head already holds the result. merged is head's commit when a merge ran.
func (w *Worker) mergeOnto(ctx context.Context, e store.RepoDocEdit, head github.Head, mine []byte) ([]byte, string, verdict, bool) {
	if head.Blob == e.BaseBlob {
		if head.Blob != "" && head.Blob == gitBlobSHA(mine) {
			return nil, "", verdict{}, true
		}
		return mine, "", verdict{}, true
	}
	var base, theirs []byte
	var err error
	if e.BaseBlob != "" {
		if base, err = w.c.Repo.Blob(ctx, e.BaseBlob); err != nil {
			return nil, "", classify(err), false
		}
	}
	if head.Blob == "" {
		return nil, "", verdict{kind: "conflict", why: "deleted on master at " + short(head.Commit)}, false
	}
	if theirs, err = w.c.Repo.Blob(ctx, head.Blob); err != nil {
		return nil, "", classify(err), false
	}
	text, ok := Merge3(base, theirs, mine)
	if !ok {
		return nil, "", verdict{kind: "conflict", why: "master changed the same lines at " + short(head.Commit)}, false
	}
	if hits := Gate(theirs, text); len(hits) > 0 {
		return nil, "", verdict{kind: "conflict", why: fmt.Sprintf("merged text rejected: %s %s line %d",
			hits[0].Kind, hits[0].Rule, hits[0].Line)}, false
	}
	if string(text) == string(theirs) {
		return nil, head.Commit, verdict{}, true
	}
	return text, head.Commit, verdict{}, true
}

// landed is the sha of a recent master commit whose message names editID:
// a worker that died after its ref update, or whose answer was lost, has
// pushed it already, and a repeat must not commit twice (spec §11).
func (w *Worker) landed(ctx context.Context, editID string) (string, error) {
	cs, err := w.c.Repo.Commits(ctx, reclaimDepth)
	if err != nil {
		return "", err
	}
	for _, c := range cs {
		if strings.Contains(c.Message, editID) {
			return c.SHA, nil
		}
	}
	return "", nil
}

// rowMessage is CommitMessage (spec §4.4) for a queued row: subject, blank
// line, body.
func rowMessage(env string, e store.RepoDocEdit) string {
	subject, body := CommitMessage(Edit{Env: env, Workspace: e.TenantID, Path: e.Path, EditID: e.EditID,
		AgentID: e.AgentID, Author: Author{Name: e.AuthorName, Email: e.AuthorEmail, Source: e.AuthorSource}})
	return subject + "\n\n" + body
}

// classify sorts a GitHub (or bucket) error into the verdicts of spec §3: a
// lost ref race is retried at once, other transient errors back off,
// permanent ones fail.
func classify(err error) verdict {
	switch {
	case errors.Is(err, github.ErrRefMoved):
		return verdict{kind: "refmoved", why: err.Error()}
	case errors.Is(err, github.ErrPermanent):
		return verdict{kind: "failed", why: err.Error()}
	}
	return verdict{kind: "retry", why: err.Error()}
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

// gitBlobSHA is git's blob id of b (`git hash-object`).
func gitBlobSHA(b []byte) string {
	// nosemgrep: go.lang.security.audit.crypto.use_of_weak_crypto.use-of-sha1 -- a git object id is sha1 by definition; it compares texts, it protects nothing.
	h := sha1.New() //nolint:gosec // git object id
	_, _ = fmt.Fprintf(h, "blob %d\x00", len(b))
	h.Write(b)
	return hex.EncodeToString(h.Sum(nil))
}
