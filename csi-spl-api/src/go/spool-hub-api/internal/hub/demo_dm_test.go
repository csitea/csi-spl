package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// sendDM sends a browser DM (no channel tag) on task; to "" addresses
// nobody, as the topics pane's reply does. Answers the ack or error frame.
func sendDM(t *testing.T, c *websocket.Conn, id, task, to string, isParent int) map[string]any {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": "hello", "is_parent": isParent}
	if to != "" {
		f["to"] = to
	}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	return readType(t, c, "ack")
}

// stored reports whether msg id is a row of tid.
func stored(t *testing.T, e *env, tid, id string) bool {
	t.Helper()
	_, _, err := e.st.MessageTimes(context.Background(), tid, id)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	return err == nil
}

// specs/077 T014 (3.2, Q3): a demo_user's DM goes to demo agents only. A new
// DM to a human, and a reply into a DM topic that has a human end (to a
// human, to an agent or to nobody), answer 403 demo_dm_human and store no
// row. A DM to a demo agent is delivered; a human DMing the visitor, a
// channel post addressed to a human, and real members' DMs are unaffected.
// CONTROL: the same refused frames sent by a developer of the same workspace
// are stored (the refusal is the role's, not the frame's).
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestDemoDMHumanRefused(t *testing.T) {
	e, demo := quotaEnv(t)
	visitor, hum, dev := seat(t, e, demo, rbac.DemoUser), seat(t, e, demo, rbac.Developer), seat(t, e, demo, rbac.Developer)
	v, h, d := dialMember(t, e, demo, "", visitor), dialMember(t, e, demo, "", hum), dialMember(t, e, demo, "", dev)

	humanDM := uuidV4() // a DM topic the human opened with the visitor
	if f := sendDM(t, h, uuidV4(), humanDM, visitor, 1); f["type"] != "ack" {
		t.Fatalf("a human's DM to a demo user: %v", f)
	}
	// spec 117 FR-1: a reply to nobody goes to the DM's one other person, so it
	// runs in a DM only the human and the visitor wrote in, and its control is
	// that human's (a developer's reply to nobody there is dm_needs_to).
	quietDM := uuidV4()
	if f := sendDM(t, h, uuidV4(), quietDM, visitor, 1); f["type"] != "ack" {
		t.Fatalf("a human's second DM to a demo user: %v", f)
	}
	refused := []struct {
		name, task, to string
		isParent       int
		ctl            *websocket.Conn
	}{
		{"new DM to a human", uuidV4(), hum, 1, d},
		{"reply to the human", humanDM, hum, 0, d},
		{"reply to nobody in a human DM", quietDM, "", 0, h},
		{"reply to an agent in a human DM", humanDM, "CLE-07", 0, d},
	}
	for _, tc := range refused {
		id := uuidV4()
		f := sendDM(t, v, id, tc.task, tc.to, tc.isParent)
		if f["type"] != "error" || f["error"] != "demo_dm_human" || f["status"] != float64(http.StatusForbidden) {
			t.Errorf("%s: %v, want 403 demo_dm_human", tc.name, f)
		}
		if stored(t, e, demo, id) {
			t.Errorf("%s: the refused DM was stored", tc.name)
		}
		// CONTROL: a developer's (or the human end's) same frame is stored.
		cid := uuidV4()
		if f := sendDM(t, tc.ctl, cid, tc.task, tc.to, tc.isParent); f["type"] != "ack" || !stored(t, e, demo, cid) {
			t.Errorf("CONTROL %s by a developer: %v", tc.name, f)
		}
	}
	agentDM := uuidV4()
	if f := sendDM(t, v, uuidV4(), agentDM, "CLE-07", 1); f["type"] != "ack" || f["to_box"] != "box-a" {
		t.Fatalf("a demo user's DM to a demo agent: %v", f)
	}
	if f := sendDM(t, v, uuidV4(), agentDM, "", 0); f["type"] != "ack" {
		t.Fatalf("a demo user's reply in its agent DM: %v", f)
	}
	if f := sendFrame(t, v, uuidV4(), "note", "hi all", hum); f["type"] != "ack" {
		t.Fatalf("a demo user's channel post addressed to a human: %v", f)
	}
	if f := sendDM(t, d, uuidV4(), uuidV4(), hum, 1); f["type"] != "ack" {
		t.Fatalf("a developer's DM to a human: %v", f)
	}
}
