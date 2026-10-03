package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 066 L3: GET /v1/admin/perf/summary is tenant.settings, one workspace,
// p95 hidden under n = 50, and a build A / B pair ranked by p75.
func TestPerfSummary(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	empty, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	adminB := seat(t, e, other, rbac.Admin)
	adminE := seat(t, e, empty, rbac.Admin)

	if code, body := call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary", dev, nil); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("CONTROL: developer = %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary", "", nil); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("CONTROL: no session = %d %v", code, body)
	}

	ps := e.st.(store.PerfSamples)
	now := time.Now().UTC().Truncate(time.Second)
	recent := now.Add(-time.Hour)
	var batch []store.PerfSample
	batch = append(batch, perfFill(recent, "send_ack", "desktop", "topic", "1.0.0", 1000, 50)...)
	batch = append(batch, perfFill(recent, "load_messages", "phone", "channel", "1.0.0", 200, 49)...)
	batch = append(batch, perfFill(recent, "switch_view", "phone", "dm", "2.0.0", 10, 3)...)
	fail := perfOne(recent, "inp", "desktop", "", "1.0.0", 9000, "fail")
	old := perfOne(now.Add(-10*24*time.Hour), "reconnect_live", "desktop", "search", "1.0.0", 5, "ok")
	batch = append(batch, fail, old)
	for _, p := range batch {
		if why := store.CheckPerfSample(p); why != "" {
			t.Fatalf("fixture: %s", why)
		}
	}
	ctx := context.Background()
	if err := ps.InsertPerfSamples(ctx, tid, batch); err != nil {
		t.Fatal(err)
	}
	foreign := perfOne(recent, "load_rail", "phone", "topic", "9.9.9", 7, "ok")
	if err := ps.InsertPerfSamples(ctx, other, []store.PerfSample{foreign}); err != nil {
		t.Fatal(err)
	}

	code, body := call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary?tenant_id="+other, admin, nil)
	rows := summaryRows(t, body, "rows")
	if code != http.StatusOK || body["days"] != 7.0 || body["off"] != nil || len(rows) != 4 {
		t.Fatalf("default window: %d days=%v rows=%d %v", code, body["days"], len(rows), body)
	}
	if _, leaked := body["rows_b"]; leaked || body["build"] != nil {
		t.Fatalf("no build filter should omit build and rows_b: %v", body)
	}
	want := []string{"send_ack", "load_messages", "switch_view", "inp"}
	for i, metric := range want {
		if rows[i]["metric"] != metric {
			t.Fatalf("rank[%d] = %v, want %s (p75 desc)", i, rows[i]["metric"], metric)
		}
	}
	slow, mid, fast, failed := rows[0], rows[1], rows[2], rows[3]
	if slow["n"] != 50.0 || slow["p75"] != 1000.0 || slow["p95"] != 1000.0 || slow["device"] != "desktop" || slow["view"] != "topic" {
		t.Fatalf("n=50 keeps p95: %+v", slow)
	}
	if _, has := mid["p95"]; mid["n"] != 49.0 || has || mid["p75"] != 200.0 {
		t.Fatalf("n=49 omits p95: %+v", mid)
	}
	if _, has := fast["p95"]; fast["n"] != 3.0 || has || fast["p50"] != 10.0 {
		t.Fatalf("small n omits p95: %+v", fast)
	}
	if _, hasP50 := failed["p50"]; !hasP50 || failed["p50"] != nil || failed["n"] != 0.0 || failed["failed"] != 1.0 {
		t.Fatalf("failures-only group: %+v", failed)
	}
	if _, has := failed["p95"]; has {
		t.Fatalf("n=0 must omit p95: %+v", failed)
	}
	for _, row := range rows {
		if row["metric"] == "load_rail" || row["metric"] == "reconnect_live" {
			t.Fatalf("default window leaked %v", row)
		}
	}

	code, body = call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary?days=30", admin, nil)
	rows = summaryRows(t, body, "rows")
	if code != 200 || len(rows) != 5 || rows[3]["metric"] != "reconnect_live" || rows[3]["p75"] != 5.0 {
		t.Fatalf("30-day window: %d %+v", code, metricsOf(rows))
	}

	code, body = call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary?build=1.0.0&build_b=2.0.0", admin, nil)
	a, b := summaryRows(t, body, "rows"), summaryRows(t, body, "rows_b")
	if code != 200 || body["build"] != "1.0.0" || body["build_b"] != "2.0.0" || metricsOf(a) != "send_ack,load_messages,inp" || metricsOf(b) != "switch_view" {
		t.Fatalf("build A/B: %d build=%v/%v a=%s b=%s", code, body["build"], body["build_b"], metricsOf(a), metricsOf(b))
	}

	code, body = call(t, e, other, http.MethodGet, "/v1/admin/perf/summary?days=30", adminB, nil)
	rows = summaryRows(t, body, "rows")
	if code != 200 || len(rows) != 1 || rows[0]["metric"] != "load_rail" || rows[0]["p50"] != 7.0 {
		t.Fatalf("other workspace: %d %+v", code, rows)
	}

	code, body = call(t, e, empty, http.MethodGet, "/v1/admin/perf/summary", adminE, nil)
	rows = summaryRows(t, body, "rows")
	if code != 200 || len(rows) != 0 || body["days"] != 7.0 {
		t.Fatalf("empty workspace: %d %v", code, body)
	}

	for _, q := range []string{"?days=0", "?days=31", "?days=week", "?build=hello%20world", "?build_b=user@example.com"} {
		if code, body := call(t, e, tid, http.MethodGet, "/v1/admin/perf/summary"+q, admin, nil); code != http.StatusBadRequest || body["error"] != "bad_query" {
			t.Fatalf("%s = %d %v", q, code, body)
		}
	}
}

func perfOne(at time.Time, metric, device, view, build string, ms int, outcome string) store.PerfSample {
	return store.PerfSample{At: at, SessionID: "00000000-0000-4000-8000-000000000001",
		Metric: metric, ValueMs: ms, Device: device, View: view, Outcome: outcome, Build: build}
}

func perfFill(at time.Time, metric, device, view, build string, ms, n int) []store.PerfSample {
	out := make([]store.PerfSample, n)
	for i := range out {
		out[i] = perfOne(at.Add(time.Duration(i)*time.Millisecond), metric, device, view, build, ms, "ok")
	}
	return out
}

func summaryRows(t *testing.T, body map[string]any, key string) []map[string]any {
	t.Helper()
	raw, ok := body[key].([]any)
	if !ok {
		t.Fatalf("%s is %T (%v)", key, body[key], body[key])
	}
	out := make([]map[string]any, len(raw))
	for i, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			t.Fatalf("%s[%d] is %T", key, i, r)
		}
		out[i] = m
	}
	return out
}

func metricsOf(rows []map[string]any) string {
	s := ""
	for i, r := range rows {
		if i > 0 {
			s += ","
		}
		m, _ := r["metric"].(string)
		s += m
	}
	return s
}
