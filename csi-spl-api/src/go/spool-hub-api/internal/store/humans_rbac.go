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

var _ rbac.SetSource = RBACSource{}

func (r RBACSource) MemberRole(ctx context.Context, humanID, tenant string) (string, error) {
	role, err := r.H.MemberRole(ctx, humanID, tenant)
	if errors.Is(err, ErrNotFound) {
		return "", rbac.ErrNotMember
	}
	return role, err
}

// MemberRoles answers the member's role set (rbac.SetSource): the
// Authorizer grants the union of its roles.
func (r RBACSource) MemberRoles(ctx context.Context, humanID, tenant string) ([]string, error) {
	set, err := r.H.MemberRoles(ctx, humanID, tenant)
	if errors.Is(err, ErrNotFound) {
		return nil, rbac.ErrNotMember
	}
	return set, err
}

func (r RBACSource) TenantRoles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return r.H.TenantRoles(ctx, tenant)
}

// memRoles is Memory's role table: the phase-1 seed (no custom roles).
func memRoles() map[string]rbac.Role { return rbac.DefaultRoles() }

// isFKViolation reports a foreign_key_violation (SQLSTATE 23503) on constraint.
func isFKViolation(err error, constraint string) bool {
	var pe *pgconn.PgError
	return sqlState(err) == "23503" && errors.As(err, &pe) && pe.ConstraintName == constraint
}

func (s *Memory) TenantRoles(context.Context, string) (map[string]rbac.Role, error) {
	return memRoles(), nil
}

// setOwner reports whether any role of set is a tenant-owner role.
func setOwner(roles map[string]rbac.Role, set []string) bool {
	for _, r := range set {
		if roles[r].TenantOwner {
			return true
		}
	}
	return false
}

// setGrants reports whether any role of set grants perm.
func setGrants(roles map[string]rbac.Role, set []string, perm string) bool {
	for _, r := range set {
		if grants(roles[r], perm) {
			return true
		}
	}
	return false
}

// memOwnersLeft counts the other enabled members of tenant whose role set
// holds a tenant-owner role. Caller holds s.mu.
func (s *Memory) memOwnersLeft(tenant, except string) int {
	roles, n := memRoles(), 0
	for k, m := range s.hum.members {
		if k[0] != tenant || k[1] == except || m.disabled || !setOwner(roles, m.roleSet()) {
			continue
		}
		if hm, ok := s.hum.humans[k[1]]; ok && !hm.disabled {
			n++
		}
	}
	return n
}

// memAdminsLeft counts the other enabled members of tenant whose role set
// grants members.invite (the last-admin guard). Caller holds s.mu.
func (s *Memory) memAdminsLeft(tenant, except string) int {
	roles, n := memRoles(), 0
	for k, m := range s.hum.members {
		if k[0] != tenant || k[1] == except || m.disabled || !setGrants(roles, m.roleSet(), rbac.MembersInvite) {
			continue
		}
		if hm, ok := s.hum.humans[k[1]]; ok && !hm.disabled {
			n++
		}
	}
	return n
}

func grants(r rbac.Role, perm string) bool {
	for _, p := range r.Perms {
		if p == perm {
			return true
		}
	}
	return false
}

// memSetGuard is ErrLastOwner / ErrLastAdmin when moving humanID's role set
// from cur to next (nil = removal or lock-out) would leave tenant with no
// enabled owner / member manager. Caller holds s.mu.
func (s *Memory) memSetGuard(tenant, humanID string, cur, next []string) error {
	roles := memRoles()
	if setOwner(roles, cur) && !setOwner(roles, next) && s.memOwnersLeft(tenant, humanID) == 0 {
		return ErrLastOwner
	}
	if setGrants(roles, cur, rbac.MembersInvite) && !setGrants(roles, next, rbac.MembersInvite) && s.memAdminsLeft(tenant, humanID) == 0 {
		return ErrLastAdmin
	}
	return nil
}

func (s *Memory) SetMemberRole(_ context.Context, tenant, humanID, role, from string) error {
	role, err := normalizeRole(role, "")
	if err != nil {
		return err
	}
	return s.setMemberRoles(tenant, humanID, []string{role}, role, func(m memMember) bool {
		return from == "" || m.role == rbac.Legacy(from)
	})
}

// SetMemberRoles sets the member's whole role set (Humans.SetMemberRoles).
func (s *Memory) SetMemberRoles(_ context.Context, tenant, humanID string, roles []string, primary string, from []string) error {
	set, primary, err := normalizeRoleSet(roles, primary)
	if err != nil {
		return err
	}
	return s.setMemberRoles(tenant, humanID, set, primary, func(m memMember) bool {
		return from == nil || sameRoles(m.roleSet(), from)
	})
}

// setMemberRoles writes a normalized set; primary "" is pickPrimary's.
// fromOK is the optimistic check on the member as it stands.
func (s *Memory) setMemberRoles(tenant, humanID string, set []string, primary string, fromOK func(memMember) bool) error {
	roles := memRoles()
	for _, r := range set {
		if _, ok := roles[r]; !ok {
			return ErrUnknownRole
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if !fromOK(m) {
		return ErrRoleChanged
	}
	if err := s.memSetGuard(tenant, humanID, m.roleSet(), set); err != nil {
		return err
	}
	m.role = pickPrimary(set, primary, m.role)
	m.extra = orderRoles(m.role, set)[1:]
	if len(m.extra) == 0 {
		m.extra = nil
	}
	s.hum.members[k] = m
	return nil
}

func (s *Memory) RemoveMember(_ context.Context, tenant, humanID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.removeMemberLocked(tenant, humanID)
}

// removeMemberLocked is RemoveMember with s.mu held (BanMember shares it).
func (s *Memory) removeMemberLocked(tenant, humanID string) error {
	s.hum.init()
	k := [2]string{tenant, humanID}
	m, ok := s.hum.members[k]
	if !ok {
		return ErrNotFound
	}
	if err := s.memSetGuard(tenant, humanID, m.roleSet(), nil); err != nil {
		return err
	}
	delete(s.hum.members, k)
	return nil
}
