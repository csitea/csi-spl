package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The operator link of two accounts of one person (spec 042 "Note to self";
// owner HUM-10 poll 3193d41f answer C: "Operator-set link only, no
// self-service"; do_spl_human_link). Both directions, idempotent. The
// CONTROLS: a self link, an unknown human, a bad body, no token, a
// non-allow-listed identity and a member session (even an admin's) link
// nothing. Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestOperatorHumanLinks(t *testing.T) {
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
	tid, _ := e.tenant()
	first, second := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	admin := seat(t, e, tid, rbac.Admin)
	link := func(hum, token string, body any) (int, map[string]any) {
		return opCall(t, e, tid, http.MethodPost, "/v1/operator/humans/"+hum+"/links", token, body)
	}
	ok := map[string]any{"linked_human_id": second, "agent_id": "c-308", "ordered_by": "HUM-10"}
	linked := func(hum string) string {
		t.Helper()
		code, body := opCall(t, e, tid, http.MethodGet, "/v1/operator/humans/"+hum+"/links", "good", nil)
		if code != http.StatusOK {
			t.Fatalf("read back %s: %d %v", hum, code, body)
		}
		return toJSON(body["linked"])
	}

	for _, c := range []struct {
		name, hum, token string
		body             any
		code             int
		err              string
	}{
		{"no token", first, "", ok, http.StatusUnauthorized, "no_token"},
		{"bad token", first, "nope", ok, http.StatusUnauthorized, "bad_token"},
		{"not an operator", first, "other-sa", ok, http.StatusForbidden, ""},
		{"self link", first, "good", map[string]any{"linked_human_id": first, "agent_id": "c-308", "ordered_by": "HUM-10"}, http.StatusBadRequest, "same_human"},
		{"unknown human", first, "good", map[string]any{"linked_human_id": "HUM-999999", "agent_id": "c-308", "ordered_by": "HUM-10"}, http.StatusNotFound, "not_found"},
		{"bad linked id", first, "good", map[string]any{"linked_human_id": "c-002", "agent_id": "c-308", "ordered_by": "HUM-10"}, http.StatusBadRequest, "bad_linked_human_id"},
		{"no agent", first, "good", map[string]any{"linked_human_id": second, "ordered_by": "HUM-10"}, http.StatusBadRequest, "bad_agent_id"},
		{"unknown field", first, "good", map[string]any{"linked_human_id": second, "agent_id": "c-308", "ordered_by": "HUM-10", "x": 1}, http.StatusBadRequest, "bad_json"},
	} {
		code, out := link(c.hum, c.token, c.body)
		if code != c.code || (c.err != "" && out["error"] != c.err) {
			t.Errorf("CONTROL %s: %d %v, want %d %s", c.name, code, out, c.code, c.err)
		}
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/operator/humans/"+first+"/links", admin, ok); code != http.StatusUnauthorized {
		t.Errorf("CONTROL an admin session on the operator route: %d, want 401", code)
	}
	if got := linked(first); got != "[]" {
		t.Fatalf("a refused call linked: %s", got)
	}

	for range 2 { // idempotent
		if code, body := link(first, "good", ok); code != http.StatusOK || toJSON(body["linked"]) != `["`+second+`"]` {
			t.Fatalf("operator links: %d %v", code, body)
		}
	}
	if got := linked(second); got != `["`+first+`"]` {
		t.Fatalf("the other direction: %s", got)
	}
}
