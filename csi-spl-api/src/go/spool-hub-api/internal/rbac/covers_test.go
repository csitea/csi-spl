package rbac

import "testing"

// TestCoversAccess: the strict ceiling used by act-as (specs/054) — an admin
// strictly outranks a developer (covers it, and holds a permission it does
// not), and neither a peer admin nor the owner.
func TestCoversAccess(t *testing.T) {
	d := DefaultRoles()
	acc := func(id string) Access {
		a := Access{Role: id, TenantOwner: d[id].TenantOwner, Perms: map[string]bool{}}
		for _, p := range d[id].Perms {
			a.Perms[p] = true
		}
		return a
	}
	strictlyAbove := func(hi, lo Access) bool { return hi.CoversAccess(lo) && !lo.CoversAccess(hi) }

	admin, dev, owner, tester := acc(Admin), acc(Developer), acc(BizOwner), acc(Tester)
	if !strictlyAbove(admin, dev) {
		t.Error("admin should strictly outrank developer")
	}
	if !strictlyAbove(admin, tester) {
		t.Error("admin should strictly outrank tester")
	}
	if !strictlyAbove(owner, admin) {
		t.Error("owner should strictly outrank admin")
	}
	if strictlyAbove(admin, admin) {
		t.Error("admin does not strictly outrank a peer admin")
	}
	if strictlyAbove(admin, owner) {
		t.Error("admin does not outrank the owner")
	}
}
