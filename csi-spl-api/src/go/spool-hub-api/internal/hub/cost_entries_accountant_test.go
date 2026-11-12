package hub_test

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5359 (spec 123 16, rdb 0276): an internal_accountant of the OPERATOR
// workspace reads the cost report (200), lists (200), creates (201) and
// deletes (204) a cost entry, and is refused a member role change (403
// members.roles) and an operator write (PATCH /v1/operator/fleet-load, 403
// operator.workspaces). The same role in another workspace writes no entry:
// the rows are the estate's (403). An external_accountant holds no
// topics.read, so every browser door refuses it (403 topics.read) until a
// costs-only door exists (spec 123 16, the open follow-up). RED CONTROL:
// without costEntryGate in costEntryCaller the operator accountant's list,
// create and delete answer 403 operator.workspaces.
func TestCostEntryAccountantRoles(t *testing.T) {
	r := newFleetTokensRig(t)
	entry := map[string]any{"type": "hr", "label": "contract staff", "amount": 3100, "currency": "EUR", "period": "2020-05", "note": "test fixture"}
	acc := seat(t, r.e, r.op, rbac.InternalAccountant)
	if code, got := call(t, r.e, r.op, http.MethodGet, "/v1/tenant/costs", acc, nil); code != http.StatusOK {
		t.Errorf("cost report: %d %v, want 200", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath+"?type=hr", acc, nil); code != http.StatusOK || got["entries"] == nil {
		t.Errorf("list: %d %v, want 200", code, got)
	}
	code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, entry)
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" || got["created_by"] != acc || got["type"] != "hr" {
		t.Fatalf("create: %d %v, want 201", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, acc, nil); code != http.StatusNoContent {
		t.Errorf("delete: %d %v, want 204", code, got)
		call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil)
	}
	if code, got := call(t, r.e, r.op, http.MethodPut, "/v1/members/"+r.dev+"/roles", acc,
		map[string]any{"roles": []string{rbac.Tester}}); code != http.StatusForbidden || got["permission"] != rbac.MembersRoles {
		t.Errorf("member role change: %d %v, want 403 members.roles", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodPatch, "/v1/operator/fleet-load", acc,
		map[string]any{"max_agents": 1}); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
		t.Errorf("operator write: %d %v, want 403 operator.workspaces", code, got)
	}
	other := seat(t, r.e, r.other, rbac.InternalAccountant)
	if code, got := call(t, r.e, r.other, http.MethodPost, costEntryPath, other, entry); code != http.StatusForbidden {
		t.Errorf("another workspace's accountant create: %d %v, want 403", code, got)
	}
	ext := seat(t, r.e, r.op, rbac.ExternalAccountant)
	for _, rt := range [][2]string{{http.MethodGet, "/v1/tenant/costs"}, {http.MethodGet, costEntryPath}, {http.MethodPost, costEntryPath}} {
		var body any
		if rt[0] == http.MethodPost {
			body = entry
		}
		if code, got := call(t, r.e, r.op, rt[0], rt[1], ext, body); code != http.StatusForbidden || got["permission"] != rbac.TopicsRead {
			t.Errorf("external_accountant %s %s: %d %v, want 403 topics.read (no costs-only door yet)", rt[0], rt[1], code, got)
		}
	}
}

// corsCall is call from the allow-listed WUI origin; it also returns the
// response headers.
func corsCall(t *testing.T, e *env, tid, method, path, as string) (int, http.Header, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, e.url(tid)+path, nil)
	req.Header.Set("Origin", wuiOrigin)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, resp.Header, out
}

// varyOrigins counts the Origin tokens across every Vary line.
func varyOrigins(h http.Header) int {
	n := 0
	for _, line := range h.Values("Vary") {
		for _, tok := range strings.Split(line, ",") {
			if strings.EqualFold(strings.TrimSpace(tok), "Origin") {
				n++
			}
		}
	}
	return n
}

// SPL-5359, R7 a-290 W1: every answer of /v1/operator/cost-entries to the
// allow-listed WUI origin carries Access-Control-Allow-Origin, Cache-Control:
// no-store and exactly one Vary: Origin, whichever branch of costEntryGate
// answers: humanTenant's refusal (the external_accountant's 403 topics.read;
// on the session door the no-session 401 view_door, with credentials
// allowed), base's refusal after the fall-through (a developer, 403
// operator.workspaces) and the accountant's 200. RED CONTROL (commit body):
// with allowOrigin back after humanTenant the 403 topics.read and the 401
// carry no ACAO; without restore() the developer's 403 carries Vary: Origin
// twice.
func TestCostEntryGateCORS(t *testing.T) {
	r := newFleetTokensRig(t)
	cases := []struct {
		name, as string
		code     int
	}{
		{"external_accountant, humanTenant refuses", seat(t, r.e, r.op, rbac.ExternalAccountant), http.StatusForbidden},
		{"developer, base refuses", r.dev, http.StatusForbidden},
		{"internal_accountant, allowed", seat(t, r.e, r.op, rbac.InternalAccountant), http.StatusOK},
	}
	for _, c := range cases {
		code, h, body := corsCall(t, r.e, r.op, http.MethodGet, costEntryPath, c.as)
		if code != c.code {
			t.Errorf("%s: %d %v, want %d", c.name, code, body, c.code)
		}
		if h.Get("Access-Control-Allow-Origin") != wuiOrigin || h.Get("Cache-Control") != "no-store" || varyOrigins(h) != 1 {
			t.Errorf("%s: ACAO %q, Cache-Control %q, Vary %v; want the WUI origin, no-store, one Vary: Origin",
				c.name, h.Get("Access-Control-Allow-Origin"), h.Get("Cache-Control"), h.Values("Vary"))
		}
	}

	ac, err := auth.LoadFrom("lde", map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	rs := newFleetTokensRig(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorSession
		o.Auth = auth.New(ac, zerolog.Nop(), auth.Options{})
	})
	code, h, body := corsCall(t, rs.e, rs.op, http.MethodGet, costEntryPath, "")
	if code != http.StatusUnauthorized || body["error"] != "view_door" {
		t.Errorf("session door, no session: %d %v, want 401 view_door", code, body)
	}
	if h.Get("Access-Control-Allow-Origin") != wuiOrigin || h.Get("Access-Control-Allow-Credentials") != "true" ||
		h.Get("Cache-Control") != "no-store" || varyOrigins(h) != 1 {
		t.Errorf("session door 401: headers %v; want ACAO the WUI origin, credentials true, no-store, one Vary: Origin", h)
	}
}
