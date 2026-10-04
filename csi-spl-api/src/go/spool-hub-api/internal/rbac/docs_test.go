package rbac

import "testing"

// specs/075 Phase 2: every system role reads and writes the workspace docs
// (owner 9f0d751c, b60bf417), by name, so a role added later holds neither.
func TestDocsGrantedToEverySystemRole(t *testing.T) {
	roles := DefaultRoles()
	for _, id := range RoleIDs {
		got := map[string]bool{}
		for _, p := range roles[id].Perms {
			got[p] = true
		}
		if !got[DocsRead] || !got[DocsWrite] {
			t.Errorf("%s lacks docs.read / docs.write: %v", id, roles[id].Perms)
		}
	}
}
