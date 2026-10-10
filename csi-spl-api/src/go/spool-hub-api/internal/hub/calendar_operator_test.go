package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The operator twin of POST /v1/calendar/events (do_spl_calendar_event_add):
// an agent writes an all-day event into one workspace, the creator shown as
// the agent; the operator reads it back; the members of that workspace see
// it. The CONTROLS: tenant B's members never see tenant A's event, a request
// on B's host naming A is 403, a topic of B is refused in A, and a member
// session, no token or a non-allow-listed identity write nothing.
func TestOperatorCalendarEvent(t *testing.T) {
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "other-sa":
				return "intruder@example-dev.iam.gserviceaccount.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	memA, memB := seat(t, e, ta, rbac.Developer), seat(t, e, tb, rbac.Developer)
	now := time.Now().UTC()
	topicA, topicB := uuidV4(), uuidV4()
	putMsg(t, e.st, ta, topicA, "tasks", "HUM-1", "box-wui", "c-001", "due on the 12th", now, "")
	putMsg(t, e.st, tb, topicB, "tasks", "HUM-1", "box-wui", "c-001", "other workspace", now, "")

	body := func(tenant, topic string) map[string]any {
		return map[string]any{"tenant": tenant, "agent_id": "c-840", "ordered_by": "HUM-10",
			"title": "Payment: VAT", "description": "source msg", "all_day": true,
			"starts_at": "2026-10-12T00:00:00Z", "ends_at": "2026-10-13T00:00:00Z", "topic_id": topic}
	}
	code, out := opCall(t, e, ta, http.MethodPost, "/v1/operator/calendar/events", "good", body(ta, topicA))
	ev, _ := out["event"].(map[string]any)
	if code != http.StatusCreated || ev == nil || ev["creator_type"] != "agent" || ev["creator_id"] != "c-840" ||
		ev["all_day"] != true || ev["topic_id"] != topicA || ev["audience"] != "workspace" {
		t.Fatalf("create: %d %v", code, out)
	}
	id := ev["id"].(string)
	if code, got := opCall(t, e, ta, http.MethodGet, "/v1/operator/calendar/events/"+id+"?tenant="+ta, "good", nil); code != http.StatusOK ||
		got["event"].(map[string]any)["title"] != "Payment: VAT" {
		t.Fatalf("read back: %d %v", code, got)
	}
	const day = "/v1/calendar/events?start=2026-10-12T00:00:00Z&end=2026-10-13T00:00:00Z"
	if _, got := call(t, e, ta, http.MethodGet, day, memA, nil); calTitles(got, "events") != "Payment: VAT" {
		t.Fatalf("member of A does not see it: %v", got)
	}
	// CONTROL: tenant B sees nothing of it, by list or by id.
	if _, got := call(t, e, tb, http.MethodGet, day, memB, nil); calTitles(got, "events") != "" {
		t.Fatalf("member of B sees A's event: %v", got)
	}
	if code, _ := opCall(t, e, tb, http.MethodGet, "/v1/operator/calendar/events/"+id+"?tenant="+tb, "good", nil); code != http.StatusNotFound {
		t.Fatalf("A's event read as B: %d, want 404", code)
	}

	for _, c := range []struct {
		name, host, token string
		body              map[string]any
		code              int
		errCode           string
	}{
		{"B's host naming A", tb, "good", body(ta, ""), http.StatusForbidden, "tenant_mismatch"},
		{"a topic of B in A", ta, "good", body(ta, topicB), http.StatusBadRequest, "bad_event"},
		{"a human creator", ta, "good", map[string]any{"tenant": ta, "agent_id": "HUM-10", "title": "x",
			"starts_at": "2026-10-12T00:00:00Z", "ends_at": "2026-10-13T00:00:00Z"}, http.StatusBadRequest, "bad_agent_id"},
		{"guests", ta, "good", map[string]any{"tenant": ta, "agent_id": "c-840", "title": "x", "guests": []any{},
			"starts_at": "2026-10-12T00:00:00Z", "ends_at": "2026-10-13T00:00:00Z"}, http.StatusBadRequest, "bad_event"},
		{"unknown workspace", ta, "good", body("tnosuchws", ""), http.StatusForbidden, "tenant_mismatch"},
		{"no token", ta, "", body(ta, ""), http.StatusUnauthorized, "no_token"},
		{"bad token", ta, "nope", body(ta, ""), http.StatusUnauthorized, "bad_token"},
		{"not allow-listed", ta, "other-sa", body(ta, ""), http.StatusForbidden, "not_operator"},
	} {
		if code, got := opCall(t, e, c.host, http.MethodPost, "/v1/operator/calendar/events", c.token, c.body); code != c.code || got["error"] != c.errCode {
			t.Fatalf("%s: %d %v, want %d %s", c.name, code, got, c.code, c.errCode)
		}
	}
	// A member session is not an operator.
	if code, _ := call(t, e, ta, http.MethodPost, "/v1/operator/calendar/events", memA, body(ta, "")); code != http.StatusUnauthorized {
		t.Fatalf("member session: %d, want 401", code)
	}
	// Nothing the refusals sent was written: A still holds the one event, B none.
	if _, got := call(t, e, ta, http.MethodGet, day, memA, nil); calTitles(got, "events") != "Payment: VAT" {
		t.Fatalf("a refusal wrote into A: %v", got)
	}
	if _, got := call(t, e, tb, http.MethodGet, day, memB, nil); calTitles(got, "events") != "" {
		t.Fatalf("a refusal wrote into B: %v", got)
	}
}
