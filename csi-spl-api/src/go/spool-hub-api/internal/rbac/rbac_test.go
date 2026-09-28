package rbac

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

type fakeSrc struct {
	members map[string]string
	roles   map[string]Role
	calls   int
	err     error
}

func (f *fakeSrc) MemberRole(_ context.Context, hum, _ string) (string, error) {
	if r, ok := f.members[hum]; ok {
		return r, nil
	}
	return "", ErrNotMember
}

func (f *fakeSrc) TenantRoles(context.Context, string) (map[string]Role, error) {
	f.calls++
	return f.roles, f.err
}

// 025 §3.2: the matrix as the spec states it, cell by cell for the cells the
// OQs defaulted, plus the one tenant owner: biz_owner holds every permission
// but members.invite, which is the admin's only (owner 2026-09-25).
func TestDefaultsMatrix(t *testing.T) {
	roles := DefaultRoles()
	has := func(role, perm string) bool {
		for _, p := range roles[role].Perms {
			if p == perm {
				return true
			}
		}
		return false
	}
	if len(roles) != 8 || len(RoleIDs) != len(roles) {
		t.Fatalf("roles: %d", len(roles))
	}
	all := map[string]bool{}
	for _, p := range Permissions {
		all[p.ID] = true
	}
	owners := 0
	for _, r := range roles {
		if r.TenantOwner {
			owners++
		}
		for _, p := range r.Perms {
			if !all[p] {
				t.Fatalf("%s grants unknown %s", r.ID, p)
			}
		}
	}
	if owners != 1 || !roles[BizOwner].TenantOwner || len(roles[BizOwner].Perms) != len(Permissions) {
		t.Fatalf("biz_owner must be the one tenant owner with every permission: %+v", roles[BizOwner])
	}
	for _, id := range RoleIDs {
		if _, ok := roles[id]; !ok {
			t.Fatalf("RoleIDs names %s, Defaults lacks it", id)
		}
	}
	for _, r := range roles {
		if r.ID != Admin && r.ID != BizOwner && has(r.ID, MembersInvite) {
			t.Errorf("%s holds members.invite: only admin and biz_owner may (specs/046)", r.ID)
		}
	}
	for _, id := range []string{BizCustomer, RegularUser} {
		if !reflect.DeepEqual(roles[id].Perms, roles[Developer].Perms) {
			t.Errorf("%s %v, want developer's %v", id, roles[id].Perms, roles[Developer].Perms)
		}
	}
	for _, c := range []struct {
		role, perm string
		want       bool
	}{
		{Tester, AgentsCommand, false}, {Tester, NotesSend, true}, {Tester, ChannelsManage, false},
		{Developer, AgentsCommand, true}, {Developer, MembersRoles, false}, {Developer, KeysManage, false},
		{Admin, BillingManage, false}, {Admin, MembersRoles, true}, {Admin, MembersInvite, true},
		{ProductOwner, MembersInvite, false}, {ProductOwner, AuditRead, true},
		{PureAgent, AgentsCommand, true}, {PureAgent, ChannelsManage, false}, {PureAgent, MembersInvite, false},
	} {
		if has(c.role, c.perm) != c.want {
			t.Errorf("%s %s = %v, want %v", c.role, c.perm, !c.want, c.want)
		}
	}
	for _, r := range roles {
		if !has(r.ID, TopicsRead) {
			t.Errorf("%s cannot read", r.ID)
		}
	}
}

// §3.4: covers = subset. CONTROL: admin covers developer but not biz_owner.
func TestCoversNoEscalation(t *testing.T) {
	z := &Authorizer{Src: &fakeSrc{members: map[string]string{"HUM-1": Admin}, roles: DefaultRoles()}}
	a, err := z.Access(context.Background(), "HUM-1", "t1")
	if err != nil {
		t.Fatal(err)
	}
	roles := DefaultRoles()
	if !a.Covers(roles[Developer]) || !a.Covers(roles[Admin]) || !a.Covers(roles[ProductOwner]) {
		t.Fatal("admin must cover developer, admin, product_owner")
	}
	if a.Covers(roles[BizOwner]) {
		t.Fatal("CONTROL: admin covers biz_owner")
	}
}

// FR-004: role table cached for TTL, membership never; errors deny.
func TestAuthorizerCacheAndFailClosed(t *testing.T) {
	now := time.Unix(1000, 0)
	src := &fakeSrc{members: map[string]string{"HUM-1": Developer, "HUM-2": "ghost"}, roles: DefaultRoles()}
	z := &Authorizer{Src: src, TTL: time.Minute, Now: func() time.Time { return now }}
	ctx := context.Background()
	if !z.Can(ctx, "HUM-1", "t1", AgentsCommand) || z.Can(ctx, "HUM-1", "t1", MembersRoles) {
		t.Fatal("developer grants")
	}
	z.Can(ctx, "HUM-1", "t1", NotesSend)
	if src.calls != 1 {
		t.Fatalf("role table fetched %d times within TTL", src.calls)
	}
	// Demotion bites at once: membership is read every time.
	src.members["HUM-1"] = Tester
	if z.Can(ctx, "HUM-1", "t1", AgentsCommand) {
		t.Fatal("demoted member still commands agents")
	}
	now = now.Add(2 * time.Minute)
	z.Can(ctx, "HUM-1", "t1", NotesSend)
	if src.calls != 2 {
		t.Fatalf("role table not refreshed after TTL: %d", src.calls)
	}
	// Not a member, unknown role, source error: all deny.
	if z.Can(ctx, "HUM-9", "t1", TopicsRead) {
		t.Fatal("non-member allowed")
	}
	if _, err := z.Access(ctx, "HUM-9", "t1"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("non-member err: %v", err)
	}
	if z.Can(ctx, "HUM-2", "t1", TopicsRead) {
		t.Fatal("unknown role allowed")
	}
	src.err = errors.New("db down")
	z.Invalidate("t1")
	if z.Can(ctx, "HUM-1", "t1", TopicsRead) {
		t.Fatal("source error allowed")
	}
}

func TestLegacy(t *testing.T) {
	if Legacy("owner") != BizOwner || Legacy("member") != Developer || Legacy("tester") != Tester {
		t.Fatal("legacy mapping")
	}
}
