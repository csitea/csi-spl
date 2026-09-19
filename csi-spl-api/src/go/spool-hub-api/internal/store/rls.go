package store

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Row level security scopes (rdb 0014, specs/017 FR-SEC-013). Every table that
// carries tenant_id shows and accepts only the rows of the tenant set by
// inTenant, or every row under asOperator. A statement run outside both sees
// zero rows. Both settings are transaction-local (set_config is_local = true),
// so they end at COMMIT / ROLLBACK and never leak to the next pool user.
const (
	pgScopeTenant   = `SELECT set_config('app.tenant_id', $1, true)`
	pgScopeOperator = `SELECT set_config('app.rls_scope', 'operator', true)`
)

// inTenant runs fn in one transaction scoped to tenant. A query in fn that
// forgets WHERE tenant_id still cannot see or write another tenant's rows.
func (s *Postgres) inTenant(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeTenant, tenant); err != nil {
			return err
		}
		return fn(tx)
	})
}

// tenantBatch sends the tenant scope and ONE statement as a single batch:
// one round trip, run by Postgres as one implicit transaction, so the scope
// ends with it (measured: inTenant's BEGIN / set_config / COMMIT added three
// round trips to every single-statement call).
func (s *Postgres) tenantBatch(ctx context.Context, tenant, sql string, args []any, use func(pgx.BatchResults) error) error {
	b := &pgx.Batch{}
	b.Queue(pgScopeTenant, tenant)
	b.Queue(sql, args...)
	br := s.pool.SendBatch(ctx, b)
	if _, err := br.Exec(); err != nil {
		br.Close()
		return err
	}
	if err := use(br); err != nil {
		br.Close()
		return err
	}
	return br.Close()
}

// execTenant is one statement in tenant's scope.
func (s *Postgres) execTenant(ctx context.Context, tenant, sql string, args ...any) (pgconn.CommandTag, error) {
	var tag pgconn.CommandTag
	err := s.tenantBatch(ctx, tenant, sql, args, func(br pgx.BatchResults) (err error) {
		tag, err = br.Exec()
		return err
	})
	return tag, err
}

// queryRowTenant is one single-row query in tenant's scope (pgx.ErrNoRows
// when it has no row).
func (s *Postgres) queryRowTenant(ctx context.Context, tenant, sql string, args []any, dest ...any) error {
	return s.tenantBatch(ctx, tenant, sql, args, func(br pgx.BatchResults) error {
		return br.QueryRow().Scan(dest...)
	})
}

// queryTenant is one query in tenant's scope; each is called once per row.
func (s *Postgres) queryTenant(ctx context.Context, tenant, sql string, args []any, each func(pgx.Rows) error) error {
	return s.tenantBatch(ctx, tenant, sql, args, func(br pgx.BatchResults) error {
		rows, err := br.Query()
		if err != nil {
			return err
		}
		return scanRows(rows, each)
	})
}

// eachRow runs sql on tx and calls each once per row.
func eachRow(ctx context.Context, tx pgx.Tx, sql string, args []any, each func(pgx.Rows) error) error {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return err
	}
	return scanRows(rows, each)
}

func scanRows(rows pgx.Rows, each func(pgx.Rows) error) error {
	defer rows.Close()
	for rows.Next() {
		if err := each(rows); err != nil {
			return err
		}
	}
	return rows.Err()
}

// asOperator runs fn in one transaction that sees every tenant. It is the one
// cross-tenant path, and only these callers use it: Sweep (retention is
// global), the payment webhook and the checkout lookups (the tenant is unknown
// until the checkout row is read), and Migrate. Anything else uses inTenant.
func (s *Postgres) asOperator(ctx context.Context, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		return fn(tx)
	})
}

// RLSBypassed reports whether the connected role skips every policy
// (superuser or BYPASSRLS). The hub logs it at startup: 0014 protects nothing
// for such a role.
func (s *Postgres) RLSBypassed(ctx context.Context) (bool, error) {
	var by bool
	err := s.pool.QueryRow(ctx, `SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user`).Scan(&by)
	return by, err
}
