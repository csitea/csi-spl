package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Editable repo docs (spec 075 repo-edit, task T06; rdb 0142): the save
// queue repo_doc_edits, the member's mapped git identity, the author-notice
// consents and the authors the repository history knows.
//
// Two callers, two scopes. The hub routes (T08) act for one workspace and run
// under inTenant. The worker (T10), the env's one pusher, drains the queue of
// every workspace and runs under asOperator: each such method is listed in
// operatorCallers. repo_doc_known_authors is hub-wide (public history, no
// tenant column, no RLS), so its calls use the pool directly.

// The states of repo_doc_edits.status (0142's CHECK; TestRepoDocEditsPinRdb).
const (
	RepoDocQueued     = "queued"     // in the bucket, push owed
	RepoDocPushing    = "pushing"    // the worker holds it
	RepoDocPushed     = "pushed"     // on master
	RepoDocPublished  = "published"  // tree.json holds a sha containing the commit
	RepoDocConflict   = "conflict"   // master changed the same lines; nothing pushed
	RepoDocFailed     = "failed"     // retries spent, or a permanent error
	RepoDocSuperseded = "superseded" // folded into a later edit's commit
)

// RepoDocStates is every status, in 0142's CHECK order.
var RepoDocStates = []string{RepoDocQueued, RepoDocPushing, RepoDocPushed, RepoDocPublished,
	RepoDocConflict, RepoDocFailed, RepoDocSuperseded}

// RepoDocBackoff is the wait before each retry of a transient push error
// (spec section 3): 7 tries over about 2 h, then failed.
var RepoDocBackoff = []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute,
	10 * time.Minute, 30 * time.Minute, time.Hour}

// RepoDocEdit is one save of a repo doc (one row of repo_doc_edits). HumanID
// is the member, or an agent's requester (spec section 4.3); AgentID is set
// iff ActorKind is "agent".
type RepoDocEdit struct {
	EditID       string
	TenantID     string
	HumanID      string
	ActorKind    string // member | agent
	AgentID      string
	Path         string
	BaseBlob     string
	OverlayKey   string
	TextSHA256   string
	AuthorName   string
	AuthorEmail  string
	AuthorSource string // mapping | history | signin
	TargetRef    string
	Status       string
	Tries        int
	NextTryAt    time.Time
	FirstSavedAt time.Time
	LastError    string
	CommitSHA    string
	MergedWith   string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

const repoDocEditCols = `edit_id::text, tenant_id, human_id, actor_kind, coalesce(agent_id, ''), path, base_blob,
	overlay_key, text_sha256, author_name, author_email, author_source, target_ref, status, tries, next_try_at,
	first_saved_at, coalesce(last_error, ''), coalesce(commit_sha, ''), coalesce(merged_with, ''), created_at, updated_at`

func scanRepoDocEdit(row pgx.Row) (RepoDocEdit, error) {
	var e RepoDocEdit
	err := row.Scan(&e.EditID, &e.TenantID, &e.HumanID, &e.ActorKind, &e.AgentID, &e.Path, &e.BaseBlob,
		&e.OverlayKey, &e.TextSHA256, &e.AuthorName, &e.AuthorEmail, &e.AuthorSource, &e.TargetRef, &e.Status,
		&e.Tries, &e.NextTryAt, &e.FirstSavedAt, &e.LastError, &e.CommitSHA, &e.MergedWith, &e.CreatedAt, &e.UpdatedAt)
	for _, t := range []*time.Time{&e.NextTryAt, &e.FirstSavedAt, &e.CreatedAt, &e.UpdatedAt} {
		*t = t.UTC()
	}
	return e, err
}

func collectRepoDocEdits(out *[]RepoDocEdit) func(pgx.Rows) error {
	return func(r pgx.Rows) error {
		e, err := scanRepoDocEdit(r)
		if err != nil {
			return err
		}
		*out = append(*out, e)
		return nil
	}
}

// InsertRepoDocEdit queues one save and folds it into the same author's
// queued run of the path (spec section 3): the queued rows of the same path,
// target ref, author identity, member and (for an agent) agent go superseded,
// the new row keeps the run's first_saved_at, and it is due coalesceAfter
// after this save, never later than coalesceMax after the run's first save.
// Two authors never fold. The author's conflict rows of the path are
// superseded too: a conflict is resolved by a new save (base = head).
// EditID, TenantID and the identity and text fields come from e; status,
// tries and the times are set here. It wakes the worker (NOTIFY) and returns
// the new row and the ids it superseded.
func (s *Postgres) InsertRepoDocEdit(ctx context.Context, e RepoDocEdit, coalesceAfter, coalesceMax time.Duration, now time.Time) (RepoDocEdit, []string, error) {
	if e.TargetRef == "" {
		e.TargetRef = "master"
	}
	var out RepoDocEdit
	var superseded []string
	err := s.inTenant(ctx, e.TenantID, func(tx pgx.Tx) error {
		superseded = nil
		// FOR UPDATE serialises two concurrent saves of one run.
		var run []RepoDocEdit
		if err := eachRow(ctx, tx, `SELECT `+repoDocEditCols+` FROM repo_doc_edits
			WHERE tenant_id = $1 AND path = $2 AND target_ref = $3 AND human_id = $4 AND actor_kind = $5
			  AND agent_id IS NOT DISTINCT FROM $6 AND author_name = $7 AND author_email = $8
			  AND status IN ('queued', 'conflict')
			ORDER BY created_at FOR UPDATE`,
			[]any{e.TenantID, e.Path, e.TargetRef, e.HumanID, e.ActorKind, nullText(e.AgentID), e.AuthorName, e.AuthorEmail},
			collectRepoDocEdits(&run)); err != nil {
			return err
		}
		first := now
		for _, r := range run {
			if r.Status == RepoDocQueued && r.FirstSavedAt.Before(first) {
				first = r.FirstSavedAt
			}
			superseded = append(superseded, r.EditID)
		}
		due := now.Add(coalesceAfter)
		if limit := first.Add(coalesceMax); due.After(limit) {
			due = limit
		}
		if len(superseded) > 0 {
			if _, err := tx.Exec(ctx, `UPDATE repo_doc_edits SET status = 'superseded', updated_at = $3
				WHERE tenant_id = $1 AND edit_id::text = ANY($2)`, e.TenantID, superseded, now); err != nil {
				return err
			}
		}
		var err error
		out, err = scanRepoDocEdit(tx.QueryRow(ctx, `INSERT INTO repo_doc_edits
			(edit_id, tenant_id, human_id, actor_kind, agent_id, path, base_blob, overlay_key, text_sha256,
			 author_name, author_email, author_source, target_ref, status, tries, next_try_at, first_saved_at,
			 created_at, updated_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'queued', 0, $14, $15, $16, $16)
			RETURNING `+repoDocEditCols,
			e.EditID, e.TenantID, e.HumanID, e.ActorKind, nullText(e.AgentID), e.Path, e.BaseBlob, e.OverlayKey,
			e.TextSHA256, e.AuthorName, e.AuthorEmail, e.AuthorSource, e.TargetRef, due, first, now))
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `SELECT pg_notify('repo_doc_edits', $1)`, out.EditID)
		return err
	})
	return out, superseded, err
}

// GetRepoDocEdit is one edit of the tenant (ErrNotFound when absent).
func (s *Postgres) GetRepoDocEdit(ctx context.Context, tenant, editID string) (RepoDocEdit, error) {
	var out []RepoDocEdit
	err := s.queryTenant(ctx, tenant, `SELECT `+repoDocEditCols+` FROM repo_doc_edits
		WHERE tenant_id = $1 AND edit_id::text = $2`, []any{tenant, editID}, collectRepoDocEdits(&out))
	if err != nil {
		return RepoDocEdit{}, err
	}
	if len(out) == 0 {
		return RepoDocEdit{}, ErrNotFound
	}
	return out[0], nil
}

// RepoDocEditFilter selects the rows of ListRepoDocEdits: HumanID ("My
// edits": the member's own and their agents' edits, which carry the
// requester as human_id), Path (one doc's edits), or both.
type RepoDocEditFilter struct {
	HumanID string
	Path    string
	Limit   int // default and cap 200
}

// ListRepoDocEdits is the tenant's edits matching f, newest first.
func (s *Postgres) ListRepoDocEdits(ctx context.Context, tenant string, f RepoDocEditFilter) ([]RepoDocEdit, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 200
	}
	out := []RepoDocEdit{}
	err := s.queryTenant(ctx, tenant, `SELECT `+repoDocEditCols+` FROM repo_doc_edits
		WHERE tenant_id = $1 AND ($2 = '' OR human_id = $2) AND ($3 = '' OR path = $3)
		ORDER BY created_at DESC, edit_id DESC LIMIT $4`, []any{tenant, f.HumanID, f.Path, f.Limit},
		collectRepoDocEdits(&out))
	return out, err
}

// RetryRepoDocEdit puts the tenant's failed edit back in the queue, due now,
// with its tries reset (the editor, the requester or an admin asked; the
// route checks who). ErrNotFound when absent, ErrConflict when not failed.
func (s *Postgres) RetryRepoDocEdit(ctx context.Context, tenant, editID string, now time.Time) (RepoDocEdit, error) {
	var out RepoDocEdit
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanRepoDocEdit(tx.QueryRow(ctx, `UPDATE repo_doc_edits
			SET status = 'queued', tries = 0, next_try_at = $3, last_error = NULL, updated_at = $3
			WHERE tenant_id = $1 AND edit_id::text = $2 AND status = 'failed'
			RETURNING `+repoDocEditCols, tenant, editID, now))
		if errors.Is(err, pgx.ErrNoRows) {
			var n int
			if err = tx.QueryRow(ctx, `SELECT count(*) FROM repo_doc_edits WHERE tenant_id = $1 AND edit_id::text = $2`,
				tenant, editID).Scan(&n); err != nil {
				return err
			}
			if n == 0 {
				return ErrNotFound
			}
			return ErrConflict
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `SELECT pg_notify('repo_doc_edits', $1)`, out.EditID)
		return err
	})
	return out, err
}

// RepoDocRates is the save counts the caps of spec section 5.1 read: the
// member's (agent edits count to the requester) and the agent's in the last
// hour, the workspace's in the last day.
type RepoDocRates struct {
	MemberHour   int
	AgentHour    int
	WorkspaceDay int
}

// RepoDocEditRates counts the tenant's saves for the caps; agentID "" counts
// no agent. Every save counts, superseded ones included: a cap bounds saves.
func (s *Postgres) RepoDocEditRates(ctx context.Context, tenant, humanID, agentID string, now time.Time) (RepoDocRates, error) {
	var r RepoDocRates
	hour, day := now.Add(-time.Hour), now.Add(-24*time.Hour)
	err := s.queryRowTenant(ctx, tenant, `SELECT
		count(*) FILTER (WHERE human_id = $2 AND created_at > $4),
		count(*) FILTER (WHERE $3 <> '' AND agent_id = $3 AND created_at > $4),
		count(*)
		FROM repo_doc_edits WHERE tenant_id = $1 AND created_at > $5`,
		[]any{tenant, humanID, agentID, hour, day}, &r.MemberHour, &r.AgentHour, &r.WorkspaceDay)
	return r, err
}

// RepoDocEditsEnvDay counts every workspace's saves since since, for the
// env-wide daily cap (300 on prd, 50 on dev). A count only: no row leaves.
func (s *Postgres) RepoDocEditsEnvDay(ctx context.Context, since time.Time) (int, error) {
	n := 0
	err := s.asOperatorQuery(ctx, `SELECT count(*) FROM repo_doc_edits WHERE created_at > $1`, []any{since},
		func(r pgx.Rows) error { return r.Scan(&n) })
	return n, err
}

// ClaimRepoDocEdits is the worker's claim: up to limit due queued rows go
// pushing, oldest first, each only when no older queued row and no pushing
// row holds its path and target ref (FIFO per path; a pushing row freezes its
// path). SKIP LOCKED lets a second claimer pass the rows the first one holds.
func (s *Postgres) ClaimRepoDocEdits(ctx context.Context, limit int, now time.Time) ([]RepoDocEdit, error) {
	out := []RepoDocEdit{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		out = out[:0]
		return eachRow(ctx, tx, `UPDATE repo_doc_edits SET status = 'pushing', updated_at = $2
			WHERE edit_id IN (
				SELECT e.edit_id FROM repo_doc_edits e
				 WHERE e.status = 'queued' AND e.next_try_at <= $2
				   AND NOT EXISTS (SELECT 1 FROM repo_doc_edits o
				                    WHERE o.path = e.path AND o.target_ref = e.target_ref
				                      AND (o.status = 'pushing'
				                           OR (o.status = 'queued' AND (o.created_at, o.edit_id) < (e.created_at, e.edit_id))))
				 ORDER BY e.created_at, e.edit_id
				 LIMIT $1
				 FOR UPDATE SKIP LOCKED)
			RETURNING `+repoDocEditCols, []any{limit, now}, collectRepoDocEdits(&out))
	})
	sortRepoDocEdits(out)
	return out, err
}

// sortRepoDocEdits orders rows oldest first (UPDATE ... RETURNING has no order).
func sortRepoDocEdits(es []RepoDocEdit) {
	sort.SliceStable(es, func(i, j int) bool {
		if !es[i].CreatedAt.Equal(es[j].CreatedAt) {
			return es[i].CreatedAt.Before(es[j].CreatedAt)
		}
		return es[i].EditID < es[j].EditID
	})
}

// repoDocTransition moves one pushing row on (the worker's verdict on its
// claim); ErrConflict when the row is not pushing (reclaimed, or never held).
func repoDocTransition(ctx context.Context, tx pgx.Tx, editID, set string, args ...any) (RepoDocEdit, error) {
	e, err := scanRepoDocEdit(tx.QueryRow(ctx, `UPDATE repo_doc_edits SET `+set+`
		WHERE edit_id::text = $1 AND status = 'pushing' RETURNING `+repoDocEditCols, append([]any{editID}, args...)...))
	if errors.Is(err, pgx.ErrNoRows) {
		return e, ErrConflict
	}
	return e, err
}

// PushedRepoDocEdit: the commit is on master. mergedWith is the head sha
// when a 3-way merge was needed, else "".
func (s *Postgres) PushedRepoDocEdit(ctx context.Context, editID, commitSHA, mergedWith string, now time.Time) (RepoDocEdit, error) {
	var out RepoDocEdit
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		out, err = repoDocTransition(ctx, tx, editID,
			`status = 'pushed', commit_sha = $2, merged_with = $3, last_error = NULL, updated_at = $4`,
			commitSHA, nullText(mergedWith), now)
		return err
	})
	return out, err
}

// RetryLaterRepoDocEdit: a transient error. The row goes back to queued with
// the next wait of RepoDocBackoff, or to failed once the tries are spent.
func (s *Postgres) RetryLaterRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (RepoDocEdit, error) {
	var out RepoDocEdit
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var tries int
		err := tx.QueryRow(ctx, `SELECT tries FROM repo_doc_edits WHERE edit_id::text = $1 AND status = 'pushing' FOR UPDATE`,
			editID).Scan(&tries)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrConflict
		}
		if err != nil {
			return err
		}
		if tries >= len(RepoDocBackoff) {
			out, err = repoDocTransition(ctx, tx, editID,
				`status = 'failed', tries = tries + 1, last_error = $2, updated_at = $3`, reason, now)
			return err
		}
		out, err = repoDocTransition(ctx, tx, editID,
			`status = 'queued', tries = tries + 1, next_try_at = $2, last_error = $3, updated_at = $4`,
			now.Add(RepoDocBackoff[tries]), reason, now)
		return err
	})
	return out, err
}

// FailRepoDocEdit: a permanent error (403 permission, 422 validation, path
// now denied); no retry.
func (s *Postgres) FailRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (RepoDocEdit, error) {
	var out RepoDocEdit
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		out, err = repoDocTransition(ctx, tx, editID, `status = 'failed', last_error = $2, updated_at = $3`, reason, now)
		return err
	})
	return out, err
}

// ConflictRepoDocEdit: master changed the same lines; nothing was pushed.
func (s *Postgres) ConflictRepoDocEdit(ctx context.Context, editID, reason string, now time.Time) (RepoDocEdit, error) {
	var out RepoDocEdit
	err := s.asOperator(ctx, func(tx pgx.Tx) (err error) {
		out, err = repoDocTransition(ctx, tx, editID, `status = 'conflict', last_error = $2, updated_at = $3`, reason, now)
		return err
	})
	return out, err
}

// ReclaimRepoDocEdits returns the rows stuck in pushing since before
// staleBefore (a worker died holding them) to queued, due now. The worker
// checks master for a commit naming each edit_id before it pushes one again.
func (s *Postgres) ReclaimRepoDocEdits(ctx context.Context, staleBefore, now time.Time) ([]RepoDocEdit, error) {
	out := []RepoDocEdit{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		out = out[:0]
		return eachRow(ctx, tx, `UPDATE repo_doc_edits
			SET status = 'queued', next_try_at = $2, last_error = 'reclaimed: stuck in pushing', updated_at = $2
			WHERE status = 'pushing' AND updated_at < $1
			RETURNING `+repoDocEditCols, []any{staleBefore, now}, collectRepoDocEdits(&out))
	})
	sortRepoDocEdits(out)
	return out, err
}

// PushedRepoDocEdits is every pushed row, oldest first: the published sweep
// compares their commits with the newest tree.json sha.
func (s *Postgres) PushedRepoDocEdits(ctx context.Context) ([]RepoDocEdit, error) {
	out := []RepoDocEdit{}
	err := s.asOperatorQuery(ctx, `SELECT `+repoDocEditCols+` FROM repo_doc_edits
		WHERE status = 'pushed' ORDER BY created_at, edit_id`, nil, collectRepoDocEdits(&out))
	return out, err
}

// NextRepoDocEditDue is when the earliest queued row of any workspace falls
// due (its next_try_at); ok false when nothing is queued. The worker sleeps
// until then instead of a full poll (spec 075 repo-edit §3).
func (s *Postgres) NextRepoDocEditDue(ctx context.Context) (time.Time, bool, error) {
	var due *time.Time
	err := s.asOperatorQuery(ctx, `SELECT min(next_try_at) FROM repo_doc_edits WHERE status = 'queued'`, nil,
		func(r pgx.Rows) error { return r.Scan(&due) })
	if err != nil || due == nil {
		return time.Time{}, false, err
	}
	return *due, true, nil
}

// PublishRepoDocEdits marks the pushed rows of these commits published (the
// published tree contains them); it returns how many moved.
func (s *Postgres) PublishRepoDocEdits(ctx context.Context, commitSHAs []string, now time.Time) (int64, error) {
	var n int64
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE repo_doc_edits SET status = 'published', updated_at = $2
			WHERE status = 'pushed' AND commit_sha = ANY($1)`, commitSHAs, now)
		n = tag.RowsAffected()
		return err
	})
	return n, err
}

// RepoDocAuthor is a member's mapped git identity (spec section 4.1 rule 1)
// and their agents opt-out (section 4.3).
type RepoDocAuthor struct {
	TenantID    string
	HumanID     string
	GitName     string
	GitEmail    string
	VerifiedAt  time.Time // zero: not verified
	AllowAgents bool
}

// GetRepoDocAuthor is the member's mapping row (ErrNotFound when none).
func (s *Postgres) GetRepoDocAuthor(ctx context.Context, tenant, humanID string) (RepoDocAuthor, error) {
	a := RepoDocAuthor{TenantID: tenant, HumanID: humanID}
	var verified *time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT git_name, git_email, verified_at, allow_agents
		FROM repo_doc_authors WHERE tenant_id = $1 AND human_id = $2`, []any{tenant, humanID},
		&a.GitName, &a.GitEmail, &verified, &a.AllowAgents)
	if errors.Is(err, pgx.ErrNoRows) {
		return RepoDocAuthor{}, ErrNotFound
	}
	if verified != nil {
		a.VerifiedAt = verified.UTC()
	}
	return a, err
}

// PutRepoDocAuthor creates or replaces the member's mapping row.
func (s *Postgres) PutRepoDocAuthor(ctx context.Context, a RepoDocAuthor) error {
	_, err := s.execTenant(ctx, a.TenantID, `INSERT INTO repo_doc_authors
		(tenant_id, human_id, git_name, git_email, verified_at, allow_agents) VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (tenant_id, human_id) DO UPDATE SET git_name = EXCLUDED.git_name, git_email = EXCLUDED.git_email,
		verified_at = EXCLUDED.verified_at, allow_agents = EXCLUDED.allow_agents`,
		a.TenantID, a.HumanID, a.GitName, a.GitEmail, nullTime(a.VerifiedAt), a.AllowAgents)
	return err
}

// SetRepoDocAllowAgents switches the member's agent edits on or off; the
// mapping row must exist (ErrNotFound otherwise).
func (s *Postgres) SetRepoDocAllowAgents(ctx context.Context, tenant, humanID string, allow bool) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE repo_doc_authors SET allow_agents = $3
		WHERE tenant_id = $1 AND human_id = $2`, tenant, humanID, allow)
	if err == nil && tag.RowsAffected() == 0 {
		err = ErrNotFound
	}
	return err
}

// DeleteRepoDocAuthor drops the member's mapping row (ErrNotFound when none).
func (s *Postgres) DeleteRepoDocAuthor(ctx context.Context, tenant, humanID string) error {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM repo_doc_authors WHERE tenant_id = $1 AND human_id = $2`,
		tenant, humanID)
	if err == nil && tag.RowsAffected() == 0 {
		err = ErrNotFound
	}
	return err
}

// AckRepoDocAuthorNotice records the member's consent to commit under this
// published identity (spec section 4.2); acking it again is a no-op.
func (s *Postgres) AckRepoDocAuthorNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `INSERT INTO repo_doc_author_notices (tenant_id, human_id, git_name, git_email, acked_at)
		VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING`, tenant, humanID, gitName, gitEmail, now)
	return err
}

// HasRepoDocAuthorNotice reports whether the member consented to exactly this
// identity: a changed name or email shows the notice again.
func (s *Postgres) HasRepoDocAuthorNotice(ctx context.Context, tenant, humanID, gitName, gitEmail string) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM repo_doc_author_notices
		WHERE tenant_id = $1 AND human_id = $2 AND git_name = $3 AND git_email = $4)`,
		[]any{tenant, humanID, gitName, gitEmail}, &ok)
	return ok, err
}

// RepoDocKnownAuthor is a git identity of the repository history (spec
// section 4.1 rule 2).
type RepoDocKnownAuthor struct {
	GitEmail string
	GitName  string
	SeenAt   time.Time
}

// LookupRepoDocKnownAuthor is the history identity of email, matched without
// case (ErrNotFound when the history does not know it).
func (s *Postgres) LookupRepoDocKnownAuthor(ctx context.Context, email string) (RepoDocKnownAuthor, error) {
	var a RepoDocKnownAuthor
	err := s.pool.QueryRow(ctx, `SELECT git_email, git_name, seen_at FROM repo_doc_known_authors
		WHERE lower(git_email) = lower($1) ORDER BY seen_at DESC, git_email LIMIT 1`, strings.TrimSpace(email)).
		Scan(&a.GitEmail, &a.GitName, &a.SeenAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return RepoDocKnownAuthor{}, ErrNotFound
	}
	a.SeenAt = a.SeenAt.UTC()
	return a, err
}

// ReplaceRepoDocKnownAuthors is the worker's daily refresh: the history's
// identities are upserted, seen now, and the ones no longer in it dropped.
// An empty list changes nothing (a failed history read must not wipe it).
func (s *Postgres) ReplaceRepoDocKnownAuthors(ctx context.Context, authors []RepoDocKnownAuthor, now time.Time) error {
	if len(authors) == 0 {
		return nil
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		for _, a := range authors {
			if _, err := tx.Exec(ctx, `INSERT INTO repo_doc_known_authors (git_email, git_name, seen_at) VALUES ($1, $2, $3)
				ON CONFLICT (git_email) DO UPDATE SET git_name = EXCLUDED.git_name, seen_at = EXCLUDED.seen_at`,
				a.GitEmail, a.GitName, now); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `DELETE FROM repo_doc_known_authors WHERE seen_at < $1`, now)
		return err
	})
}
