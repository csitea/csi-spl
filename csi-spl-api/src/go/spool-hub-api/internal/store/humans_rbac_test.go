package store

import (
	"context"
	"errors"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
)

// admitAs seats a fresh human in tid with role through an operator invite.
func admitAs(t *testing.T, h Humans, tid, role string) string {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	email := uid("m-") + "@example.com"
	if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: role, InvitedBy: AdmittedOperator,
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatalf("invite %s: %v", role, err)
	}
	hum, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("s-"), Email: email}, tid, AdmitPolicy{}, now)
	if err != nil {
		t.Fatalf("admit %s: %v", role, err)
	}
	return hum
}

// 025 FR-002/FR-003, §3.4 rule 3: roles are data; legacy names map; an
// unknown role is refused; the last tenant owner can be neither demoted nor
// removed, a second one frees the first.
func TestTenantRolesAndLastOwner(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			roles, err := h.TenantRoles(ctx, tid)
			if err != nil || !reflect.DeepEqual(roles, rbac.DefaultRoles()) {
				t.Fatalf("tenant roles = %v %v", roles, err)
			}
			// Legacy input names are mapped; stored values are the 025 ids.
			own := admitAs(t, h, tid, "owner")
			dev := admitAs(t, h, tid, "")
			tst := admitAs(t, h, tid, rbac.Tester)
			for hum, want := range map[string]string{own: rbac.BizOwner, dev: rbac.Developer, tst: rbac.Tester} {
				if r, err := h.MemberRole(ctx, hum, tid); err != nil || r != want {
					t.Fatalf("%s role %q %v, want %s", hum, r, err, want)
				}
			}
			// CONTROL: an unknown role is refused on invite and on change.
			if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: "x@example.com", Role: "superuser",
				InvitedBy: AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); !errors.Is(err, ErrUnknownRole) {
				t.Fatalf("unknown invite role: %v", err)
			}
			if err := h.SetMemberRole(ctx, tid, dev, "superuser", ""); !errors.Is(err, ErrUnknownRole) {
				t.Fatalf("unknown role change: %v", err)
			}
			if err := h.SetMemberRole(ctx, tid, dev, "Bad Role!", ""); !errors.Is(err, ErrUnknownRole) {
				t.Fatalf("malformed role: %v", err)
			}
			// from-role guard.
			if err := h.SetMemberRole(ctx, tid, dev, rbac.Admin, rbac.Tester); !errors.Is(err, ErrRoleChanged) {
				t.Fatalf("stale from: %v", err)
			}
			if err := h.SetMemberRole(ctx, tid, dev, rbac.Admin, "member"); err != nil {
				t.Fatalf("legacy from: %v", err)
			}
			if r, _ := h.MemberRole(ctx, dev, tid); r != rbac.Admin {
				t.Fatalf("after change: %q", r)
			}
			// Not a member.
			if err := h.SetMemberRole(ctx, tid, "HUM-999999", rbac.Tester, ""); !errors.Is(err, ErrNotFound) {
				t.Fatalf("non-member change: %v", err)
			}
			if err := h.RemoveMember(ctx, tid, "HUM-999999"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("non-member remove: %v", err)
			}
			// Last owner: no demotion, no removal (CONTROL: nothing changed).
			if err := h.SetMemberRole(ctx, tid, own, rbac.Developer, ""); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("last owner demoted: %v", err)
			}
			if err := h.RemoveMember(ctx, tid, own); !errors.Is(err, ErrLastOwner) {
				t.Fatalf("last owner removed: %v", err)
			}
			if r, _ := h.MemberRole(ctx, own, tid); r != rbac.BizOwner {
				t.Fatalf("last owner changed anyway: %q", r)
			}
			// Last admin (CLE-34969): dev is the only members.invite holder, so
			// it cannot move to a role without it (CONTROL: nothing changed).
			if err := h.SetMemberRole(ctx, tid, dev, rbac.BizOwner, ""); !errors.Is(err, ErrLastAdmin) {
				t.Fatalf("last admin demoted: %v", err)
			}
			if err := h.RemoveMember(ctx, tid, dev); !errors.Is(err, ErrLastAdmin) {
				t.Fatalf("last admin removed: %v", err)
			}
			if r, _ := h.MemberRole(ctx, dev, tid); r != rbac.Admin {
				t.Fatalf("last admin changed anyway: %q", r)
			}
			// A second admin frees the first; a second owner frees the first owner.
			if err := h.SetMemberRole(ctx, tid, tst, rbac.Admin, ""); err != nil {
				t.Fatal(err)
			}
			if err := h.SetMemberRole(ctx, tid, dev, rbac.BizOwner, ""); err != nil {
				t.Fatal(err)
			}
			if err := h.SetMemberRole(ctx, tid, own, rbac.Developer, ""); err != nil {
				t.Fatalf("demote with a second owner: %v", err)
			}
			// tst is now the last admin: removal waits for another.
			if err := h.RemoveMember(ctx, tid, tst); !errors.Is(err, ErrLastAdmin) {
				t.Fatalf("last admin removed: %v", err)
			}
			if err := h.SetMemberRole(ctx, tid, own, rbac.Admin, ""); err != nil {
				t.Fatal(err)
			}
			if err := h.RemoveMember(ctx, tid, tst); err != nil {
				t.Fatal(err)
			}
			if _, err := h.MemberRole(ctx, tst, tid); !errors.Is(err, ErrNotFound) {
				t.Fatalf("removed member: %v", err)
			}
			// Bootstrap seats the tenant-owner role.
			t2 := newTenant(t, s)
			b, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("b-")}, t2, AdmitPolicy{BootstrapOwner: true}, now)
			if err != nil {
				t.Fatal(err)
			}
			if r, _ := h.MemberRole(ctx, b, t2); r != rbac.BizOwner {
				t.Fatalf("bootstrap role %q", r)
			}
			// Membership is per tenant: t2's owner changes nothing in tid.
			if err := h.SetMemberRole(ctx, tid, b, rbac.Tester, ""); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cross-tenant change: %v", err)
			}
		})
	}
}

// The migrated seed equals rbac.Defaults + rbac.Permissions (025 §3), so the
// memory store and Postgres cannot drift.
func TestRBACSeedMatchesDefaults(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	var perms []string
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT array_agg(permission_id ORDER BY permission_id) FROM rbac_permissions`).Scan(&perms)
	})
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, p := range rbac.Permissions {
		want = append(want, p.ID)
	}
	sort.Strings(want)
	if !reflect.DeepEqual(perms, want) {
		t.Fatalf("rbac_permissions %v, want %v", perms, want)
	}
	tid := newTenant(t, pg)
	roles, err := pg.TenantRoles(ctx, tid)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(roles, rbac.DefaultRoles()) {
		t.Fatalf("seeded roles\n %v\nwant\n %v", roles, rbac.DefaultRoles())
	}
}

// SEC-RBAC-4: a tenant scope reads the system roles but can neither change
// nor delete one, nor grant it a permission; the operator can (CONTROL).
func TestRBACRLSSystemRolesReadOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM rbac_roles`).Scan(&n); err != nil || n != len(rbac.Defaults) {
			t.Errorf("tenant sees %d system roles (%v)", n, err)
		}
		for _, q := range []string{
			`UPDATE rbac_roles SET tenant_owner = true WHERE role_id = 'tester'`,
			`DELETE FROM rbac_roles WHERE role_id = 'tester'`,
			`DELETE FROM rbac_role_permissions WHERE role_id = 'tester'`,
		} {
			tag, err := tx.Exec(ctx, q)
			if err != nil {
				return err
			}
			if tag.RowsAffected() != 0 {
				t.Errorf("tenant scope changed a system row: %s", q)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	err = pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES ('tester', 'billing.manage')`)
		return err
	})
	if err == nil {
		t.Fatal("tenant scope granted a system role a permission")
	}
	// CONTROL: the operator scope sees and could write the same rows.
	err = pg.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE rbac_roles SET description = description WHERE role_id = 'tester'`)
		if err == nil && tag.RowsAffected() != 1 {
			t.Error("control void: operator could not touch the system role")
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// 0021's legacy trigger: a pre-025 writer (old hub image, old operator SQL)
// storing 'owner' / 'member' lands as biz_owner / developer, not an FK error.
func TestRBACLegacyRoleTrigger(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("lg-")}, "", AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	err = pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
			VALUES ($1, $2, 'owner', 'operator')`, tid, hum); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO tenant_invites (tenant_id, email, role, invited_by, expires_at)
			VALUES ($1, 'legacy@example.com', 'member', 'operator', now() + interval '1 hour')`, tid)
		return err
	})
	if err != nil {
		t.Fatalf("legacy write: %v", err)
	}
	if r, _ := pg.MemberRole(ctx, hum, tid); r != rbac.BizOwner {
		t.Fatalf("legacy owner stored as %q", r)
	}
	if err := pg.SetMemberRole(ctx, tid, hum, "member", ""); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("legacy demotion of the last owner: %v", err)
	}
	var inv string
	err = pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT role FROM tenant_invites WHERE tenant_id = $1`, tid).Scan(&inv)
	})
	if err != nil || inv != rbac.Developer {
		t.Fatalf("legacy invite stored as %q %v", inv, err)
	}
}
