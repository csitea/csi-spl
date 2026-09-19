// Package rbac is the tenant authorizer of specs/025: roles, permissions and
// the role -> permission grant are rows (rdb 0021_tenant_rbac.sql); the hub
// asks for a PERMISSION at each entry point, never for a role name.
//
// Defaults is the phase-1 seed. The migration seeds the same rows and the
// Postgres suite asserts they match (store TestRBACSeedMatchesDefaults); the
// memory store runs on Defaults directly.
package rbac

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Permission ids (025 §3.1).
const (
	ThreadsRead    = "threads.read"
	NotesSend      = "notes.send"
	AgentsCommand  = "agents.command"
	ChannelsManage = "channels.manage"
	MembersInvite  = "members.invite"
	MembersRoles   = "members.roles"
	BillingManage  = "billing.manage"
	TenantSettings = "tenant.settings"
	KeysManage     = "keys.manage"
	AuditRead      = "audit.read"
)

// System role ids (025 §3.2). BizOwner is the tenant owner (owner decision
// 2026-09-19: "tenant owner = biz-owner").
const (
	BizOwner     = "biz_owner"
	ProductOwner = "product_owner"
	Admin        = "admin"
	Developer    = "developer"
	Tester       = "tester"
	PureAgent    = "pure_agent"
)

// ErrNotMember: the human holds no role in the tenant (or is disabled).
var ErrNotMember = errors.New("rbac: not a member of the tenant")

// Role is one role visible to a tenant and what it grants.
type Role struct {
	ID          string
	TenantOwner bool
	Perms       []string // sorted
}

// PermissionDoc is one catalogue row (rbac_permissions).
type PermissionDoc struct{ ID, Description string }

// Permissions is the phase-1 catalogue, in the order the spec lists it.
var Permissions = []PermissionDoc{
	{ThreadsRead, "read roster, channels and threads; open the WUI socket"},
	{NotesSend, "post a note from the WUI"},
	{AgentsCommand, "command an agent through box-wui dispatch"},
	{ChannelsManage, "create channels"},
	{MembersInvite, "invite and remove members"},
	{MembersRoles, "change a member's role"},
	{BillingManage, "billing, checkout and seats of the tenant"},
	{TenantSettings, "tenant settings"},
	{KeysManage, "tenant-level keys (box pins, the box-wui pin)"},
	{AuditRead, "see the tenant audit trail"},
}

// Defaults is the phase-1 system role seed (025 §3.2, OQ-1..8 defaults).
var Defaults = []Role{
	{ID: BizOwner, TenantOwner: true, Perms: sorted(ThreadsRead, NotesSend, AgentsCommand, ChannelsManage,
		MembersInvite, MembersRoles, BillingManage, TenantSettings, KeysManage, AuditRead)},
	{ID: ProductOwner, Perms: sorted(ThreadsRead, NotesSend, AgentsCommand, ChannelsManage, AuditRead)},
	{ID: Admin, Perms: sorted(ThreadsRead, NotesSend, AgentsCommand, ChannelsManage,
		MembersInvite, MembersRoles, TenantSettings, KeysManage, AuditRead)},
	{ID: Developer, Perms: sorted(ThreadsRead, NotesSend, AgentsCommand, ChannelsManage)},
	{ID: Tester, Perms: sorted(ThreadsRead, NotesSend)},
	{ID: PureAgent, Perms: sorted(ThreadsRead, NotesSend, AgentsCommand)},
}

// DefaultRoles is Defaults keyed by id (a fresh map each call).
func DefaultRoles() map[string]Role {
	out := make(map[string]Role, len(Defaults))
	for _, r := range Defaults {
		out[r.ID] = r
	}
	return out
}

// Legacy maps the 010 role names still accepted as INPUT (old scripts,
// `spool hub-invite --role owner`) to their 025 ids; anything else is itself.
func Legacy(role string) string {
	switch role {
	case "owner":
		return BizOwner
	case "member":
		return Developer
	}
	return role
}

func sorted(p ...string) []string {
	sort.Strings(p)
	return p
}

// Access is one human's standing in one tenant.
type Access struct {
	HumanID     string
	Role        string
	TenantOwner bool
	Perms       map[string]bool
}

// Can reports one permission.
func (a Access) Can(perm string) bool { return a.Perms[perm] }

// List is the granted permissions, sorted.
func (a Access) List() []string {
	out := make([]string, 0, len(a.Perms))
	for p, ok := range a.Perms {
		if ok {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// Covers reports perms(role) ⊆ perms(a): the no-escalation rule (025 §3.4).
func (a Access) Covers(r Role) bool {
	for _, p := range r.Perms {
		if !a.Perms[p] {
			return false
		}
	}
	return true
}

// Source is the store side: the human's role (ErrNotMember when none) and the
// roles visible to a tenant.
type Source interface {
	MemberRole(ctx context.Context, humanID, tenant string) (string, error)
	TenantRoles(ctx context.Context, tenant string) (map[string]Role, error)
}

// DefaultTTL is how long a tenant's role table is cached (025 FR-004).
const DefaultTTL = time.Minute

// Authorizer answers Access with the role table cached per tenant for TTL.
// The membership lookup is never cached: a removed or demoted member loses
// access on the next request.
type Authorizer struct {
	Src Source
	TTL time.Duration    // 0 = DefaultTTL
	Now func() time.Time // nil = time.Now

	mu    sync.Mutex
	roles map[string]cached
}

type cached struct {
	at    time.Time
	roles map[string]Role
}

// Roles returns the roles visible to tenant (cached).
func (z *Authorizer) Roles(ctx context.Context, tenant string) (map[string]Role, error) {
	now := time.Now
	if z.Now != nil {
		now = z.Now
	}
	ttl := z.TTL
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	z.mu.Lock()
	c, ok := z.roles[tenant]
	z.mu.Unlock()
	if ok && now().Sub(c.at) < ttl {
		return c.roles, nil
	}
	roles, err := z.Src.TenantRoles(ctx, tenant)
	if err != nil {
		return nil, err
	}
	z.mu.Lock()
	if z.roles == nil {
		z.roles = map[string]cached{}
	}
	z.roles[tenant] = cached{at: now(), roles: roles}
	z.mu.Unlock()
	return roles, nil
}

// Invalidate drops tenant's cached role table.
func (z *Authorizer) Invalidate(tenant string) {
	z.mu.Lock()
	delete(z.roles, tenant)
	z.mu.Unlock()
}

// Access is the human's role and permissions in tenant. ErrNotMember when
// the human holds no role; a role the tenant cannot see grants nothing (an
// Access with no permissions, never an error the caller could mistake for
// "allow"). Any other error: deny.
func (z *Authorizer) Access(ctx context.Context, humanID, tenant string) (Access, error) {
	role, err := z.Src.MemberRole(ctx, humanID, tenant)
	if err != nil {
		return Access{}, err
	}
	roles, err := z.Roles(ctx, tenant)
	if err != nil {
		return Access{}, err
	}
	a := Access{HumanID: humanID, Role: role, Perms: map[string]bool{}}
	if r, ok := roles[role]; ok {
		a.TenantOwner = r.TenantOwner
		for _, p := range r.Perms {
			a.Perms[p] = true
		}
	}
	return a, nil
}

// Can reports one permission; every error is a deny.
func (z *Authorizer) Can(ctx context.Context, humanID, tenant, perm string) bool {
	a, err := z.Access(ctx, humanID, tenant)
	return err == nil && a.Can(perm)
}
