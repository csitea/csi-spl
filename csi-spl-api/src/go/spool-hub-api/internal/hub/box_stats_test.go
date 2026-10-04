package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// rdb 0117: a box appends its load + memory sample over its hello (the
// writing box and the time are the hub's, never the frame's), reads the
// history back with per-hour avg / peak, and an operator reads the same over
// HTTP; a member without audit.read does not.
func TestBoxStats(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	ctx := context.Background()

	for _, s := range []string{
		`{"box":"sat","load1":2.5,"load5":2,"load15":1.5,"cpus":8,"mem_total_kb":1000,"mem_avail_kb":600,"swap_used_kb":0,"agents_live":3}`,
		`{"box":"sat","load1":4.5,"load5":3,"load15":2,"cpus":8,"mem_total_kb":1000,"mem_avail_kb":200,"swap_used_kb":0,"agents_live":5,"writer_box":"forged"}`,
	} {
		raw, err := b.c.Lane(ctx, "box_stats_put", "", json.RawMessage(s))
		if err != nil {
			t.Fatalf("put %s: %v", s, err)
		}
		var got map[string]any
		if json.Unmarshal(raw, &got) != nil || got["ok"] != true || got["writer_box"] != "box-b" {
			t.Fatalf("put answer %s", raw)
		}
	}
	// CONTROL: what the table would refuse, and an unknown field or op.
	for _, bad := range []string{`{"box":"Sat","cpus":8}`, `{"box":"sat","cpus":0}`, `{"box":"sat","cpus":8,"load1":-1}`,
		`{"box":"sat","cpus":8,"extra":1}`, `"not an object"`} {
		if _, err := b.c.Lane(ctx, "box_stats_put", "", json.RawMessage(bad)); err == nil {
			t.Errorf("put %s accepted", bad)
		}
	}
	if _, err := b.c.Lane(ctx, "box_stats_drop", "", nil); err == nil {
		t.Error("unknown box_stats op accepted")
	}
	if _, err := b.c.Lane(ctx, "box_stats_list", "", json.RawMessage(`{"since":"yesterday"}`)); err == nil {
		t.Error("since=yesterday accepted")
	}

	type answer struct {
		Rows []struct {
			Box       string  `json:"box"`
			WriterBox string  `json:"writer_box"`
			Load1     float64 `json:"load1"`
		} `json:"rows"`
		Hours []struct {
			Box       string  `json:"box"`
			N         int     `json:"n"`
			Load1Avg  float64 `json:"load1_avg"`
			Load1Peak float64 `json:"load1_peak"`
			MemPeak   int64   `json:"mem_used_peak_kb"`
		} `json:"hours"`
	}
	raw, err := b.c.Lane(ctx, "box_stats_list", "", json.RawMessage(`{"box":"sat","since":"20h"}`))
	if err != nil {
		t.Fatal(err)
	}
	var a answer
	if err := json.Unmarshal(raw, &a); err != nil || len(a.Rows) != 2 || a.Rows[1].WriterBox != "box-b" || len(a.Hours) < 1 {
		t.Fatalf("box list %s: %v", raw, err)
	}
	n, peak := 0, 0.0
	for _, h := range a.Hours {
		n += h.N
		peak = max(peak, h.Load1Peak)
	}
	if n != 2 || peak != 4.5 {
		t.Fatalf("hours %+v", a.Hours)
	}

	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/box-stats?box=sat&since=7d", admin, nil)
	if rows, _ := body["rows"].([]any); code != 200 || len(rows) != 2 {
		t.Fatalf("http read: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/tenant/box-stats?box=Sat", admin, nil); code != http.StatusBadRequest {
		t.Errorf("box=Sat: %d", code)
	}
	// CONTROL: a developer holds no audit.read.
	dev := seat(t, e, tid, rbac.Developer)
	if code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/box-stats", dev, nil); code != http.StatusForbidden || body["permission"] != rbac.AuditRead {
		t.Fatalf("CONTROL: developer read: %d %v", code, body)
	}
}
