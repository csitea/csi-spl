package hub

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// accessFor is the Defaults grant of a system role as an rbac.Access.
func accessFor(role string) rbac.Access {
	r := rbac.DefaultRoles()[role]
	a := rbac.Access{Role: role, TenantOwner: r.TenantOwner, Perms: map[string]bool{}}
	for _, p := range r.Perms {
		a.Perms[p] = true
	}
	return a
}

// fakeAuthz answers Access from a humanID -> role map; an unknown human is not
// a member.
type fakeAuthz map[string]string

func (f fakeAuthz) Access(_ context.Context, hum, _ string) (rbac.Access, error) {
	role, ok := f[hum]
	if !ok {
		return rbac.Access{}, rbac.ErrNotMember
	}
	return accessFor(role), nil
}
func (f fakeAuthz) Roles(context.Context, string) (map[string]rbac.Role, error) {
	return rbac.DefaultRoles(), nil
}

// fakeClones records whether a clone was minted.
type fakeClones struct {
	started store.CloneStart
	minted  bool
}

func (c *fakeClones) StartClone(_ context.Context, in store.CloneStart, now time.Time) (store.Clone, error) {
	c.started, c.minted = in, true
	return store.Clone{CloneHum: "HUM-clone", TenantID: in.TenantID, TargetHum: in.TargetHum,
		CreatedBy: in.CreatedBy, Role: "developer", CreatedAt: now, ExpiresAt: in.ExpiresAt}, nil
}
func (c *fakeClones) StopClone(context.Context, string, string, string, time.Time) error { return nil }
func (c *fakeClones) Clone(context.Context, string, string) (store.Clone, error) {
	return store.Clone{}, store.ErrNotFound
}

// TestActAsCeiling is the whole server-side gate: who may act as whom. It must
// mint a clone ONLY for a permitted admin acting on a strictly-lower member.
func TestActAsCeiling(t *testing.T) {
	cases := []struct {
		name, admin, target string
		roles               map[string]string
		want                error
	}{
		{"admin acts as developer", "A", "T", map[string]string{"A": rbac.Admin, "T": rbac.Developer}, nil},
		{"admin acts as tester", "A", "T", map[string]string{"A": rbac.Admin, "T": rbac.Tester}, nil},
		{"biz_owner acts as admin", "A", "T", map[string]string{"A": rbac.BizOwner, "T": rbac.Admin}, nil},
		{"developer cannot (no perm)", "A", "T", map[string]string{"A": rbac.Developer, "T": rbac.Tester}, auth.ErrActAsForbidden},
		{"admin cannot act as admin", "A", "T", map[string]string{"A": rbac.Admin, "T": rbac.Admin}, auth.ErrActAsCeiling},
		{"admin cannot act as owner", "A", "T", map[string]string{"A": rbac.Admin, "T": rbac.BizOwner}, auth.ErrActAsCeiling},
		{"biz_owner cannot act as biz_owner", "A", "T", map[string]string{"A": rbac.BizOwner, "T": rbac.BizOwner}, auth.ErrActAsCeiling},
		{"cannot act as self", "A", "A", map[string]string{"A": rbac.Admin}, auth.ErrActAsCeiling},
		{"cannot act as non-member", "A", "T", map[string]string{"A": rbac.Admin}, auth.ErrActAsNotMember},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clones := &fakeClones{}
			a := &actAs{clones: clones, authz: fakeAuthz(tc.roles), ttl: time.Hour, now: func() time.Time { return time.Unix(1000, 0) }}
			_, err := a.StartActAs(context.Background(), "t1", tc.admin, "Admin", tc.target)
			if !errors.Is(err, tc.want) {
				t.Fatalf("StartActAs = %v, want %v", err, tc.want)
			}
			if tc.want == nil {
				if !clones.minted {
					t.Error("a permitted act-as minted no clone")
				}
				if clones.started.TargetHum != tc.target || clones.started.CreatedBy != tc.admin {
					t.Errorf("clone start = %+v", clones.started)
				}
			} else if clones.minted {
				t.Error("a refused act-as still minted a clone")
			}
		})
	}
}

// TestActAsTTL: the clone's expiry is now + ttl.
func TestActAsTTL(t *testing.T) {
	clones := &fakeClones{}
	now := time.Unix(5000, 0)
	a := &actAs{clones: clones, authz: fakeAuthz{"A": rbac.Admin, "T": rbac.Developer}, ttl: 30 * time.Minute,
		now: func() time.Time { return now }}
	res, err := a.StartActAs(context.Background(), "t1", "A", "Admin", "T")
	if err != nil {
		t.Fatal(err)
	}
	if !res.ExpiresAt.Equal(now.Add(30 * time.Minute)) {
		t.Errorf("expiry = %v, want %v", res.ExpiresAt, now.Add(30*time.Minute))
	}
}
