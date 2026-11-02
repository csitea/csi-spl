package store

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func cellOf(action, role string, granted bool) RoleCell {
	return RoleCell{Action: action, Role: role, Granted: &granted}
}

// listCells is the list as TenantRoles answers it for tenant.
func listCells(t *testing.T, h Humans, tenant string) rbac.Cells {
	t.Helper()
	roles, err := h.TenantRoles(context.Background(), tenant)
	if err != nil {
		t.Fatal(err)
	}
	return rbac.CellsOf(roles)
}

// storedRows is the tenant's stored rows.
func storedRows(t *testing.T, s Store, tenant string) []RoleGrant {
	t.Helper()
	rows, err := s.(RoleGrants).RoleGrants(context.Background(), tenant)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// TestListDefaultIsToday (spec 152 3.6, R12, store half): with no rows the
// answers through TenantRoles equal rbac.Today() cell for cell, 312 of 312 (the
// rbac test of this name pins Today() to the frozen table), and the whole table
// equals the system grants. Red control: one row (developer, agents.start,
// false) turns exactly one cell red.
func TestListDefaultIsToday(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid := s.(Humans), newTenant(t, s)
			roles, err := h.TenantRoles(ctx, tid)
			if err != nil || !reflect.DeepEqual(roles, rbac.DefaultRoles()) {
				t.Fatalf("no rows: %v %v", roles, err)
			}
			got, today := rbac.CellsOf(roles), rbac.Today()
			if d := rbac.Diff(today, got); len(d) != 0 {
				t.Fatalf("no rows: %d of 312 equal: %v", 312-len(d), d)
			}
			if err := s.(RoleGrants).SetRoleCells(ctx, tid, "HUM-1", []RoleCell{cellOf(rbac.AgentsStart, rbac.Developer, false)}, now); err != nil {
				t.Fatal(err)
			}
			want := []rbac.Cell{{Action: rbac.AgentsStart, Role: rbac.Developer}}
			if d := rbac.Diff(today, listCells(t, h, tid)); !reflect.DeepEqual(d, want) {
				t.Fatalf("red control: %v, want %v", d, want)
			}
		})
	}
}

// TestRoleCellsOverlay (spec 152 3.4, 3.7): a false row takes a system grant
// away, a true row adds one, nil or today's value clears the row, a grant
// outside the list stays, and set_by / set_at follow the last writer.
func TestRoleCellsOverlay(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	t1 := t0.Add(time.Hour)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, g, tid := s.(Humans), s.(RoleGrants), newTenant(t, s)
			err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{
				cellOf(rbac.AgentsDM, rbac.Tester, true),
				cellOf(rbac.AgentsStart, rbac.Developer, false),
				cellOf(rbac.DocsWrite, rbac.Tester, true), // today's value: no row
			}, t0)
			if err != nil {
				t.Fatal(err)
			}
			want := []RoleGrant{
				{Action: rbac.AgentsStart, Role: rbac.Developer, Granted: false, SetBy: "HUM-1", SetAt: t0},
				{Action: rbac.AgentsDM, Role: rbac.Tester, Granted: true, SetBy: "HUM-1", SetAt: t0},
			}
			if got := storedRows(t, s, tid); !reflect.DeepEqual(got, want) {
				t.Fatalf("rows %+v, want %+v", got, want)
			}
			c := listCells(t, h, tid)
			if !c.Get(rbac.AgentsDM, rbac.Tester) || c.Get(rbac.AgentsStart, rbac.Developer) || !c.Get(rbac.AgentsDM, rbac.Developer) {
				t.Fatalf("effective: tester dm %v, developer start %v, developer dm %v",
					c.Get(rbac.AgentsDM, rbac.Tester), c.Get(rbac.AgentsStart, rbac.Developer), c.Get(rbac.AgentsDM, rbac.Developer))
			}
			roles, _ := h.TenantRoles(ctx, tid)
			if !grants(roles[rbac.Developer], rbac.AgentsCommand) || !grants(roles[rbac.Developer], rbac.TopicsRead) {
				t.Fatalf("a grant outside the list moved: %v", roles[rbac.Developer].Perms)
			}
			// A later write wins and names its writer; the other row stays.
			if err := g.SetRoleCells(ctx, tid, "HUM-2", []RoleCell{cellOf(rbac.AgentsDM, rbac.Tester, true)}, t1); err != nil {
				t.Fatal(err)
			}
			want[1].SetBy, want[1].SetAt = "HUM-2", t1
			if got := storedRows(t, s, tid); !reflect.DeepEqual(got, want) {
				t.Fatalf("after rewrite %+v, want %+v", got, want)
			}
			// Back to today's: nil and today's value both clear; the same
			// cell twice in a set: the later one wins.
			err = g.SetRoleCells(ctx, tid, "HUM-2", []RoleCell{
				{Action: rbac.AgentsDM, Role: rbac.Tester},
				cellOf(rbac.AgentsStart, rbac.Developer, false),
				cellOf(rbac.AgentsStart, rbac.Developer, true),
			}, t1)
			if err != nil {
				t.Fatal(err)
			}
			if got := storedRows(t, s, tid); len(got) != 0 {
				t.Fatalf("back to today keeps rows: %+v", got)
			}
			if d := rbac.Diff(rbac.Today(), listCells(t, h, tid)); len(d) != 0 {
				t.Fatalf("back to today: %v", d)
			}
		})
	}
}

// TestRolePresetsStoreDifference (spec 152 3.3, 3.5, R3 store half): a preset
// drops the workspace's rows and writes its difference from today, and
// TenantRoles then answers exactly that preset.
func TestRolePresetsStoreDifference(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	wantRows := map[string]int{rbac.PresetStrict: 68, rbac.PresetCorporate: 43, rbac.PresetMoveFast: 35, rbac.PresetAgile: 0}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, g, tid := s.(Humans), s.(RoleGrants), newTenant(t, s)
			// A custom row no preset writes: every preset must drop it.
			custom := []RoleCell{cellOf(rbac.HoursRead, rbac.Tester, true)}
			for _, id := range rbac.PresetIDs {
				if err := g.SetRoleCells(ctx, tid, "HUM-1", custom, now); err != nil {
					t.Fatal(err)
				}
				if err := g.ApplyRolePreset(ctx, tid, "HUM-1", id, now); err != nil {
					t.Fatalf("%s: %v", id, err)
				}
				if n := len(storedRows(t, s, tid)); n != wantRows[id] {
					t.Errorf("%s: %d rows, want %d", id, n, wantRows[id])
				}
				if got := rbac.PresetMatch(listCells(t, h, tid)); got != id {
					t.Errorf("%s reads back as %q", id, got)
				}
			}
			before := storedRows(t, s, tid)
			if err := g.ApplyRolePreset(ctx, tid, "HUM-1", "chaos", now); !errors.Is(err, ErrUnknownPreset) {
				t.Fatalf("unknown preset: %v", err)
			}
			if got := storedRows(t, s, tid); !reflect.DeepEqual(got, before) {
				t.Fatalf("a refused preset changed rows: %+v", got)
			}
		})
	}
}

// TestRoleCellsRefused (spec 152 3.7, R14 store half): clearing any of the six
// locked cells is refused and nothing of that set lands; a true or nil on a
// locked cell changes nothing and stores nothing. Control: the same set without
// the locked cell lands.
func TestRoleCellsRefused(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			g, tid := s.(RoleGrants), newTenant(t, s)
			other := cellOf(rbac.AgentsDM, rbac.Tester, true)
			locked := rbac.LockedCells()
			if len(locked) != 6 {
				t.Fatalf("locked cells: %v", locked)
			}
			for _, c := range locked {
				err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{other, cellOf(c.Action, c.Role, false)}, now)
				if !errors.Is(err, ErrLockedCell) || !strings.Contains(err.Error(), c.Action+" / "+c.Role) {
					t.Errorf("%v: %v", c, err)
				}
				for _, noop := range []RoleCell{cellOf(c.Action, c.Role, true), {Action: c.Action, Role: c.Role}} {
					if err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{noop}, now); err != nil {
						t.Errorf("%v no-op: %v", c, err)
					}
				}
				if rows := storedRows(t, s, tid); len(rows) != 0 {
					t.Fatalf("%v: a refused set or a no-op stored %+v", c, rows)
				}
			}
			for _, c := range [][2]string{
				{rbac.TopicsArchive, rbac.Developer}, // the archive setting, not a cell (D11)
				{rbac.AgentsCommand, rbac.Developer}, // outside the list (3.2)
				{"nope", rbac.Developer},
				{rbac.AgentsDM, rbac.TimeAccountant},
				{rbac.AgentsDM, rbac.DemoUser},
				{rbac.AgentsDM, "nope"},
			} {
				err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{other, cellOf(c[0], c[1], true)}, now)
				if !errors.Is(err, ErrUnknownCell) {
					t.Errorf("%v: %v", c, err)
				}
			}
			for _, by := range []string{"", strings.Repeat("x", roleGrantSetByMax+1)} {
				if err := g.SetRoleCells(ctx, tid, by, []RoleCell{other}, now); !errors.Is(err, ErrBadRoleGrantSetBy) {
					t.Errorf("set_by %d chars: %v", len(by), err)
				}
			}
			if err := g.SetRoleCells(ctx, "", "HUM-1", []RoleCell{other}, now); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant: %v", err)
			}
			if err := g.SetRoleCells(ctx, uid("t-"), "HUM-1", []RoleCell{other}, now); !errors.Is(err, ErrNotFound) {
				t.Errorf("unknown tenant: %v", err)
			}
			if rows := storedRows(t, s, tid); len(rows) != 0 {
				t.Fatalf("refused writes stored %+v", rows)
			}
			if err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{other}, now); err != nil {
				t.Fatalf("control: %v", err)
			}
			if rows := storedRows(t, s, tid); len(rows) != 1 {
				t.Fatalf("control stored %+v", rows)
			}
		})
	}
}

// TestRoleGrantsTenantIsolation (spec 152 3.3): one workspace's list never
// reaches another's through the store, read or write.
func TestRoleGrantsTenantIsolation(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, g := s.(Humans), s.(RoleGrants)
			a, b := newTenant(t, s), newTenant(t, s)
			if err := g.ApplyRolePreset(ctx, a, "HUM-1", rbac.PresetStrict, now); err != nil {
				t.Fatal(err)
			}
			if n := len(storedRows(t, s, a)); n != 68 {
				t.Fatalf("control void: tenant a holds %d rows", n)
			}
			if rows := storedRows(t, s, b); len(rows) != 0 {
				t.Fatalf("tenant b reads rows of a: %+v", rows)
			}
			roles, err := h.TenantRoles(ctx, b)
			if err != nil || !reflect.DeepEqual(roles, rbac.DefaultRoles()) {
				t.Fatalf("tenant b's roles moved: %v %v", roles, err)
			}
			if err := g.ApplyRolePreset(ctx, b, "HUM-2", rbac.PresetAgile, now); err != nil {
				t.Fatal(err)
			}
			if n := len(storedRows(t, s, a)); n != 68 {
				t.Fatalf("tenant b's preset dropped a's rows: %d left", n)
			}
		})
	}
}

// TestRoleGrantsRLS: another tenant's scope neither sees, deletes nor writes a
// tenant's rows. Control: the operator scope sees them.
func TestRoleGrantsRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now()
	a, b := newTenant(t, pg), newTenant(t, pg)
	if err := pg.ApplyRolePreset(ctx, a, "HUM-1", rbac.PresetStrict, now); err != nil {
		t.Fatal(err)
	}
	err := pg.inTenant(ctx, b, func(tx pgx.Tx) error {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM tenant_role_grants WHERE tenant_id = $1`, a).Scan(&n); err != nil || n != 0 {
			t.Errorf("tenant b's scope sees %d rows of a (%v)", n, err)
		}
		tag, err := tx.Exec(ctx, `DELETE FROM tenant_role_grants WHERE tenant_id = $1`, a)
		if err == nil && tag.RowsAffected() != 0 {
			t.Errorf("tenant b's scope deleted %d rows of a", tag.RowsAffected())
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	err = pg.inTenant(ctx, b, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_role_grants (tenant_id, role_id, permission_id, granted, set_by)
			VALUES ($1, 'developer', 'docs.write', false, 'HUM-2')`, a)
		return err
	})
	if err == nil {
		t.Fatal("tenant b's scope wrote a row for a")
	}
	var n int
	err = pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM tenant_role_grants WHERE tenant_id = $1`, a).Scan(&n)
	})
	if err != nil || n != 68 {
		t.Fatalf("control: operator sees %d rows of a (%v), want 68", n, err)
	}
}

// TestRolePlanOneTransaction: a write that fails after the preset's DELETE
// leaves the old rows; two presets at once leave one preset whole, never a mix
// (spec 152 3.7). Control: the same statement with a good plan lands.
func TestRolePlanOneTransaction(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC()
	tid := newTenant(t, pg)
	if err := pg.ApplyRolePreset(ctx, tid, "HUM-1", rbac.PresetCorporate, now); err != nil {
		t.Fatal(err)
	}
	before := storedRows(t, pg, tid)
	row := RoleGrant{Action: rbac.AgentsDM, Role: "nope", Granted: true, SetBy: "HUM-1", SetAt: now}
	write := func(p roleCellPlan) error {
		return pg.inTenant(ctx, tid, func(tx pgx.Tx) error { return writeRolePlanTx(ctx, tx, tid, p, true) })
	}
	if err := write(roleCellPlan{write: []RoleGrant{row}}); err == nil {
		t.Fatal("control void: a row with an unknown role was stored")
	}
	if got := storedRows(t, pg, tid); !reflect.DeepEqual(got, before) {
		t.Fatalf("a failed preset changed %d rows to %d", len(before), len(got))
	}
	row.Role = rbac.Tester
	if err := write(roleCellPlan{write: []RoleGrant{row}}); err != nil {
		t.Fatalf("control: %v", err)
	}
	if got := storedRows(t, pg, tid); len(got) != 1 {
		t.Fatalf("control: %d rows, want 1", len(got))
	}
	for i := 0; i < 8; i++ {
		var wg sync.WaitGroup
		for _, id := range []string{rbac.PresetStrict, rbac.PresetMoveFast} {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				if err := pg.ApplyRolePreset(ctx, tid, "HUM-1", id, now); err != nil {
					t.Errorf("%s: %v", id, err)
				}
			}(id)
		}
		wg.Wait()
		if m := rbac.PresetMatch(listCells(t, pg, tid)); m != rbac.PresetStrict && m != rbac.PresetMoveFast {
			t.Fatalf("round %d: two presets left a mix (%d rows)", i, len(storedRows(t, pg, tid)))
		}
	}
}

// TestLastGuardsReadSystemGrants (spec 152 3.7): the last-admin guard keeps
// reading the system grants: a developer given members.invite by the list does
// not free the only admin.
func TestLastGuardsReadSystemGrants(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, g, tid := s.(Humans), s.(RoleGrants), newTenant(t, s)
			adm := admitAs(t, h, tid, rbac.Admin)
			admitAs(t, h, tid, rbac.Developer)
			if err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{cellOf(rbac.MembersInvite, rbac.Developer, true)}, now); err != nil {
				t.Fatal(err)
			}
			if !listCells(t, h, tid).Get(rbac.MembersInvite, rbac.Developer) {
				t.Fatal("control void: the list did not grant it")
			}
			if err := h.SetMemberRole(ctx, tid, adm, rbac.Developer, ""); !errors.Is(err, ErrLastAdmin) {
				t.Fatalf("last admin demoted beside a list grant: %v", err)
			}
		})
	}
}

// operatorSessionStore is a second store on the test database whose connections
// hold the operator scope for the whole session. A store call's tenant scope
// does not clear it, so rdb 0223's operator_scope policy passes every row and
// only the statement's own tenant_id filter keeps it on one tenant. Tests only.
func operatorSessionStore(t *testing.T) *Postgres {
	t.Helper()
	ctx := context.Background()
	cfg, err := pgxpool.ParseConfig(os.Getenv("SPOOL_TEST_PG_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		_, err := c.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', false)`)
		return err
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return &Postgres{pool: pool}
}

// TestRoleGrantsStatementsFilterTenant: RLS is the second lock, so RLS-scoped
// tests cannot see a statement that lost its tenant_id filter. Here RLS passes
// every row and each statement must still keep to its tenant: RoleGrants,
// TenantRoles (both overlay arms), the cell delete and the preset delete.
// Control: this session's tenant scope does read the other tenant's rows.
func TestRoleGrantsStatementsFilterTenant(t *testing.T) {
	pg := rlsStore(t)
	op := operatorSessionStore(t)
	ctx, now := context.Background(), time.Now()
	a, b := newTenant(t, pg), newTenant(t, pg)
	shared := cellOf(rbac.AgentsDM, rbac.Tester, true)
	onlyA := []RoleCell{shared, cellOf(rbac.AgentsStart, rbac.Developer, false), cellOf(rbac.HoursRead, rbac.Tester, true)}
	if err := pg.SetRoleCells(ctx, a, "HUM-1", onlyA, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetRoleCells(ctx, b, "HUM-2", []RoleCell{shared}, now); err != nil {
		t.Fatal(err)
	}
	var n int
	err := op.inTenant(ctx, b, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM tenant_role_grants WHERE tenant_id = $1`, a).Scan(&n)
	})
	if err != nil || n != 3 {
		t.Fatalf("control void: b's scope on this session reads %d rows of a (%v), want 3", n, err)
	}
	rows := storedRows(t, op, b)
	if len(rows) != 1 || rows[0].SetBy != "HUM-2" {
		t.Errorf("RoleGrants of b lost its filter: %+v", rows)
	}
	want := []rbac.Cell{{Action: rbac.AgentsDM, Role: rbac.Tester}}
	if d := rbac.Diff(rbac.Today(), listCells(t, op, b)); !reflect.DeepEqual(d, want) {
		t.Errorf("TenantRoles of b lost a filter: differs from today in %v, want %v", d, want)
	}
	if err := op.SetRoleCells(ctx, b, "HUM-2", []RoleCell{{Action: shared.Action, Role: shared.Role}}, now); err != nil {
		t.Fatal(err)
	}
	if n := len(storedRows(t, pg, a)); n != 3 {
		t.Errorf("b's cell delete reached a: %d rows left, want 3", n)
	}
	if err := op.ApplyRolePreset(ctx, b, "HUM-2", rbac.PresetAgile, now); err != nil {
		t.Fatal(err)
	}
	if n := len(storedRows(t, pg, a)); n != 3 {
		t.Errorf("b's preset delete reached a: %d rows left, want 3", n)
	}
}

// TestRoleCellsConcurrentWriters: writers of different cells at once all land,
// and a locked cell's refusal among them stores nothing. A plan reads no stored
// row (only its arguments and the fixed system grants), so computing it outside
// the lock can neither lose a cell nor pass a locked one.
func TestRoleCellsConcurrentWriters(t *testing.T) {
	ctx, now := context.Background(), time.Now()
	fill, ok := rbac.Preset(rbac.PresetStrict)
	if !ok {
		t.Fatal("no strict preset")
	}
	diff := rbac.Diff(rbac.Today(), fill)
	if len(diff) < 8 {
		t.Fatalf("control void: %d cells", len(diff))
	}
	var cells []RoleCell
	for _, c := range diff[:8] {
		cells = append(cells, cellOf(c.Action, c.Role, fill.Get(c.Action, c.Role)))
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			g, tid := s.(RoleGrants), newTenant(t, s)
			for round := 0; round < 8; round++ {
				var wg sync.WaitGroup
				wg.Add(len(cells) + 1)
				for _, c := range cells {
					go func(c RoleCell) {
						defer wg.Done()
						if err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{c}, now); err != nil {
							t.Errorf("%s / %s: %v", c.Action, c.Role, err)
						}
					}(c)
				}
				go func() {
					defer wg.Done()
					err := g.SetRoleCells(ctx, tid, "HUM-1", []RoleCell{cellOf(rbac.PermsEdit, rbac.BizOwner, false)}, now)
					if !errors.Is(err, ErrLockedCell) {
						t.Errorf("locked cell among writers: %v", err)
					}
				}()
				wg.Wait()
				rows := storedRows(t, s, tid)
				if len(rows) != len(cells) {
					t.Fatalf("round %d: %d writers left %d rows: %+v", round, len(cells), len(rows), rows)
				}
				clear := make([]RoleCell, len(cells))
				for i, c := range cells {
					clear[i] = RoleCell{Action: c.Action, Role: c.Role}
				}
				if err := g.SetRoleCells(ctx, tid, "HUM-1", clear, now); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
