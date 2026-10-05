package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// MarketingSwitch is the workspace admin's marketing switch (spec 090 §15,
// rdb 0129 tenants.marketing_enabled). It is the inner half of the gate: the
// hub turns marketing on for a workspace only when the cnf allow-list names
// it (or is "all") AND this flag is on. A workspace starts off (owner, t1
// f0c3927e msg 5cd2e544): nothing posts until its admin turns it on.
type MarketingSwitch interface {
	// MarketingEnabled reads the flag; ErrNotFound when no such tenant.
	MarketingEnabled(ctx context.Context, tenant string) (bool, error)
	// SetMarketingEnabled writes it; ErrNotFound when no such tenant.
	SetMarketingEnabled(ctx context.Context, tenant string, on bool) error
}

// ---- Memory -----------------------------------------------------------------

func (s *Memory) MarketingEnabled(_ context.Context, tenant string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	return s.marketingOn[tenant], nil
}

func (s *Memory) SetMarketingEnabled(_ context.Context, tenant string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.marketingOn == nil {
		s.marketingOn = map[string]bool{}
	}
	if on {
		s.marketingOn[tenant] = true
	} else {
		delete(s.marketingOn, tenant)
	}
	return nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) MarketingEnabled(ctx context.Context, tenant string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT marketing_enabled FROM tenants WHERE tenant_id = $1`,
		[]any{tenant}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return on, err
}

func (s *Postgres) SetMarketingEnabled(ctx context.Context, tenant string, on bool) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET marketing_enabled = $2 WHERE tenant_id = $1`, tenant, on)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
