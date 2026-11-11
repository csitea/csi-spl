package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func costSplit(key CostItemKey, by string, shares ...CostAllocShare) CostAllocation {
	return CostAllocation{CostItemKey: key, Shares: shares, CreatedBy: by}
}

func share(ws string, bp int) CostAllocShare { return CostAllocShare{WorkspaceID: ws, ShareBP: bp} }

// splitOf is the stored split of the test's own item (nil = none).
func splitOf(t *testing.T, ca CostAllocationStore, key CostItemKey) []CostAllocShare {
	t.Helper()
	all, err := ca.CostAllocations(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range all {
		if a.CostItemKey == key {
			return a.Shares
		}
	}
	return nil
}

// SPL-5291: the operator's split is stored whole, a re-put replaces it, an
// empty one removes it; a bad split (a Tokens item, the sum, a duplicate,
// a zero share) is never stored. Memory and Postgres.
func TestCostAllocationStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ca, ok := st.(CostAllocationStore)
			if !ok {
				t.Fatalf("%s keeps no cost allocations", name)
			}
			wa, wb := newTenant(t, st), newTenant(t, st)
			key, by := CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("bill-"), Kind: "cloud"}, uid("op-")
			got, err := ca.PutCostAllocation(ctx, costSplit(key, by, share(wb, 4000), share(wa, 6000)), nil)
			if err != nil || len(got.Shares) != 2 || got.CreatedAt.IsZero() {
				t.Fatalf("put: %+v %v", got, err)
			}
			if s := splitOf(t, ca, key); len(s) != 2 {
				t.Fatalf("read back: %+v", s)
			}
			if _, err := ca.PutCostAllocation(ctx, costSplit(key, by, share(wa, 10000)), nil); err != nil {
				t.Fatal(err)
			}
			if s := splitOf(t, ca, key); len(s) != 1 || s[0] != share(wa, 10000) {
				t.Fatalf("assigned to one workspace: %+v", s)
			}
			for why, bad := range map[string]CostAllocation{
				"sum 9999": costSplit(key, by, share(wa, 9999)),
				"twice":    costSplit(key, by, share(wa, 5000), share(wa, 5000)),
				"zero":     costSplit(key, by, share(wa, 0), share(wb, 10000)),
				"tokens":   costSplit(CostItemKey{Source: CostSourceAIPaid, ProjectOrVendor: "claude", Kind: "max"}, by, share(wa, 10000)),
				"no kind":  costSplit(CostItemKey{Source: "x", ProjectOrVendor: "y"}, by, share(wa, 10000)),
			} {
				if _, err := ca.PutCostAllocation(ctx, bad, nil); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
			if s := splitOf(t, ca, key); len(s) != 1 || s[0] != share(wa, 10000) {
				t.Fatalf("a refused split changed the stored one: %+v", s)
			}
			if _, err := ca.PutCostAllocation(ctx, costSplit(key, by), nil); err != nil {
				t.Fatal(err)
			}
			if s := splitOf(t, ca, key); s != nil {
				t.Fatalf("after the removal: %+v", s)
			}
		})
	}
}

// SPL-5291, costs-allocation.md section 3 (answer 3 B): a customer admin of
// W1 and W2 moves cost only between them. Allowed: 60/40 to 30/70 with W3's
// 2000 kept. Refused, each with its rule, the split unchanged: W3's share
// changed (1), W4 added (2), a removal of an item W1 + W2 hold whole (3), an item with no
// share in W1 or W2 (4). Memory and Postgres. RED CONTROL: rule 1 removed
// from CheckCostAllocWithin, the "W3 changed" case is stored.
func TestCostAllocationWithin(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ca := st.(CostAllocationStore)
			w1, w2, w3, w4 := newTenant(t, st), newTenant(t, st), newTenant(t, st), newTenant(t, st)
			admin := map[string]bool{w1: true, w2: true}
			key, by := CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("hours-"), Kind: "hr"}, uid("hum-")
			if _, err := ca.PutCostAllocation(ctx, costSplit(key, "op", share(w1, 4800), share(w2, 3200), share(w3, 2000)), nil); err != nil {
				t.Fatal(err)
			}
			if _, err := ca.PutCostAllocation(ctx, costSplit(key, by, share(w1, 2400), share(w2, 5600), share(w3, 2000)), admin); err != nil {
				t.Fatalf("allowed re-split: %v", err)
			}
			want := []CostAllocShare{share(w1, 2400), share(w2, 5600), share(w3, 2000)}
			for name, bad := range map[string]CostAllocation{
				"rule 1": costSplit(key, by, share(w1, 2400), share(w2, 6600), share(w3, 1000)),
				"rule 2": costSplit(key, by, share(w1, 2400), share(w2, 4600), share(w3, 2000), share(w4, 1000)),
			} {
				_, err := ca.PutCostAllocation(ctx, bad, admin)
				if !errors.Is(err, ErrCostAllocOutside) || !strings.Contains(err.Error(), name) {
					t.Errorf("%s: %v, want ErrCostAllocOutside naming %s", name, err, name)
				}
			}
			s := splitOf(t, ca, key)
			if len(s) != 3 {
				t.Fatalf("after the refusals: %+v", s)
			}
			for i := range want {
				if !containsShare(s, want[i]) {
					t.Fatalf("after the refusals: %+v, want %+v", s, want)
				}
			}
			// the admin never reads W3's share, so their body names W1 and
			// W2 only: the store keeps W3's 2000 (MergeCostAllocWithin).
			// CONTROL: the same body as the operator's is not a whole split.
			got, perr := ca.PutCostAllocation(ctx, costSplit(key, by, share(w1, 5000), share(w2, 3000)), admin)
			if perr != nil {
				t.Fatalf("a body of the admin's own shares: %v", perr)
			}
			s = splitOf(t, ca, key)
			for _, x := range []CostAllocShare{share(w1, 5000), share(w2, 3000), share(w3, 2000)} {
				if !containsShare(s, x) || !containsShare(got.Shares, x) {
					t.Fatalf("after a body of the admin's own shares: stored %+v, answered %+v, want %+v kept", s, got.Shares, x)
				}
			}
			if len(s) != 3 {
				t.Fatalf("after a body of the admin's own shares: %+v", s)
			}
			if _, err := ca.PutCostAllocation(ctx, costSplit(key, "op", share(w1, 5000), share(w2, 3000)), nil); err == nil {
				t.Fatal("CONTROL: the operator's body of 8000 bp was stored, want the sum refusal")
			}
			// rule 3: an item held whole by W1 + W2; removing it gives the
			// estate back what they held
			own := CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("own-"), Kind: "cloud"}
			if _, err := ca.PutCostAllocation(ctx, costSplit(own, "op", share(w1, 5000), share(w2, 5000)), nil); err != nil {
				t.Fatal(err)
			}
			if _, err := ca.PutCostAllocation(ctx, costSplit(own, by), admin); !errors.Is(err, ErrCostAllocOutside) || !strings.Contains(err.Error(), "rule 3") {
				t.Errorf("rule 3: %v", err)
			}
			if s := splitOf(t, ca, own); len(s) != 2 {
				t.Errorf("rule 3 refusal changed the split: %+v", s)
			}
			other := CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("other-"), Kind: "cloud"}
			if _, err := ca.PutCostAllocation(ctx, costSplit(other, "op", share(w3, 10000)), nil); err != nil {
				t.Fatal(err)
			}
			_, err := ca.PutCostAllocation(ctx, costSplit(other, by, share(w1, 10000)), admin)
			if !errors.Is(err, ErrCostAllocOutside) || !strings.Contains(err.Error(), "rule 4") {
				t.Errorf("rule 4: %v", err)
			}
			_, err = ca.PutCostAllocation(ctx, costSplit(CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("new-"), Kind: "cloud"}, by, share(w1, 10000)), admin)
			if !errors.Is(err, ErrCostAllocOutside) {
				t.Errorf("rule 4, an item with no split: %v", err)
			}
		})
	}
}

func containsShare(s []CostAllocShare, x CostAllocShare) bool {
	for _, y := range s {
		if y == x {
			return true
		}
	}
	return false
}

// SPL-5291: the share is rounded down and never more than the item, even
// for many small shares and the largest amounts (no int64 overflow).
// CONTROL: a share rounded to nearest gives three 3333 bp shares of 1.0 USD
// plus a 1 bp one more than the item.
func TestCostAllocShareOf(t *testing.T) {
	cases := []struct {
		micros int64
		bp     int
		want   int64
	}{{1_000_000, 6000, 600_000}, {1_000_000, 3333, 333_300}, {999_999, 3333, 333_299}, {1, 9999, 0}, {-5, 10000, 0},
		{9_000_000_000_000_000_000, 10000, 9_000_000_000_000_000_000}, {9_000_000_000_000_000_000, 5000, 4_500_000_000_000_000_000}}
	for _, c := range cases {
		if got := CostAllocShareOf(c.micros, c.bp); got != c.want {
			t.Errorf("CostAllocShareOf(%d, %d) = %d, want %d", c.micros, c.bp, got, c.want)
		}
	}
	for _, item := range []int64{1, 7, 999_999, 1_234_567_891} {
		sum := CostAllocShareOf(item, 3333)*3 + CostAllocShareOf(item, 1)
		if sum > item {
			t.Errorf("item %d: shares sum to %d", item, sum)
		}
	}
}

// SPL-5291, rdb 0275: no scope and a workspace scope read no allocation and
// may not insert one; CONTROL: the operator scope reads the row.
func TestCostAllocationRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	key := CostItemKey{Source: "cost_entry", ProjectOrVendor: uid("rls-"), Kind: "cloud"}
	if _, err := pg.PutCostAllocation(ctx, costSplit(key, uid("op-"), share(tenant, 10000)), nil); err != nil {
		t.Fatal(err)
	}
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	} {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM cost_allocations`).Scan(&n)
		}); err != nil || n != 0 {
			t.Errorf("%s scope reads %d allocations (%v), want 0", scope, n, err)
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO cost_allocations (source, project_or_vendor, kind, workspace_id, share_bp, created_by)
				VALUES ('x', 'y', 'z', $1, 10000, 'x')`, tenant)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM cost_allocations WHERE project_or_vendor = $1`, key.ProjectOrVendor); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator scope reads the row: %d %v", n, err)
	}
}
