package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// IssueOpens keeps which issues a member has opened (rdb 0184, SPL-1559).
// The owner (HUM-10, t1 7edebc75, msg 7d76ce22): "A new issue should be
// marked as a new issue, which has not been opened yet, so it will be
// distinguishable from the rest of the issues." The hub lists an open issue
// as unopened for its assignee until the assignee opens it (hub issues.go,
// issueUnopened); the WUI marks those rows the way it marks unread lines.
type IssueOpens interface {
	// IssuesOpenedBy is every issue number the member has opened in the tenant.
	IssuesOpenedBy(ctx context.Context, tenant, member string) (map[int]bool, error)
	// MarkIssueOpened records that the member opened the issue; opening it
	// again keeps the first time. ErrNotFound when the tenant has no such
	// live issue.
	MarkIssueOpened(ctx context.Context, tenant, member string, number int, now time.Time) error
}

var (
	_ IssueOpens = (*Memory)(nil)
	_ IssueOpens = (*Postgres)(nil)
)

func (s *Memory) IssuesOpenedBy(_ context.Context, tenant, member string) (map[int]bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[int]bool{}
	for n := range s.iss.opened[[2]string{tenant, member}] {
		out[n] = true
	}
	return out, nil
}

func (s *Memory) MarkIssueOpened(_ context.Context, tenant, member string, number int, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.iss.rows[tenant][number]; !ok {
		return ErrNotFound
	}
	if s.iss.opened == nil {
		s.iss.opened = map[[2]string]map[int]time.Time{}
	}
	k := [2]string{tenant, member}
	if s.iss.opened[k] == nil {
		s.iss.opened[k] = map[int]time.Time{}
	}
	if _, ok := s.iss.opened[k][number]; !ok {
		s.iss.opened[k][number] = now
	}
	return nil
}

func (s *Postgres) IssuesOpenedBy(ctx context.Context, tenant, member string) (map[int]bool, error) {
	out := map[int]bool{}
	err := s.queryTenant(ctx, tenant, `SELECT number FROM issue_opens WHERE tenant_id = $1 AND member_id = $2`,
		[]any{tenant, member}, func(r pgx.Rows) error {
			var n int
			if err := r.Scan(&n); err != nil {
				return err
			}
			out[n] = true
			return nil
		})
	return out, err
}

func (s *Postgres) MarkIssueOpened(ctx context.Context, tenant, member string, number int, now time.Time) error {
	// One statement: a row only for a live issue; a second open keeps the first.
	tag, err := s.execTenant(ctx, tenant, `INSERT INTO issue_opens (tenant_id, member_id, number, opened_at)
			SELECT tenant_id, $2, number, $4 FROM issues
			WHERE tenant_id = $1 AND number = $3 AND deleted_at IS NULL AND archived_at IS NULL
			ON CONFLICT (tenant_id, member_id, number) DO UPDATE SET opened_at = issue_opens.opened_at`,
		tenant, member, number, now)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
