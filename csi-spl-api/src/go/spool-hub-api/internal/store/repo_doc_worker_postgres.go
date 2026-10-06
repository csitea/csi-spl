package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The repo-edit worker's hold on its env (spec 075 repo-edit section 3, task
// T10): one worker per env pushes, the one holding a session advisory lock;
// a second hub instance idles. The lock lives on ONE extra connection outside
// the pool (as ListenWake's), which also LISTENs for the NOTIFY
// InsertRepoDocEdit and RetryRepoDocEdit send, so the lock and the wake-up
// die together: a lost connection is a lost lock.

// RepoDocEditsChannel is the NOTIFY channel of a newly queued edit.
const RepoDocEditsChannel = "repo_doc_edits"

// repoDocWorkerLockKey names the env's one advisory lock.
const repoDocWorkerLockKey = `hashtextextended('repo_doc_edits/worker', 0)`

// RepoDocWorkerSession is the held lock and its listen connection.
type RepoDocWorkerSession struct{ conn *pgx.Conn }

// LockRepoDocWorker tries the env's worker lock. ok false: another instance
// holds it (nothing is kept open). The caller Closes a held session.
func (s *Postgres) LockRepoDocWorker(ctx context.Context) (*RepoDocWorkerSession, bool, error) {
	conn, err := pgx.ConnectConfig(ctx, s.pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, false, err
	}
	var got bool
	if err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(`+repoDocWorkerLockKey+`)`).Scan(&got); err == nil && got {
		_, err = conn.Exec(ctx, "LISTEN "+RepoDocEditsChannel)
	}
	if err != nil || !got {
		_ = conn.Close(context.Background())
		return nil, false, err
	}
	return &RepoDocWorkerSession{conn: conn}, true, nil
}

// Wait returns at the first NOTIFY of a queued edit or after d, whichever
// comes first (nil). An error is a lost connection: the lock is gone too.
func (w *RepoDocWorkerSession) Wait(ctx context.Context, d time.Duration) error {
	wctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()
	_, err := w.conn.WaitForNotification(wctx)
	if err != nil && ctx.Err() == nil && errors.Is(wctx.Err(), context.DeadlineExceeded) && !w.conn.IsClosed() {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

// Close releases the lock with its connection.
func (w *RepoDocWorkerSession) Close() error {
	return w.conn.Close(context.Background())
}

// RepoDocEditStatuses is the status of each edit of ids that has a row, of
// any workspace: the worker's 30-day overlay sweep keys a bucket object by
// its edit_id alone. An id with no row is absent from the map.
func (s *Postgres) RepoDocEditStatuses(ctx context.Context, ids []string) (map[string]string, error) {
	out := map[string]string{}
	if len(ids) == 0 {
		return out, nil
	}
	err := s.asOperatorQuery(ctx, `SELECT edit_id::text, status FROM repo_doc_edits WHERE edit_id::text = ANY($1)`,
		[]any{ids}, func(r pgx.Rows) error {
			var id, st string
			if err := r.Scan(&id, &st); err != nil {
				return err
			}
			out[id] = st
			return nil
		})
	return out, err
}
