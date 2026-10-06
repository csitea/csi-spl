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

// The operator twin of PATCH /v1/members/{id} access_until: a box ends a
// member's access with no member session (do_spl_hub_member_access_until).
// A past end shuts the door (403) while a CONTROL member keeps 200; null
// clears it; the last-owner guard holds; bad input and a non-operator are
// refused.
func TestOperatorMemberAccessUntil(t *testing.T) {
	const aud = "https://api.dev.example"
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = aud
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
	owner := seat(t, e, tid, rbac.BizOwner)
	guest := seat(t, e, tid, rbac.Admin)
	ctl := seat(t, e, tid, rbac.Developer)
	path := "/v1/operator/members/" + guest

	past := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	code, body := opCall(t, e, tid, http.MethodPatch, path, "good",
		map[string]any{"tenant": tid, "access_until": past, "ordered_by": "HUM-10", "ordered_via": "c-001"})
	if code != http.StatusOK || body["access_until"] != past || body["access_ended"] != true || body["human_id"] != guest {
		t.Fatalf("set past: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", guest, nil); code != http.StatusForbidden {
		t.Fatalf("member past access_until reads: %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", ctl, nil); code != http.StatusOK {
		t.Fatalf("CONTROL member refused: %d, want 200", code)
	}
	_, list := call(t, e, tid, http.MethodGet, "/v1/members", owner, nil)
	found := false
	for _, m := range list["members"].([]any) {
		if mm := m.(map[string]any); mm["human_id"] == guest {
			found = mm["access_ended"] == true && mm["access_until"] == past
		}
	}
	if !found {
		t.Fatalf("member list does not show the ended access: %v", list)
	}

	// a future end: not ended yet; null clears and restores the door
	future := time.Now().Add(12 * time.Hour).UTC().Format(time.RFC3339)
	if code, body := opCall(t, e, tid, http.MethodPatch, path, "good",
		map[string]any{"tenant": tid, "access_until": future}); code != http.StatusOK || body["access_ended"] != false {
		t.Fatalf("set future: %d %v", code, body)
	}
	if code, body := opCall(t, e, tid, http.MethodPatch, path, "good",
		map[string]any{"tenant": tid, "access_until": nil}); code != http.StatusOK || body["access_until"] != nil {
		t.Fatalf("clear: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", guest, nil); code != http.StatusOK {
		t.Fatalf("cleared member refused: %d", code)
	}

	// the same last-owner guard as the member PATCH
	if code, body := opCall(t, e, tid, http.MethodPatch, "/v1/operator/members/"+owner, "good",
		map[string]any{"tenant": tid, "access_until": future}); code != http.StatusConflict || body["error"] != "last_owner" {
		t.Fatalf("last owner: %d %v", code, body)
	}

	// refusals
	for name, c := range map[string]struct {
		path string
		body map[string]any
		want int
	}{
		"missing access_until": {path, map[string]any{"tenant": tid}, http.StatusBadRequest},
		"bad time":             {path, map[string]any{"tenant": tid, "access_until": "tomorrow"}, http.StatusBadRequest},
		"bad human id":         {"/v1/operator/members/someone", map[string]any{"tenant": tid, "access_until": future}, http.StatusBadRequest},
		"bad ordered_by":       {path, map[string]any{"tenant": tid, "access_until": future, "ordered_by": "x"}, http.StatusBadRequest},
		"bad tenant":           {path, map[string]any{"tenant": "NO", "access_until": future}, http.StatusBadRequest},
		"not a member":         {"/v1/operator/members/HUM-999999", map[string]any{"tenant": tid, "access_until": future}, http.StatusNotFound},
	} {
		if code, body := opCall(t, e, tid, http.MethodPatch, c.path, "good", c.body); code != c.want {
			t.Errorf("%s: %d %v, want %d", name, code, body, c.want)
		}
	}
	req := map[string]any{"tenant": tid, "access_until": past}
	if code, _ := opCall(t, e, tid, http.MethodPatch, path, "", req); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodPatch, path, "other-sa", req); code != http.StatusForbidden {
		t.Fatalf("non-operator identity: %d", code)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", guest, nil); code != http.StatusOK {
		t.Fatalf("a refused call changed the member: %d", code)
	}
}
