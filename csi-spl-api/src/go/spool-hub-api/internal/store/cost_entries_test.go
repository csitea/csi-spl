package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func costEntry(by, typ, label string, amount float64, cur, month string) CostEntry {
	return CostEntry{Type: typ, Label: label, Amount: amount, Currency: cur, Period: month, CreatedBy: by}
}

// SPL-4383: create, list by type and month, delete; an unknown id is
// ErrNotFound; a bad entry never reaches the table. Memory and Postgres.
func TestCostEntryStoreCRUD(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ce, ok := st.(CostEntryStore)
			if !ok {
				t.Fatalf("%s keeps no cost entries", name)
			}
			by := uid("op-")
			cloud, err := ce.CreateCostEntry(ctx, costEntry(by, "cloud", "prd project", 212.5, "EUR", "2026-10"))
			if err != nil || !uuidRe.MatchString(cloud.ID) || cloud.CreatedBy != by || cloud.Amount != 212.5 || cloud.Period != "2026-10" {
				t.Fatalf("create: %+v %v", cloud, err)
			}
			hr, err := ce.CreateCostEntry(ctx, costEntry(by, "hr", "contractor", 3000, "EUR", "2026-10"))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := ce.CreateCostEntry(ctx, costEntry(by, "hr", "contractor", 3000, "EUR", "2026-09")); err != nil {
				t.Fatal(err)
			}
			for why, bad := range map[string]CostEntry{
				"ai type": costEntry(by, "ai", "x", 1, "USD", "2026-10"), "a day": costEntry(by, "hr", "x", 1, "USD", "2026-10-01"),
				"zero amount": costEntry(by, "hr", "x", 0, "USD", "2026-10"), "no label": costEntry(by, "hr", " ", 1, "USD", "2026-10"),
				"lower currency": costEntry(by, "hr", "x", 1, "usd", "2026-10"),
			} {
				if _, err := ce.CreateCostEntry(ctx, bad); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
			mine := func(typ, month string) []CostEntry {
				all, err := ce.ListCostEntries(ctx, typ, month)
				if err != nil {
					t.Fatal(err)
				}
				var out []CostEntry
				for _, x := range all {
					if x.CreatedBy == by {
						out = append(out, x)
					}
				}
				return out
			}
			if got := mine("cloud", "2026-10"); len(got) != 1 || got[0].ID != cloud.ID || got[0].Label != "prd project" {
				t.Fatalf("cloud 2026-10: %+v", got)
			}
			if got := mine("hr", "2026-10"); len(got) != 1 || got[0].ID != hr.ID {
				t.Fatalf("hr 2026-10: %+v", got)
			}
			if got := mine("hr", ""); len(got) != 2 || got[0].Period != "2026-09" {
				t.Fatalf("hr, every month: %+v", got)
			}
			if got := mine("", "2026-10"); len(got) != 2 {
				t.Fatalf("every type, 2026-10: %+v", got)
			}
			if err := ce.DeleteCostEntry(ctx, cloud.ID); err != nil {
				t.Fatal(err)
			}
			if err := ce.DeleteCostEntry(ctx, cloud.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v, want ErrNotFound", err)
			}
			if got := mine("cloud", ""); len(got) != 0 {
				t.Fatalf("after delete: %+v", got)
			}
			for _, x := range mine("", "") {
				ce.DeleteCostEntry(ctx, x.ID) //nolint:errcheck
			}
		})
	}
}

// SPL-4383, rdb 0245: no scope and a workspace scope read no cost entry and
// may not insert one; CONTROL: the operator scope reads the row.
func TestCostEntryRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	e, err := pg.CreateCostEntry(ctx, costEntry(uid("op-"), "cloud", "rls fixture", 1, "USD", "2026-10"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pg.DeleteCostEntry(ctx, e.ID) }) //nolint:errcheck
	tenant := newTenant(t, pg)
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	} {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM cost_entries`).Scan(&n)
		}); err != nil || n != 0 {
			t.Errorf("%s scope reads %d cost entries (%v), want 0", scope, n, err)
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by)
				VALUES (gen_random_uuid(), 'hr', 'x', 1, 'USD', '2026-10-01', 'x')`)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM cost_entries WHERE id = $1::uuid`, e.ID); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator scope reads the row: %d %v", n, err)
	}
	if _, err := pg.asOperator2(ctx, `INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by)
		VALUES (gen_random_uuid(), 'hr', 'x', 1, 'USD', '2026-10-02', 'x')`); err == nil {
		t.Error("a period that is not the 1st of a month was stored")
	}
}
