package store

import (
	"context"
	"encoding/json"
	"testing"
)

// Spec 123 13.8 row P01: the project's cost folded from the month read.

// costProjectFixture is an estate month: two GCP parts (one with no second
// currency rate), a hand-entered cloud entry with no rate at all, an owned
// asset's share, a paid AI item, the token counts (units, a list value) and
// a gcp coverage of 2 of 3 ended days.
func costProjectFixture() CostProjectInput {
	return CostProjectInput{Estate: true, AIRead: true, DaysEnded: 3,
		Parts: []CostPart{
			{Estate: true, Source: "gcp", ProjectOrVendor: "csi-spl-dev", Kind: "cloud_run", USDMicros: 2_000_000, EURMicros: 1_800_000, SecondMicros: i64(1_800_000)},
			{Estate: true, Source: "gcp", ProjectOrVendor: "csi-spl-prd", Kind: "cloud_sql", USDMicros: 1_000_000, EURMicros: 900_000},
			{Estate: true, Source: CostSourceEntry, ProjectOrVendor: "dns", Kind: "cloud", Origin: "hand", Unpriced: true, EntryMicros: 50_000_000, EntryCurrency: "SEK"},
			{Estate: true, Source: CostSourceHandAsset, ProjectOrVendor: "laptop", Kind: "asset", Origin: "hand", USDMicros: 3_000_000, EURMicros: 2_700_000, SecondMicros: i64(2_700_000)},
			{Estate: true, Source: CostSourceAIPaid, ProjectOrVendor: "claude", Kind: "max", USDMicros: 4_000_000, EURMicros: 3_600_000, SecondMicros: i64(3_600_000)},
			{Estate: true, Source: "fleet_tokens.box1", ProjectOrVendor: "claude", Kind: "output", Units: 900, ListValueMicros: i64(70_000_000)},
		},
		Coverage: []CostSourceDays{{Source: "gcp", OK: 2, Missing: 1}, {Source: CostSourceAIPaid, OK: 3}},
	}
}

func projectPart(t *testing.T, cp CostProject, name string) CostProjectPart {
	t.Helper()
	for _, p := range cp.Parts {
		if p.Part == name {
			return p
		}
	}
	t.Fatalf("no part %s in %+v", name, cp.Parts)
	return CostProjectPart{}
}

func pv(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}

// costProjectSumsHold: each currency's known part amounts sum to total.priced.
func costProjectSumsHold(t *testing.T, cp CostProject) {
	t.Helper()
	var s [3]int64
	for _, p := range cp.Parts {
		for i, v := range []*int64{p.USDMicros, p.EURMicros, p.SecondMicros} {
			if v != nil {
				s[i] += *v
			}
		}
	}
	tot := cp.Total.Priced
	if s[0] != *tot.USDMicros || s[1] != *tot.EURMicros || s[2] != *tot.SecondMicros {
		t.Errorf("parts sum %v, total.priced %v/%v/%v", s, pv(tot.USDMicros), pv(tot.EURMicros), pv(tot.SecondMicros))
	}
}

// TestCostProjectParts: the four estate parts with their amounts, shares and
// completeness; the parts sum to total.priced; an unpriced part is null,
// never 0; Human is not_tracked; a customer workspace gets AI + Human only,
// its allocated share named in left_out.
// CONTROL 1: a line with no rate summed as 0 turns the null parts into 0
// and the answer changes. CONTROL 2: the hand_asset line left out changes
// the total.
func TestCostProjectParts(t *testing.T) {
	cp := CostProjectParts(costProjectFixture())
	if len(cp.Parts) != 4 || cp.Parts[0].Part != CostProjectCloud || cp.Parts[3].Part != CostProjectHuman {
		t.Fatalf("parts %+v: want cloud, owned_hardware, ai_tokens, human", cp.Parts)
	}
	costProjectSumsHold(t, cp)
	cloud := projectPart(t, cp, CostProjectCloud)
	if pv(cloud.USDMicros) != int64(3_000_000) || pv(cloud.SecondMicros) != int64(1_800_000) || cloud.Lines != 3 ||
		cloud.Unpriced != 2 || cloud.Completeness != CostProjectUnpriced || *cloud.DaysRead != 2 || *cloud.Days != 3 {
		t.Errorf("cloud %+v: want 3.00 USD of the priced lines, 1.80 second, 2 unpriced of 3, 2 of 3 days", cloud)
	}
	hw := projectPart(t, cp, CostProjectHardware)
	if pv(hw.USDMicros) != int64(3_000_000) || hw.Completeness != CostProjectHand || hw.DaysRead != nil {
		t.Errorf("owned hardware %+v: want 3.00 USD, entered by hand", hw)
	}
	ai := projectPart(t, cp, CostProjectAI)
	if pv(ai.USDMicros) != int64(4_000_000) || ai.Completeness != CostProjectComplete || ai.Lines != 1 {
		t.Errorf("ai %+v: want 4.00 USD paid, the token list value not in it (Q-4 A)", ai)
	}
	hu := projectPart(t, cp, CostProjectHuman)
	if hu.USDMicros != nil || hu.EURMicros != nil || hu.SecondMicros != nil || hu.Completeness != CostProjectNotTracked || hu.Share != nil {
		t.Errorf("human %+v: want not_tracked, null, no share", hu)
	}
	if *cp.Total.Priced.USDMicros != 10_000_000 || !cp.Total.Partial || len(cp.LeftOut) != 0 {
		t.Errorf("total %+v left out %+v: want 10.00 USD priced, partial", cp.Total, cp.LeftOut)
	}
	if *cloud.Share != 30 || *ai.Share != 40 {
		t.Errorf("shares cloud %v ai %v: want 30 and 40", *cloud.Share, *ai.Share)
	}

	// an unpriced part alone is null in that currency, never 0
	solo := CostProjectParts(CostProjectInput{Estate: true, AIRead: true, Parts: []CostPart{
		{Source: CostSourceEntry, Kind: "cloud", Unpriced: true}}})
	if c := projectPart(t, solo, CostProjectCloud); c.USDMicros != nil || c.SecondMicros != nil || c.Completeness != CostProjectUnpriced {
		t.Errorf("an unpriced cloud alone %+v: want null, unpriced", c)
	}
	costProjectWorkspace(t)
	costProjectControls(t, cp)
}

// costProjectWorkspace: a customer workspace's two parts (Q-8 A).
func costProjectWorkspace(t *testing.T) {
	t.Helper()
	ws := CostProjectParts(CostProjectInput{AIRead: true, DaysEnded: 3, Parts: []CostPart{
		{Source: CostSourceAIShare, ProjectOrVendor: "claude", USDMicros: 1_500_000, EURMicros: 1_350_000, SecondMicros: i64(1_350_000)},
		{Source: "fleet_tokens", ProjectOrVendor: "claude", Units: 40, ListValueMicros: i64(9_000_000)},
		{Source: CostSourceAllocated, ProjectOrVendor: "csi-spl-prd", Kind: "cloud_run", AllocatedSource: "gcp", USDMicros: 700_000},
		{Source: "gcp", ProjectOrVendor: "leak", USDMicros: 9_000_000}, // never a workspace's part
	}, Coverage: []CostSourceDays{{Source: CostSourceAIShare, OK: 3}}})
	if len(ws.Parts) != 2 || ws.Parts[0].Part != CostProjectAI || ws.Parts[1].Part != CostProjectHuman {
		t.Fatalf("workspace parts %+v: want ai_tokens, human", ws.Parts)
	}
	costProjectSumsHold(t, ws)
	if *ws.Total.Priced.USDMicros != 1_500_000 || len(ws.LeftOut) != 2 || ws.LeftOut[0].Source != CostSourceAllocated {
		t.Errorf("workspace total %+v left out %+v: want 1.50 USD, the allocated share and the gcp line named", ws.Total, ws.LeftOut)
	}
	none := CostProjectParts(CostProjectInput{})
	if a := projectPart(t, none, CostProjectAI); a.Completeness != CostProjectNotTracked || a.USDMicros != nil {
		t.Errorf("no AI source read %+v: want not_tracked", a)
	}
}

// costProjectControls are the row's two red controls, run on the fixture.
func costProjectControls(t *testing.T, cp CostProject) {
	t.Helper()
	want, _ := json.Marshal(cp)
	costProjectUnknownIsNull = false
	zero := CostProjectParts(costProjectFixture())
	costProjectUnknownIsNull = true
	got, _ := json.Marshal(zero)
	if c := projectPart(t, zero, CostProjectCloud); string(got) == string(want) || c.SecondMicros == nil || c.Unpriced != 0 {
		t.Errorf("CONTROL 1: a line with no rate summed as 0 reads the same: the null guard proves nothing")
	}
	of := costProjectOf
	costProjectOf = func(p CostPart, estate bool) (string, bool) {
		if p.Source == CostSourceHandAsset {
			return "", true
		}
		return of(p, estate)
	}
	drop := CostProjectParts(costProjectFixture())
	costProjectOf = of
	if *drop.Total.Priced.USDMicros == *cp.Total.Priced.USDMicros {
		t.Errorf("CONTROL 2: the hand_asset line left out, the total is unchanged %d", *drop.Total.Priced.USDMicros)
	}
}

// TestCostProjectPartsOnPostgres: an owned asset's daily share seeded as a
// cost line (source hand_asset) is read by the month read and lands in
// Owned hardware and the total; a gcp line in Cloud.
func TestCostProjectPartsOnPostgres(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonthClean(t, pg)
	a := newTenant(t, pg)
	costSeed(t, pg, "", day(1), CostSourceHandAsset, uid("laptop-"), "asset", "hand", 0, 2_750_000, 2_500_000)
	costSeed(t, pg, "", day(2), CostSourceHandAsset, uid("laptop-"), "asset", "hand", 0, 2_750_000, 2_500_000)
	costSeed(t, pg, "", day(1), "gcp", uid("csi-spl-"), "cloud_run", "billing_export", 0, 1_000_000, 900_000)
	cm, err := pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, Estate: true, From: from, To: to})
	if err != nil {
		t.Fatal(err)
	}
	cp := CostProjectParts(CostProjectInput{Estate: true, Parts: cm.Parts, Coverage: cm.Coverage})
	costProjectSumsHold(t, cp)
	if hw := projectPart(t, cp, CostProjectHardware); pv(hw.USDMicros) != int64(5_500_000) || hw.Lines != 2 {
		t.Errorf("owned hardware %+v: want 5.50 USD from 2 hand_asset lines", hw)
	}
	if c := projectPart(t, cp, CostProjectCloud); pv(c.USDMicros) != int64(1_000_000) {
		t.Errorf("cloud %+v: want 1.00 USD", c)
	}
	if *cp.Total.Priced.USDMicros != 6_500_000 {
		t.Errorf("total %d, want 6.50 USD", *cp.Total.Priced.USDMicros)
	}
	// the workspace's own read holds none of it (RLS, 5.2)
	cm, err = pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, From: from, To: to})
	if err != nil {
		t.Fatal(err)
	}
	if ws := CostProjectParts(CostProjectInput{Parts: cm.Parts}); *ws.Total.Priced.USDMicros != 0 {
		t.Errorf("workspace read %+v: the estate's money leaked", ws.Total)
	}
}
