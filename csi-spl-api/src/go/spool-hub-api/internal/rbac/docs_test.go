package rbac

import (
	"testing"
)

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

// TestRolesAndPermissionsDocSync ensures the help page "Roles and permissions"
// stays in sync with rbac.go. Extend this test when adding a role or permission.
func TestRolesAndPermissionsDocSync(t *testing.T) {
	roles := DefaultRoles()
	perms := make(map[string]PermissionDoc, len(Permissions))
	for _, p := range Permissions {
		perms[p.ID] = p
	}

	// RoleIDs must match the help page's table.
	expectedRoles := []string{
		BizOwner, ProductOwner, Admin, Developer, Tester, PureAgent, BizCustomer, RegularUser,
	}
	if len(RoleIDs) != len(expectedRoles) {
		t.Errorf("RoleIDs length mismatch: got %d, want %d", len(RoleIDs), len(expectedRoles))
	}
	for i, id := range RoleIDs {
		if id != expectedRoles[i] {
			t.Errorf("RoleIDs[%d]: got %q, want %q", i, id, expectedRoles[i])
		}
	}

	// Permissions must match the help page's table.
	expectedPerms := []string{
		TopicsRead, NotesSend, AgentsCommand, ChannelsManage, MembersInvite, MembersRoles,
		BillingManage, TenantSettings, KeysManage, AuditRead, MembersImpersonate, AgentsJoin,
		DocsRead, DocsWrite, FilesWrite, TopicsManage, SelfKeys, ChannelsEdit, HoursRead, HoursApprove,
	}
	if len(Permissions) != len(expectedPerms) {
		t.Errorf("Permissions length mismatch: got %d, want %d", len(Permissions), len(expectedPerms))
	}
	for i, p := range Permissions {
		if p.ID != expectedPerms[i] {
			t.Errorf("Permissions[%d].ID: got %q, want %q", i, p.ID, expectedPerms[i])
		}
	}

	// Every role's permissions must match the help page's description.
	roleDescriptions := map[string]string{
		BizOwner:     "The tenant owner. Holds every permission except `agents.join` (reserved for admins).",
		ProductOwner: "A product or project lead. Can read and post, command agents, and manage channels and docs.",
		Admin:        "A workspace administrator. Can invite and remove members, change roles, manage tenant settings, keys, and audit logs, and impersonate members. Holds `agents.join` (the only permission `biz_owner` does not have).",
		Developer:    "A developer or engineer. Can read and post, command agents, manage channels, and edit docs.",
		Tester:       "A tester or QA engineer. Can read and post, and edit docs.",
		PureAgent:    "An autonomous AI agent. Can read and post, command other agents, and edit docs.",
		BizCustomer:  "A business stakeholder. Can read and post, command agents, manage channels, and edit docs.",
		RegularUser:  "A regular workspace member. Can read and post, command agents, manage channels, and edit docs.",
	}
	for _, id := range RoleIDs {
		if _, ok := roleDescriptions[id]; !ok {
			t.Errorf("Role %q missing from roleDescriptions", id)
		}
	}

	// Every permission's description must match the help page's table.
	permDescriptions := map[string]string{
		TopicsRead:     "Read roster, channels, and topics; open the WUI socket.",
		NotesSend:      "Post a note from the WUI.",
		AgentsCommand:  "Command an agent through box-wui dispatch.",
		ChannelsManage: "Create channels.",
		MembersInvite:  "Invite and remove members.",
		MembersRoles:   "Change a member's role.",
		BillingManage:  "Manage billing, checkout, and tenant seats.",
		TenantSettings: "Change tenant settings.",
		KeysManage:     "Manage tenant-level keys (box pins, the box-wui pin).",
		AuditRead:      "View the tenant audit trail.",
		MembersImpersonate: "Act as a member through a temporary clone (biz_owner and admin only).",
		AgentsJoin:     "Mint, list, and revoke agent join tokens, and revoke one seat from the WUI (admin only).",
		DocsRead:       "Read the workspace docs.",
		DocsWrite:      "Create, edit, and delete the workspace docs.",
		FilesWrite:     "Upload and delete files; manage the WUI upload token.",
		TopicsManage:   "Move, merge, and promote topics; create and edit issues.",
		SelfKeys:       "Add and revoke one's own keys; write one's own event log.",
		ChannelsEdit:   "Add or remove channel members and agents; archive or delete a channel.",
		HoursRead:      "View every member's approved hours and period states; download them (biz_owner only).",
		HoursApprove:   "Approve or return a member's frozen hours period (biz_owner only).",
	}
	for _, p := range Permissions {
		if desc, ok := permDescriptions[p.ID]; !ok || desc != p.Description {
			t.Errorf("Permission %q: got description %q, want %q", p.ID, p.Description, desc)
		}
	}
}
