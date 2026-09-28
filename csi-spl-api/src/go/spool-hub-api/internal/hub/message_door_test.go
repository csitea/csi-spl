package hub_test

import (
	"net/http"
	"testing"
	"time"
)

// edit, delete and reactions ask the per-message read door FIRST.
// A DM between HUM-2 and CLE-07, in a topic that also holds a #lobby post
// (so the TOPIC door lets HUM-1 in): HUM-1's edit and delete answered 403
// not_author - confirming a message a missing id answers 404 for - and a
// reaction went through on a DM HUM-1 cannot read. Each is now the 404 of a
// missing id, and nothing is written. CONTROL: HUM-2, an end of the DM,
// reacts to it.
func TestMessageDoorBeforeAuthorGate(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	task := uuidV4()
	putMsg(t, e.st, tid, task, "lobby", "CLE-07", "box-b", "ALL-0", "lobby hello", now.Add(-2*time.Minute), "")
	dm := putMsg(t, e.st, tid, task, "", "HUM-2", "box-wui", "CLE-07", "salary figures", now.Add(-time.Minute), "")

	if code, out := patchEdit(t, e, tid, dm.MsgID, "HUM-1", map[string]string{"body": "x"}); code != http.StatusNotFound || out["error"] != "not_found" {
		t.Fatalf("HUM-1 edits HUM-2's DM: %d %v (want 404 not_found)", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+dm.MsgID, "HUM-1", nil); code != http.StatusNotFound || out["error"] != "not_found" {
		t.Fatalf("HUM-1 deletes HUM-2's DM: %d %v (want 404 not_found)", code, out)
	}
	if code, out := putReaction(t, e, tid, dm.MsgID, "HUM-1", "👍"); code != http.StatusNotFound {
		t.Fatalf("HUM-1 reacts to HUM-2's DM: %d %v (want 404)", code, out)
	}
	if rs, _ := e.st.ReactionsFor(t.Context(), tid, []string{dm.MsgID}); len(rs[dm.MsgID]) != 0 {
		t.Fatalf("a refused reaction was stored: %+v", rs)
	}
	if code, out := putReaction(t, e, tid, dm.MsgID, "HUM-2", "👍"); code != http.StatusOK {
		t.Fatalf("CONTROL: HUM-2 reacts to their own DM: %d %v", code, out)
	}
}
