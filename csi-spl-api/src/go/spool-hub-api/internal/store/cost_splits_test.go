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

// SPL-6301, costs-allocation.md 7.7: a tokens_vendor split of one vendor
// over a month range is stored and read back beside the tokens split; a bad
// subject (an unknown vendor, a bad month, from after to, no range) is never
// stored; CostSplitVendorShares answers it only for its vendor inside its
// months, and CostSplitVendorOverlap names a stored split of the same vendor
// whose months meet. Memory and Postgres (rdb 0313 widens 0293's CHECKs:
// without it Postgres refuses the kind). RED CONTROL: CheckCostSplit without
// the tokens_vendor kind refuses the first put.
func TestCostSplitVendorStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs := st.(CostSplitStore)
			wa, wb := newTenant(t, st), newTenant(t, st)
			tok := CostSplitKey{Kind: CostSplitTokens}
			ven := CostSplitKey{Kind: CostSplitTokensVendor, Subject: "claude:2002-02:2002-03"}
			put := func(k CostSplitKey, shares ...CostAllocShare) error {
				_, err := cs.PutCostSplit(ctx, CostSplit{CostSplitKey: k, Shares: shares, CreatedBy: "op"})
				return err
			}
			if err := put(tok, share(wa, 7000), share(wb, 3000)); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = put(tok); _ = put(ven) })
			if err := put(ven, share(wa, 6000), share(wb, 4000)); err != nil {
				t.Fatalf("tokens_vendor put: %v", err)
			}
			for _, bad := range []string{"", "openai:2002-01:2002-02", "claude:2002-13:2002-12", "claude:2002-03:2002-02",
				"claude:2002-02", "claude:2002-02:2002-03:x", "Claude:2002-02:2002-03"} {
				if err := put(CostSplitKey{Kind: CostSplitTokensVendor, Subject: bad}, share(wa, 10000)); err == nil {
					t.Errorf("subject %q: stored", bad)
				}
			}
			all, err := cs.CostSplits(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if s := splitShares(t, cs, ven); ShareOf(s, wb) != 4000 {
				t.Fatalf("tokens_vendor read back: %+v", s)
			}
			if tokens, _ := CostSplitShares(all); ShareOf(tokens, wb) != 3000 {
				t.Fatalf("the tokens split changed: %+v", tokens)
			}
			for _, c := range []struct {
				vendor, month string
				want          int
			}{{"claude", "2002-02", 4000}, {"claude", "2002-03", 4000}, {"claude", "2002-01", 0}, {"claude", "2002-04", 0}, {"grok", "2002-02", 0}} {
				if got := ShareOf(CostSplitVendorShares(all, c.vendor, c.month), wb); got != c.want {
					t.Errorf("CostSplitVendorShares %s %s: %d, want %d", c.vendor, c.month, got, c.want)
				}
			}
			for subject, want := range map[string]string{"claude:2002-03:2002-05": ven.Subject, "claude:2001-01:2002-02": ven.Subject,
				"claude:2002-04:2002-05": "", "grok:2002-02:2002-03": "", ven.Subject: ""} {
				sp := CostSplit{CostSplitKey: CostSplitKey{Kind: CostSplitTokensVendor, Subject: subject}}
				if got := CostSplitVendorOverlap(all, sp); got != want {
					t.Errorf("CostSplitVendorOverlap %s: %q, want %q", subject, got, want)
				}
			}
		})
	}
}
