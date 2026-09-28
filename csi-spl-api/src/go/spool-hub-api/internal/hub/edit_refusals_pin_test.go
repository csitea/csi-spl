package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Pins of PATCH /v1/messages/{id} refusals that no other test drove, taken
// before handleEditMessage was split into named steps (SPL-1029 round 2).
// Each leaves the stored body as it was.
func TestEditMessageRequestRefusals(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "kept")["msg_id"].(string)
	for _, c := range []struct {
		name  string
		msgID string
		body  any
		code  int
		token string
	}{
		{"id not a UUID", "not-a-uuid", map[string]string{"body": "x"}, http.StatusBadRequest, "bad_json"},
		{"unknown field", id, map[string]any{"body": "x", "extra": 1}, http.StatusBadRequest, "bad_json"},
		{"not an object", id, []string{"x"}, http.StatusBadRequest, "bad_json"},
		{"too large", id, map[string]string{"body": strings.Repeat("a", 65537)}, http.StatusRequestEntityTooLarge, "too_large"},
		{"no such message", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", map[string]string{"body": "x"}, http.StatusNotFound, "not_found"},
	} {
		code, out := patchEdit(t, e, tid, c.msgID, "HUM-1", c.body)
		if code != c.code || out["error"] != c.token {
			t.Errorf("%s: %d %v, want %d %s", c.name, code, out, c.code, c.token)
		}
	}
	// an unpaid tenant cannot edit
	if err := e.st.SetBillingStatus(context.Background(), tid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	if code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": "x"}); code != billing.HTTPUnpaid || out["error"] != billing.TokenUnpaid {
		t.Errorf("unpaid: %d %v", code, out)
	}
	if got := storedBody(t, e, tid, id); got != "kept" {
		t.Fatalf("a refusal changed the body to %q", got)
	}
}

// A member whose role has no notes.send (here: no role at all) is refused
// before the message is looked up.
func TestEditMessageNeedsNotesSend(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = rbac.Fixed("no-such-role")
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	tid, _ := e.tenant()
	code, out := patchEdit(t, e, tid, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "HUM-1", map[string]string{"body": "x"})
	if code != http.StatusForbidden {
		t.Fatalf("no notes.send: %d %v", code, out)
	}
}
