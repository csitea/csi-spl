package store

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The operator workspace is a database flag (rdb 0116, spec 074 phase 1b;
// owner decision D1: "in the db"): tenants.is_operator, at most one row true.
// The hub reads it through OperatorTenant (cached) and, while no row is
// flagged, claims its cnf workspace once at start (ClaimOperatorTenant); the
// cnf SPOOL_HUB_OPERATOR_TENANT is only that bootstrap value.

// operatorTTL is how long a hub trusts its cached operator workspace. Its own
// writes forget the cache at once; another instance's write is seen within it.
const operatorTTL = 30 * time.Second

// OperatorFlag is implemented by Memory and Postgres.
type OperatorFlag interface {
	// OperatorTenant answers the flagged operator workspace; "" = no row is
	// flagged, or this database has no tenants.is_operator yet.
	OperatorTenant(ctx context.Context) (string, error)
	// ClaimOperatorTenant flags tenant as the operator workspace when NO row
	// is flagged, and answers the flagged one after the call ("" = none: the
	// tenant does not exist, or the column is not there yet). An existing
	// flag is never moved.
	ClaimOperatorTenant(ctx context.Context, tenant string) (string, error)
}

var (
	_ OperatorFlag = (*Memory)(nil)
	_ OperatorFlag = (*Postgres)(nil)
)

// operatorCache holds the last read of the flag.
type operatorCache struct {
	mu   sync.Mutex
	id   string
	read time.Time // zero = nothing cached
}

func (c *operatorCache) get(now time.Time) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.read.IsZero() || now.Sub(c.read) >= operatorTTL {
		return "", false
	}
	return c.id, true
}

func (c *operatorCache) put(id string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.id, c.read = id, now
}

func (c *operatorCache) forget() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.read = time.Time{}
}

// hasOperatorFlag is the catalogue probe for rdb 0116: the hub may roll
// before the migration reaches its database, so until the column is there
// no row is flagged and the hub uses its cnf workspace, never a 500.
func (s *Postgres) hasOperatorFlag(ctx context.Context) bool {
	return s.opFlag.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('tenants') AND attname = 'is_operator' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, time.Now())
}

func (s *Postgres) OperatorTenant(ctx context.Context) (string, error) {
	now := time.Now()
	if id, ok := s.opCache.get(now); ok {
		return id, nil
	}
	if !s.hasOperatorFlag(ctx) {
		return "", nil
	}
	var id string
	err := s.asOperatorQuery(ctx, `SELECT tenant_id FROM tenants WHERE is_operator`, nil, func(r pgx.Rows) error {
		return r.Scan(&id)
	})
	if err != nil {
		return "", err
	}
	s.opCache.put(id, now)
	return id, nil
}

func (s *Postgres) ClaimOperatorTenant(ctx context.Context, tenant string) (string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", err
	}
	if !s.hasOperatorFlag(ctx) {
		return "", nil
	}
	s.opCache.forget()
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenants SET is_operator = true
			WHERE tenant_id = $1 AND NOT EXISTS (SELECT 1 FROM tenants WHERE is_operator)`, tenant)
		return err
	})
	// 23505 = tenants_operator_unique: another hub claimed first; read its flag.
	if pe := (*pgconn.PgError)(nil); err != nil && !(errors.As(err, &pe) && pe.Code == "23505") {
		return "", err
	}
	return s.OperatorTenant(ctx)
}

func (s *Memory) OperatorTenant(context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.operatorTenant, nil
}

func (s *Memory) ClaimOperatorTenant(_ context.Context, tenant string) (string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; ok && s.operatorTenant == "" {
		s.operatorTenant = tenant
	}
	return s.operatorTenant, nil
}
