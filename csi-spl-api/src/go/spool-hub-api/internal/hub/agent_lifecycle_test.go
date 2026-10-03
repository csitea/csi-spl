package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 063 sections 11 + 12: the admin reads and patches the lifecycle
// config (tenant.settings), every patch is a config_change in the event log,
// and a box reads the config and appends events over its hello with the
// writing box taken from the session.
func TestAgentLifecycleAdmin(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)

	// CONTROL: no tenant.settings, no door.
	dev := seat(t, e, tid, rbac.Developer)
	for _, x := range []struct{ method, path string }{
		{http.MethodGet, "/v1/tenant/agent-lifecycle"},
		{http.MethodPatch, "/v1/tenant/agent-lifecycle"},
		{http.MethodGet, "/v1/tenant/agent-lifecycle/events"},
	} {
		if code, body := call(t, e, tid, x.method, x.path, dev, map[string]any{"notes_tail_lines": 1}); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
			t.Fatalf("CONTROL: developer %s %s = %d %v", x.method, x.path, code, body)
		}
	}

	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/agent-lifecycle", admin, nil)
	cfg, _ := body["config"].(map[string]any)
	if code != 200 || cfg["lane_restart_ctx_k"] != 400.0 || cfg["seat_fail_action"] != "compact" || body["stored"].(map[string]any)["lane_restart_ctx_k"] != nil {
		t.Fatalf("fresh: %d %v", code, body)
	}

	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/agent-lifecycle", admin,
		map[string]any{"lane_restart_ctx_k": 200, "seat_fail_action": "respawn"})
	cfg, _ = body["config"].(map[string]any)
	if code != 200 || cfg["lane_restart_ctx_k"] != 200.0 || cfg["seat_fail_action"] != "respawn" || body["updated_by"] != admin {
		t.Fatalf("patch: %d %v", code, body)
	}
	// 400 names the key; nothing is written.
	for _, bad := range []map[string]any{{"lane_restart_ctx_k": 99}, {"seat_fail_action": "reboot"},
		{"lane_restart_wall_min": 5}, {"nosuch": 1}, {"lane_restart_ctx_k": "400"}, {}} {
		code, body := call(t, e, tid, http.MethodPatch, "/v1/tenant/agent-lifecycle", admin, bad)
		detail, _ := body["detail"].(string)
		for k := range bad {
			if !strings.HasPrefix(detail, k) {
				t.Errorf("400 for %v does not name the key: %v", bad, body)
			}
		}
		if code != http.StatusBadRequest {
			t.Errorf("patch %v: %d %v", bad, code, body)
		}
	}
	// null = reset to the default.
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/agent-lifecycle", admin, map[string]any{"lane_restart_ctx_k": nil})
	if cfg, _ = body["config"].(map[string]any); code != 200 || cfg["lane_restart_ctx_k"] != 400.0 || cfg["seat_fail_action"] != "respawn" {
		t.Fatalf("reset: %d %v", code, body)
	}

	code, body = call(t, e, tid, http.MethodGet, "/v1/tenant/agent-lifecycle/events?since=1h&limit=10", admin, nil)
	evs, _ := body["events"].([]any)
	ag, _ := body["aggregates"].([]any)
	if code != 200 || len(evs) != 2 || len(ag) != 1 {
		t.Fatalf("events: %d %v", code, body)
	}
	first := evs[1].(map[string]any)
	cc, _ := json.Marshal(first["config"])
	if first["event"] != "config_change" || first["agent_id"] != admin || first["writer_box"] != "hub" ||
		string(cc) != `{"new":{"lane_restart_ctx_k":200,"seat_fail_action":"respawn"},"old":{"lane_restart_ctx_k":400,"seat_fail_action":"compact"}}` {
		t.Fatalf("config_change row %v (config %s)", first, cc)
	}
	for _, q := range []string{"?limit=201", "?limit=0", "?since=yesterday"} {
		if code, _ := call(t, e, tid, http.MethodGet, "/v1/tenant/agent-lifecycle/events"+q, admin, nil); code != http.StatusBadRequest {
			t.Errorf("events%s: %d", q, code)
		}
	}
}

func TestAgentLifecycleBox(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	ctx := context.Background()

	call(t, e, tid, http.MethodPatch, "/v1/tenant/agent-lifecycle", admin, map[string]any{"seat_max_age_min": 30})
	raw, err := b.c.Lane(ctx, "lifecycle_config", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Config map[string]any `json:"config"`
	}
	if err := json.Unmarshal(raw, &got); err != nil || got.Config["seat_max_age_min"] != 30.0 || got.Config["notes_tail_lines"] != 40.0 {
		t.Fatalf("box config %s: %v", raw, err)
	}

	ev := json.RawMessage(`{"agent_id":"c-001","agent_box":"sat","writer_box":"forged","role":"orch","event":"rotate","reason":"clock","rid":"r1","ctx_before_k":420,"ctx_after_k":38,"refetch":{"lane_map":1},"outcome":"ok"}`)
	if _, err := b.c.Lane(ctx, "lifecycle_event", "main", ev); err != nil {
		t.Fatal(err)
	}
	// CONTROL: the hub refuses what the store would, and config_change from a box.
	for _, bad := range []string{`{"event":"nap"}`, `{"event":"config_change"}`, `{"event":"rotate","extra":1}`, `{"event":"rotate","at":"2000-01-01T00:00:00Z"}`} {
		if _, err := b.c.Lane(ctx, "lifecycle_event", "main", json.RawMessage(bad)); err == nil {
			t.Errorf("box event %s accepted", bad)
		}
	}
	if _, err := b.c.Lane(ctx, "lifecycle_nosuch", "main", nil); err == nil {
		t.Error("unknown lifecycle op accepted")
	}

	_, body := call(t, e, tid, http.MethodGet, "/v1/tenant/agent-lifecycle/events", admin, nil)
	evs, _ := body["events"].([]any)
	if len(evs) != 2 {
		t.Fatalf("events %v", body)
	}
	row := evs[0].(map[string]any)
	if row["event"] != "rotate" || row["writer_box"] != "box-b" || row["fleet"] != "main" || row["ctx_before_k"] != 420.0 {
		t.Fatalf("box row (writer_box from the session, not the frame): %v", row)
	}
}
