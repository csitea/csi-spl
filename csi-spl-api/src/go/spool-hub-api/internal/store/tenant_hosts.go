package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Tenant host statuses (rdb 0015, specs/022). The hub never provisions a
// host: a trigger on tenants queues one, csi-spl-orc do_spl_tenant_host_reconcile
// applies it through terraform and marks it ready.
const (
	HostPending  = "pending"
	HostReady    = "ready"
	HostFailed   = "failed"
	HostRemoving = "removing"
	HostRemoved  = "removed"
)

// TenantHost is one tenant_hosts row.
type TenantHost struct {
	TenantID  string
	Status    string
	Detail    string
	UpdatedAt time.Time
}

// TenantHosts reads (and, for the operator side and tests, sets) the host
// status of a tenant.
type TenantHosts interface {
	// TenantHost is the host row of tenantID; ErrNotFound when it has none.
	TenantHost(ctx context.Context, tenantID string) (TenantHost, error)
	// SetTenantHost sets a row's status (operator scope). The reconcile does
	// this through psql; the Go method exists for the contract tests.
	SetTenantHost(ctx context.Context, tenantID, status, detail string, now time.Time) error
}

func validHostStatus(s string) bool {
	switch s {
	case HostPending, HostReady, HostFailed, HostRemoving, HostRemoved:
		return true
	}
	return false
}

func (s *Postgres) TenantHost(ctx context.Context, tenantID string) (TenantHost, error) {
	h := TenantHost{TenantID: tenantID}
	err := s.queryRowTenant(ctx, tenantID, `SELECT status, detail, updated_at FROM tenant_hosts WHERE tenant_id = $1`,
		[]any{tenantID}, &h.Status, &h.Detail, &h.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return TenantHost{}, ErrNotFound
	}
	return h, err
}

func (s *Postgres) SetTenantHost(ctx context.Context, tenantID, status, detail string, now time.Time) error {
	if !validHostStatus(status) {
		return fmt.Errorf("tenant host status %q is not one of pending|ready|failed|removing|removed", status)
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_hosts (tenant_id, status, detail, updated_at) VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant_id) DO UPDATE SET status = $2, detail = $3, updated_at = $4`,
			tenantID, status, detail, now)
		return err
	})
}

// Memory mirrors the 0015 triggers without hooking every insert path: a
// tenant with no explicit row reads pending.
func (s *Memory) TenantHost(_ context.Context, tenantID string) (TenantHost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h, ok := s.hosts[tenantID]; ok {
		return h, nil
	}
	if _, ok := s.tenants[tenantID]; ok {
		return TenantHost{TenantID: tenantID, Status: HostPending}, nil
	}
	return TenantHost{}, ErrNotFound
}

func (s *Memory) SetTenantHost(_ context.Context, tenantID, status, detail string, now time.Time) error {
	if !validHostStatus(status) {
		return fmt.Errorf("tenant host status %q is not one of pending|ready|failed|removing|removed", status)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.hosts == nil {
		s.hosts = map[string]TenantHost{}
	}
	s.hosts[tenantID] = TenantHost{TenantID: tenantID, Status: status, Detail: detail, UpdatedAt: now}
	return nil
}
