package store

import (
	"context"
	"testing"
)

func splitShares(t *testing.T, cs CostSplitStore, k CostSplitKey) []CostAllocShare {
	t.Helper()
	all, err := cs.CostSplits(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, sp := range all {
		if sp.CostSplitKey == k {
			return sp.Shares
		}
	}
	return nil
}

// SPL-5768, costs-allocation.md section 7: a tokens split and a person split
// are stored whole, a re-put replaces, an empty one removes; a bad split (a
// sum of 9999, a tokens subject, a person with no subject, an unknown kind,
// a duplicate) is never stored. Memory and Postgres.
func TestCostSplitStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs, ok := st.(CostSplitStore)
			if !ok {
				t.Fatalf("%s keeps no cost splits", name)
			}
			wa, wb := newTenant(t, st), newTenant(t, st)
			tok := CostSplitKey{Kind: CostSplitTokens}
			per := CostSplitKey{Kind: CostSplitPerson, Subject: uid("person-")}
			put := func(k CostSplitKey, shares ...CostAllocShare) error {
				_, err := cs.PutCostSplit(ctx, CostSplit{CostSplitKey: k, Shares: shares, CreatedBy: "op"})
				return err
			}
			if err := put(tok, share(wa, 7000), share(wb, 3000)); err != nil {
				t.Fatal(err)
			}
			if err := put(per, share(wa, 3000), share(wb, 7000)); err != nil {
				t.Fatal(err)
			}
			if s := splitShares(t, cs, tok); len(s) != 2 || ShareOf(s, wa) != 7000 || ShareOf(s, wb) != 3000 {
				t.Fatalf("tokens read back: %+v", s)
			}
			if s := splitShares(t, cs, per); ShareOf(s, wb) != 7000 {
				t.Fatalf("person read back: %+v", s)
			}
			for why, bad := range map[string]CostSplit{
				"sum 9999":       {CostSplitKey: tok, Shares: []CostAllocShare{share(wa, 9999)}},
				"tokens subject": {CostSplitKey: CostSplitKey{Kind: CostSplitTokens, Subject: "x"}, Shares: []CostAllocShare{share(wa, 10000)}},
				"no person":      {CostSplitKey: CostSplitKey{Kind: CostSplitPerson}, Shares: []CostAllocShare{share(wa, 10000)}},
				"kind":           {CostSplitKey: CostSplitKey{Kind: "cloud"}, Shares: []CostAllocShare{share(wa, 10000)}},
				"twice":          {CostSplitKey: tok, Shares: []CostAllocShare{share(wa, 5000), share(wa, 5000)}},
			} {
				bad.CreatedBy = "op"
				if _, err := cs.PutCostSplit(ctx, bad); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
			if s := splitShares(t, cs, tok); ShareOf(s, wa) != 7000 {
				t.Fatalf("a refused split changed the stored one: %+v", s)
			}
			if err := put(tok, share(wb, 10000)); err != nil {
				t.Fatal(err)
			}
			if s := splitShares(t, cs, tok); len(s) != 1 || ShareOf(s, wb) != 10000 {
				t.Fatalf("replaced: %+v", s)
			}
			if err := put(tok); err != nil {
				t.Fatal(err)
			}
			if s := splitShares(t, cs, tok); s != nil {
				t.Fatalf("after the removal: %+v", s)
			}
			tokens, person := CostSplitShares([]CostSplit{{CostSplitKey: per, Shares: []CostAllocShare{share(wa, 10000)}}})
			if tokens != nil || ShareOf(person[per.Subject], wa) != 10000 {
				t.Fatalf("CostSplitShares: %+v %+v", tokens, person)
			}
		})
	}
}
