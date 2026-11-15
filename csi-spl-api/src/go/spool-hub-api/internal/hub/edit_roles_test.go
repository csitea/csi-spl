package hub_test

import (
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-1291 (owner HUM-10, 2026-09-30: "this works for some roles, it MUST work
// for all the other roles as well"): EVERY human role edits its OWN message and
// the title of the topics it started. SPL-5570 (owner HUM-10, 2026-11-13)
// made it author-only: the tenant owner and an admin no longer edit anyone's
// (author_only_test.go).
//
// A topic's title is the first line of its opening card, and a lobby note IS an
// opening card (topic_archive_test archives lobby notes as cards). So one lobby
// note is at once "a sent message" and "a topic title", it is a real box-wui
// envelope the hub can re-sign (unlike a putCard row), and it sits in the public
// lobby channel so the read door lets the owner and the admin reach another
// member's note. Editing its body is therefore exactly the owner's two asks.
//
// The matrix is a control: drop notes.send from a role's Defaults and its
// own-edit row goes red. HUM ids are valid v:1 ids so the hub uses them verbatim
// (an unmapped id like HUM-99 falls to roleOf's default developer role).

// theEightRoles pairs rbac.RoleIDs with a distinct human, so one env holds every
// role at once. HUM-51 (biz_owner) and HUM-53 (admin) are the elevated pair.
var theEightRoles = map[string]string{
	"HUM-51": rbac.BizOwner,
	"HUM-52": rbac.ProductOwner,
	"HUM-53": rbac.Admin,
	"HUM-54": rbac.Developer,
	"HUM-55": rbac.Tester,
	"HUM-56": rbac.PureAgent,
	"HUM-57": rbac.BizCustomer,
	"HUM-58": rbac.RegularUser,
}

// rolesEnv is followEnv with a per-human authorizer (roleOf), so each seat holds
// the role theEightRoles gives it. No WUI key: lobby notes are unsigned box-wui
// envelopes, the simplest editable shape (edit.go rule 7's EnvSig == "" branch).
func rolesEnv(t *testing.T) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roleOf(theEightRoles)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
}

// TestEditEveryRoleEditsOwn — the owner's rule, positive half. Each of the eight
// roles edits its OWN lobby note (a message, and the title of the topic that note
// opens): 200, and the marker records the author as the editor.
func TestEditEveryRoleEditsOwn(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	for hum, role := range theEightRoles {
		c := dialMember(t, e, tid, hum, hum)
		id, _ := postNote(t, c, "note by "+role)["msg_id"].(string)
		code, out := patchEdit(t, e, tid, id, hum, map[string]string{"body": "note by " + role + " (fixed)"})
		if code != http.StatusOK {
			t.Fatalf("%s editing its own message/title: %d %v (want 200)", role, code, out)
		}
		if out["edited_by"] != hum {
			t.Fatalf("%s own edit: edited_by=%v, want %s", role, out["edited_by"], hum)
		}
		if got := storedBody(t, e, tid, id); got != "note by "+role+" (fixed)" {
			t.Fatalf("%s own edit not stored: %q", role, got)
		}
	}
}

// TestEditNonAdminNotOthers — the owner's rule, ceiling half. A non-owner,
// non-admin role editing ANOTHER member's message/title is 403 not_author, and
// the refusal leaves the body and the register untouched.
func TestEditNonAdminNotOthers(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-54", "HUM-54") // a developer starts the topic
	id, _ := postNote(t, author, "the developer's note")["msg_id"].(string)

	// product_owner is here on purpose: despite the name it is NOT the tenant
	// owner and holds no admin role (those two: author_only_test.go). HUM-99 is
	// unmapped, so roleOf makes it a second developer: a PEER of the author,
	// proving the gate is per-message-author, not per-role.
	for _, hum := range []string{"HUM-52", "HUM-55", "HUM-56", "HUM-57", "HUM-58", "HUM-99"} {
		_ = dialMember(t, e, tid, hum, hum) // the read door needs a session that can see the lobby
		code, out := patchEdit(t, e, tid, id, hum, map[string]string{"body": "hijacked by " + hum})
		if code != http.StatusForbidden || out["error"] != "not_author" {
			t.Fatalf("%s editing another's message/title: %d %v (want 403 not_author)", hum, code, out)
		}
	}
	if got := storedBody(t, e, tid, id); got != "the developer's note" {
		t.Fatalf("a refused edit changed the message: %q", got)
	}
	if rs := revisions(t, e, tid, id); len(rs) != 0 {
		t.Fatalf("a refused edit wrote %d revision(s)", len(rs))
	}
}

// The elevated half (the tenant owner and an admin editing anyone's) was
// reversed by SPL-5570: author_only_test.go TestEditAuthorOnly.
