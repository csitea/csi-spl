package store

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPerfSamplesPinRdbChecks pins rdb 0106's enum CHECKs to the Go sets
// (spec 066 section 4.1): a value added on one side only turns this red.
func TestPerfSamplesPinRdbChecks(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0106_wui_perf_samples.sql"))
	if err != nil {
		t.Fatal(err)
	}
	col := regexp.MustCompile(`(?m)^\s+([a-z_]+)\s+text\s+(?:NOT )?NULL CHECK \([a-z_]+ IN \((.*)\)\),?$`)
	got := map[string]string{}
	for _, m := range col.FindAllStringSubmatch(string(raw), -1) {
		got[m[1]] = m[2]
	}
	want := map[string][]string{"metric": PerfMetrics, "device": PerfDevices, "view": PerfViews, "cache": PerfCaches,
		"outcome": PerfOutcomes, "net": PerfNets, "hidden_s": PerfHiddenS}
	if len(got) != len(want) {
		t.Fatalf("0106 has %d enum columns, Go %d: %v", len(got), len(want), got)
	}
	for c, set := range want {
		if w := "'" + strings.Join(set, "', '") + "'"; got[c] != w {
			t.Errorf("%s: rdb IN (%s), Go says (%s)", c, got[c], w)
		}
	}
	if !strings.Contains(string(raw), `build ~ '`+perfBuildRe.String()+`'`) {
		t.Errorf("0106 build CHECK is not %s", perfBuildRe)
	}
}

func perfOK(at time.Time, metric, device, view string, ms int) PerfSample {
	return PerfSample{At: at, SessionID: uuid4(), Metric: metric, ValueMs: ms, Device: device, View: view,
		Outcome: "ok", Build: "1.3.7"}
}

// insert, read, RLS by tenant, summary, prune: on memory and, with
// SPOOL_TEST_PG_DSN, Postgres.
func TestPerfSamples(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ps := st.(PerfSamples)
			tid, other := newTenant(t, st), newTenant(t, st)
			base := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)

			ratio, clk := 0.25, 40
			full := PerfSample{At: base, SessionID: uuid4(), Metric: "scroll_jank", ValueMs: 120, Ratio: &ratio,
				Device: "phone", View: "channel", Cache: "warm", Outcome: "ok", Build: "1.3.7-rc.1",
				Net: "4g", ClockErrMs: &clk, HiddenS: "300-3600"}
			// send_ack desktop/topic: 100, 200, 300, 400 ok (p50 250, p75 325,
			// p95 385) plus one fail; switch_view phone/"": 50.
			batch := []PerfSample{full}
			for i, ms := range []int{100, 200, 300, 400} {
				batch = append(batch, perfOK(base.Add(time.Duration(i+1)*time.Second), "send_ack", "desktop", "topic", ms))
			}
			f := perfOK(base.Add(5*time.Second), "send_ack", "desktop", "topic", 9000)
			f.Outcome = "fail"
			sv := perfOK(base.Add(6*time.Second), "switch_view", "phone", "", 50)
			sv.Build = "1.3.8"
			batch = append(batch, f, sv)
			for _, p := range batch {
				if why := CheckPerfSample(p); why != "" {
					t.Fatalf("check %+v: %s", p, why)
				}
			}
			old := perfOK(time.Now().Add(-PerfSampleRetention-time.Hour), "inp", "desktop", "", 80)
			if err := ps.InsertPerfSamples(ctx, tid, append(batch, old)); err != nil {
				t.Fatal(err)
			}
			if err := ps.InsertPerfSamples(ctx, other, []PerfSample{perfOK(base, "send_ack", "desktop", "topic", 7)}); err != nil {
				t.Fatal(err)
			}
			if err := ps.InsertPerfSamples(ctx, tid, nil); err != nil {
				t.Fatalf("empty batch: %v", err)
			}

			got, err := ps.ListPerfSamples(ctx, tid, base, 0)
			if err != nil || len(got) != 7 {
				t.Fatalf("list %d %+v: %v", len(got), got, err)
			}
			g := got[0]
			if g.SessionID != full.SessionID || g.Metric != "scroll_jank" || g.Ratio == nil || *g.Ratio != 0.25 ||
				g.ClockErrMs == nil || *g.ClockErrMs != 40 || g.View != "channel" || g.Cache != "warm" ||
				g.Net != "4g" || g.HiddenS != "300-3600" || g.Build != "1.3.7-rc.1" || !g.At.Equal(base) {
				t.Fatalf("round trip %+v", g)
			}
			if got[6].View != "" || got[6].Cache != "" || got[6].Ratio != nil || got[6].ClockErrMs != nil {
				t.Fatalf("NULLs round trip %+v", got[6])
			}
			if lim, _ := ps.ListPerfSamples(ctx, tid, base, 2); len(lim) != 2 {
				t.Fatalf("limit 2 gave %d", len(lim))
			}
			// RLS / tenant scope: the other workspace sees only its own row.
			if oth, _ := ps.ListPerfSamples(ctx, other, time.Time{}, 0); len(oth) != 1 || oth[0].ValueMs != 7 {
				t.Fatalf("other tenant %+v", oth)
			}

			sum, err := ps.PerfSummary(ctx, tid, base, "")
			if err != nil || len(sum) != 3 {
				t.Fatalf("summary %+v: %v", sum, err)
			}
			sa := sum[1]
			if sum[0].Metric != "scroll_jank" || sa.Metric != "send_ack" || sa.Device != "desktop" || sa.View != "topic" ||
				sa.N != 4 || sa.Failed != 1 || *sa.P50 != 250 || *sa.P75 != 325 || *sa.P95 != 385 {
				t.Fatalf("send_ack summary %+v", sa)
			}
			if sum[2].Metric != "switch_view" || sum[2].View != "" || sum[2].N != 1 || *sum[2].P95 != 50 {
				t.Fatalf("switch_view summary %+v", sum[2])
			}
			if b, _ := ps.PerfSummary(ctx, tid, base, "1.3.8"); len(b) != 1 || b[0].Metric != "switch_view" {
				t.Fatalf("build filter %+v", b)
			}
			if failOnly, _ := ps.PerfSummary(ctx, tid, base.Add(5*time.Second), "1.3.7"); len(failOnly) != 1 || failOnly[0].N != 0 || failOnly[0].P50 != nil || failOnly[0].Failed != 1 {
				t.Fatalf("failures-only group %+v", failOnly)
			}

			n, err := ps.PrunePerfSamples(ctx, time.Now().Add(-PerfSampleRetention))
			if err != nil || n < 1 {
				t.Fatalf("prune %d: %v", n, err)
			}
			if all, _ := ps.ListPerfSamples(ctx, tid, time.Time{}, 0); len(all) != 7 {
				t.Fatalf("after prune %d rows", len(all))
			}
			if oth, _ := ps.ListPerfSamples(ctx, other, time.Time{}, 0); len(oth) != 1 {
				t.Fatalf("other tenant after prune %d rows", len(oth))
			}
		})
	}
}

// The 0106 CHECKs refuse what CheckPerfSample refuses, and RLS refuses a row
// written into another tenant, on the raw table.
func TestPerfSamplesRdbChecks(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("needs $SPOOL_TEST_PG_DSN")
	}
	ctx := context.Background()
	tid, other := newTenant(t, pg), newTenant(t, pg)
	ins := func(set string) error {
		return pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO wui_perf_samples (tenant_id, at, session_id, metric, value_ms, device, outcome)
				VALUES ($1, now(), gen_random_uuid(), 'inp', 1, 'phone', 'ok')`, tid)
			if err != nil || set == "" {
				return err
			}
			_, err = tx.Exec(ctx, `UPDATE wui_perf_samples SET `+set+` WHERE tenant_id = $1`, tid)
			return err
		})
	}
	if err := ins(""); err != nil {
		t.Fatalf("control row refused: %v", err)
	}
	for _, bad := range []string{`metric = 'ttfb'`, `device = 'tablet'`, `view = 'msg-123'`, `cache = 'hot'`,
		`outcome = 'meh'`, `net = 'wifi'`, `hidden_s = '1'`, `value_ms = -1`, `value_ms = 600001`, `ratio = 1.5`,
		`clock_err_ms = -1`, `build = 'a user@example.com'`, `build = repeat('1', 41)`} {
		if err := ins(bad); err == nil {
			t.Errorf("rdb took %s", bad)
		}
	}
	err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO wui_perf_samples (tenant_id, at, session_id, metric, value_ms, device, outcome)
			VALUES ($1, now(), gen_random_uuid(), 'inp', 1, 'phone', 'ok')`, other)
		return err
	})
	if err == nil {
		t.Error("RLS took a row for another tenant")
	}
}

func TestCheckPerfSample(t *testing.T) {
	good := perfOK(time.Now(), "inp", "phone", "", 10)
	if why := CheckPerfSample(good); why != "" {
		t.Fatalf("good refused: %s", why)
	}
	neg, big := -0.1, 700000
	for name, mut := range map[string]func(*PerfSample){
		"no at":        func(p *PerfSample) { p.At = time.Time{} },
		"session":      func(p *PerfSample) { p.SessionID = "user-42" },
		"metric":       func(p *PerfSample) { p.Metric = "ttfb" },
		"value":        func(p *PerfSample) { p.ValueMs = -1 },
		"ratio":        func(p *PerfSample) { p.Ratio = &neg },
		"device":       func(p *PerfSample) { p.Device = "tablet" },
		"view id":      func(p *PerfSample) { p.View = "6e21c7d8" },
		"cache":        func(p *PerfSample) { p.Cache = "hot" },
		"outcome":      func(p *PerfSample) { p.Outcome = "" },
		"build text":   func(p *PerfSample) { p.Build = "hello world" },
		"net":          func(p *PerfSample) { p.Net = "wifi" },
		"clock_err_ms": func(p *PerfSample) { p.ClockErrMs = &big },
		"hidden_s":     func(p *PerfSample) { p.HiddenS = "45" },
	} {
		p := good
		mut(&p)
		if CheckPerfSample(p) == "" {
			t.Errorf("%s: took %+v", name, p)
		}
	}
}
