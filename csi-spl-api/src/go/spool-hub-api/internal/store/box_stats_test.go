package store

import (
	"context"
	"testing"
	"time"
)

// rdb 0117: the box load + memory history. Samples append, list oldest first
// per box or for every box, fold into per-hour avg / peak, a CHECK the Go
// side refuses is a CHECK the table refuses, the prune drops only rows past
// the cut, and another tenant sees none of it. Run on Memory and Postgres.
func TestBoxStatsAppendListPrune(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			bs, ok := st.(BoxStats)
			if !ok {
				t.Fatalf("%s keeps no box stats", name)
			}
			tid := newTenant(t, st)
			other := newTenant(t, st)
			s := func(box string, at time.Time, l1 float64, avail int64, agents int) BoxStat {
				return BoxStat{Box: box, WriterBox: "box-desk-" + box, At: at, Load1: l1, Load5: l1 / 2, Load15: 0.25,
					CPUs: 8, MemTotalKB: 1000, MemAvailKB: avail, SwapUsedKB: 5, AgentsLive: agents}
			}
			for _, b := range []BoxStat{
				s("sat", t0.Add(5*time.Minute), 2.5, 600, 3),
				s("sat", t0.Add(10*time.Minute), 4.5, 200, 5),
				s("sat", t0.Add(65*time.Minute), 1.25, 900, 1),
				s("tower", t0.Add(7*time.Minute), 0.47, 400, 2),
			} {
				if why := CheckBoxStat(b); why != "" {
					t.Fatalf("sample %+v: %s", b, why)
				}
				if err := bs.AppendBoxStat(ctx, tid, b); err != nil {
					t.Fatal(err)
				}
			}

			rows, err := bs.ListBoxStats(ctx, tid, "sat", t0)
			if err != nil || len(rows) != 3 || rows[0].Load1 != 2.5 || rows[2].MemAvailKB != 900 || rows[0].WriterBox != "box-desk-sat" || !rows[0].At.Equal(t0.Add(5*time.Minute)) {
				t.Fatalf("sat rows: %+v %v", rows, err)
			}
			all, _ := bs.ListBoxStats(ctx, tid, "", t0)
			if len(all) != 4 || all[1].Box != "tower" || all[1].Load1 != 0.47 {
				t.Fatalf("every box, oldest first (0.47 reads back as 0.47): %+v", all)
			}
			if late, _ := bs.ListBoxStats(ctx, tid, "sat", t0.Add(time.Hour)); len(late) != 1 {
				t.Fatalf("since: %+v", late)
			}
			if none, _ := bs.ListBoxStats(ctx, other, "", t0); len(none) != 0 {
				t.Fatalf("another tenant reads: %+v", none)
			}

			h := BoxStatHours(all)
			if len(h) != 3 {
				t.Fatalf("hours: %+v", h)
			}
			if a := h[0]; a.Box != "sat" || !a.Hour.Equal(t0) || a.N != 2 || a.Load1Avg != 3.5 || a.Load1Peak != 4.5 ||
				a.MemUsedAvgKB != 600 || a.MemUsedPeakKB != 800 || a.MemAvailMinKB != 200 || a.AgentsAvg != 4 || a.AgentsPeak != 5 || a.CPUs != 8 {
				t.Fatalf("sat 10:00: %+v", a)
			}
			if h[1].Box != "sat" || h[1].N != 1 || h[2].Box != "tower" {
				t.Fatalf("order box, hour: %+v", h)
			}

			// the prune is every tenant's, older than the cut only
			if err := bs.AppendBoxStat(ctx, other, s("sat", t0.Add(-time.Hour), 1, 1, 1)); err != nil {
				t.Fatal(err)
			}
			n, err := bs.PruneBoxStats(ctx, t0.Add(6*time.Minute))
			if err != nil || n < 2 {
				t.Fatalf("prune: %d %v", n, err)
			}
			if rest, _ := bs.ListBoxStats(ctx, tid, "", t0.Add(-BoxStatsRetention)); len(rest) != 3 {
				t.Fatalf("after prune: %+v", rest)
			}
		})
	}
}

func TestCheckBoxStat(t *testing.T) {
	ok := BoxStat{Box: "sat", Load1: 1, Load5: 1, Load15: 1, CPUs: 4, MemTotalKB: 1, MemAvailKB: 1}
	if why := CheckBoxStat(ok); why != "" {
		t.Fatal(why)
	}
	for _, f := range []func(*BoxStat){
		func(b *BoxStat) { b.Box = "Sat" },
		func(b *BoxStat) { b.Box = "" },
		func(b *BoxStat) { b.Load1 = -1 },
		func(b *BoxStat) { b.Load15 = 100001 },
		func(b *BoxStat) { b.CPUs = 0 },
		func(b *BoxStat) { b.MemAvailKB = -1 },
		func(b *BoxStat) { b.SwapUsedKB = -1 },
		func(b *BoxStat) { b.AgentsLive = -1 },
	} {
		b := ok
		f(&b)
		if CheckBoxStat(b) == "" {
			t.Errorf("accepted %+v", b)
		}
	}
}
