package store

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Memory side: a per-store map beside the Memory struct (*Memory -> tenant ->
// cell -> row); the rows are guarded by s.mu.
var memRoleGrantRows sync.Map

// memRoleGrantsLocked is this store's rows per tenant. Caller holds s.mu.
func (s *Memory) memRoleGrantsLocked() map[string]map[rbac.Cell]RoleGrant {
	v, _ := memRoleGrantRows.LoadOrStore(s, map[string]map[rbac.Cell]RoleGrant{})
	return v.(map[string]map[rbac.Cell]RoleGrant)
}

// memTenantRoles is the tenant's effective role table: memRoles() with its
// rows over the cells; with no row, exactly memRoles().
func (s *Memory) memTenantRoles(tenant string) map[string]rbac.Role {
	roles := memRoles()
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := s.memRoleGrantsLocked()[tenant]
	if len(rows) == 0 {
		return roles
	}
	cells := rbac.CellsOf(roles)
	for cell, row := range rows {
		cells[cell.Action][cell.Role] = row.Granted
	}
	return rbac.Apply(roles, cells)
}

// RoleGrants is the tenant's stored rows, by role then action.
func (s *Memory) RoleGrants(_ context.Context, tenant string) ([]RoleGrant, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []RoleGrant{}
	for _, row := range s.memRoleGrantsLocked()[tenant] {
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Role != out[j].Role {
			return out[i].Role < out[j].Role
		}
		return out[i].Action < out[j].Action
	})
	return out, nil
}

// SetRoleCells writes a cell set in one transaction; other cells stay as they are.
func (s *Memory) SetRoleCells(_ context.Context, tenant, setBy string, cells []RoleCell, now time.Time) error {
	plan, err := planRoleCells(tenant, setBy, cells, now)
	if err != nil {
		return err
	}
	return s.memWriteRolePlan(tenant, plan, false)
}

// ApplyRolePreset drops the tenant's rows and writes the preset's difference from today.
func (s *Memory) ApplyRolePreset(_ context.Context, tenant, setBy, preset string, now time.Time) error {
	plan, err := planRolePreset(tenant, setBy, preset, now)
	if err != nil {
		return err
	}
	return s.memWriteRolePlan(tenant, plan, true)
}

// memWriteRolePlan applies a checked plan under one hold of s.mu; dropAll first
// clears the tenant's rows (a preset).
func (s *Memory) memWriteRolePlan(tenant string, plan roleCellPlan, dropAll bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	all := s.memRoleGrantsLocked()
	rows := all[tenant]
	if rows == nil || dropAll {
		rows = map[rbac.Cell]RoleGrant{}
		all[tenant] = rows
	}
	for _, cell := range plan.drop {
		delete(rows, cell)
	}
	for _, row := range plan.write {
		rows[rbac.Cell{Action: row.Action, Role: row.Role}] = row
	}
	return nil
}
