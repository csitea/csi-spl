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
// but agents.join, which is the admin's only (specs/073 §4.7, Q1), and
// hours.rates, which is time_accountant's only (specs/107 FR-20).
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
	// demo_user (specs/077), channel_guest (specs/121) and time_accountant
	// (specs/107 T065; its invite is T047's) are roles no member route
	// grants: not in RoleIDs.
	if len(roles) != 11 || len(RoleIDs) != len(roles)-3 {
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
	if owners != 1 || !roles[BizOwner].TenantOwner || len(roles[BizOwner].Perms) != len(Permissions)-2 || has(BizOwner, AgentsJoin) || has(BizOwner, HoursRates) {
		t.Fatalf("biz_owner must be the one tenant owner with every permission but agents.join and hours.rates: %+v", roles[BizOwner])
	}
	for _, r := range roles { // specs/073 §4.7 (Q1): agents.join is admin only
		if has(r.ID, AgentsJoin) != (r.ID == Admin) {
			t.Errorf("%s agents.join = %v, want %v (admin only)", r.ID, !(r.ID == Admin), r.ID == Admin)
		}
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
		if r.ID != ChannelGuest && r.ID != TimeAccountant && !has(r.ID, TopicsRead) {
			t.Errorf("%s cannot read", r.ID)
		}
	}
	// specs/121 4.2: channel_guest holds nothing; its channel is reached by
	// its token under the channel scope, never through a permission.
	if g, ok := roles[ChannelGuest]; !ok || len(g.Perms) != 0 || g.TenantOwner {
		t.Errorf("channel_guest %+v (present %v), want no permission", g, ok)
	}
	// specs/077 §3.2: every member role holds files.write, topics.manage,
	// self.keys and channels.edit; demo_user holds exactly read, post,
	// agents.command and docs.read.
	for _, id := range RoleIDs {
		for _, p := range []string{FilesWrite, TopicsManage, SelfKeys, ChannelsEdit} {
			if !has(id, p) {
				t.Errorf("%s lacks %s", id, p)
			}
		}
	}
	if !reflect.DeepEqual(roles[DemoUser].Perms, sorted(AgentsCommand, DocsRead, NotesSend, TopicsRead)) || roles[DemoUser].TenantOwner {
		t.Errorf("demo_user %+v, want topics.read, notes.send, agents.command, docs.read only", roles[DemoUser])
	}
	for _, id := range RoleIDs {
		if id == DemoUser || id == ChannelGuest || id == TimeAccountant {
			t.Errorf("CONTROL: RoleIDs names %s: the Users page would offer it", id)
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
	// specs/073: biz_owner lacks agents.join yet still appoints and manages admins.
	owner := Access{Role: BizOwner, TenantOwner: true, Perms: map[string]bool{}}
	for _, p := range roles[BizOwner].Perms {
		owner.Perms[p] = true
	}
	if owner.Perms[AgentsJoin] || !owner.Covers(roles[Admin]) {
		t.Fatal("biz_owner must cover admin without holding agents.join")
	}
}

// specs/107 §6.1 (owner Q5 = A): hours.read and hours.approve are biz_owner's;
// every other role, demo_user included, holds neither, but for v2's
// time_accountant, which reads (FR-20, TestTimeAccountantHoursRates).
// CONTROL: the Fixed seam answers the same, so a route asking for them
// denies an admin.
func TestHoursPermissionsBizOwnerOnly(t *testing.T) {
	roles := DefaultRoles()
	for _, r := range roles {
		for _, p := range []string{HoursRead, HoursApprove} {
			held := false
			for _, q := range r.Perms {
				held = held || q == p
			}
			want := r.ID == BizOwner || (r.ID == TimeAccountant && p == HoursRead)
			if held != want {
				t.Errorf("%s %s = %v, want %v (biz_owner only, time_accountant reads)", r.ID, p, held, want)
			}
		}
	}
	ctx := context.Background()
	for _, c := range []struct {
		role string
		want bool
	}{{BizOwner, true}, {Admin, false}, {ProductOwner, false}, {Developer, false}, {DemoUser, false}} {
		a, err := Fixed(c.role).Access(ctx, "HUM-1", "t1")
		if err != nil {
			t.Fatal(err)
		}
		if a.Can(HoursRead) != c.want || a.Can(HoursApprove) != c.want {
			t.Errorf("%s via Fixed: hours.read=%v hours.approve=%v, want %v", c.role, a.Can(HoursRead), a.Can(HoursApprove), c.want)
		}
	}
	// The biz owner still covers the admin it manages, and the admin still
	// does not cover the biz owner (now two more permissions apart).
	if a, _ := Fixed(Admin).Access(ctx, "HUM-2", "t1"); a.Covers(roles[BizOwner]) {
		t.Error("admin covers biz_owner")
	}
}

// specs/123 §5.1 (owner Q-1 = A): costs.read is biz_owner's and admin's;
// every other role, demo_user included, lacks it. It is its own permission,
// not billing.manage: the admin holds costs.read without billing.manage.
// CONTROL: the Fixed seam answers the same, so a developer is denied.
func TestCostsReadBizOwnerAndAdmin(t *testing.T) {
	for _, r := range DefaultRoles() {
		held := false
		for _, q := range r.Perms {
			held = held || q == CostsRead
		}
		if want := r.ID == BizOwner || r.ID == Admin; held != want {
			t.Errorf("%s costs.read = %v, want %v", r.ID, held, want)
		}
	}
	ctx := context.Background()
	for _, c := range []struct {
		role string
		want bool
	}{{BizOwner, true}, {Admin, true}, {ProductOwner, false}, {Developer, false}, {Tester, false},
		{PureAgent, false}, {BizCustomer, false}, {RegularUser, false}, {DemoUser, false}} {
		a, err := Fixed(c.role).Access(ctx, "HUM-1", "t1")
		if err != nil {
			t.Fatal(err)
		}
		if a.Can(CostsRead) != c.want {
			t.Errorf("%s via Fixed: costs.read=%v, want %v", c.role, a.Can(CostsRead), c.want)
		}
	}
	if a, _ := Fixed(Admin).Access(ctx, "HUM-2", "t1"); a.Can(BillingManage) {
		t.Error("admin holds billing.manage: costs.read must not ride on it")
	}
}

// specs/107 FR-20, FR-21 (T065): time_accountant holds exactly hours.read
// and hours.rates, none of the four permissions every member role holds
// (withMember) and no topics.read; hours.rates is pinned to it, the biz
// owner's role included. CONTROL: a seat holding developer and
// time_accountant gets the union, rates included; developer alone not.
func TestTimeAccountantHoursRates(t *testing.T) {
	roles := DefaultRoles()
	ta, ok := roles[TimeAccountant]
	if !ok || ta.TenantOwner || !reflect.DeepEqual(ta.Perms, []string{HoursRates, HoursRead}) {
		t.Fatalf("time_accountant %+v (present %v), want exactly hours.rates + hours.read", ta, ok)
	}
	for _, r := range roles {
		for _, q := range r.Perms {
			if q == HoursRates && r.ID != TimeAccountant {
				t.Errorf("%s holds hours.rates: it is time_accountant's only", r.ID)
			}
		}
	}
	documented := false
	for _, p := range Permissions {
		documented = documented || p.ID == HoursRates
	}
	if !documented {
		t.Error("hours.rates is not in the Permissions catalogue")
	}
	ctx := context.Background()
	a, err := FixedSet{TimeAccountant}.Access(ctx, "HUM-1", "t1")
	if err != nil {
		t.Fatal(err)
	}
	if !a.Can(HoursRates) || !a.Can(HoursRead) || a.Can(HoursApprove) || a.Can(TopicsRead) || a.Can(FilesWrite) || a.Can(DocsRead) {
		t.Errorf("time_accountant seat grants %v", a.List())
	}
	both, err := FixedSet{Developer, TimeAccountant}.Access(ctx, "HUM-2", "t1")
	if err != nil {
		t.Fatal(err)
	}
	if !both.Can(HoursRates) || !both.Can(TopicsRead) || !both.Can(AgentsCommand) {
		t.Errorf("developer + time_accountant grants %v, want the union", both.List())
	}
	if dev, _ := Fixed(Developer).Access(ctx, "HUM-3", "t1"); dev.Can(HoursRates) || dev.Can(HoursRead) {
		t.Error("CONTROL: developer alone reads hours or rates")
	}
	if owner, _ := Fixed(BizOwner).Access(ctx, "HUM-4", "t1"); owner.Can(HoursRates) {
		t.Error("biz_owner holds hours.rates: it assigns itself time_accountant instead (FR-20)")
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

// setSrc is a fakeSrc that also answers role sets (SetSource).
type setSrc struct {
	fakeSrc
	sets map[string][]string
}

func (f *setSrc) MemberRoles(_ context.Context, hum, _ string) ([]string, error) {
	if s, ok := f.sets[hum]; ok {
		return s, nil
	}
	return nil, ErrNotMember
}

// 025 §10.2: the Authorizer grants the union of the member's role set; Role
// is the primary, TenantOwner holds when any role is a tenant owner; Has and
// HasAny read the set. A Source that is no SetSource still answers the
// primary alone (CONTROL: the same member through it lacks the union).
func TestAccessUnionOfRoles(t *testing.T) {
	ctx := context.Background()
	src := &setSrc{fakeSrc: fakeSrc{members: map[string]string{"HUM-1": Tester}, roles: DefaultRoles()},
		sets: map[string][]string{"HUM-1": {Tester, Developer}, "HUM-2": {Tester, BizOwner}, "HUM-3": {}}}
	z := &Authorizer{Src: src}
	a, err := z.Access(ctx, "HUM-1", "t1")
	if err != nil {
		t.Fatal(err)
	}
	if a.Role != Tester || !reflect.DeepEqual(a.Roles, []string{Tester, Developer}) || a.TenantOwner {
		t.Fatalf("access %+v", a)
	}
	if !a.Can(AgentsCommand) || !a.Can(ChannelsManage) || a.Can(MembersRoles) {
		t.Fatalf("union perms %v", a.List())
	}
	if !a.Has(Developer) || a.Has(Admin) || !a.HasAny(Admin, Developer) || a.HasAny(Admin, BizOwner) || a.HasAny() {
		t.Fatal("Has / HasAny")
	}
	if a, _ := z.Access(ctx, "HUM-2", "t1"); !a.TenantOwner || a.Role != Tester || !a.Can(HoursApprove) {
		t.Fatalf("owner in the set: %+v", a)
	}
	if _, err := z.Access(ctx, "HUM-3", "t1"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("empty set: %v", err)
	}
	// CONTROL: the primary-only Source.
	if a, _ := (&Authorizer{Src: &src.fakeSrc}).Access(ctx, "HUM-1", "t1"); a.Can(AgentsCommand) ||
		!reflect.DeepEqual(a.Roles, []string{Tester}) {
		t.Fatalf("primary-only source: %+v", a)
	}
}

// FixedSet is the test seam for a several-role member; Fixed is its
// one-role case.
func TestFixedSet(t *testing.T) {
	ctx := context.Background()
	a, err := FixedSet{Tester, PureAgent}.Access(ctx, "HUM-1", "t1")
	if err != nil || a.Role != Tester || !a.Can(AgentsCommand) || !a.Has(PureAgent) {
		t.Fatalf("FixedSet %+v %v", a, err)
	}
	if _, err := (FixedSet{Tester, "ghost"}).Access(ctx, "HUM-1", "t1"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("unknown role: %v", err)
	}
	if _, err := (FixedSet{}).Access(ctx, "HUM-1", "t1"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("empty: %v", err)
	}
	if a, _ := Fixed(Admin).Access(ctx, "HUM-1", "t1"); !reflect.DeepEqual(a.Roles, []string{Admin}) {
		t.Fatalf("Fixed roles %v", a.Roles)
	}
	if !Exclusive(DemoUser) || !Exclusive(ChannelGuest) || Exclusive(Admin) {
		t.Fatal("Exclusive")
	}
}
