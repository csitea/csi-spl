package rbac

import "sort"

// The role x action list of spec 152 (build row B2): the five stages of agent
// work, the 39 cells of the list in the spec's catalogue order (3.1), the four
// preset fills (3.5), the locked cells (3.7) and the no-escalation check of a
// cell and of a preset (3.7, D6). Nothing here reads a store: B3 stores a
// workspace's changed cells and B4 serves them.

// Stage ids (spec 152 3.1), in the order the list shows them.
const (
	StageStart      = "start"
	StageSteer      = "steer"
	StageReview     = "review"
	StageShip       = "ship"
	StageAdminister = "administer"
)

// Stages is every stage id, in order.
var Stages = []string{StageStart, StageSteer, StageReview, StageShip, StageAdminister}

// TopicsArchive is the 40th action: the archive policy setting
// (topic_archive_policy), shown in the review stage after its cells and never
// stored in the list nor changed by a preset (spec 152 3.2, D11).
const TopicsArchive = "topics.archive"

// Action is one cell row of the list: a permission id and its stage.
type Action struct{ ID, Stage string }

// Catalogue is the 39 cell rows, in the order of spec 152 3.1.
var Catalogue = []Action{
	{NotesSend, StageStart}, {ChannelsManage, StageStart}, {IssuesCreate, StageStart},
	{AgentsDM, StageStart}, {AgentsStart, StageStart}, {AgentsMention, StageStart}, {AgentsPost, StageStart},

	{AgentsReply, StageSteer}, {IssuesEdit, StageSteer}, {IssuesAssign, StageSteer},
	{IssuesPrioritise, StageSteer}, {TopicsManage, StageSteer}, {DocsWrite, StageSteer},
	{FilesWrite, StageSteer}, {ChannelsEdit, StageSteer}, {ChannelsAIAgents, StageSteer}, {MessagesKind, StageSteer},

	{IssuesStatus, StageReview}, {IssuesBlocker, StageReview}, {TopicsChangeOthers, StageReview},
	{IssuesRemoveOthers, StageReview}, {ResultsAccept, StageReview},

	{ShipApprove, StageShip}, {RoadmapPublish, StageShip}, {MarketingPublish, StageShip}, {EmbedsManage, StageShip},

	{MembersInvite, StageAdminister}, {MembersRoles, StageAdminister}, {MembersImpersonate, StageAdminister},
	{AgentsJoin, StageAdminister}, {TenantSettings, StageAdminister}, {PermsEdit, StageAdminister},
	{BillingManage, StageAdminister}, {AuditRead, StageAdminister}, {CostsRead, StageAdminister},
	{HoursRead, StageAdminister}, {HoursApprove, StageAdminister}, {ReportingSQL, StageAdminister},
	{EmbedsVisitors, StageAdminister},
}

// InCatalogue reports whether perm is a cell row of the list.
func InCatalogue(perm string) bool {
	for _, a := range Catalogue {
		if a.ID == perm {
			return true
		}
	}
	return false
}

// Preset ids (spec 152 3.5), in the order the page shows them.
const (
	PresetStrict    = "strict"
	PresetCorporate = "corporate"
	PresetAgile     = "agile"
	PresetMoveFast  = "move_fast"
)

// PresetIDs is every preset id, in order.
var PresetIDs = []string{PresetStrict, PresetCorporate, PresetAgile, PresetMoveFast}

// Cells is a filled list: action id -> role id -> granted, over the
// Catalogue and RoleIDs.
type Cells map[string]map[string]bool

// Get reports one cell; a cell the list does not hold is false.
func (c Cells) Get(action, role string) bool { return c[action][role] }

func (c Cells) set(action, role string, granted bool) {
	if c[action] == nil {
		c[action] = map[string]bool{}
	}
	c[action][role] = granted
}

// Cell names one cell of the list.
type Cell struct{ Action, Role string }

// Locked reports the six cells no PUT and no preset changes, always true:
// perms.edit, members.roles and members.invite of biz_owner and admin (spec
// 152 3.7, D7). The last-owner and last-admin guards do the rest.
func Locked(action, role string) bool {
	return (role == BizOwner || role == Admin) &&
		(action == PermsEdit || action == MembersRoles || action == MembersInvite)
}

// LockedCells is the six locked cells, in catalogue then RoleIDs order.
func LockedCells() []Cell {
	var out []Cell
	for _, a := range Catalogue {
		for _, r := range RoleIDs {
			if Locked(a.ID, r) {
				out = append(out, Cell{a.ID, r})
			}
		}
	}
	return out
}

// CellsOf reads the list out of a role table (the system grants, or a
// tenant's TenantRoles); a role the table lacks grants nothing.
func CellsOf(roles map[string]Role) Cells {
	c := Cells{}
	for _, r := range RoleIDs {
		held := map[string]bool{}
		for _, p := range roles[r].Perms {
			held[p] = true
		}
		for _, a := range Catalogue {
			c.set(a.ID, r, held[a.ID])
		}
	}
	return c
}

// Today is the list as the system grants fill it: the agile preset.
func Today() Cells { return CellsOf(DefaultRoles()) }

// roleLetters is the spec's one-letter shorthand of the member roles.
var roleLetters = map[byte]string{
	'O': BizOwner, 'A': Admin, 'P': ProductOwner, 'D': Developer,
	'T': Tester, 'G': PureAgent, 'C': BizCustomer, 'U': RegularUser,
}

const (
	lettersAll     = "OAPDTGCU"
	lettersAllButT = "OAPDGCU"
)

// presetFills is spec 152 3.5 for the start, steer, review and ship rows, in
// the columns strict, corporate, move_fast. agile is Today(), and every
// preset leaves the administer rows as today.
var presetFills = map[string][3]string{
	NotesSend:          {lettersAll, lettersAll, lettersAll},
	ChannelsManage:     {"OAP", "OAPD", lettersAll},
	IssuesCreate:       {lettersAll, lettersAll, lettersAll},
	AgentsDM:           {"OA", lettersAllButT, lettersAll},
	AgentsStart:        {"OA", "OAP", lettersAll},
	AgentsMention:      {"OA", "OAPDG", lettersAll},
	AgentsPost:         {"OA", "OAPDG", lettersAll},
	AgentsReply:        {"OA", lettersAllButT, lettersAll},
	IssuesEdit:         {"OAP", "OAPDG", lettersAll},
	IssuesAssign:       {"OAP", "OAP", lettersAll},
	IssuesPrioritise:   {"OAP", "OAP", lettersAll},
	TopicsManage:       {"OAP", "OAPDG", lettersAll},
	DocsWrite:          {lettersAll, lettersAll, lettersAll},
	FilesWrite:         {lettersAll, lettersAll, lettersAll},
	ChannelsEdit:       {"OAP", "OAPDG", lettersAll},
	ChannelsAIAgents:   {"OA", "OA", lettersAll},
	MessagesKind:       {"OA", "OAP", lettersAll},
	IssuesStatus:       {"OAP", "OAPDG", lettersAll},
	IssuesBlocker:      {"O", "O", "OA"},
	TopicsChangeOthers: {"OA", "OAP", lettersAll},
	IssuesRemoveOthers: {"OA", "OA", lettersAll},
	ResultsAccept:      {"OA", "OAP", lettersAll},
	ShipApprove:        {"OA", "OA", lettersAll},
	RoadmapPublish:     {"OA", "OA", "OAP"},
	MarketingPublish:   {"O", "O", "O"},
	EmbedsManage:       {"O", "O", "O"},
}

// presetColumn is each preset's column in presetFills.
var presetColumn = map[string]int{PresetStrict: 0, PresetCorporate: 1, PresetMoveFast: 2}

// Preset is the preset's fill of all 39 cells (a fresh map each call);
// false for an unknown id.
func Preset(id string) (Cells, bool) {
	col, filled := presetColumn[id]
	if !filled && id != PresetAgile {
		return nil, false
	}
	c := Today()
	if !filled {
		return c, true
	}
	for action, fills := range presetFills {
		for _, r := range RoleIDs {
			c.set(action, r, false)
		}
		for j := 0; j < len(fills[col]); j++ {
			c.set(action, roleLetters[fills[col][j]], true)
		}
	}
	return c, true
}

// Diff is every cell where to differs from from, in catalogue then RoleIDs
// order: what a preset or a PUT changes.
func Diff(from, to Cells) []Cell {
	var out []Cell
	for _, a := range Catalogue {
		for _, r := range RoleIDs {
			if from.Get(a.ID, r) != to.Get(a.ID, r) {
				out = append(out, Cell{a.ID, r})
			}
		}
	}
	return out
}

// PresetMatch is the preset the list equals cell for cell, or "" (custom).
func PresetMatch(c Cells) string {
	for _, id := range PresetIDs {
		p, _ := Preset(id)
		if len(Diff(p, c)) == 0 {
			return id
		}
	}
	return ""
}

// Apply is roles with the list's cells written over their grants: the
// permissions outside the list (topics.read, agents.command, ...) stay as
// they are, and roles outside RoleIDs are copied unchanged. A fresh map.
func Apply(roles map[string]Role, c Cells) map[string]Role {
	out := make(map[string]Role, len(roles))
	for id, r := range roles {
		out[id] = r
	}
	for _, id := range RoleIDs {
		r, ok := out[id]
		if !ok {
			continue
		}
		perms := []string{}
		for _, p := range r.Perms {
			if !InCatalogue(p) {
				perms = append(perms, p)
			}
		}
		for _, a := range Catalogue {
			if c.Get(a.ID, id) {
				perms = append(perms, a.ID)
			}
		}
		sort.Strings(perms)
		r.Perms = perms
		out[id] = r
	}
	return out
}

// MayChangeCell is the no-escalation rule of one cell (spec 152 3.7, D6):
// the actor changes (role, action) only when it Covers the role as it stands,
// and grants the action only when it holds it. A locked cell never turns
// false, whoever asks.
func (a Access) MayChangeCell(role Role, action string, granted bool) bool {
	if Locked(action, role.ID) && !granted {
		return false
	}
	if !a.Covers(role) {
		return false
	}
	return !granted || a.Can(action)
}

// PresetRefusal checks a preset cell by cell against the list in force
// (roles): the first cell it would change that MayChangeCell refuses, in
// catalogue then RoleIDs order, and false when the actor may apply it whole.
func (a Access) PresetRefusal(roles map[string]Role, preset Cells) (Cell, bool) {
	for _, cell := range Diff(CellsOf(roles), preset) {
		if !a.MayChangeCell(roles[cell.Role], cell.Action, preset.Get(cell.Action, cell.Role)) {
			return cell, true
		}
	}
	return Cell{}, false
}
