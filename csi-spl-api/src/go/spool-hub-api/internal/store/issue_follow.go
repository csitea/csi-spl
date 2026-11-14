package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// An issue follows its discussion (SPL-5284, rdb 0281, spec 041
// archive-releases-work.md). The owner (HUM-10, t1 fcf09921, msgs a081dcf2
// and eae27b5d; poll 063a4bdd 1 B, 2 A, 3 A):
//
//   - archive a discussion: every OPEN issue it links goes to diss, its
//     previous status kept in issue_discussion_closes;
//   - unarchive it: each issue it closed goes back to that status, unless the
//     issue was changed in between (no longer diss with the same canceled_at);
//   - delete it: every open issue it links is soft-deleted (deleted_at), its
//     status and link kept, for a discussion undelete (its own lane);
//   - any ONE linked discussion decides (1 B).
//
// It runs in the same transaction as the discussion's own change, so the two
// never disagree. Open is IssueFollowOpen; an epic or feature is never
// closed by one discussion (its children have their own), nor a foreign link
// (operator only, SPL-5126), nor an issue already archived or deleted.

// IssueFollowOpen are the statuses a discussion's archive or delete closes.
// Done, diss and qas (in review) are left as they are.
var IssueFollowOpen = []string{IssueEval, IssueTodo, IssueWIP, IssueBlocked, IssueOnHold}

// The ops of an issue_discussion_closes row.
const (
	IssueFollowArchive = "archive"
	IssueFollowDelete  = "delete"
)

// IssueFollow is one issue a discussion's archive, unarchive or delete
// changed: its number, the discussion (task) that did it, and the status
// before and after. To is "" for a delete.
type IssueFollow struct {
	Number int
	TaskID string
	Op     string // archive, unarchive or delete
	From   string
	To     string
}

// issueFollowHit is the open, live, non-epic issues that link one of $2,
// one row per issue with the first such discussion ($1 tenant, $2 tasks,
// $3 open statuses).
const issueFollowHit = `SELECT i.number, i.status, min(d.task_id::text) AS task
		FROM issues i JOIN issue_discussions d ON d.tenant_id = i.tenant_id AND d.number = i.number
		WHERE i.tenant_id = $1 AND d.task_id = ANY($2::uuid[]) AND d.origin_tenant IS NULL
			AND i.deleted_at IS NULL AND i.archived_at IS NULL
			AND i.status = ANY($3::text[]) AND i.kind NOT IN ('epic', 'feature')
		GROUP BY i.number, i.status`

// issueFollowRecord keeps each hit issue's status ($4 op, $5 at, $6 by);
// a stale row of the same issue is overwritten.
const issueFollowRecord = `INSERT INTO issue_discussion_closes (tenant_id, number, task_id, op, prev_status, closed_at, closed_by)
		SELECT $1, hit.number, hit.task::uuid, $4, hit.status, $5, left($6, 64) FROM hit
		ON CONFLICT (tenant_id, number) DO UPDATE SET task_id = EXCLUDED.task_id, op = EXCLUDED.op,
			prev_status = EXCLUDED.prev_status, closed_at = EXCLUDED.closed_at, closed_by = EXCLUDED.closed_by`

// followArchiveTx closes the open issues of tasks (archive).
func followArchiveTx(ctx context.Context, tx pgx.Tx, tenant string, tasks []string, by string, at time.Time) ([]IssueFollow, error) {
	return followQuery(ctx, tx, IssueFollowArchive, `WITH hit AS (`+issueFollowHit+`), rec AS (`+issueFollowRecord+`)
		UPDATE issues i SET status = 'diss', canceled_at = $5, updated_at = $5, updated_by = left($6, 64)
		FROM hit WHERE i.tenant_id = $1 AND i.number = hit.number
		RETURNING i.number, hit.task, hit.status, 'diss'`,
		tenant, followTasks(tasks), IssueFollowOpen, IssueFollowArchive, followAt(at), by)
}

// followDeleteTx soft-deletes the open issues of tasks (delete).
func followDeleteTx(ctx context.Context, tx pgx.Tx, tenant string, tasks []string, by string, at time.Time) ([]IssueFollow, error) {
	return followQuery(ctx, tx, IssueFollowDelete, `WITH hit AS (`+issueFollowHit+`), rec AS (`+issueFollowRecord+`)
		UPDATE issues i SET deleted_at = $5, deleted_by = left($6, 64)
		FROM hit WHERE i.tenant_id = $1 AND i.number = hit.number
		RETURNING i.number, hit.task, hit.status, ''`,
		tenant, followTasks(tasks), IssueFollowOpen, IssueFollowDelete, followAt(at), by)
}

// followUnarchiveTx reopens what the archive of tasks closed: back to the
// kept status when the issue is still diss with the canceled_at the archive
// gave it. Every archive row of tasks is dropped, reverted or not.
func followUnarchiveTx(ctx context.Context, tx pgx.Tx, tenant string, tasks []string, by string, at time.Time) ([]IssueFollow, error) {
	return followQuery(ctx, tx, "unarchive", `WITH back AS (
			DELETE FROM issue_discussion_closes c
			WHERE c.tenant_id = $1 AND c.task_id = ANY($2::uuid[]) AND c.op = 'archive'
			RETURNING c.number, c.task_id::text AS task, c.prev_status, c.closed_at)
		UPDATE issues i SET status = back.prev_status, canceled_at = NULL, updated_at = $3, updated_by = left($4, 64)
		FROM back WHERE i.tenant_id = $1 AND i.number = back.number AND i.status = 'diss'
			AND i.canceled_at = back.closed_at AND i.deleted_at IS NULL AND i.archived_at IS NULL
		RETURNING i.number, back.task, 'diss', back.prev_status`,
		tenant, followTasks(tasks), followAt(at), by)
}

// IssueFollowHub is the updated_by of a reopen nobody named.
const IssueFollowHub = "hub"

// followBy is by, or IssueFollowHub when empty.
func followBy(by string) string {
	if by == "" {
		return IssueFollowHub
	}
	return by
}

// followChannelTx soft-deletes the open issues of every topic of channel id
// (a channel delete) and answers them.
func followChannelTx(ctx context.Context, tx pgx.Tx, tenant, id, by string, at time.Time) ([]IssueFollow, error) {
	tasks, err := taskList(tx.Query(ctx, `SELECT DISTINCT task_id::text FROM messages WHERE tenant_id = $1 AND channel = $2`, tenant, id))
	if err != nil {
		return nil, err
	}
	return followDeleteTx(ctx, tx, tenant, tasks, by, at)
}

// taskList reads one text column.
func taskList(rows pgx.Rows, err error) ([]string, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// followTasks drops the empty and malformed ids (a lobby card has no task).
func followTasks(tasks []string) []string {
	out := make([]string, 0, len(tasks))
	for _, t := range tasks {
		if canonUUIDRe.MatchString(t) {
			out = append(out, t)
		}
	}
	return out
}

// followAt is at in UTC at microseconds, or now when zero.
func followAt(at time.Time) time.Time {
	if at.IsZero() {
		at = time.Now()
	}
	return at.UTC().Truncate(time.Microsecond)
}

// followQuery runs one follow statement and reads its number, task, from,
// to; sorted by number. No task, no statement.
func followQuery(ctx context.Context, tx pgx.Tx, op, sql string, args ...any) ([]IssueFollow, error) {
	if len(args) > 1 {
		if ts, ok := args[1].([]string); ok && len(ts) == 0 {
			return nil, nil
		}
	}
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []IssueFollow
	for rows.Next() {
		f := IssueFollow{Op: op}
		if err := rows.Scan(&f.Number, &f.TaskID, &f.From, &f.To); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out, nil
}

// issueFollowClose is one Memory issue_discussion_closes row.
type issueFollowClose struct {
	task, op, prev string
	at             time.Time
}

// followOpen reports a status IssueFollowOpen holds.
func followOpen(status string) bool {
	for _, s := range IssueFollowOpen {
		if s == status {
			return true
		}
	}
	return false
}

// followLocked is the Memory twin of followArchiveTx / followDeleteTx. The
// caller holds s.mu.
func (s *Memory) followLocked(tenant string, tasks []string, op, by string, at time.Time) []IssueFollow {
	want := map[string]bool{}
	for _, t := range followTasks(tasks) {
		want[t] = true
	}
	at = followAt(at)
	var out []IssueFollow
	for n, i := range s.iss.rows[tenant] {
		task := s.followTaskLocked(tenant, n, want)
		if task == "" || !followOpen(i.Status) || i.IsEpic() {
			continue
		}
		f := IssueFollow{Number: n, TaskID: task, Op: op, From: i.Status}
		if s.iss.closes == nil {
			s.iss.closes = map[string]map[int]issueFollowClose{}
		}
		if s.iss.closes[tenant] == nil {
			s.iss.closes[tenant] = map[int]issueFollowClose{}
		}
		s.iss.closes[tenant][n] = issueFollowClose{task: task, op: op, prev: i.Status, at: at}
		if op == IssueFollowDelete {
			if s.iss.gone[tenant] == nil {
				s.iss.gone[tenant] = map[int]Issue{}
			}
			s.iss.gone[tenant][n] = i
			delete(s.iss.rows[tenant], n)
		} else {
			stamp := at
			i.Status, i.CanceledAt, i.UpdatedAt, i.UpdatedBy = IssueDiss, &stamp, at, by
			s.iss.rows[tenant][n] = i
			f.To = IssueDiss
		}
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out
}

// followTaskLocked is the first wanted, non-foreign discussion issue n
// links, or "".
func (s *Memory) followTaskLocked(tenant string, n int, want map[string]bool) string {
	first := ""
	for _, l := range s.iss.linksOf(tenant, n) {
		if want[l.TaskID] && l.OriginTenant == "" && (first == "" || l.TaskID < first) {
			first = l.TaskID
		}
	}
	return first
}

// unfollowLocked is the Memory twin of followUnarchiveTx.
func (s *Memory) unfollowLocked(tenant string, tasks []string, by string, at time.Time) []IssueFollow {
	want := map[string]bool{}
	for _, t := range followTasks(tasks) {
		want[t] = true
	}
	at = followAt(at)
	var out []IssueFollow
	for n, c := range s.iss.closes[tenant] {
		if !want[c.task] || c.op != IssueFollowArchive {
			continue
		}
		delete(s.iss.closes[tenant], n)
		i, ok := s.iss.rows[tenant][n]
		if !ok || i.Status != IssueDiss || i.CanceledAt == nil || !i.CanceledAt.Equal(c.at) {
			continue
		}
		i.Status, i.CanceledAt, i.UpdatedAt, i.UpdatedBy = c.prev, nil, at, by
		s.iss.rows[tenant][n] = i
		out = append(out, IssueFollow{Number: n, TaskID: c.task, Op: "unarchive", From: IssueDiss, To: c.prev})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out
}
