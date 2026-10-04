package hub_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 072 A27 acceptance: a member past access_until gets 403 and a control
// member does not. An admin sets the end on Tenant settings -> Members (PATCH),
// the list shows it, and clearing it restores access.
func TestMemberAccessUntilDoor(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	admin := seat(t, e, tid, rbac.Admin)
	guest := seat(t, e, tid, rbac.Developer)
	ctl := seat(t, e, tid, rbac.Developer)

	past := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+guest, admin, map[string]any{"access_until": past}); code != http.StatusNoContent {
		t.Fatalf("set access_until: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", guest, nil); code != http.StatusForbidden {
		t.Fatalf("member past access_until reads: %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", ctl, nil); code != http.StatusOK {
		t.Fatalf("CONTROL member refused: %d, want 200", code)
	}
	_, body := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil)
	rows := map[string]map[string]any{}
	for _, m := range body["members"].([]any) {
		mm := m.(map[string]any)
		rows[mm["human_id"].(string)] = mm
	}
	if r := rows[guest]; r == nil || r["access_until"] != past || r["access_ended"] != true || r["suspended"] != false {
		t.Fatalf("lapsed row: %v", r)
	}
	if r := rows[ctl]; r == nil || r["access_until"] != nil || r["access_ended"] != false {
		t.Fatalf("control row: %v", r)
	}

	// A future end keeps access; null clears.
	future := time.Now().Add(48 * time.Hour).UTC().Format(time.RFC3339)
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+guest, admin, map[string]any{"access_until": future}); code != http.StatusNoContent {
		t.Fatalf("extend: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/me", guest, nil); code != http.StatusOK {
		t.Fatalf("extended member refused: %d", code)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+guest, admin, map[string]any{"access_until": nil}); code != http.StatusNoContent {
		t.Fatalf("clear: %d %v", code, body)
	}

	// Refusals: a bad time, yourself, and the last member manager.
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+guest, admin, map[string]any{"access_until": "next week"}); code != http.StatusBadRequest || body["error"] != "bad_access_until" {
		t.Fatalf("bad time: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodPatch, "/v1/members/"+admin, admin, map[string]any{"access_until": future}); code != http.StatusConflict || body["error"] != "self" {
		t.Fatalf("self: %d %v", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/members/"+guest, ctl, map[string]any{"access_until": past}); code != http.StatusForbidden {
		t.Fatalf("developer sets an end: %d, want 403", code)
	}
}
