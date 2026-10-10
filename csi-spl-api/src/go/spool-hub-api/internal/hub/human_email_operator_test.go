package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The operator twin of POST /v1/members/{human_id}/emails
// (do_spl_human_email_add, owner HUM-10 t1 f265541a msg 1ee61a2b): an agent
// adds a PENDING address to a human and reads the list back. The CONTROLS:
// an address active or pending on another human is 409 with no hint of
// whose, the operator add never activates (a cold provider sign-in does not
// reach the human; only a link sign-in from the human's own session does),
// and no token, a bad token, a non-allow-listed identity or a member session
// add nothing. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full).
func TestOperatorHumanEmails(t *testing.T) {
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
	other, _ := e.tenant()
	x, xid := seatIdent(t, e, tid, rbac.Developer)
	admin := seat(t, e, tid, rbac.Admin)
	y, yid := seatIdent(t, e, other, rbac.Developer)
	path := "/v1/operator/humans/" + x + "/emails"
	h := e.st.(store.Humans)
	ctx, now := context.Background(), time.Now()
	second := randHex(5) + "@example.com"
	add := func(hum, token, email string) (int, map[string]any) {
		return opCall(t, e, tid, http.MethodPost, "/v1/operator/humans/"+hum+"/emails", token,
			map[string]any{"email": email, "agent_id": "c-764", "ordered_by": "HUM-10"})
	}

	code, body := add(x, "good", strings.ToUpper(second))
	if code != http.StatusOK || body["state"] != store.EmailPending || body["email"] != second ||
		body["reason"] != "pending_until_provider_sign_in" || body["human_id"] != x {
		t.Fatalf("operator adds: %d %v", code, body)
	}
	// Idempotent: a second add answers pending again and writes nothing new.
	if code, body := add(x, "good", second); code != http.StatusOK || body["state"] != store.EmailPending {
		t.Fatalf("add twice: %d %v", code, body)
	}
	code, body = opCall(t, e, tid, http.MethodGet, path, "good", nil)
	list := toJSON(body["emails"])
	if code != http.StatusOK || !strings.Contains(list, `"email":"`+second+`","main":false,"providers":[],"state":"pending"`) ||
		!strings.Contains(list, `"email":"`+xid.Email+`","main":true,"providers":["google"],"state":"active"`) {
		t.Fatalf("read back: %d %v", code, body)
	}
	// The member's own list shows the same pending address.
	if code, body := call(t, e, tid, http.MethodGet, "/v1/members/"+x+"/emails", x, nil); code != http.StatusOK ||
		!strings.Contains(toJSON(body["emails"]), `"email":"`+second+`","main":false,"providers":[],"state":"pending"`) {
		t.Fatalf("member's own list: %d %v", code, body)
	}

	// CONTROL: a squat on another human, active or pending, is 409 and never
	// says whose; the other human's list is unchanged.
	code, body = add(x, "good", yid.Email)
	if code != http.StatusConflict || body["error"] != "email_taken" || strings.Contains(toJSON(body), y) {
		t.Fatalf("CONTROL another human's active address: %d %v", code, body)
	}
	code, body = add(y, "good", second)
	if code != http.StatusConflict || body["error"] != "email_taken" || strings.Contains(toJSON(body), x) {
		t.Fatalf("CONTROL x's pending address onto y: %d %v", code, body)
	}
	if code, body := opCall(t, e, tid, http.MethodGet, "/v1/operator/humans/"+y+"/emails", "good", nil); code != http.StatusOK ||
		strings.Contains(toJSON(body["emails"]), second) || strings.Contains(toJSON(body["emails"]), xid.Email) {
		t.Fatalf("CONTROL y's list after the squats: %d %v", code, body)
	}

	// CONTROL: the operator add never activates. A COLD provider sign-in of
	// a pending address does not reach x, and it stays pending on x (its own
	// address: the cold sign-in may mint another human that owns it).
	cold := randHex(5) + "@example.com"
	if code, body := add(x, "good", cold); code != http.StatusOK || body["state"] != store.EmailPending {
		t.Fatalf("operator adds the cold address: %d %v", code, body)
	}
	if got, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "cold-" + cold, Email: cold}, "", store.AdmitPolicy{}, now); err == nil && got == x {
		t.Fatalf("CONTROL a cold sign-in of an operator-added address reached the human")
	}
	if code, body := opCall(t, e, tid, http.MethodGet, path, "good", nil); code != http.StatusOK ||
		!strings.Contains(toJSON(body["emails"]), `"email":"`+cold+`","main":false,"providers":[],"state":"pending"`) {
		t.Fatalf("CONTROL still pending after a cold sign-in: %d %v", code, body)
	}
	// Only a link sign-in from x's own session proves it.
	if got, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "link-" + second, Email: second, LinkTo: x}, "", store.AdmitPolicy{}, now); err != nil || got != x {
		t.Fatalf("link sign-in of the pending address: %q %v, want %q", got, err, x)
	}
	if code, body := add(x, "good", second); code != http.StatusOK || body["state"] != store.EmailActive || body["reason"] != "already_active" {
		t.Fatalf("re-add after the link sign-in: %d %v", code, body)
	}

	// Who may call, and what a call must carry.
	third := randHex(5) + "@example.com"
	for _, c := range []struct {
		name, hum, token string
		body             map[string]any
		code             int
		errCode          string
	}{
		{"no token", x, "", nil, http.StatusUnauthorized, "no_token"},
		{"bad token", x, "nope", nil, http.StatusUnauthorized, "bad_token"},
		{"not allow-listed", x, "other-sa", nil, http.StatusForbidden, "not_operator"},
		{"unknown human", "HUM-999999999", "good", nil, http.StatusNotFound, "not_found"},
		{"bad human id", "c-764", "good", nil, http.StatusBadRequest, "bad_human_id"},
		{"no agent", x, "good", map[string]any{"email": third, "ordered_by": "HUM-10"}, http.StatusBadRequest, "bad_agent_id"},
		{"no ordering human", x, "good", map[string]any{"email": third, "agent_id": "c-764"}, http.StatusBadRequest, "bad_ordered_by"},
		{"an agent orders", x, "good", map[string]any{"email": third, "agent_id": "c-764", "ordered_by": "c-001"}, http.StatusBadRequest, "bad_ordered_by"},
		{"bad address", x, "good", map[string]any{"email": "not an address", "agent_id": "c-764", "ordered_by": "HUM-10"}, http.StatusBadRequest, "bad_email"},
		{"unknown field", x, "good", map[string]any{"email": third, "agent_id": "c-764", "ordered_by": "HUM-10", "state": "active"}, http.StatusBadRequest, "bad_json"},
	} {
		b := c.body
		if b == nil {
			b = map[string]any{"email": third, "agent_id": "c-764", "ordered_by": "HUM-10"}
		}
		code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/humans/"+c.hum+"/emails", c.token, b)
		if code != c.code || out["error"] != c.errCode {
			t.Errorf("CONTROL %s: %d %v, want %d %s", c.name, code, out, c.code, c.errCode)
		}
	}
	// CONTROL: a member session, even an admin's, is no operator.
	if code, _ := call(t, e, tid, http.MethodPost, path, admin, map[string]any{"email": third, "agent_id": "c-764", "ordered_by": "HUM-10"}); code != http.StatusUnauthorized {
		t.Errorf("CONTROL an admin session on the operator route: %d, want 401", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodGet, path, "other-sa", nil); code != http.StatusForbidden {
		t.Errorf("CONTROL a non-operator reads the list: %d, want 403", code)
	}
	if code, body := opCall(t, e, tid, http.MethodGet, path, "good", nil); code != http.StatusOK || strings.Contains(toJSON(body), third) {
		t.Errorf("CONTROL a refused call added the address: %d %v", code, body)
	}
}
