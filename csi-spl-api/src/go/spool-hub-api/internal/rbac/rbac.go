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
	TopicsRead     = "topics.read"
	NotesSend      = "notes.send"
	AgentsCommand  = "agents.command"
	ChannelsManage = "channels.manage"
	MembersInvite  = "members.invite"
	MembersRoles   = "members.roles"
	BillingManage  = "billing.manage"
	TenantSettings = "tenant.settings"
	KeysManage     = "keys.manage"
	AuditRead      = "audit.read"
	// MembersImpersonate is the permission to start an "act as a member"
	// session through a temporary clone (specs/054). biz_owner and admin.
	MembersImpersonate = "members.impersonate"
	// AgentsJoin is the permission to mint, list and revoke agent join tokens
	// and to revoke one seat from the WUI (specs/073 §4.7). admin only: the
	// one permission biz_owner does not hold (owner 2026-10-04, Q1).
	AgentsJoin = "agents.join"
	// DocsRead and DocsWrite gate the workspace docs (specs/075 Phase 2).
	// Every role holds both for now (owner, 9f0d751c: "all of the users to
	// be able to edit docs"); "who edits what" later is a grant change.
	DocsRead  = "docs.read"
	DocsWrite = "docs.write"
	// FilesWrite, TopicsManage, SelfKeys and ChannelsEdit close the demo gaps
	// on data (specs/077 §3.2, rdb 0124): every role but demo_user holds all four.
	FilesWrite   = "files.write"   // upload and delete files, the WUI upload token
	TopicsManage = "topics.manage" // move / merge / promote topics; create and edit issues
	SelfKeys     = "self.keys"     // a human's own keys and event-log writes
	ChannelsEdit = "channels.edit" // channel members, agents, invite setting, archive, delete
	// HoursRead and HoursApprove gate the team side of hours tracking
	// (specs/107 §6.1, rdb 0151): biz_owner only (owner Q5 = A); a member's
	// own hours need neither.
	HoursRead    = "hours.read"    // every member's approved hours and period states; download
	HoursApprove = "hours.approve" // approve or return a member's frozen period
)

// System role ids (025 §3.2). BizOwner is the tenant owner (owner decision
// 2026-09-19: "tenant owner = biz-owner"). BizCustomer and RegularUser: owner
// 2026-09-25, "for now will have the same permissions as the Developer role".
const (
	BizOwner     = "biz_owner"
	ProductOwner = "product_owner"
	Admin        = "admin"
	Developer    = "developer"
	Tester       = "tester"
	PureAgent    = "pure_agent"
	BizCustomer  = "biz_customer"
	RegularUser  = "regular_user"
	// DemoUser is a visitor from the Internet (specs/077): read, post, talk to
	// the demo agents. Not in RoleIDs: no member route grants it, and the hub
	// grants it nothing outside the open demo workspace (hub/demo.go).
	DemoUser = "demo_user"
)

// RoleIDs is every system role id, in the spec's order.
var RoleIDs = []string{BizOwner, ProductOwner, Admin, Developer, Tester, PureAgent, BizCustomer, RegularUser}

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
	{TopicsRead, "read roster, channels and topics; open the WUI socket"},
	{NotesSend, "post a note from the WUI"},
	{AgentsCommand, "command an agent through box-wui dispatch"},
	{ChannelsManage, "create channels"},
	{MembersInvite, "invite and remove members"},
	{MembersRoles, "change a member's role"},
	{BillingManage, "billing, checkout and seats of the tenant"},
	{TenantSettings, "tenant settings"},
	{KeysManage, "tenant-level keys (box pins, the box-wui pin)"},
	{AuditRead, "see the tenant audit trail"},
	{MembersImpersonate, "act as a member through a temporary clone"},
	{AgentsJoin, "mint, list and revoke agent join tokens, and revoke one seat from the WUI"},
	{DocsRead, "read the workspace docs"},
	{DocsWrite, "create, edit and delete the workspace docs"},
	{FilesWrite, "upload and delete files"},
	{TopicsManage, "move, merge and promote topics; create and edit issues"},
	{SelfKeys, "add and revoke one's own keys; write one's own event log"},
	{ChannelsEdit, "add or remove channel members and agents; archive or delete a channel"},
	{HoursRead, "see every member's approved hours and period states; download them"},
	{HoursApprove, "approve or return a member's frozen hours period"},
}

// Defaults is the system role seed (025 §3.2, OQ-1..8 defaults; rdb 0021,
// 0029, 0039, 0074, 0119, 0123, 0124, 0151). biz_owner holds every permission but agents.join:
// rdb 0039 had made members.invite the admin's only, and 0074 returns it
// (owner 2026-09-28, specs/046: "the admins and the biz_owners of the tenant
// can CRUD users"); agents.join is admin only (specs/073 §4.7, Q1). rdb 0124
// gives every role files.write, topics.manage, self.keys and channels.edit, and adds
// demo_user without them (specs/077). rdb 0151 gives hours.read and
// hours.approve to biz_owner alone (specs/107 §6.1, owner Q5 = A).
var Defaults = []Role{
	{ID: BizOwner, TenantOwner: true, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage,
		MembersInvite, MembersRoles, BillingManage, TenantSettings, KeysManage, AuditRead, MembersImpersonate, DocsRead, DocsWrite,
		HoursRead, HoursApprove)},
	{ID: ProductOwner, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage, AuditRead, DocsRead, DocsWrite)},
	{ID: Admin, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage,
		MembersInvite, MembersRoles, TenantSettings, KeysManage, AuditRead, MembersImpersonate, AgentsJoin, DocsRead, DocsWrite)},
	{ID: Developer, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage, DocsRead, DocsWrite)},
	{ID: Tester, Perms: withMember(TopicsRead, NotesSend, DocsRead, DocsWrite)},
	{ID: PureAgent, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, DocsRead, DocsWrite)},
	{ID: BizCustomer, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage, DocsRead, DocsWrite)},
	{ID: RegularUser, Perms: withMember(TopicsRead, NotesSend, AgentsCommand, ChannelsManage, DocsRead, DocsWrite)},
	{ID: DemoUser, Perms: sorted(TopicsRead, NotesSend, AgentsCommand, DocsRead)},
}

// withMember is p plus the four permissions every member role holds and
// demo_user does not (rdb 0124), sorted.
func withMember(p ...string) []string {
	return sorted(append(p, FilesWrite, TopicsManage, SelfKeys, ChannelsEdit)...)
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
// The tenant owner covers every role: it held every permission until
// agents.join (specs/073 §4.7), which is admin only for the session that
// mints, not a bar on the owner appointing or managing an admin.
func (a Access) Covers(r Role) bool {
	if a.TenantOwner {
		return true
	}
	for _, p := range r.Perms {
		if !a.Perms[p] {
			return false
		}
	}
	return true
}

// CoversAccess reports perms(b) ⊆ perms(a). With the strict form (a covers b
// AND b does not cover a) it is the act-as role ceiling (specs/054): an admin
// may clone a strictly-lower member, never a peer admin or the owner. The
// tenant owner covers everyone, as in Covers.
func (a Access) CoversAccess(b Access) bool {
	if a.TenantOwner {
		return true
	}
	for p, ok := range b.Perms {
		if ok && !a.Perms[p] {
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

// Fixed grants every caller the Defaults role it names. It is a seam for
// tests and lde rigs whose humans come from a session stub, never a store.
type Fixed string

// Access answers the fixed role's Defaults grants.
func (f Fixed) Access(_ context.Context, humanID, _ string) (Access, error) {
	r, ok := DefaultRoles()[string(f)]
	if !ok {
		return Access{}, ErrNotMember
	}
	a := Access{HumanID: humanID, Role: r.ID, TenantOwner: r.TenantOwner, Perms: map[string]bool{}}
	for _, p := range r.Perms {
		a.Perms[p] = true
	}
	return a, nil
}

// Roles answers Defaults.
func (Fixed) Roles(context.Context, string) (map[string]Role, error) { return DefaultRoles(), nil }
