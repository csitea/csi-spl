package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0204. The tree's read policy is every scope's, so
// ListCategories reads it plainly; its writes run in the operator scope (the
// rows are the instance's, no tenant: operatorCallers says who reaches
// them). A request's category is written in its tenant's scope.

const categoryCols = `category_path, coalesce(parent_path, ''), title, description, dimensions, is_active, created_at, updated_at`

func scanCategory(row pgx.Row) (Category, error) {
	var c Category
	err := row.Scan(&c.Path, &c.ParentPath, &c.Title, &c.Description, &c.Dimensions, &c.IsActive, &c.CreatedAt, &c.UpdatedAt)
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	c.CreatedAt, c.UpdatedAt = c.CreatedAt.UTC(), c.UpdatedAt.UTC()
	return c, err
}

// ListCategories is CategoryStore on Postgres.
func (s *Postgres) ListCategories(ctx context.Context) ([]Category, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+categoryCols+` FROM activity_categories ORDER BY category_path`)
	if err != nil {
		return nil, err
	}
	out := []Category{}
	err = scanRows(rows, func(rows pgx.Rows) error {
		c, err := scanCategory(rows)
		out = append(out, c)
		return err
	})
	return out, err
}

// CreateCategory is CategoryStore on Postgres.
func (s *Postgres) CreateCategory(ctx context.Context, c Category) (Category, error) {
	if why := CheckCategory(c); why != "" {
		return Category{}, fmt.Errorf("category: %s", why)
	}
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	var out Category
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanCategory(tx.QueryRow(ctx, `INSERT INTO activity_categories (category_path, parent_path, title, description, dimensions, is_active)
			VALUES ($1, NULLIF($2, ''), $3, $4, $5, $6) RETURNING `+categoryCols,
			c.Path, c.ParentPath, c.Title, c.Description, c.Dimensions, c.IsActive))
		return err
	})
	switch sqlState(err) {
	case "23505":
		return Category{}, ErrConflict
	case "23503":
		return Category{}, ErrUnknownCategory
	}
	return out, err
}

// UpdateCategory is CategoryStore on Postgres.
func (s *Postgres) UpdateCategory(ctx context.Context, c Category) (Category, error) {
	if why := CheckCategory(c); why != "" {
		return Category{}, fmt.Errorf("category: %s", why)
	}
	if c.Dimensions == nil {
		c.Dimensions = map[string]any{}
	}
	var out Category
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanCategory(tx.QueryRow(ctx, `UPDATE activity_categories SET title = $2, description = $3, dimensions = $4,
			is_active = $5, updated_at = now() WHERE category_path = $1 RETURNING `+categoryCols,
			c.Path, c.Title, c.Description, c.Dimensions, c.IsActive))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Category{}, ErrNotFound
	}
	return out, err
}

// SetAskCategory is CategoryStore on Postgres. updated_at is left alone: it
// is the request's last state change, which the placer's lock reads.
func (s *Postgres) SetAskCategory(ctx context.Context, tenant, fleet, askID, workKind, path string) error {
	if why := CheckAskCategory(workKind, path); why != "" {
		return fmt.Errorf("ask category: %s", why)
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE fleet_asks SET work_kind = $4, category_path = NULLIF($5, '')
			WHERE tenant_id = $1 AND fleet = $2 AND ask_id = $3`, tenant, fleet, askID, workKind, path)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
	if sqlState(err) == "23503" {
		return ErrUnknownCategory
	}
	return err
}

// categoryTokensSQL is the metered burn of [$1, $2) per category leaf: a
// placed request of tenant $3 ("placed: <agent>@<box>") claims its lane's
// minutes from $4 before the placement to $4 before the next placement of
// the same (agent, box); a minute no span claims is "".
const categoryTokensSQL = `WITH placed AS (
	SELECT a.category_path, m[1] AS agent_id, m[2] AS box_tag, a.updated_at - $4::interval AS span_from
	FROM fleet_asks a, regexp_match(a.reason, '^placed: ([A-Za-z0-9-]+)@([a-z0-9-]+)$') AS m
	WHERE a.tenant_id = $3 AND a.state = 'done' AND m IS NOT NULL
), spans AS (
	SELECT category_path, agent_id, box_tag, span_from,
		lead(span_from) OVER (PARTITION BY agent_id, box_tag ORDER BY span_from) AS span_until
	FROM placed
)
SELECT coalesce(s.category_path, ''), sum(e.tokens_in + e.tokens_out + e.cache_write)::bigint, sum(e.cache_read)::bigint,
	(coalesce(sum(e.cost_micros) FILTER (WHERE e.priced AND e.currency = 'USD'), 0) / 1e6)::float8
FROM fleet_token_burn_events e
LEFT JOIN spans s ON s.agent_id = e.agent_id AND s.box_tag = e.box_tag
	AND e.minute_bucket >= s.span_from AND (s.span_until IS NULL OR e.minute_bucket < s.span_until)
WHERE e.is_metered AND e.minute_bucket >= $1 AND e.minute_bucket < $2
GROUP BY 1 ORDER BY 1`

// CategoryTokens is CategoryStore on Postgres.
func (s *Postgres) CategoryTokens(ctx context.Context, op string, from, to time.Time) ([]CategoryLaneTokens, error) {
	out := []CategoryLaneTokens{}
	lead := fmt.Sprintf("%d seconds", int(CategoryPlaceLead/time.Second))
	err := s.asOperatorQuery(ctx, categoryTokensSQL, []any{from.UTC(), to.UTC(), op, lead}, func(rows pgx.Rows) error {
		var l CategoryLaneTokens
		if err := rows.Scan(&l.Path, &l.Tokens, &l.CacheRead, &l.CostUSD); err != nil {
			return err
		}
		out = append(out, l)
		return nil
	})
	return out, err
}

var _ CategoryStore = (*Postgres)(nil)
