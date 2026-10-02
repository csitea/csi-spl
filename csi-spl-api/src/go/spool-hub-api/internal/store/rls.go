package store

import (
	"context"
	"errors"
	"strings"

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

// ErrNoTenant: a tenant-scoped statement was asked for without a tenant. The
// store refuses it before it reaches Postgres (specs/017 FR-SEC-014): an empty
// scope is an error, never "every row" and never a silent empty answer.
var ErrNoTenant = errors.New("store: tenant-scoped statement without a tenant")

// checkTenant is the store half of fail-closed; 0021 is the database half.
func checkTenant(tenant string) error {
	if strings.TrimSpace(tenant) == "" {
		return ErrNoTenant
	}
	return nil
}

// inTenant runs fn in one transaction scoped to tenant. A query in fn that
// forgets WHERE tenant_id still cannot see or write another tenant's rows.
func (s *Postgres) inTenant(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
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
	if err := checkTenant(tenant); err != nil {
		return err
	}
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

// tenantRead is one statement of a queryTenantBatch.
type tenantRead struct {
	sql  string
	args []any
	each func(pgx.Rows) error // once per row
}

// queryTenantBatch sends the tenant scope and several reads as ONE batch: one
// round trip, where inTenant paid BEGIN + scope + one per read + COMMIT
// The batch is one implicit transaction, like inTenant's, so the
// scope ends with it. Results are read in queue order, so a read's each may
// depend on what an earlier read's each stored.
func (s *Postgres) queryTenantBatch(ctx context.Context, tenant string, reads ...tenantRead) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	b := &pgx.Batch{}
	b.Queue(pgScopeTenant, tenant)
	for _, r := range reads {
		b.Queue(r.sql, r.args...)
	}
	br := s.pool.SendBatch(ctx, b)
	_, err := br.Exec()
	for i := 0; err == nil && i < len(reads); i++ {
		var rows pgx.Rows
		if rows, err = br.Query(); err == nil {
			err = scanRows(rows, reads[i].each)
		}
	}
	if cerr := br.Close(); err == nil {
		err = cerr
	}
	return err
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

// asOperatorQuery is asOperator for ONE read: the operator scope and the read
// go as a single batch, one round trip, where asOperator paid BEGIN + scope +
// the read + COMMIT. The batch is one implicit transaction, so the scope ends
// with it, as tenantBatch's does. It sees every tenant like asOperator, so
// TestOperatorScopeCallers lists its callers too. each is called once per row.
func (s *Postgres) asOperatorQuery(ctx context.Context, sql string, args []any, each func(pgx.Rows) error) error {
	b := &pgx.Batch{}
	b.Queue(pgScopeOperator)
	b.Queue(sql, args...)
	br := s.pool.SendBatch(ctx, b)
	_, err := br.Exec()
	if err == nil {
		var rows pgx.Rows
		if rows, err = br.Query(); err == nil {
			err = scanRows(rows, each)
		}
	}
	if cerr := br.Close(); err == nil {
		err = cerr
	}
	return err
}

// RLSBypassed reports whether the connected role skips every policy
// (superuser or BYPASSRLS). The hub logs it at startup: 0014 protects nothing
// for such a role.
func (s *Postgres) RLSBypassed(ctx context.Context) (bool, error) {
	var by bool
	err := s.pool.QueryRow(ctx, `SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user`).Scan(&by)
	return by, err
}

// HubRoleCanLiftRLS lists every way the connected role could switch tenant
// row level security off for itself (specs/017 FR-SEC-014): superuser or
// BYPASSRLS, owning (or being able to SET ROLE to the owner of) a tenant_id
// table - an owner may ALTER TABLE ... NO FORCE / DISABLE ROW LEVEL SECURITY
// or DROP POLICY - or being able to SET ROLE to a superuser / BYPASSRLS role.
// Empty means the role is bound and cannot unbind itself.
func (s *Postgres) HubRoleCanLiftRLS(ctx context.Context) ([]string, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT 'superuser or BYPASSRLS' FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolbypassrls)
		UNION ALL
		SELECT 'can SET ROLE to ' || r.rolname || ' (superuser or BYPASSRLS)' FROM pg_roles r
		 WHERE r.rolname <> current_user AND (r.rolsuper OR r.rolbypassrls) AND pg_has_role(current_user, r.oid, 'MEMBER')
		UNION ALL
		SELECT 'owns or can SET ROLE to the owner of ' || c.relname FROM pg_class c
		  JOIN pg_namespace n ON n.oid = c.relnamespace
		  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
		 WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND pg_has_role(current_user, c.relowner, 'MEMBER')
		ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	var out []string
	err = scanRows(rows, func(r pgx.Rows) error {
		var why string
		if err := r.Scan(&why); err != nil {
			return err
		}
		out = append(out, why)
		return nil
	})
	return out, err
}
