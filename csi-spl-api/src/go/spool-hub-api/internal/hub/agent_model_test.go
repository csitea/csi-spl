package hub_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// spec 184 row H1 (contract 7.1.5): the model per agent kind on the tenant
// settings, and the boxes' readings.
//   - PATCH /v1/tenant/settings agent_models sets cells, "" and null drop
//     them; GET returns them sorted with their writer.
//   - refused 400 bad_model, nothing written (not even display_name beside
//     it): an unknown vendor, an unknown or alias kind, a model with a space
//     or a quote.
//   - PUT /v1/boxes/{box}/agent-models/{vendor}, the box's own upload token
//     (an application/octet-stream body, as hubclient sends it): stored; an
//     older read_at ignored (200, stored false); a newer one replaces it.
//   - CONTROLS on the PUT: another box's path 403 box_mismatch; a WUI token
//     403 box_only; no token 401; an unknown vendor 400 bad_vendor; a model
//     failing the syntax, an unknown field, a future read_at 400
//     bad_reading.
//   - GET /v1/tenant/agent-model-readings reads only the caller's
//     workspace; a developer (no tenant.settings) is 403 on both reads.

func modelsLine(t *testing.T, body map[string]any) string {
	t.Helper()
	list, ok := body["agent_models"].([]any)
	if !ok {
		t.Fatalf("agent_models: %v", body["agent_models"])
	}
	var out []string
	for _, x := range list {
		m := x.(map[string]any)
		out = append(out, m["vendor"].(string)+":"+m["kind"].(string)+"="+m["model"].(string))
	}
	return strings.Join(out, ",")
}

func TestTenantSettingsAgentModels(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	const path = "/v1/tenant/settings"

	code, body := call(t, e, tid, http.MethodGet, path, admin, nil)
	if code != 200 || modelsLine(t, body) != "" {
		t.Fatalf("fresh: %d %v", code, body["agent_models"])
	}
	code, body = call(t, e, tid, http.MethodPatch, path, admin, map[string]any{"agent_models": map[string]any{
		"claude": map[string]any{"*": "sonnet", "complex_coding": "opus"},
		"grok":   map[string]any{"tests": "grok-4.6"},
	}})
	if code != 200 || modelsLine(t, body) != "claude:*=sonnet,claude:complex_coding=opus,grok:tests=grok-4.6" {
		t.Fatalf("set: %d %v", code, body)
	}
	if m := body["agent_models"].([]any)[0].(map[string]any); m["updated_by"] != admin || m["updated_at"] == nil {
		t.Fatalf("writer: %v", m)
	}
	for label, models := range map[string]map[string]any{
		"unknown vendor":     {"gemini": map[string]any{"*": "x"}},
		"unknown kind":       {"claude": map[string]any{"docs": "x"}},
		"alias kind hard":    {"claude": map[string]any{"hard": "opus"}},
		"model with a space": {"agy": map[string]any{"*": "Gemini 3.8 Flash (High)"}},
		"model with a quote": {"claude": map[string]any{"tests": "opus'"}},
	} {
		code, body = call(t, e, tid, http.MethodPatch, path, admin, map[string]any{
			"display_name": "renamed " + label, "agent_models": models})
		if code != http.StatusBadRequest || body["error"] != "bad_model" {
			t.Errorf("%s: %d %v, want 400 bad_model", label, code, body)
		}
	}
	code, body = call(t, e, tid, http.MethodPatch, path, admin, map[string]any{"agent_models": map[string]any{
		"claude": map[string]any{"*": nil, "complex_coding": ""}}})
	if code != 200 || modelsLine(t, body) != "grok:tests=grok-4.6" || strings.HasPrefix(body["display_name"].(string), "renamed") {
		t.Fatalf("reset: %d %v %v", code, body["agent_models"], body["display_name"])
	}
	dev := seat(t, e, tid, rbac.Developer)
	for _, p := range []string{path, "/v1/tenant/agent-model-readings"} {
		if code, body = call(t, e, tid, http.MethodGet, p, dev, nil); code != http.StatusForbidden {
			t.Errorf("CONTROL: developer GET %s = %d %v, want 403", p, code, body)
		}
	}
}

// putReading sends one reading with tok (no token when ""), as
// application/octet-stream, the way hubclient's REST sends a body.
func putReading(t *testing.T, e *env, tid, tok, box, vendor string, body any) (int, map[string]any) {
	t.Helper()
	raw, ok := body.([]byte)
	if !ok {
		raw, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(http.MethodPut, e.url(tid)+"/v1/boxes/"+box+"/agent-models/"+vendor, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/octet-stream")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func TestAgentModelReadings(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	admin, otherAdmin := seat(t, e, tid, rbac.Admin), seat(t, e, other, rbac.Admin)
	ba := e.box(tid, "box-a")
	e.pin(tid, ba)
	tok := e.uploadToken(tid, ba)
	at := time.Now().UTC().Truncate(time.Second)
	reading := func(cli string, at time.Time, models ...string) map[string]any {
		return map[string]any{"cli_version": cli, "models": models, "read_at": at.Format(time.RFC3339)}
	}

	for _, c := range []struct {
		label  string
		at     time.Time
		cli    string
		stored bool
	}{
		{"first", at, "1.0.89", true},
		{"older", at.Add(-time.Hour), "1.0.80", false},
		{"newer", at.Add(time.Minute), "1.0.92", true},
	} {
		code, body := putReading(t, e, tid, tok, "box-a", "grok", reading(c.cli, c.at, "grok-4.7", "grok-4.6"))
		if code != 200 || body["stored"] != c.stored || body["box"] != "box-a" || body["vendor"] != "grok" {
			t.Fatalf("%s: %d %v, want 200 stored=%v", c.label, code, body, c.stored)
		}
	}
	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/agent-model-readings", admin, nil)
	rs, _ := body["readings"].([]any)
	if code != 200 || len(rs) != 1 {
		t.Fatalf("readings: %d %v", code, body)
	}
	if r := rs[0].(map[string]any); r["cli_version"] != "1.0.92" || r["box"] != "box-a" ||
		r["read_at"] != at.Add(time.Minute).Format(time.RFC3339) || len(r["models"].([]any)) != 2 {
		t.Fatalf("the newer reading did not replace the older: %v", r)
	}
	if code, body = call(t, e, other, http.MethodGet, "/v1/tenant/agent-model-readings", otherAdmin, nil); code != 200 ||
		len(body["readings"].([]any)) != 0 {
		t.Fatalf("another workspace reads %d %v", code, body)
	}

	wui := uploadToken(t, e, tid, admin)
	for _, c := range []struct {
		label, tok, box, vendor string
		body                    any
		code                    int
		token                   string
	}{
		{"another box's path", tok, "box-b", "grok", reading("1", at), 403, "box_mismatch"},
		{"a WUI token", wui, "box-wui", "grok", reading("1", at), 403, "box_only"},
		{"no token", "", "box-a", "grok", reading("1", at), 401, "door"},
		{"unknown vendor", tok, "box-a", "gemini", reading("1", at), 400, "bad_vendor"},
		{"model with a space", tok, "box-a", "agy", reading("1", at, "ok", "Gemini 3.8"), 400, "bad_reading"},
		{"unknown field", tok, "box-a", "grok", map[string]any{"read_at": at.Format(time.RFC3339), "box": "x"}, 400, "bad_reading"},
		{"future read_at", tok, "box-a", "grok", reading("1", at.Add(time.Hour)), 400, "bad_reading"},
		{"not JSON", tok, "box-a", "grok", []byte("grok-4.7\n"), 400, "bad_reading"},
	} {
		if code, body := putReading(t, e, tid, c.tok, c.box, c.vendor, c.body); code != c.code || body["error"] != c.token {
			t.Errorf("CONTROL %s: %d %v, want %d %s", c.label, code, body, c.code, c.token)
		}
	}
}
