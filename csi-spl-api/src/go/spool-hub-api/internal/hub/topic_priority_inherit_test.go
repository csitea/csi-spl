package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-5147 (ruling c-001 8ae0ff4e): the agent issue op inherit-priority. A
// follow-up discussion takes its archived parent's stored priority: same
// workspace only, the source archived and the target live, no parent row = no
// write, a priority the target has is kept.
// RED CONTROLS: without the archived check "source is live" writes; without
// the live check "target archived" writes; a hub that falls back to the
// default answers inherited for "parent has none".

// inherit runs the op from a box of tid; its answer, or the hub's refusal.
func inherit(t *testing.T, r *fleetTokensRig, tid, from, to string) (map[string]any, error) {
	t.Helper()
	ctx := context.Background()
	b := r.e.box(tid, "box-"+newTenantID(""), "CLE-07")
	r.e.pin(tid, b)
	sa, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	raw, err := action.Issue(ctx, b.cfg, action.IssueArgs{Op: "inherit-priority", As: "CLE-07", Query: "from=" + from + "&to=" + to, Hub: b.c})
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("reply %s: %v", raw, err)
	}
	return out, nil
}

// archiveTopic archives a topic's opening card (lobbyTopic: its msg id is the task).
func archiveTopic(t *testing.T, r *fleetTokensRig, tid, task string) {
	t.Helper()
	if _, err := r.e.st.SetArchived(context.Background(), tid, task, r.admin, time.Now().UTC(), true); err != nil {
		t.Fatalf("archive %s: %v", task, err)
	}
}

func TestInheritPriorityOp(t *testing.T) {
	r := newFleetTokensRig(t)
	topic := func(tid string) string {
		id := uid.New()
		lobbyTopic(t, r.e, tid, id, "## Topic\n\nrow")
		return id
	}
	setP := func(tid, task string, p int) {
		t.Helper()
		if code, out := putPriority(t, r.e, tid, task, r.admin, map[string]any{"priority": p}); code != http.StatusOK {
			t.Fatalf("PUT %d: %d %v", p, code, out)
		}
	}
	refused := func(name string, err error, token string) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), token) {
			t.Errorf("%s: err %v, want a refusal %q", name, err, token)
		}
	}
	unset := func(name, tid, task string) {
		t.Helper()
		if got := storedPriority(t, r.e, tid, task); got != 3 {
			t.Errorf("%s: target reads %d, want the unset 3", name, got)
		}
	}

	parent, follow := topic(r.op), topic(r.op)
	setP(r.op, parent, 2)
	archiveTopic(t, r, r.op, parent)
	out, err := inherit(t, r, r.op, parent, follow)
	if err != nil || out["inherited"] != true || out["priority"] != float64(2) {
		t.Fatalf("parent at 2: %v %v, want inherited 2", out, err)
	}
	if got := storedPriority(t, r.e, r.op, follow); got != 2 {
		t.Errorf("parent at 2: follow-up reads %d, want 2", got)
	}

	none, follow2 := topic(r.op), topic(r.op)
	archiveTopic(t, r, r.op, none)
	out, err = inherit(t, r, r.op, none, follow2)
	if err != nil || out["inherited"] != false || out["reason"] != "source_has_no_priority" {
		t.Errorf("parent has none: %v %v, want no write", out, err)
	}
	unset("parent has none", r.op, follow2)

	kept := topic(r.op)
	setP(r.op, kept, 4)
	out, err = inherit(t, r, r.op, parent, kept)
	if err != nil || out["inherited"] != false || out["reason"] != "target_already_set" {
		t.Errorf("target already set: %v %v", out, err)
	}
	if got := storedPriority(t, r.e, r.op, kept); got != 4 {
		t.Errorf("target already set: reads %d, want its own 4", got)
	}

	live, follow3 := topic(r.op), topic(r.op)
	setP(r.op, live, 1)
	_, err = inherit(t, r, r.op, live, follow3)
	refused("source is live", err, "source_not_archived")
	unset("source is live", r.op, follow3)

	gone := topic(r.op)
	archiveTopic(t, r, r.op, gone)
	_, err = inherit(t, r, r.op, parent, gone)
	refused("target archived", err, "target_not_live")

	_, err = inherit(t, r, r.op, parent, uid.New())
	refused("target unknown", err, "not_found")

	follow4 := topic(r.op)
	far := topic(r.other)
	setP2 := func() {
		if code, o := putPriority(t, r.e, r.other, far, r.otherA, map[string]any{"priority": 1}); code != http.StatusOK {
			t.Fatalf("PUT far: %d %v", code, o)
		}
	}
	setP2()
	archiveTopic(t, r, r.other, far)
	_, err = inherit(t, r, r.op, far, follow4)
	refused("source of another workspace", err, "source_not_archived")
	unset("source of another workspace", r.op, follow4)

	_, err = inherit(t, r, r.op, parent, parent)
	refused("same topic", err, "bad_issue")
	_, err = inherit(t, r, r.op, "not-a-uuid", follow4)
	refused("bad id", err, "bad_issue")
}
