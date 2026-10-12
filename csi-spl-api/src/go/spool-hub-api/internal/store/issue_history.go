package store

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Issue history (rdb 0181, owner HUM-10 t1 62e48cef): the Jira-like History
// tab of one issue. Field changes, create, delete and archive come from
// issue_events, written by a trigger on issues; comments are the messages of
// the issue's topic, read here, never copied.

// The events of an issue's history.
const (
	IssueEventCreated    = "created"
	IssueEventChanged    = "changed"
	IssueEventCommented  = "commented"
	IssueEventDeleted    = "deleted"
	IssueEventRestored   = "restored"
	IssueEventArchived   = "archived"
	IssueEventUnarchived = "unarchived"
)

// IssueHistoryCap bounds one read: the oldest rows win, the tab is
// oldest-first.
const IssueHistoryCap = 2000

// issueCommentExcerpt is how much of a comment's body the history repeats.
const issueCommentExcerpt = 280

// IssueEvent is one row of an issue's history. Old / New are nil where a
// value does not apply (a create, a comment's old value, a description).
type IssueEvent struct {
	At    time.Time
	Actor string // created_by / updated_by / the comment's author
	Event string // IssueEvent*
	Field string // the changed field for IssueEventChanged, else ""
	Old   *string
	New   *string // a comment's excerpt for IssueEventCommented
	MsgID string  // the comment's message, else ""
}

// IssueHistories reads an issue's history. Both drivers implement it.
type IssueHistories interface {
	// IssueHistory is the issue's events and comments, oldest first, at most
	// IssueHistoryCap. ErrNotFound for no such issue or a deleted one.
	IssueHistory(ctx context.Context, tenantID string, number int) ([]IssueEvent, error)
}

var issueHistorySQL = `
	SELECT at, actor, event, field, old_value, new_value, '' AS msg_id, 1 AS tie, id
	FROM issue_events WHERE tenant_id = $1 AND number = $2
	UNION ALL
	SELECT m.ts, coalesce(nullif(m.typed_by, ''), m.from_id), 'commented', '', NULL, left(m.body, ` + strconv.Itoa(issueCommentExcerpt) + `),
		m.msg_id::text, 2, 0
	FROM messages m
	WHERE m.tenant_id = $1 AND m.task_id = $3 AND m.archived_at IS NULL
	ORDER BY 1, 8, 9
	LIMIT ` + strconv.Itoa(IssueHistoryCap)

func (s *Postgres) IssueHistory(ctx context.Context, tenant string, number int) ([]IssueEvent, error) {
	out := []IssueEvent{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var task string
		err := tx.QueryRow(ctx, `SELECT task_id::text FROM issues WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL`,
			tenant, number).Scan(&task)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, issueHistorySQL, tenant, number, task)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var e IssueEvent
			var tie int
			var id int64
			if err := rows.Scan(&e.At, &e.Actor, &e.Event, &e.Field, &e.Old, &e.New, &e.MsgID, &tie, &id); err != nil {
				return err
			}
			e.At = e.At.UTC()
			out = append(out, e)
		}
		return rows.Err()
	})
	return out, err
}

// issueChanges is the memory twin of the rdb 0181 trigger's field diff, in
// its order.
func issueChanges(was, now Issue) []IssueEvent {
	itoa := func(n int) string { return strconv.Itoa(n) }
	parent := func(n int) *string {
		if n == 0 {
			return nil
		}
		v := itoa(n)
		return &v
	}
	deadline := func(t *time.Time) *string {
		if t == nil {
			return nil
		}
		v := t.UTC().Format("2006-01-02T15:04:05Z")
		return &v
	}
	str := func(v string) *string { return &v }
	type diff struct {
		field    string
		old, new *string
		changed  bool
	}
	ds := []diff{
		{"title", str(was.Title), str(now.Title), was.Title != now.Title},
		{"description", nil, nil, was.Description != now.Description},
		{"status", str(was.Status), str(now.Status), was.Status != now.Status},
		{"priority", str(itoa(was.Priority)), str(itoa(now.Priority)), was.Priority != now.Priority},
		{"level", str(itoa(was.Level)), str(itoa(now.Level)), was.Level != now.Level},
		{"assignee", str(was.Assignee), str(now.Assignee), was.Assignee != now.Assignee},
		{"kind", str(was.Kind), str(now.Kind), was.Kind != now.Kind},
		{"parent", parent(was.Parent), parent(now.Parent), was.Parent != now.Parent},
		{"deadline", deadline(was.Deadline), deadline(now.Deadline), !equalDeadline(was.Deadline, now.Deadline)},
		{"labels", str(strings.Join(was.Labels, ",")), str(strings.Join(now.Labels, ",")),
			strings.Join(was.Labels, ",") != strings.Join(now.Labels, ",")},
	}
	var out []IssueEvent
	for _, d := range ds {
		if d.changed {
			out = append(out, IssueEvent{At: now.UpdatedAt, Actor: now.UpdatedBy, Event: IssueEventChanged,
				Field: d.field, Old: d.old, New: d.new})
		}
	}
	return out
}

func equalDeadline(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Equal(*b)
}

// recordLocked appends events to an issue's memory history. Caller holds
// Memory.mu.
func (m *memIssues) recordLocked(tenant string, number int, evs ...IssueEvent) {
	if m.history == nil {
		m.history = map[string]map[int][]IssueEvent{}
	}
	if m.history[tenant] == nil {
		m.history[tenant] = map[int][]IssueEvent{}
	}
	m.history[tenant][number] = append(m.history[tenant][number], evs...)
}

func (s *Memory) IssueHistory(_ context.Context, tenant string, number int) ([]IssueEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		row, ok = s.iss.archived[tenant][number]
	}
	if !ok {
		return nil, ErrNotFound
	}
	out := append([]IssueEvent{}, s.iss.history[tenant][number]...)
	for _, m := range s.messages {
		if m.TenantID != tenant || m.TaskID != row.TaskID || !m.ArchivedAt.IsZero() {
			continue
		}
		by := m.FromID
		if m.TypedBy != "" {
			by = m.TypedBy
		}
		body := m.Body
		if r := []rune(body); len(r) > issueCommentExcerpt {
			body = string(r[:issueCommentExcerpt])
		}
		out = append(out, IssueEvent{At: m.TS.UTC(), Actor: by, Event: IssueEventCommented, New: &body, MsgID: m.MsgID})
	}
	sort.SliceStable(out, func(a, b int) bool {
		if !out[a].At.Equal(out[b].At) {
			return out[a].At.Before(out[b].At)
		}
		return out[a].Event != IssueEventCommented && out[b].Event == IssueEventCommented
	})
	if len(out) > IssueHistoryCap {
		out = out[:IssueHistoryCap]
	}
	return out, nil
}
