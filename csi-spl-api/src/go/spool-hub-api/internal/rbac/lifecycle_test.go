package rbac

import (
	"reflect"
	"testing"
)

// todayFrozen is the "today" column of spec 152 3.1, one row per cell row,
// in the spec's role letters (O A P D T G C U). costs.read is every member
// role: rdb 0229 (specs/140 3.10) widened it after the spec read O A.
var todayFrozen = map[string]string{
	NotesSend: "OAPDTGCU", ChannelsManage: "OAPDCU", IssuesCreate: "OAPDTGCU",
	AgentsDM: "OAPDGCU", AgentsStart: "OAPDGCU", AgentsMention: "OAPDGCU", AgentsPost: "OAPDGCU",
	AgentsReply: "OAPDGCU", IssuesEdit: "OAPDTGCU", IssuesAssign: "OAPDTGCU", IssuesPrioritise: "OAPDTGCU",
	TopicsManage: "OAPDTGCU", DocsWrite: "OAPDTGCU", FilesWrite: "OAPDTGCU", ChannelsEdit: "OAPDTGCU",
	ChannelsAIAgents: "OA", MessagesKind: "OA",
	IssuesStatus: "OAPDTGCU", IssuesBlocker: "O", TopicsChangeOthers: "OA", IssuesRemoveOthers: "OA",
	ResultsAccept: "OAPDGCU",
	ShipApprove:   "OAPDGCU", RoadmapPublish: "OA", MarketingPublish: "O", EmbedsManage: "O",
	MembersInvite: "OA", MembersRoles: "OA", MembersImpersonate: "OA", AgentsJoin: "A",
	TenantSettings: "OA", PermsEdit: "OA", BillingManage: "O", AuditRead: "OAP",
	CostsRead: "OAPDTGCU", HoursRead: "O", HoursApprove: "O", ReportingSQL: "A", EmbedsVisitors: "OA",
}

func frozenCells(t *testing.T) Cells {
	t.Helper()
	c := Cells{}
	for _, a := range Catalogue {
		letters, ok := todayFrozen[a.ID]
		if !ok {
			t.Fatalf("frozen table has no row %s", a.ID)
		}
		for _, r := range RoleIDs {
			c.set(a.ID, r, false)
		}
		for i := 0; i < len(letters); i++ {
			c.set(a.ID, roleLetters[letters[i]], true)
		}
	}
	return c
}

// countEqual is how many of the 312 cells two lists answer alike.
func countEqual(a, b Cells) int {
	n := 0
	for _, act := range Catalogue {
		for _, r := range RoleIDs {
			if a.Get(act.ID, r) == b.Get(act.ID, r) {
				n++
			}
		}
	}
	return n
}

// TestCatalogueOrder: 39 cell rows in five stages, 7 10 5 4 13 (review's
// sixth action, topics.archive, is the archive setting, not a cell), the
// stages in order, every id a catalogue permission, none twice.
func TestCatalogueOrder(t *testing.T) {
	if len(Catalogue) != 39 {
		t.Fatalf("catalogue rows: %d, want 39", len(Catalogue))
	}
	known := map[string]bool{}
	for _, p := range Permissions {
		known[p.ID] = true
	}
	want := map[string]int{StageStart: 7, StageSteer: 10, StageReview: 5, StageShip: 4, StageAdminister: 13}
	got := map[string]int{}
	seen := map[string]bool{}
	stage := 0
	for _, a := range Catalogue {
		for stage < len(Stages) && Stages[stage] != a.Stage {
			stage++
		}
		if stage == len(Stages) {
			t.Fatalf("%s: stage %q out of order", a.ID, a.Stage)
		}
		if !known[a.ID] || seen[a.ID] || !InCatalogue(a.ID) {
			t.Errorf("%s: unknown, twice or not found", a.ID)
		}
		seen[a.ID] = true
		got[a.Stage]++
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("stage counts %v, want %v", got, want)
	}
	for _, out := range []string{TopicsRead, DocsRead, SelfKeys, KeysManage, AgentsCommand, TopicsArchive} {
		if InCatalogue(out) {
			t.Errorf("%s is not a cell of the list (spec 152 3.2)", out)
		}
	}
}

// TestListDefaultIsToday (spec 152 3.6, R12, rbac half): the system grants
// answer the frozen "today" table, 312 of 312, and its red control: one
// changed cell (developer, agents.start) turns exactly one cell red.
func TestListDefaultIsToday(t *testing.T) {
	frozen := frozenCells(t)
	if n := countEqual(frozen, Today()); n != 312 {
		t.Fatalf("today: %d of 312 equal: %v", n, Diff(frozen, Today()))
	}
	red := Today()
	red.set(AgentsStart, Developer, false)
	if n := countEqual(frozen, red); n != 311 {
		t.Fatalf("red control: %d of 312 equal, want 311", n)
	}
	if d := Diff(frozen, red); !reflect.DeepEqual(d, []Cell{{AgentsStart, Developer}}) {
		t.Errorf("red control diff: %v", d)
	}
}

// TestPresetFills (spec 152 3.5): each preset fills all 39 x 8 cells, keeps
// the six locked cells true and the administer stage as today; agile is the
// system grants and stores 0 rows, strict 68, corporate 43, move_fast 35.
func TestPresetFills(t *testing.T) {
	rows := map[string]int{PresetStrict: 68, PresetCorporate: 43, PresetAgile: 0, PresetMoveFast: 35}
	today := Today()
	for _, id := range PresetIDs {
		p, ok := Preset(id)
		if !ok {
			t.Fatalf("%s: unknown", id)
		}
		filled := 0
		for _, a := range Catalogue {
			for _, r := range RoleIDs {
				if _, ok := p[a.ID][r]; ok {
					filled++
				}
				if a.Stage == StageAdminister && p.Get(a.ID, r) != today.Get(a.ID, r) {
					t.Errorf("%s changes administer cell %s/%s", id, a.ID, r)
				}
			}
		}
		if filled != 312 || len(p) != 39 {
			t.Errorf("%s fills %d cells in %d rows, want 312 in 39", id, filled, len(p))
		}
		for _, c := range LockedCells() {
			if !p.Get(c.Action, c.Role) {
				t.Errorf("%s clears locked cell %v", id, c)
			}
		}
		if n := len(Diff(today, p)); n != rows[id] {
			t.Errorf("%s differs from today in %d cells, want %d", id, n, rows[id])
		}
	}
	if _, ok := Preset("chaos"); ok {
		t.Error("an unknown preset id must be refused")
	}
	if agile, _ := Preset(PresetAgile); !reflect.DeepEqual(Apply(DefaultRoles(), agile), DefaultRoles()) {
		t.Error("agile applied must equal Defaults")
	}
}

// TestLockedCells: perms.edit, members.roles and members.invite of
// biz_owner and admin, and nothing else (spec 152 3.7, D7).
func TestLockedCells(t *testing.T) {
	want := []Cell{
		{MembersInvite, BizOwner}, {MembersInvite, Admin},
		{MembersRoles, BizOwner}, {MembersRoles, Admin},
		{PermsEdit, BizOwner}, {PermsEdit, Admin},
	}
	if got := LockedCells(); !reflect.DeepEqual(got, want) {
		t.Errorf("locked cells %v, want %v", got, want)
	}
}

// TestPresetMatch: each preset's fill reads back as that preset; one changed
// cell reads as custom ("").
func TestPresetMatch(t *testing.T) {
	for _, id := range PresetIDs {
		p, _ := Preset(id)
		if got := PresetMatch(p); got != id {
			t.Errorf("PresetMatch(%s) = %q", id, got)
		}
		p.set(DocsWrite, Tester, !p.Get(DocsWrite, Tester))
		if got := PresetMatch(p); got != "" {
			t.Errorf("%s with one cell changed matches %q, want custom", id, got)
		}
	}
	if got := PresetMatch(CellsOf(DefaultRoles())); got != PresetAgile {
		t.Errorf("the system grants match %q, want agile", got)
	}
}

// TestPresetsStayInsideAdminSet (spec 152 3.5, D14, R34): under every preset
// the admin still Covers every role it Covers today, so no preset takes a
// role out of the admins' reach.
func TestPresetsStayInsideAdminSet(t *testing.T) {
	today := DefaultRoles()
	admin := accessOf("hum", []string{Admin}, today)
	for _, id := range PresetIDs {
		p, _ := Preset(id)
		roles := Apply(today, p)
		under := accessOf("hum", []string{Admin}, roles)
		for _, r := range RoleIDs {
			if admin.Covers(today[r]) && !under.Covers(roles[r]) {
				t.Errorf("%s: admin no longer covers %s", id, r)
			}
		}
	}
}

// TestApplyKeepsOtherGrants: a preset writes only its cells; the grants
// outside the list stay (spec 152 3.2).
func TestApplyKeepsOtherGrants(t *testing.T) {
	strict, _ := Preset(PresetStrict)
	moveFast, _ := Preset(PresetMoveFast)
	dev := accessOf("hum", []string{Developer}, Apply(DefaultRoles(), strict))
	if dev.Can(AgentsDM) || !dev.Can(AgentsCommand) || !dev.Can(TopicsRead) {
		t.Errorf("strict developer: %v", dev.List())
	}
	tester := accessOf("hum", []string{Tester}, Apply(DefaultRoles(), moveFast))
	if !tester.Can(MessagesKind) || !tester.Can(AgentsDM) || tester.Can(MarketingPublish) || tester.Can(AgentsCommand) {
		t.Errorf("move_fast tester: %v", tester.List())
	}
	if guest := Apply(DefaultRoles(), moveFast)[DemoUser]; !reflect.DeepEqual(guest, DefaultRoles()[DemoUser]) {
		t.Errorf("demo_user changed: %v", guest.Perms)
	}
}

// TestMayChangeCell: the no-escalation rule of one cell (spec 152 3.7, D6;
// R15, R28) and the locked cells (R14).
func TestMayChangeCell(t *testing.T) {
	roles := DefaultRoles()
	owner := accessOf("hum", []string{BizOwner}, roles)
	admin := accessOf("hum", []string{Admin}, roles)
	po := roles[ProductOwner]
	po.Perms = sorted(append(append([]string(nil), po.Perms...), PermsEdit)...)
	poEditor := accessOf("hum", []string{ProductOwner}, map[string]Role{ProductOwner: po})
	cases := []struct {
		name    string
		actor   Access
		role    string
		action  string
		granted bool
		want    bool
	}{
		{"R28 admin grants itself hours.approve", admin, Admin, HoursApprove, true, false},
		{"R28 admin takes costs.read from the owner", admin, BizOwner, CostsRead, false, false},
		{"R28 owner grants admin hours.approve", owner, Admin, HoursApprove, true, true},
		{"R28 owner takes costs.read from itself", owner, BizOwner, CostsRead, false, true},
		{"R15 product_owner grants members.invite", poEditor, Developer, MembersInvite, true, false},
		{"admin stops a developer starting agent work", admin, Developer, AgentsStart, false, true},
		{"admin gives a tester agents.dm", admin, Tester, AgentsDM, true, true},
		{"R14 locked: owner clears admin perms.edit", owner, Admin, PermsEdit, false, false},
		{"R14 locked: admin clears its members.roles", admin, Admin, MembersRoles, false, false},
	}
	for _, c := range cases {
		if got := c.actor.MayChangeCell(roles[c.role], c.action, c.granted); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// TestPresetRefusal (spec 152 3.7, R32): an admin applies strict, corporate
// and agile, not move_fast, refused at (issues.blocker, admin); the owner
// applies all four.
func TestPresetRefusal(t *testing.T) {
	roles := DefaultRoles()
	owner := accessOf("hum", []string{BizOwner}, roles)
	admin := accessOf("hum", []string{Admin}, roles)
	for _, id := range PresetIDs {
		p, _ := Preset(id)
		if cell, refused := owner.PresetRefusal(roles, p); refused {
			t.Errorf("owner refused %s at %v", id, cell)
		}
		cell, refused := admin.PresetRefusal(roles, p)
		if id == PresetMoveFast {
			if !refused || cell != (Cell{IssuesBlocker, Admin}) {
				t.Errorf("admin move_fast: %v %v, want refused at issues.blocker/admin", cell, refused)
			}
			continue
		}
		if refused {
			t.Errorf("admin refused %s at %v", id, cell)
		}
	}
}
