package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The operator twin of POST /v1/channels (do_spl_channel_create): an agent
// creates a members-only channel in one workspace, created_by the ordering
// human, who is seated in it; the operator reads it back. The CONTROLS:
// tenant B has no such channel, a request on B's host naming A is 403, an
// ordering human of B is refused in A, a reserved or existing slug is 409,
// "public" privacy is refused, and a member session, no token or a
// non-allow-listed identity create nothing.
func TestOperatorChannelCreate(t *testing.T) {
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
	memA, memB := seat(t, e, ta, rbac.Admin), seat(t, e, tb, rbac.Admin)

	body := func(tenant, ch, by string) map[string]any {
		return map[string]any{"tenant": tenant, "channel": ch, "ordered_by": by,
			"description": "the review topics", "privacy": "members"}
	}
	code, out := opCall(t, e, ta, http.MethodPost, "/v1/operator/channels", "good", body(ta, "trading", memA))
	if code != http.StatusCreated || out["channel"] != "trading" || out["created_by"] != memA ||
		out["privacy"] != "members" || out["default"] != false {
		t.Fatalf("create: %d %v", code, out)
	}
	code, got := opCall(t, e, ta, http.MethodGet, "/v1/operator/channels/trading?tenant="+ta, "good", nil)
	if ms, _ := got["members"].([]any); code != http.StatusOK || got["created_by"] != memA ||
		got["description"] != "the review topics" || len(ms) != 1 || ms[0] != memA {
		t.Fatalf("read back: %d %v", code, got)
	}
	// The creator reads it as a member does.
	if code, got := call(t, e, ta, http.MethodGet, "/v1/channels/trading/members", memA, nil); code != http.StatusOK {
		t.Fatalf("creator's member list: %d %v", code, got)
	}
	// CONTROL: tenant B has no #trading.
	if code, _ := opCall(t, e, tb, http.MethodGet, "/v1/operator/channels/trading?tenant="+tb, "good", nil); code != http.StatusNotFound {
		t.Fatalf("A's channel read as B: %d, want 404", code)
	}

	for _, c := range []struct {
		name, host, token string
		body              map[string]any
		code              int
		errCode           string
	}{
		{"B's host naming A", tb, "good", body(ta, "other", memA), http.StatusForbidden, "tenant_mismatch"},
		{"unknown workspace", ta, "good", body("tnosuchws", "other", memA), http.StatusForbidden, "tenant_mismatch"},
		{"an ordering human of B", ta, "good", body(ta, "other", memB), http.StatusNotFound, "not_a_member"},
		{"no ordering human", ta, "good", body(ta, "other", ""), http.StatusBadRequest, "bad_ordered_by"},
		{"an agent orders", ta, "good", body(ta, "other", "c-843"), http.StatusBadRequest, "bad_ordered_by"},
		{"public privacy", ta, "good", map[string]any{"tenant": ta, "channel": "other", "ordered_by": memA,
			"privacy": "public"}, http.StatusBadRequest, "bad_privacy"},
		{"bad slug", ta, "good", body(ta, "Bad Slug", memA), http.StatusBadRequest, "bad_channel"},
		{"a default channel", ta, "good", body(ta, "lobby", memA), http.StatusConflict, "channel_exists"},
		{"the reserved issues", ta, "good", body(ta, "issues", memA), http.StatusConflict, "channel_exists"},
		{"an existing channel", ta, "good", body(ta, "trading", memA), http.StatusConflict, "channel_exists"},
		{"no token", ta, "", body(ta, "other", memA), http.StatusUnauthorized, "no_token"},
		{"bad token", ta, "nope", body(ta, "other", memA), http.StatusUnauthorized, "bad_token"},
		{"not allow-listed", ta, "other-sa", body(ta, "other", memA), http.StatusForbidden, "not_operator"},
	} {
		if code, got := opCall(t, e, c.host, http.MethodPost, "/v1/operator/channels", c.token, c.body); code != c.code || got["error"] != c.errCode {
			t.Fatalf("%s: %d %v, want %d %s", c.name, code, got, c.code, c.errCode)
		}
	}
	// A member session is not an operator.
	if code, _ := call(t, e, ta, http.MethodPost, "/v1/operator/channels", memA, body(ta, "other", memA)); code != http.StatusUnauthorized {
		t.Fatalf("member session: %d, want 401", code)
	}
	// Nothing the refusals sent was written, in A or in B.
	for _, tid := range []string{ta, tb} {
		if code, _ := opCall(t, e, tid, http.MethodGet, "/v1/operator/channels/other?tenant="+tid, "good", nil); code != http.StatusNotFound {
			t.Fatalf("a refusal created #other in %s: %d", tid, code)
		}
	}
}
