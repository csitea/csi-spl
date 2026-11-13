package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// opWriteEnv is an env whose operator token "good" is the allow-listed SA.
func opWriteEnv(t *testing.T) *env {
	return rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
}

// opEvent writes one whole-day event as agent c-840 and answers its id.
func opEvent(t *testing.T, e *env, tid, title string) string {
	t.Helper()
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/calendar/events", "good", map[string]any{
		"tenant": tid, "agent_id": "c-840", "title": title, "all_day": true,
		"starts_at": "2027-02-01T00:00:00Z", "ends_at": "2027-02-02T00:00:00Z"})
	ev, _ := out["event"].(map[string]any)
	if code != http.StatusCreated || ev == nil {
		t.Fatalf("create %s: %d %v", title, code, out)
	}
	return ev["id"].(string)
}

// SPL-5453: PATCH /v1/operator/calendar/events/{id} sets props.pinned and
// nothing else; members read pinned on the wire, a member's own edit keeps
// it. CONTROLS: another field, another props key, a non-bool, another
// workspace's host, a private event and no token change nothing.
func TestOperatorCalendarPin(t *testing.T) {
	e := opWriteEnv(t)
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	mem := seat(t, e, ta, rbac.Developer)
	id := opEvent(t, e, ta, "Holland")
	pin := func(host string, body map[string]any) (int, map[string]any) {
		return opCall(t, e, host, http.MethodPatch, "/v1/operator/calendar/events/"+id, "good", body)
	}
	body := func(props map[string]any) map[string]any {
		return map[string]any{"tenant": ta, "agent_id": "c-840", "ordered_by": "HUM-10", "props": props}
	}
	code, out := pin(ta, body(map[string]any{"pinned": true}))
	if ev, _ := out["event"].(map[string]any); code != http.StatusOK || ev["pinned"] != true || ev["title"] != "Holland" {
		t.Fatalf("pin: %d %v", code, out)
	}
	const day = "/v1/calendar/events?start=2027-02-01T00:00:00Z&end=2027-02-02T00:00:00Z"
	if _, got := call(t, e, ta, http.MethodGet, day, mem, nil); got["events"].([]any)[0].(map[string]any)["pinned"] != true {
		t.Fatalf("member does not read pinned: %v", got)
	}
	// A member's edit of another field keeps the pin.
	if code, got := call(t, e, ta, http.MethodPatch, "/v1/calendar/events/"+id, mem, map[string]any{"location": "Amsterdam"}); code != http.StatusOK ||
		got["event"].(map[string]any)["pinned"] != true {
		t.Fatalf("member edit dropped the pin: %d %v", code, got)
	}
	for _, c := range []struct {
		name, host string
		body       map[string]any
		code       int
		errCode    string
	}{
		{"another field", ta, map[string]any{"tenant": ta, "agent_id": "c-840", "title": "x", "props": map[string]any{"pinned": true}}, http.StatusBadRequest, "bad_json"},
		{"another props key", ta, body(map[string]any{"pinned": true, "color": "sage"}), http.StatusBadRequest, "bad_event"},
		{"no pinned", ta, body(map[string]any{"color": "sage"}), http.StatusBadRequest, "bad_event"},
		{"not a bool", ta, body(map[string]any{"pinned": "yes"}), http.StatusBadRequest, "bad_event"},
		{"a human agent_id", ta, map[string]any{"tenant": ta, "agent_id": "HUM-10", "props": map[string]any{"pinned": false}}, http.StatusBadRequest, "bad_agent_id"},
		{"B's host naming A", tb, body(map[string]any{"pinned": false}), http.StatusForbidden, "tenant_mismatch"},
	} {
		if code, got := pin(c.host, c.body); code != c.code || got["error"] != c.errCode {
			t.Fatalf("%s: %d %v, want %d %s", c.name, code, got, c.code, c.errCode)
		}
	}
	if code, _ := opCall(t, e, ta, http.MethodPatch, "/v1/operator/calendar/events/"+id, "", body(map[string]any{"pinned": false})); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	// The event in A is still pinned, as Amsterdam: no refusal wrote.
	if _, got := opCall(t, e, ta, http.MethodGet, "/v1/operator/calendar/events/"+id+"?tenant="+ta, "good", nil); got["event"].(map[string]any)["pinned"] != true {
		t.Fatalf("a refusal changed the event: %v", got)
	}
	// A private event of a member is not the operator's to pin.
	priv := calCreate(t, e, ta, mem, calBody("Mine", map[string]any{"audience": "private"}))["id"].(string)
	if code, _ := opCall(t, e, ta, http.MethodPatch, "/v1/operator/calendar/events/"+priv, "good", body(map[string]any{"pinned": true})); code != http.StatusNotFound {
		t.Fatalf("private pinned: %d, want 404", code)
	}
	// Unpinning drops the key.
	if code, out := pin(ta, body(map[string]any{"pinned": false})); code != http.StatusOK || out["event"].(map[string]any)["pinned"] != nil {
		t.Fatalf("unpin: %d %v", code, out)
	}
}

// SPL-5453: DELETE /v1/operator/calendar/events/{id} is the member soft
// delete: the event leaves the calendar and sits in ordered_by's trash (a
// member, who can Undo it), else in the agent's. CONTROLS: another
// workspace's host, a private event, a bad agent and no token delete nothing.
func TestOperatorCalendarDelete(t *testing.T) {
	e := opWriteEnv(t)
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	mem, other := seat(t, e, ta, rbac.Developer), seat(t, e, ta, rbac.Developer)
	keep, gone := opEvent(t, e, ta, "Keep"), opEvent(t, e, ta, "Gone")
	del := func(host, id, token, q string) (int, map[string]any) {
		return opCall(t, e, host, http.MethodDelete, "/v1/operator/calendar/events/"+id+"?"+q, token, nil)
	}
	good := "tenant=" + ta + "&agent_id=c-840&ordered_by=" + mem
	priv := calCreate(t, e, ta, mem, calBody("Mine", map[string]any{"audience": "private"}))["id"].(string)
	for _, c := range []struct {
		name, host, id, token, q string
		code                     int
	}{
		{"B's host naming A", tb, keep, "good", good, http.StatusForbidden},
		{"A's event named in B", tb, keep, "good", "tenant=" + tb + "&agent_id=c-840", http.StatusNotFound},
		{"a private event", ta, priv, "good", good, http.StatusNotFound},
		{"a human agent_id", ta, keep, "good", "tenant=" + ta + "&agent_id=HUM-10", http.StatusBadRequest},
		{"bad ordered_by", ta, keep, "good", "tenant=" + ta + "&agent_id=c-840&ordered_by=x", http.StatusBadRequest},
		{"no token", ta, keep, "", good, http.StatusUnauthorized},
	} {
		if code, got := del(c.host, c.id, c.token, c.q); code != c.code {
			t.Fatalf("%s: %d %v, want %d", c.name, code, got, c.code)
		}
	}
	code, out := del(ta, gone, "good", good)
	if ev, _ := out["event"].(map[string]any); code != http.StatusOK || ev["deleted_at"] == "" || ev["title"] != "Gone" {
		t.Fatalf("delete: %d %v", code, out)
	}
	const day = "/v1/calendar/events?start=2027-02-01T00:00:00Z&end=2027-02-02T00:00:00Z"
	if _, got := call(t, e, ta, http.MethodGet, day, other, nil); calTitles(got, "events") != "Keep" {
		t.Fatalf("after delete the day holds: %v", got)
	}
	if code, _ := opCall(t, e, ta, http.MethodGet, "/v1/operator/calendar/events/"+gone+"?tenant="+ta, "good", nil); code != http.StatusNotFound {
		t.Fatalf("read back of a trashed event: %d, want 404", code)
	}
	// In the ordering member's trash, not another member's; Undo brings it back.
	if _, got := call(t, e, ta, http.MethodGet, "/v1/calendar/trash", mem, nil); calTitles(got, "events") != "Gone" {
		t.Fatalf("ordered_by's trash: %v", got)
	}
	if _, got := call(t, e, ta, http.MethodGet, "/v1/calendar/trash", other, nil); calTitles(got, "events") != "" {
		t.Fatalf("another member's trash: %v", got)
	}
	if code, _ := call(t, e, ta, http.MethodPost, "/v1/calendar/events/"+gone+"/restore", mem, nil); code != http.StatusOK {
		t.Fatalf("undo: %d", code)
	}
	// ordered_by not a member: the agent's trash, still out of the calendar.
	if code, _ := del(ta, gone, "good", "tenant="+ta+"&agent_id=c-840&ordered_by=HUM-99999"); code != http.StatusOK {
		t.Fatalf("delete with a non-member ordered_by: %d", code)
	}
	if _, got := call(t, e, ta, http.MethodGet, day, other, nil); calTitles(got, "events") != "Keep" {
		t.Fatalf("after the second delete: %v", got)
	}
}
