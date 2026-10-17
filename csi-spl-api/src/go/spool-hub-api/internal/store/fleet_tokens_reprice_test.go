package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// repriceRows is box's rows keyed agent@HH:MM.
func repriceRows(t *testing.T, ft FleetTokenStore, box string, since time.Time) map[string]FleetTokenBucket {
	t.Helper()
	out := map[string]FleetTokenBucket{}
	for _, r := range boxRows(t, ft, box, since) {
		out[r.AgentID+"@"+r.Minute.Format("15:04")] = r
	}
	return out
}

func repriceLine(t *testing.T, res FleetTokenReprice, model string) FleetTokenRepriceModel {
	t.Helper()
	for _, m := range res.Models {
		if m.Model == model {
			return m
		}
	}
	t.Fatalf("no line for %s in %+v", model, res)
	return FleetTokenRepriceModel{}
}

// putModelPrices adds one price per kind of model at from.
func putModelPrices(t *testing.T, st Store, provider, model string, from time.Time, in, out, cr, cw int64) {
	t.Helper()
	for k, v := range map[string]int64{UsageKindIn: in, UsageKindOut: out, UsageKindCacheRead: cr, UsageKindCacheWrite: cw} {
		putFleetPrice(t, st, ModelPrice{provider, model, k, v, "USD", from})
	}
}

// SPL-2405: the minutes stored unpriced before their model had a price get,
// once, the cost a push of the same minute gets now (the live pricer); a
// priced row, another model's row, an unmetered row and a row before from
// are never touched; a dry run writes nothing; a re-run prices 0 rows.
// Memory and Postgres.
func TestFleetTokenRepriceUnpriced(t *testing.T) {
	ctx := context.Background()
	m0 := time.Now().UTC().Truncate(time.Minute).Add(-30 * time.Minute)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft, rp := st.(FleetTokenStore), st.(FleetTokenRepricer)
			box, live := strings.ToLower(uid("rp")), strings.ToLower(uid("lv"))
			base, mis, other := uid("claude-rp-"), uid("mistral-rp-"), uid("claude-other-")
			dated := base + "-20251001"
			samples := []wire.FleetTokenSample{
				fleetSample("c-1", "claude", dated, m0, 1000, 200, 30000, 400),
				fleetSample("c-1", "claude", dated, m0.Add(time.Minute), 3, 0, 0, 0),
				fleetSample("m-1", "mistral", mis, m0, 2000, 100, 100000, 0),
				fleetSample("c-2", "claude", other, m0, 5000, 0, 0, 0),
				fleetSample("c-3", "claude", dated, m0.Add(-10*time.Minute), 1000, 0, 0, 0), // before from
				{AgentID: "c-4", Vendor: "claude", Model: &dated, Minute: m0},               // unmetered
			}
			if _, err := ft.RecordSamples(ctx, box, samples); err != nil {
				t.Fatal(err)
			}
			// The prices arrive after the minutes (SPL-2323), valid from before them.
			putModelPrices(t, st, "anthropic", base, m0.Add(-time.Hour), 1_000_000, 5_000_000, 100_000, 1_250_000)
			putModelPrices(t, st, "mistral", mis, m0.Add(-time.Hour), 500_000, 1_500_000, 50_000, 500_000)
			putModelPrices(t, st, "anthropic", other, m0.Add(-time.Hour), 1_000_000, 1_000_000, 1_000_000, 1_000_000)
			// A minute pushed once its price exists is priced live ...
			if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{fleetSample("c-5", "claude", dated, m0, 1000, 0, 0, 0)}); err != nil {
				t.Fatal(err)
			}
			// ... and stays at that price when the price row changes later.
			putFleetPrice(t, st, ModelPrice{"anthropic", base, UsageKindIn, 9_000_000, "USD", m0.Add(-30 * time.Minute)})
			// The live path now: the same samples pushed fresh, the parity oracle.
			if _, err := ft.RecordSamples(ctx, live, samples[:3]); err != nil {
				t.Fatal(err)
			}
			want := repriceRows(t, ft, live, m0)
			from := m0.Add(-5 * time.Minute)
			models := []string{dated, mis}

			dry, err := rp.RepriceUnpriced(ctx, models, from, true)
			if err != nil {
				t.Fatal(err)
			}
			if l := repriceLine(t, dry, dated); !dry.DryRun || l.UnpricedBefore != 2 || l.Priced != 2 || l.UnpricedAfter != 0 {
				t.Fatalf("dry run line %+v", l)
			}
			if r := repriceRows(t, ft, box, from)["c-1@"+m0.Format("15:04")]; r.Priced || r.CostMicros != 0 {
				t.Fatalf("RED CONTROL: the dry run wrote %+v", r)
			}

			res, err := rp.RepriceUnpriced(ctx, models, from, false)
			if err != nil {
				t.Fatal(err)
			}
			hd, mi := repriceLine(t, res, dated), repriceLine(t, res, mis)
			// in 9 (the price in force now) + out 5 + cr 0.1 + cw 1.25 per token:
			// 9000 + 1000 + 3000 + 500, then 27; mistral 1000 + 150 + 5000.
			if hd.UnpricedBefore != 2 || hd.Priced != 2 || hd.UnpricedAfter != 0 || hd.CostMicros != "13527.000000" || hd.Currency != "USD" {
				t.Fatalf("haiku line %+v", hd)
			}
			if mi.UnpricedBefore != 1 || mi.Priced != 1 || mi.UnpricedAfter != 0 || mi.CostMicros != "6150.000000" {
				t.Fatalf("mistral line %+v", mi)
			}
			got := repriceRows(t, ft, box, m0.Add(-time.Hour))
			at := func(a string, m time.Time) FleetTokenBucket { return got[a+"@"+m.Format("15:04")] }
			for _, k := range []string{"c-1@" + m0.Format("15:04"), "c-1@" + m0.Add(time.Minute).Format("15:04"), "m-1@" + m0.Format("15:04")} {
				if g, w := got[k], want[k]; !g.Priced || g.CostMicros != w.CostMicros || g.Currency != w.Currency || g.Model != w.Model {
					t.Fatalf("%s repriced %+v, the live path prices it %+v", k, g, w)
				}
			}
			if r := at("c-5", m0); !r.Priced || r.CostMicros != 1000 {
				t.Fatalf("RED CONTROL: a priced row was re-priced: %+v, want its 1000 micros kept", r)
			}
			if r := at("c-2", m0); r.Priced || r.CostMicros != 0 {
				t.Fatalf("RED CONTROL: another model's row was priced: %+v", r)
			}
			if r := at("c-3", m0.Add(-10*time.Minute)); r.Priced || r.CostMicros != 0 {
				t.Fatalf("RED CONTROL: a row before from was priced: %+v", r)
			}
			if r := at("c-4", m0); r.Priced || r.CostMicros != 0 {
				t.Fatalf("an unmetered row was priced: %+v", r)
			}

			again, err := rp.RepriceUnpriced(ctx, models, from, false)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range again.Models {
				if m.UnpricedBefore != 0 || m.Priced != 0 || m.CostMicros != "0.000000" {
					t.Fatalf("RED CONTROL: a re-run priced again: %+v", m)
				}
			}
			// The control behind "another model is never touched": named, it prices.
			if o, err := rp.RepriceUnpriced(ctx, []string{other}, from, false); err != nil || repriceLine(t, o, other).Priced != 1 {
				t.Fatalf("naming the other model prices its row: %+v %v", o, err)
			}
		})
	}
}

// The arguments: no model, an empty or repeated one and no from are refused.
func TestFleetTokenRepriceArgs(t *testing.T) {
	now := time.Now()
	for _, c := range []struct {
		models []string
		from   time.Time
	}{{nil, now}, {[]string{""}, now}, {[]string{"a", "a"}, now}, {[]string{"a"}, time.Time{}}} {
		if _, err := NewMemory().RepriceUnpriced(context.Background(), c.models, c.from, true); err == nil {
			t.Errorf("%v from %v accepted", c.models, c.from)
		}
	}
	if err := repriceArgs([]string{"a", "b"}, now); err != nil {
		t.Errorf("CONTROL: two models and a from refused: %v", err)
	}
}
