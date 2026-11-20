package hub

import (
	"strconv"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 123 13.8 row P03, 13.6 and the 13.9 case "an operator admin without
// hours.rates": the Human part carries no money for that reader and
// total.priced holds none of it, so total minus the parts reveals nothing.
// Made-up figures (13.2's), none a real cost.

func maskMoney(usd, eur int64, second *int64) store.CostProjectMoney {
	return store.CostProjectMoney{USDMicros: &usd, EURMicros: &eur, SecondMicros: second}
}

func maskI64(v int64) *int64 { return &v }

// maskProject is a project answer as the store folds it once Human is priced
// (P02): the parts sum to total.priced in every currency they are known in.
func maskProject(parts ...store.CostProjectPart) store.CostProject {
	var t [3]int64
	for _, p := range parts {
		for i, v := range []*int64{p.USDMicros, p.EURMicros, p.SecondMicros} {
			if v != nil {
				t[i] += *v
			}
		}
	}
	return store.CostProject{Parts: parts, LeftOut: []store.CostProjectLeftOut{},
		Total: store.CostProjectTotal{Priced: store.CostProjectMoney{USDMicros: &t[0], EURMicros: &t[1], SecondMicros: &t[2]}}}
}

// maskLeak is, per currency, total.priced minus the parts' known amounts:
// what a reader can work out about money no part shows.
func maskLeak(cp store.CostProject) [3]int64 {
	t := cp.Total.Priced
	var out [3]int64
	for i, v := range []*int64{t.USDMicros, t.EURMicros, t.SecondMicros} {
		if v != nil {
			out[i] = *v
		}
	}
	for _, p := range cp.Parts {
		for i, v := range []*int64{p.USDMicros, p.EURMicros, p.SecondMicros} {
			if v != nil {
				out[i] -= *v
			}
		}
	}
	return out
}

func maskPart(cp store.CostProject, name string) store.CostProjectPart {
	for _, p := range cp.Parts {
		if p.Part == name {
			return p
		}
	}
	return store.CostProjectPart{}
}

// maskEstate is the estate's four parts: Cloud 160, Owned hardware 80,
// AI tokens 630, Human 130 (USD), EUR 0.9 of each, the second currency
// known for all but Human (a day with no fx rate).
func maskEstate() store.CostProject {
	return maskProject(
		store.CostProjectPart{Part: store.CostProjectCloud, CostProjectMoney: maskMoney(160_000_000, 144_000_000, maskI64(1_600_000_000)), Completeness: store.CostProjectComplete, Lines: 2},
		store.CostProjectPart{Part: store.CostProjectHardware, CostProjectMoney: maskMoney(80_000_000, 72_000_000, maskI64(800_000_000)), Completeness: store.CostProjectHand, Lines: 1},
		store.CostProjectPart{Part: store.CostProjectAI, CostProjectMoney: maskMoney(630_000_000, 567_000_000, maskI64(6_300_000_000)), Completeness: store.CostProjectComplete, Lines: 3},
		store.CostProjectPart{Part: store.CostProjectHuman, CostProjectMoney: maskMoney(130_000_000, 117_000_000, nil), Completeness: store.CostProjectUnpriced, Lines: 4, Unpriced: 1},
	)
}

// TestCostProjectHumanMask: without hours.rates the Human amount and share
// are null, total.priced is Cloud + owned hardware + AI tokens only (870 of
// 1,000 USD), the shares are of that total, and total minus the parts is 0
// in every currency; Human keeps its counts and words. With hours.rates the
// answer is unchanged. A customer workspace's two parts are masked the same
// way. CONTROL: with the mask dropped, total minus the parts is the human
// money (130 USD), so the leak check can see what it guards.
func TestCostProjectHumanMask(t *testing.T) {
	in := maskEstate()
	got, masked := costProjectHumanMask(in, false)
	h := maskPart(got, store.CostProjectHuman)
	if !masked || h.USDMicros != nil || h.EURMicros != nil || h.SecondMicros != nil || h.Share != nil {
		t.Fatalf("no hours.rates: masked %v, human %+v, want masked and no money", masked, h)
	}
	if h.Lines != 4 || h.Unpriced != 1 || h.Completeness != store.CostProjectUnpriced {
		t.Errorf("human %+v: want its counts and words kept", h)
	}
	if leak := maskLeak(got); leak != [3]int64{} {
		t.Errorf("total minus parts = %v, want 0 in every currency (the human money leaks)", leak)
	}
	if tot := got.Total.Priced; *tot.USDMicros != 870_000_000 || *tot.EURMicros != 783_000_000 || *tot.SecondMicros != 8_700_000_000 {
		t.Errorf("total %d / %d / %d, want Cloud + owned hardware + AI tokens: 870 USD, 783 EUR, 8700 second",
			*tot.USDMicros, *tot.EURMicros, *tot.SecondMicros)
	}
	if ai := maskPart(got, store.CostProjectAI); ai.Share == nil || *ai.Share != 72.4 {
		share := "null"
		if ai.Share != nil {
			share = strconv.FormatFloat(*ai.Share, 'f', -1, 64)
		}
		t.Errorf("ai share %s, want 72.4 (630 of 870), not 63 (of 1,000)", share)
	}
	if h := maskPart(in, store.CostProjectHuman); h.USDMicros == nil || *in.Total.Priced.USDMicros != 1_000_000_000 {
		t.Errorf("the store's answer was changed in place: human %+v total %d", h, *in.Total.Priced.USDMicros)
	}

	same, masked := costProjectHumanMask(maskEstate(), true)
	if h := maskPart(same, store.CostProjectHuman); masked || h.USDMicros == nil || *h.USDMicros != 130_000_000 ||
		*same.Total.Priced.USDMicros != 1_000_000_000 {
		t.Errorf("hours.rates: masked %v human %+v total %d, want the answer unchanged", masked, h, *same.Total.Priced.USDMicros)
	}

	ws := maskProject(
		store.CostProjectPart{Part: store.CostProjectAI, CostProjectMoney: maskMoney(50_000_000, 45_000_000, maskI64(500_000_000)), Completeness: store.CostProjectComplete},
		store.CostProjectPart{Part: store.CostProjectHuman, CostProjectMoney: maskMoney(30_000_000, 27_000_000, maskI64(300_000_000)), Completeness: store.CostProjectComplete},
	)
	got, _ = costProjectHumanMask(ws, false)
	if leak := maskLeak(got); leak != [3]int64{} || *got.Total.Priced.USDMicros != 50_000_000 || *maskPart(got, store.CostProjectAI).Share != 100 {
		t.Errorf("customer workspace: leak %v total %d, want 0 and AI tokens alone (50 USD, 100 %%)", leak, *got.Total.Priced.USDMicros)
	}

	costProjectMaskOn = false
	defer func() { costProjectMaskOn = true }()
	raw, _ := costProjectHumanMask(maskEstate(), false)
	if leak := maskLeak(raw); leak != [3]int64{} {
		t.Fatalf("CONTROL: the mask dropped, Human shows its money, so nothing is hidden: leak %v", leak)
	}
	raw.Parts[3].CostProjectMoney = store.CostProjectMoney{} // a WUI that only hides the Human row
	if leak := maskLeak(raw); leak[0] != 130_000_000 {
		t.Errorf("CONTROL: with the mask dropped and the Human row hidden, total minus parts = %v, want the human 130 USD", leak)
	}
}
