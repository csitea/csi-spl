package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Postgres side of rdb 0047. Every statement runs in the tenant scope.

const issueCols = `number, title, description, status, priority, level, assignee, labels, deadline,
	COALESCE(parent_number, 0), task_id::text, created_by, created_at, updated_by, updated_at, completed_at, canceled_at, kind`

func scanIssue(row pgx.Row, tenant, prefix string) (Issue, error) {
	i := Issue{TenantID: tenant, Prefix: prefix}
	err := row.Scan(&i.Number, &i.Title, &i.Description, &i.Status, &i.Priority, &i.Level, &i.Assignee, &i.Labels,
		&i.Deadline, &i.Parent, &i.TaskID, &i.CreatedBy, &i.CreatedAt, &i.UpdatedBy, &i.UpdatedAt, &i.CompletedAt, &i.CanceledAt, &i.Kind)
	if i.Labels == nil {
		i.Labels = []string{}
	}
	i.Status = NormalizeIssueStatus(i.Status) // a first-set status from the roll window
	if i.Priority == 0 {                      // written by a hub older than rdb 0055
		i.Priority = IssuePriorityDefault
	}
	return i, err
}

// txPrefix reads the tenant's prefix inside tx.
func txPrefix(ctx context.Context, tx pgx.Tx, tenant string) (string, error) {
	var p string
	err := tx.QueryRow(ctx, `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, tenant).Scan(&p)
	if errors.Is(err, pgx.ErrNoRows) {
		return IssuePrefixDefault, nil
	}
	return p, err
}

// txIssueRefs checks labels and the tree rule inside tx.
func txIssueRefs(ctx context.Context, tx pgx.Tx, i Issue, rule, wasEpic bool) error {
	if len(i.Labels) > 0 {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM issue_labels WHERE tenant_id = $1 AND label_id = ANY($2)`,
			i.TenantID, i.Labels).Scan(&n); err != nil {
			return err
		}
		if n != len(i.Labels) {
			return ErrUnknownLabel
		}
	}
	if !rule {
		return nil
	}
	// The tree rule (SPL-18). The parent row is locked FOR SHARE, so it
	// cannot change kind (UpdateIssue locks FOR UPDATE) while an issue is
	// being put under it.
	r := treeRefs{wasEpic: wasEpic}
	if i.Parent != 0 {
		var grand string
		err := tx.QueryRow(ctx, `SELECT p.kind, COALESCE(p.parent_number, 0), COALESCE(g.kind, '')
			FROM issues p LEFT JOIN issues g ON g.tenant_id = p.tenant_id AND g.number = p.parent_number
			WHERE p.tenant_id = $1 AND p.number = $2 FOR SHARE OF p`,
			i.TenantID, i.Parent).Scan(&r.parent.Kind, &r.parent.Parent, &grand)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
		case err != nil:
			return err
		default:
			r.parentOK = true
			r.parentLevel2 = !r.parent.IsEpic() && (Issue{Kind: grand}).IsEpic()
		}
	}
	if i.Number != 0 {
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM issues WHERE tenant_id = $1 AND parent_number = $2)`,
			i.TenantID, i.Number).Scan(&r.hasChildren); err != nil {
			return err
		}
	}
	return treeRule(i, r)
}

func nullParent(p int) any {
	if p == 0 {
		return nil
	}
	return p
}

func (s *Postgres) CreateIssue(ctx context.Context, in Issue, now time.Time) (Issue, error) {
	in.UpdatedBy = in.CreatedBy
	if in.Status == "" {
		in.Status = IssueBacklog
	}
	if err := checkIssue(&in); err != nil {
		return Issue{}, err
	}
	now = now.UTC().Truncate(time.Microsecond)
	stampStatus(&in, now)
	var out Issue
	err := s.inTenant(ctx, in.TenantID, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)`, in.TenantID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		if err := txIssueRefs(ctx, tx, in, true, false); err != nil {
			return err
		}
		// The counter row is the lock: two creates in one tenant serialize
		// on it and never share a number.
		var prefix string
		if err := tx.QueryRow(ctx, `INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, 1)
			ON CONFLICT (tenant_id) DO UPDATE SET last_number = issue_counters.last_number + 1
			RETURNING last_number, prefix`, in.TenantID).Scan(&in.Number, &prefix); err != nil {
			return err
		}
		row := tx.QueryRow(ctx, `INSERT INTO issues (tenant_id, number, title, description, status, priority, level,
				assignee, labels, deadline, parent_number, task_id, created_by, created_at, updated_by, updated_at,
				completed_at, canceled_at, kind)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $13, $14, $15, $16, $17)
			RETURNING `+issueCols,
			in.TenantID, in.Number, in.Title, in.Description, in.Status, in.Priority, in.Level, in.Assignee, in.Labels,
			in.Deadline, nullParent(in.Parent), in.TaskID, in.CreatedBy, now, in.CompletedAt, in.CanceledAt, in.Kind)
		var err error
		out, err = scanIssue(row, in.TenantID, prefix)
		return err
	})
	return out, pgIssueErr(err)
}

func (s *Postgres) UpdateIssue(ctx context.Context, tenant string, number int, p IssuePatch, by string, now time.Time) (Issue, error) {
	now = now.UTC().Truncate(time.Microsecond)
	var out Issue
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, tenant)
		if err != nil {
			return err
		}
		cur, err := scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues
			WHERE tenant_id = $1 AND number = $2 FOR UPDATE`, tenant, number), tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		wasEpic := cur.IsEpic()
		applyPatch(&cur, p, by, now)
		if err := checkIssue(&cur); err != nil {
			return err
		}
		if err := txIssueRefs(ctx, tx, cur, epicTouched(p), wasEpic); err != nil {
			return err
		}
		out, err = scanIssue(tx.QueryRow(ctx, `UPDATE issues SET title = $3, description = $4, status = $5,
				priority = $6, level = $7, assignee = $8, labels = $9, deadline = $10, parent_number = $11,
				updated_by = $12, updated_at = $13, completed_at = $14, canceled_at = $15, kind = $16
			WHERE tenant_id = $1 AND number = $2
			RETURNING `+issueCols,
			tenant, number, cur.Title, cur.Description, cur.Status, cur.Priority, cur.Level, cur.Assignee, cur.Labels,
			cur.Deadline, nullParent(cur.Parent), cur.UpdatedBy, cur.UpdatedAt, cur.CompletedAt, cur.CanceledAt, cur.Kind), tenant, prefix)
		return err
	})
	return out, pgIssueErr(err)
}

func (s *Postgres) GetIssue(ctx context.Context, tenant string, number int) (Issue, error) {
	var out Issue
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, tenant)
		if err != nil {
			return err
		}
		out, err = scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues WHERE tenant_id = $1 AND number = $2`,
			tenant, number), tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return out, err
}

func (s *Postgres) ListIssues(ctx context.Context, tenant string) ([]Issue, error) {
	out := []Issue{}
	prefix := IssuePrefixDefault
	err := s.queryTenantBatch(ctx, tenant,
		tenantRead{sql: `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, args: []any{tenant},
			each: func(r pgx.Rows) error { return r.Scan(&prefix) }},
		tenantRead{sql: `SELECT ` + issueCols + ` FROM issues WHERE tenant_id = $1 ORDER BY number DESC`, args: []any{tenant},
			each: func(r pgx.Rows) error {
				i, err := scanIssue(r, tenant, "")
				out = append(out, i)
				return err
			}})
	for k := range out {
		out[k].Prefix = prefix
	}
	return out, err
}

func (s *Postgres) IssuePrefix(ctx context.Context, tenant string) (string, error) {
	p := IssuePrefixDefault
	err := s.queryRowTenant(ctx, tenant, `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, []any{tenant}, &p)
	if errors.Is(err, pgx.ErrNoRows) {
		return IssuePrefixDefault, nil
	}
	return p, err
}

func (s *Postgres) ListIssueLabels(ctx context.Context, tenant string) ([]IssueLabel, error) {
	out := []IssueLabel{}
	err := s.queryTenant(ctx, tenant, `SELECT label_id, name, color, created_by, created_at FROM issue_labels
		WHERE tenant_id = $1`, []any{tenant}, func(r pgx.Rows) error {
		l := IssueLabel{TenantID: tenant}
		out = append(out, l)
		k := &out[len(out)-1]
		return r.Scan(&k.LabelID, &k.Name, &k.Color, &k.CreatedBy, &k.CreatedAt)
	})
	sortLabels(out)
	return out, err
}

func (s *Postgres) CreateIssueLabel(ctx context.Context, l IssueLabel, now time.Time) (IssueLabel, error) {
	if err := checkLabel(&l); err != nil {
		return IssueLabel{}, err
	}
	l.CreatedAt = now.UTC().Truncate(time.Microsecond)
	tag, err := s.execTenant(ctx, l.TenantID, `INSERT INTO issue_labels (tenant_id, label_id, name, color, created_by, created_at)
		VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING`, l.TenantID, l.LabelID, l.Name, l.Color, l.CreatedBy, l.CreatedAt)
	if err != nil {
		return IssueLabel{}, pgIssueErr(err)
	}
	if tag.RowsAffected() == 0 {
		return IssueLabel{}, ErrConflict
	}
	return l, nil
}

// pgIssueErr maps the constraint errors a race can still reach to the
// store's own: an unknown tenant (FK) and a check the Go side missed.
func pgIssueErr(err error) error {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch pe.Code {
		case "23503":
			if pe.ConstraintName == "issues_tenant_id_parent_number_fkey" {
				return ErrUnknownParent
			}
			return ErrNotFound
		case "23514":
			return fmt.Errorf("%w: %s", ErrInvalidIssue, pe.ConstraintName)
		case "23505":
			return ErrConflict
		}
	}
	return err
}
