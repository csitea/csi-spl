package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// A workspace's role x action list (spec 152 3.3, 3.4, build row B3, rdb
// 0223): one tenant_role_grants row per cell that differs from the system
// grants, read inside TenantRoles. The hub checks who may write (no-escalation,
// row B4); the store refuses what nobody may write: a locked cell (3.7, D7).

var (
	// ErrLockedCell: a write would clear one of the six locked cells.
	ErrLockedCell = errors.New("locked cell")
	// ErrUnknownCell: the action or the role is not a cell of the list.
	ErrUnknownCell = errors.New("unknown cell")
	// ErrUnknownPreset: not one of rbac.PresetIDs.
	ErrUnknownPreset = errors.New("unknown preset")
	// ErrBadRoleGrantSetBy: set_by is empty or longer than the column allows.
	ErrBadRoleGrantSetBy = errors.New("set_by must be 1 to 200 characters")
)

// roleGrantSetByMax is rdb 0223's CHECK on set_by.
const roleGrantSetByMax = 200

// RoleCell is one cell of a write. Granted nil, or the value of today's system
// grant, means back to today's: the cell keeps no row (spec 152 3.7).
type RoleCell struct {
	Action, Role string
	Granted      *bool
}

// RoleGrant is one stored row: a cell that differs from the system grants and
// its last writer.
type RoleGrant struct {
	Action, Role string
	Granted      bool
	SetBy        string
	SetAt        time.Time
}

// RoleGrants is the write side of the list and its rows; the effective grants
// are read through Humans.TenantRoles. Each write is one transaction: all of it
// lands or none. ErrNotFound when the tenant does not exist.
type RoleGrants interface {
	// RoleGrants is the tenant's stored rows, by role then action.
	RoleGrants(ctx context.Context, tenant string) ([]RoleGrant, error)
	// SetRoleCells writes a cell set; other cells stay as they are. A later
	// cell of the set wins over an earlier one with the same action and role.
	SetRoleCells(ctx context.Context, tenant, setBy string, cells []RoleCell, now time.Time) error
	// ApplyRolePreset drops the tenant's rows and writes the preset's
	// difference from today (strict 68 rows, corporate 43, move_fast 35, agile 0).
	ApplyRolePreset(ctx context.Context, tenant, setBy, preset string, now time.Time) error
}

var (
	_ RoleGrants = (*Memory)(nil)
	_ RoleGrants = (*Postgres)(nil)
)

// roleCellPlan is a checked write: the rows to upsert, the cells to clear.
type roleCellPlan struct {
	write []RoleGrant
	drop  []rbac.Cell
}

// isListRole reports whether role is a column of the list.
func isListRole(role string) bool {
	for _, r := range rbac.RoleIDs {
		if r == role {
			return true
		}
	}
	return false
}

// planRoleCells checks a cell set before anything is written and splits it
// into rows that differ from today and cells that go back to today's.
func planRoleCells(tenant, setBy string, cells []RoleCell, now time.Time) (roleCellPlan, error) {
	var plan roleCellPlan
	if err := checkTenant(tenant); err != nil {
		return plan, err
	}
	if n := len([]rune(setBy)); n < 1 || n > roleGrantSetByMax {
		return plan, ErrBadRoleGrantSetBy
	}
	wanted := make(map[rbac.Cell]*bool, len(cells))
	for _, c := range cells {
		if !rbac.InCatalogue(c.Action) || !isListRole(c.Role) {
			return plan, fmt.Errorf("%w: %s / %s", ErrUnknownCell, c.Action, c.Role)
		}
		if rbac.Locked(c.Action, c.Role) && c.Granted != nil && !*c.Granted {
			return plan, fmt.Errorf("%w: %s / %s", ErrLockedCell, c.Action, c.Role)
		}
		wanted[rbac.Cell{Action: c.Action, Role: c.Role}] = c.Granted
	}
	today := rbac.Today()
	for cell, granted := range wanted {
		if granted == nil || *granted == today.Get(cell.Action, cell.Role) {
			plan.drop = append(plan.drop, cell)
			continue
		}
		plan.write = append(plan.write, RoleGrant{Action: cell.Action, Role: cell.Role, Granted: *granted, SetBy: setBy, SetAt: now.UTC()})
	}
	return plan, nil
}

// planRolePreset is the preset's difference from today as a cell set, through
// the same checks as any other write.
func planRolePreset(tenant, setBy, preset string, now time.Time) (roleCellPlan, error) {
	fill, ok := rbac.Preset(preset)
	if !ok {
		return roleCellPlan{}, fmt.Errorf("%w: %s", ErrUnknownPreset, preset)
	}
	var cells []RoleCell
	for _, cell := range rbac.Diff(rbac.Today(), fill) {
		granted := fill.Get(cell.Action, cell.Role)
		cells = append(cells, RoleCell{Action: cell.Action, Role: cell.Role, Granted: &granted})
	}
	return planRoleCells(tenant, setBy, cells, now)
}
