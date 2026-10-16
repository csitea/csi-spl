package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// Several roles per member (specs/025 §10.2, rdb 0201, row R1, SPL-2203).

// 025 §10.5 R1: a member holding tester + developer holds agents.command
// (developer's, not tester's) through the union; removing developer drops it
// on the very next request (no membership cache). The primary stays tester
// throughout, so an authorizer that reads the primary alone is red here.
func TestTenantMemberRolesUnion(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			admitAs(t, h, tid, rbac.BizOwner)
			hum := admitAs(t, h, tid, rbac.Tester)
			z := &rbac.Authorizer{Src: RBACSource{H: h}}
			if z.Can(ctx, hum, tid, rbac.AgentsCommand) {
				t.Fatal("tester alone holds agents.command")
			}
			if err := h.SetMemberRoles(ctx, tid, hum, []string{rbac.Developer, rbac.Tester}, rbac.Tester, nil); err != nil {
				t.Fatal(err)
			}
			if r, err := h.MemberRole(ctx, hum, tid); err != nil || r != rbac.Tester {
				t.Fatalf("primary %q %v, want tester", r, err)
			}
			if set, err := h.MemberRoles(ctx, hum, tid); err != nil || !reflect.DeepEqual(set, []string{rbac.Tester, rbac.Developer}) {
				t.Fatalf("set %v %v, want [tester developer]", set, err)
			}
			a, err := z.Access(ctx, hum, tid)
			if err != nil {
				t.Fatal(err)
			}
			if !a.Can(rbac.AgentsCommand) || !a.Can(rbac.TopicsRead) || a.Role != rbac.Tester ||
				!a.Has(rbac.Developer) || !a.HasAny(rbac.Admin, rbac.Developer) || a.HasAny(rbac.Admin, rbac.BizOwner) || a.TenantOwner {
				t.Fatalf("union access %+v", a)
			}
			if err := h.SetMemberRoles(ctx, tid, hum, []string{rbac.Tester}, "", nil); err != nil {
				t.Fatal(err)
			}
			if z.Can(ctx, hum, tid, rbac.AgentsCommand) {
				t.Fatal("agents.command kept after developer was removed")
			}
			// A tenant-owner role anywhere in the set makes a tenant owner.
			if err := h.SetMemberRoles(ctx, tid, hum, []string{rbac.Tester, rbac.BizOwner}, rbac.Tester, nil); err != nil {
				t.Fatal(err)
			}
			if a, _ := z.Access(ctx, hum, tid); !a.TenantOwner || !a.Can(rbac.HoursApprove) {
				t.Fatalf("owner in the set: %+v", a)
			}
		})
	}
}

// The store side of the set: its shape (ErrBadRole), the optimistic
// from-set (ErrRoleChanged), the primary pick, the last-owner and last-admin
// guards counted over sets, and the readers (ListMembers, Memberships).
func TestTenantMemberRolesStore(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			own := admitAs(t, h, tid, rbac.BizOwner)
			dev := admitAs(t, h, tid, rbac.Developer)
			for _, bad := range [][]string{nil, {rbac.DemoUser, rbac.Developer}, {rbac.ChannelGuest, rbac.Tester}} {
				if err := h.SetMemberRoles(ctx, tid, dev, bad, "", nil); !errors.Is(err, ErrBadRole) {
					t.Fatalf("set %v: %v, want ErrBadRole", bad, err)
				}
			}
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Developer}, rbac.Admin, nil); !errors.Is(err, ErrBadRole) {
				t.Fatalf("primary outside the set: %v", err)
			}
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Developer, "superuser"}, "", nil); !errors.Is(err, ErrUnknownRole) {
				t.Fatalf("unknown role in the set: %v", err)
			}
			if err := h.SetMemberRoles(ctx, tid, "HUM-999999", []string{rbac.Tester}, "", nil); !errors.Is(err, ErrNotFound) {
				t.Fatalf("non-member: %v", err)
			}
			// Legacy names map; "" primary keeps the current one in the set.
			if err := h.SetMemberRoles(ctx, tid, dev, []string{"member", rbac.RegularUser, rbac.RegularUser}, "", []string{"member"}); err != nil {
				t.Fatal(err)
			}
			if set, _ := h.MemberRoles(ctx, dev, tid); !reflect.DeepEqual(set, []string{rbac.Developer, rbac.RegularUser}) {
				t.Fatalf("set %v", set)
			}
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Tester}, "", []string{rbac.Developer}); !errors.Is(err, ErrRoleChanged) {
				t.Fatalf("stale from-set: %v", err)
			}
			// The primary leaves the set: the new primary is the set's first.
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Tester, rbac.RegularUser}, "",
				[]string{rbac.RegularUser, rbac.Developer}); err != nil {
				t.Fatal(err)
			}
			if set, _ := h.MemberRoles(ctx, dev, tid); !reflect.DeepEqual(set, []string{rbac.RegularUser, rbac.Tester}) {
				t.Fatalf("after primary left: %v", set)
			}
			// SetMemberRole stays the one-role call: the set becomes {role}.
			if err := h.SetMemberRole(ctx, tid, dev, rbac.Developer, rbac.RegularUser); err != nil {
				t.Fatal(err)
			}
			if set, _ := h.MemberRoles(ctx, dev, tid); !reflect.DeepEqual(set, []string{rbac.Developer}) {
				t.Fatalf("one-role call: %v", set)
			}
			// Last owner over sets: the owner may hold a second role and drop
			// it, never the owner role while alone.
			if err := h.SetMemberRoles(ctx, tid, own, []string{rbac.BizOwner, rbac.Admin}, rbac.Admin, nil); err != nil {
				t.Fatal(err)
			}
			if err := h.SetMemberRoles(ctx, tid, own, []string{rbac.Admin}, "", nil); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("last owner dropped from the set: %v", err)
			}
			if err := h.RemoveMember(ctx, tid, own); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("last owner removed: %v", err)
			}
			// A second member holding biz_owner as a NON-primary role is an
			// owner the guard counts.
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Developer, rbac.BizOwner}, rbac.Developer, nil); err != nil {
				t.Fatal(err)
			}
			if err := h.SetMemberRoles(ctx, tid, own, []string{rbac.Admin}, "", nil); err != nil {
				t.Fatalf("owner freed by a non-primary owner: %v", err)
			}
			// dev is now the only owner, through its non-primary biz_owner.
			// Its set also grants members.invite, so own may drop admin.
			if err := h.SetMemberRoles(ctx, tid, dev, []string{rbac.Developer}, "", nil); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("dev is the last owner now: %v", err)
			}
			if err := h.SetMemberRoles(ctx, tid, own, []string{rbac.Tester}, "", nil); err != nil {
				t.Fatalf("dev still grants members.invite: %v", err)
			}
			if err := h.SetMemberRoles(ctx, tid, own, []string{rbac.Tester, rbac.Admin}, rbac.Tester, nil); err != nil {
				t.Fatal(err)
			}
			// Readers carry the set, primary first.
			ms, err := s.(MemberDirectory).ListMembers(ctx, tid)
			if err != nil {
				t.Fatal(err)
			}
			got := map[string][]string{}
			for _, m := range ms {
				got[m.HumanID] = m.Roles
				if len(m.Roles) == 0 || m.Roles[0] != m.Role {
					t.Fatalf("member %s role %q roles %v", m.HumanID, m.Role, m.Roles)
				}
			}
			if !reflect.DeepEqual(got[own], []string{rbac.Tester, rbac.Admin}) ||
				!reflect.DeepEqual(got[dev], []string{rbac.Developer, rbac.BizOwner}) {
				t.Fatalf("ListMembers roles %v", got)
			}
			mss, err := s.(MembershipLister).Memberships(ctx, own)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range mss {
				if m.TenantID == tid && !reflect.DeepEqual(m.Roles, []string{rbac.Tester, rbac.Admin}) {
					t.Fatalf("Memberships roles %v", m.Roles)
				}
			}
			// The lock-out guards (suspension) count over sets too.
			ts := s.(interface {
				SetMemberDisabled(ctx context.Context, tenant, humanID string, off bool, now time.Time) error
			})
			if err := ts.SetMemberDisabled(ctx, tid, dev, true, time.Now()); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("suspend the last owner (non-primary): %v", err)
			}
		})
	}
}

// 025 §10.5 R1 (POSTGRES): the rdb 0201 triggers. A legacy `UPDATE
// tenant_memberships SET role` (the operator shell actions) keeps the extra
// roles and moves the primary; a raw insert puts the primary in the set; an
// exclusive role next to another is refused (23514) both ways; a membership
// delete empties the set. Red control: without the triggers the primary
// update leaves the old primary in the set and the raw insert leaves the set
// empty, and both checks below fail.
func TestTenantMemberRolesTriggers(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admitAs(t, pg, tid, rbac.BizOwner)
	hum := admitAs(t, pg, tid, rbac.Developer)
	setOf := func() []string {
		t.Helper()
		var set []string
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT coalesce(array_agg(role_id ORDER BY role_id), '{}') FROM tenant_member_roles
				WHERE tenant_id = $1 AND human_id = $2`, tid, hum).Scan(&set)
		}); err != nil {
			t.Fatal(err)
		}
		return set
	}
	if got := setOf(); !reflect.DeepEqual(got, []string{rbac.Developer}) {
		t.Fatalf("admit seated %v, want [developer]", got)
	}
	if err := pg.SetMemberRoles(ctx, tid, hum, []string{rbac.Developer, rbac.RegularUser}, rbac.Developer, nil); err != nil {
		t.Fatal(err)
	}
	exec := func(q string, args ...any) error {
		return pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, q, args...)
			return err
		})
	}
	if err := exec(`UPDATE tenant_memberships SET role = 'tester' WHERE tenant_id = $1 AND human_id = $2`, tid, hum); err != nil {
		t.Fatal(err)
	}
	if got := setOf(); !reflect.DeepEqual(got, []string{rbac.RegularUser, rbac.Tester}) {
		t.Fatalf("legacy role update: set %v, want [regular_user tester]", got)
	}
	if set, err := pg.MemberRoles(ctx, hum, tid); err != nil || !reflect.DeepEqual(set, []string{rbac.Tester, rbac.RegularUser}) {
		t.Fatalf("MemberRoles %v %v", set, err)
	}
	// Exclusive roles, both ways: no demo_user next to another role, and
	// nothing next to a demo_user.
	if err := exec(`INSERT INTO tenant_member_roles (tenant_id, human_id, role_id) VALUES ($1, $2, 'demo_user')`, tid, hum); sqlState(err) != "23514" {
		t.Fatalf("demo_user next to tester: %v, want 23514", err)
	}
	if err := exec(`UPDATE tenant_memberships SET role = 'channel_guest' WHERE tenant_id = $1 AND human_id = $2`, tid, hum); sqlState(err) != "23514" {
		t.Fatalf("channel_guest primary next to regular_user: %v, want 23514", err)
	}
	if !isExclusiveRoleViolation(exec(`INSERT INTO tenant_member_roles (tenant_id, human_id, role_id)
		VALUES ($1, $2, 'channel_guest')`, tid, hum)) {
		t.Fatal("the store does not recognise the trigger's refusal")
	}
	// Alone, an exclusive role is fine: the legacy path to a demo seat.
	if err := pg.SetMemberRoles(ctx, tid, hum, []string{rbac.Tester}, "", nil); err != nil {
		t.Fatal(err)
	}
	if err := exec(`UPDATE tenant_memberships SET role = 'demo_user' WHERE tenant_id = $1 AND human_id = $2`, tid, hum); err != nil {
		t.Fatalf("tester -> demo_user alone: %v", err)
	}
	if got := setOf(); !reflect.DeepEqual(got, []string{rbac.DemoUser}) {
		t.Fatalf("demo seat set %v", got)
	}
	if err := exec(`INSERT INTO tenant_member_roles (tenant_id, human_id, role_id) VALUES ($1, $2, 'developer')`, tid, hum); sqlState(err) != "23514" {
		t.Fatalf("developer next to demo_user: %v, want 23514", err)
	}
	// A raw membership insert seats its primary; a delete empties the set.
	raw := admitAs(t, pg, tid, rbac.Tester)
	if err := exec(`DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tid, raw); err != nil {
		t.Fatal(err)
	}
	if err := exec(`INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES ($1, $2, 'pure_agent', 'test')`, tid, raw); err != nil {
		t.Fatal(err)
	}
	if set, err := pg.MemberRoles(ctx, raw, tid); err != nil || !reflect.DeepEqual(set, []string{rbac.PureAgent}) {
		t.Fatalf("raw insert set %v %v", set, err)
	}
	if err := exec(`DELETE FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $2`, tid, raw); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM tenant_member_roles WHERE tenant_id = $1 AND human_id = $2`, tid, raw).Scan(&left)
	}); err != nil || left != 0 {
		t.Fatalf("set after delete: %d %v", left, err)
	}
	// The invite side keeps its primary in its set the same way.
	now := time.Now().UTC()
	if err := pg.PutInvite(ctx, Invite{TenantID: tid, Email: "roles@example.com", Role: rbac.Tester, InvitedBy: AdmittedOperator,
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.PutInvite(ctx, Invite{TenantID: tid, Email: "roles@example.com", Role: rbac.Admin, InvitedBy: AdmittedOperator,
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	var inv []string
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT array_agg(role_id ORDER BY role_id) FROM tenant_invite_roles
			WHERE tenant_id = $1 AND email = 'roles@example.com'`, tid).Scan(&inv)
	}); err != nil || !reflect.DeepEqual(inv, []string{rbac.Admin}) {
		t.Fatalf("invite set %v %v, want [admin]", inv, err)
	}
}

// The clone of an act-as session holds its target's whole role set (rdb
// 0201), so the act-as ceiling sees the member as they are.
func TestTenantMemberRolesClone(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	adm := admitAs(t, pg, tid, rbac.Admin)
	target := admitAs(t, pg, tid, rbac.Tester)
	if err := pg.SetMemberRoles(ctx, tid, target, []string{rbac.Tester, rbac.Developer}, rbac.Tester, nil); err != nil {
		t.Fatal(err)
	}
	cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, CreatedBy: adm, AdminName: "A",
		ExpiresAt: time.Now().Add(time.Hour)}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if set, err := pg.MemberRoles(ctx, cl.CloneHum, tid); err != nil || !reflect.DeepEqual(set, []string{rbac.Tester, rbac.Developer}) {
		t.Fatalf("clone set %v %v", set, err)
	}
}
