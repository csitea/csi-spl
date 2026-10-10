package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// The box modes a join declares (spec 108 3.8, rdb 0170 pins.box_mode).
const (
	// BoxModeDedicated is a box enrolled into one workspace
	// (do_spl_box_workspace_setup, spec 108 3.5).
	BoxModeDedicated = "dedicated"
	// BoxModeShared is a box that may serve several workspaces.
	BoxModeShared = "shared"
)

// ValidBoxMode reports whether m is a box mode a join may declare.
func ValidBoxMode(m string) bool { return m == BoxModeDedicated || m == BoxModeShared }

// BoxJoinSwitch is spec 108's per-workspace feature switch (section 3.8, rdb
// 0170 tenants.box_join_enabled, owner msg 9bdc5980): false, the default for
// every workspace, refuses minting and redeeming a join token; boxes seated
// before keep working. Only the operator workspace writes it.
type BoxJoinSwitch interface {
	// BoxJoinEnabled reads the switch; ErrNotFound when no such tenant.
	BoxJoinEnabled(ctx context.Context, tenant string) (bool, error)
	// SetBoxJoinEnabled writes it; ErrNotFound when no such tenant.
	SetBoxJoinEnabled(ctx context.Context, tenant string, on bool) error
	// PinBoxMode is the box mode box's pin recorded at join; "" when none
	// (a root-key pin, or a pin before 0170). ErrNotFound when no pin.
	PinBoxMode(ctx context.Context, tenant, box string) (string, error)
}

var (
	_ BoxJoinSwitch = (*Memory)(nil)
	_ BoxJoinSwitch = (*Postgres)(nil)
)

// ---- Memory -----------------------------------------------------------------

func (s *Memory) BoxJoinEnabled(_ context.Context, tenant string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	return s.boxJoinOn[tenant], nil
}

func (s *Memory) SetBoxJoinEnabled(_ context.Context, tenant string, on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.boxJoinOn == nil {
		s.boxJoinOn = map[string]bool{}
	}
	if on {
		s.boxJoinOn[tenant] = true
	} else {
		delete(s.boxJoinOn, tenant)
	}
	return nil
}

func (s *Memory) PinBoxMode(_ context.Context, tenant, box string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.pins[[2]string{tenant, box}]
	if !ok {
		return "", ErrNotFound
	}
	return p.mode, nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) BoxJoinEnabled(ctx context.Context, tenant string) (bool, error) {
	var on bool
	err := s.queryRowTenant(ctx, tenant, `SELECT box_join_enabled FROM tenants WHERE tenant_id = $1`,
		[]any{tenant}, &on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return on, err
}

func (s *Postgres) SetBoxJoinEnabled(ctx context.Context, tenant string, on bool) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET box_join_enabled = $2 WHERE tenant_id = $1`, tenant, on)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) PinBoxMode(ctx context.Context, tenant, box string) (string, error) {
	var mode string
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(box_mode, '') FROM pins
		WHERE tenant_id = $1 AND box_id = $2`, []any{tenant, box}, &mode)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return mode, err
}
