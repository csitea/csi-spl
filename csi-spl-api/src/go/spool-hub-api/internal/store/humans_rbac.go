package store

import (
	"context"
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5/pgconn"
)

// Tenant roles and permissions (specs/025, rdb 0021_tenant_rbac.sql).

// RBACSource adapts Humans to rbac.Source: a missing membership is
// rbac.ErrNotMember.
type RBACSource struct{ H Humans }

var _ rbac.Source = RBACSource{}

func (r RBACSource) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	role, err := r.H.MemberRole(ctx, humanID, tenant)
	if errors.Is(err, ErrNotFound) {
		return "", rbac.ErrNotMember
	}
	return role, err
}

func (r RBACSource) TenantRoles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return r.H.TenantRoles(ctx, tenant)
}

// memRoles is Memory's role table: the phase-1 seed (no custom roles).
func memRoles() map[string]rbac.Role { return rbac.DefaultRoles() }

func isFKViolation(err error, constraint string) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23503" && pe.ConstraintName == constraint
}

func (s *Memory) TenantRoles(context.Context, string) (map[string]rbac.Role, error) {
	return memRoles(), nil
}

// memOwnersLeft counts the other enabled members of tenant holding a
// tenant-owner role. Caller holds s.mu.
func (s *Memory) memOwnersLeft(tenant, except string) int {
	roles, n := memRoles(), 0
	for k, m := range s.hum.members {
		if k[0] != tenant || k[1] == except || !roles[m.role].TenantOwner {
			continue
		}
		if hm, ok := s.hum.humans[k[1]]; ok && !hm.disabled {
			n++
		}
	}
	return n
}

func (s *Memory) SetMemberRole(_ context.Context, tenant, humanID, role, from string) error {
	role, err := normalizeRole(role, "")
	if err != nil {
		return err
	}
	roles := memRoles()
	if _, ok := roles[role]; !ok {
		return ErrUnknownRole
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if from != "" && m.role != rbac.Legacy(from) {
		return ErrRoleChanged
	}
	if roles[m.role].TenantOwner && !roles[role].TenantOwner && s.memOwnersLeft(tenant, humanID) == 0 {
		return ErrLastOwner
	}
	m.role = role
	s.hum.members[k] = m
	return nil
}

func (s *Memory) RemoveMember(_ context.Context, tenant, humanID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if memRoles()[m.role].TenantOwner && s.memOwnersLeft(tenant, humanID) == 0 {
		return ErrLastOwner
	}
	delete(s.hum.members, k)
	return nil
}
