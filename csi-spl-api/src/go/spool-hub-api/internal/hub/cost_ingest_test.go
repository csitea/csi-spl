package hub_test

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 123 lane 4: POST /v1/operator/cost/day, the box feed of cost lines.
// On Postgres (hub-pg.tst.sh) the real store writes; on the memory store a
// recording wrapper stands in, since only the Postgres store keeps cost lines.

type costRecorder struct {
	*store.Memory
	mu   sync.Mutex
	days []store.CostDay
}

func (c *costRecorder) PutCostDay(_ context.Context, d store.CostDay) (store.CostIngestResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.days = append(c.days, d)
	return store.CostIngestResult{Written: len(d.Lines)}, nil
}

// costEnv: rec is the recording wrapper, nil when the store is Postgres.
func costEnv(t *testing.T) (*env, string, *costRecorder) {
	t.Helper()
	var rec *costRecorder
	e := rbacEnv(t, func(o *hub.Options) {
		if m, ok := o.Store.(*store.Memory); ok {
			rec = &costRecorder{Memory: m}
			o.Store = rec
		}
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "stranger":
				return "someone@example.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	tid, _ := e.tenant()
	return e, tid, rec
}

func costBody(source string) map[string]any {
	return map[string]any{"day": "2026-10-09", "source": source, "run_id": "rollup-1",
		"coverage": map[string]any{"state": "partial", "reason": "1 agent(s) unmetered"},
		"lines": []map[string]any{
			{"project_or_vendor": "claude", "agent_id": "c-101", "model": "m-x", "kind": "output.standard", "units": 107, "origin": "transcript"},
			{"project_or_vendor": "grok", "agent_id": "g-201", "kind": "unmetered", "units": 0, "origin": "transcript"},
		}}
}

// TestCostIngestOperatorOnly: the env's operator SA writes the day and gets
// counts back, never a row; no token is 401, a verified identity that is not
// an operator 403, a member session (no Bearer) 401. CONTROL: the same body
// with the good token is 200, so each refusal is the auth's.
func TestCostIngestOperatorOnly(t *testing.T) {
	e, tid, rec := costEnv(t)
	src := "fleet_tokens.box-" + tid
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/cost/day", "good", costBody(src))
	if code != http.StatusOK || out["written"] != float64(2) || out["lines"] != float64(2) || out["state"] != "partial" {
		t.Fatalf("CONTROL: the operator's post: %d %v", code, out)
	}
	for k := range out {
		switch k {
		case "day", "source", "state", "lines", "written", "removed":
		default:
			t.Errorf("the answer carries %q: counts only", k)
		}
	}
	if rec != nil {
		if len(rec.days) != 1 || rec.days[0].Source != src || rec.days[0].Lines[0].Units != 107 || rec.days[0].Reason != "1 agent(s) unmetered" {
			t.Fatalf("stored: %+v", rec.days)
		}
	}
	for _, c := range []struct {
		token string
		want  int
	}{{"", http.StatusUnauthorized}, {"forged", http.StatusUnauthorized}, {"stranger", http.StatusForbidden}} {
		if code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/cost/day", c.token, costBody(src)); code != c.want {
			t.Errorf("token %q: %d %v, want %d", c.token, code, out, c.want)
		}
	}
}

// TestCostIngestRefusals: a GCP or hand origin, a missing day with lines and
// an unknown field are 400 and store nothing.
func TestCostIngestRefusals(t *testing.T) {
	e, tid, rec := costEnv(t)
	src := "agent_hours.box-" + tid
	for name, mut := range map[string]func(map[string]any){
		"gcp origin": func(b map[string]any) { b["lines"].([]map[string]any)[0]["origin"] = "billing_export" },
		"hand row":   func(b map[string]any) { b["lines"].([]map[string]any)[0]["origin"] = "hand" },
		"missing + lines": func(b map[string]any) {
			b["coverage"] = map[string]any{"state": "missing", "reason": "reader failed"}
		},
		"unknown field": func(b map[string]any) { b["tenant_id"] = tid },
		"money":         func(b map[string]any) { b["lines"].([]map[string]any)[0]["usd_micros"] = 5 },
	} {
		b := costBody(src)
		mut(b)
		if code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/cost/day", "good", b); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v, want 400", name, code, out)
		}
	}
	if rec != nil && len(rec.days) != 0 {
		t.Fatalf("a refused post was stored: %+v", rec.days)
	}
}
