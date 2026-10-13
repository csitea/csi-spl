package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// senderEnv is rbacEnv with box-wui pinned and CLE-07 announced on box-a, so
// a member's "@CLE-07 ..." and DM to CLE-07 are signed dispatches; it seats
// an admin and two developers.
func senderEnv(t *testing.T) (e *env, tid, admin, listed, other string) {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e = rbacEnv(t, func(o *hub.Options) { o.WUIKey = key })
	tid, _ = e.tenant()
	e.pin(tid, e.box(tid, "box-a", "CLE-07"))
	e.pinKey(tid, hub.WUIBox, pub)
	if err := e.st.SetRoster(context.Background(), tid, "box-a", []string{"CLE-07"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	return e, tid, seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
}

// wantRefused asserts f is the 403 sender_not_allowed frame naming agent and
// that msg id was neither stored nor queued for the agent's box.
func wantRefused(t *testing.T, e *env, tid, id, what string, f map[string]any) {
	t.Helper()
	if f["type"] != "error" || f["error"] != hub.TokenSenderNotAllowed || f["status"] != float64(http.StatusForbidden) ||
		f["agent"] != "CLE-07" || f["msg_id"] != id {
		t.Fatalf("%s: %v, want 403 sender_not_allowed naming CLE-07", what, f)
	}
	if stored(t, e, tid, id) || queued(t, e, tid)[id] {
		t.Fatalf("%s: the refused send was stored or delivered", what)
	}
}

// wantDelivered asserts f acked a dispatch of msg id to box-a.
func wantDelivered(t *testing.T, e *env, tid, id, what string, f map[string]any) {
	t.Helper()
	if f["type"] != "ack" || f["to_box"] != "box-a" || !queued(t, e, tid)[id] {
		t.Fatalf("%s: %v, want an ack delivered to box-a", what, f)
	}
}

// SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): an agent's
// sender allow-list, per decision. Each refusal has its control: the same
// frame from the listed member is delivered.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestSenderAllowList(t *testing.T) {
	e, tid, admin, listed, other := senderEnv(t)
	l, o := dialMember(t, e, tid, "", listed), dialMember(t, e, tid, "", other)

	// Decision 2: no list, every member gets through (today's behaviour).
	id := uuidV4()
	wantDelivered(t, e, tid, id, "no list: an unlisted member's @mention", sendFrame(t, o, id, "task", "@CLE-07 run tests", ""))

	// Decision 1: an admin puts listed on CLE-07's list.
	code, body := call(t, e, tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-07@box-a", admin, map[string]any{"members": []string{listed}})
	if code != http.StatusOK || body["agent"] != "CLE-07" {
		t.Fatalf("put list: %d %v", code, body)
	}

	// Decisions 3 + 4: an @mention command, a DM, and an @mention inside the
	// text by the unlisted member are refused; the listed member's same
	// frames are delivered (CONTROL).
	cases := []struct {
		name string
		send func(c *websocket.Conn, id string) map[string]any
	}{
		{"@mention command", func(c *websocket.Conn, id string) map[string]any {
			return sendFrame(t, c, id, "task", "@CLE-07 run tests", "")
		}},
		{"direct message", func(c *websocket.Conn, id string) map[string]any {
			return sendDM(t, c, id, uuidV4(), "CLE-07", 1)
		}},
		{"@mention mid-text", func(c *websocket.Conn, id string) map[string]any {
			return sendFrame(t, c, id, "note", "see this, @CLE-07@box-a", "")
		}},
	}
	for _, tc := range cases {
		id := uuidV4()
		wantRefused(t, e, tid, id, "unlisted "+tc.name, tc.send(o, id))
		cid := uuidV4()
		if f := tc.send(l, cid); f["type"] != "ack" || !stored(t, e, tid, cid) {
			t.Fatalf("CONTROL listed %s: %v", tc.name, f)
		}
	}

	// Decision 3: a post that names no agent is not covered; CONTROL: the
	// same member's post naming the agent was refused above.
	id = uuidV4()
	if f := sendFrame(t, o, id, "note", "hello everyone, mail me at a@CLE-07.example", ""); f["type"] != "ack" || !stored(t, e, tid, id) {
		t.Fatalf("unlisted post without an @mention: %v", f)
	}

	// An empty list is nobody, not everybody.
	if code, body := call(t, e, tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-07", admin, map[string]any{"members": []string{}}); code != http.StatusOK {
		t.Fatalf("empty list: %d %v", code, body)
	}
	id = uuidV4()
	wantRefused(t, e, tid, id, "empty list: the once listed member", sendFrame(t, l, id, "task", "@CLE-07 run tests", ""))

	// GET lists it; DELETE drops it and every member gets through again.
	code, body = call(t, e, tid, http.MethodGet, "/v1/tenant/agent-senders", admin, nil)
	if ls, _ := body["lists"].([]any); code != http.StatusOK || len(ls) != 1 {
		t.Fatalf("get lists: %d %v", code, body)
	}
	if code, body := call(t, e, tid, http.MethodDelete, "/v1/tenant/agent-senders/CLE-07", admin, nil); code != http.StatusNoContent {
		t.Fatalf("delete list: %d %v", code, body)
	}
	id = uuidV4()
	wantDelivered(t, e, tid, id, "list dropped: an unlisted member", sendFrame(t, o, id, "task", "@CLE-07 run tests", ""))
}

// SPL-1018 decision 1: only a workspace admin reads or edits the lists, and
// a list holds members of the workspace only. CONTROL: the admin's own
// valid PUT is 200.
func TestSenderAllowListAdminOnly(t *testing.T) {
	e, tid, admin, listed, _ := senderEnv(t)
	put := map[string]any{"members": []string{listed}}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/tenant/agent-senders", listed, nil); code != http.StatusForbidden {
		t.Fatalf("developer GET: %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-07", listed, put); code != http.StatusForbidden {
		t.Fatalf("developer PUT: %d, want 403", code)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/tenant/agent-senders/CLE-07", listed, nil); code != http.StatusForbidden {
		t.Fatalf("developer DELETE: %d, want 403", code)
	}
	for _, tc := range []struct {
		path string
		body any
		tok  string
	}{
		{"/v1/tenant/agent-senders/CLE-07", map[string]any{"members": []string{"HUM-999999"}}, "not_a_member"},
		{"/v1/tenant/agent-senders/CLE-07", map[string]any{"members": []string{"CLE-08"}}, "bad_members"},
		{"/v1/tenant/agent-senders/CLE-07", map[string]any{}, "bad_members"},
		{"/v1/tenant/agent-senders/HUM-3", put, "bad_agent"},
	} {
		if code, body := call(t, e, tid, http.MethodPut, tc.path, admin, tc.body); code != http.StatusBadRequest || body["error"] != tc.tok {
			t.Fatalf("PUT %s %v: %d %v, want 400 %s", tc.path, tc.body, code, body, tc.tok)
		}
	}
	if code, body := call(t, e, tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-07", admin, put); code != http.StatusOK {
		t.Fatalf("CONTROL admin PUT: %d %v", code, body)
	}
}
