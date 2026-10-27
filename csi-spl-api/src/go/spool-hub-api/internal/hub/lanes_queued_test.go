package hub_test

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 v1.3 section 3.8 (SPL-3818; owner HUM-10, csitea a1ae72a7 msgs
// 80e92ffb + a6c87420, t1 f94e07bf msg 67c63b8d): a queued spawn ask is a
// Lanes row, and every row names its workspace. Memory, and Postgres under
// SPOOL_TEST_PG_DSN. RED CONTROL (master 2d74bdd49): C40 and C41 fail, no
// route lists an ask; C42 fails, no row has a workspace.

// queueAsk records an ask of the operator workspace on topic and queues it
// with placement, at minutes ago.
func queueAsk(t *testing.T, r *wsLanesRig, topic, summary, placement string, ago time.Duration) {
	t.Helper()
	ctx, id, box := context.Background(), uid.New(), r.opBox.id
	at := time.Now().Add(-ago)
	if _, _, err := r.e.st.PutFleetAsk(ctx, r.op, store.FleetAsk{Fleet: "main", AskID: id, Role: "orch", Kind: "task",
		From: "c-002@" + box, Topic: topic, Summary: summary}, box, at); err != nil {
		t.Fatalf("ask %s: %v", summary, err)
	}
	if placement == "" {
		return // stays open: not queued
	}
	if _, err := r.e.st.UpdateFleetAsk(ctx, r.op, store.AskUpdate{Fleet: "main", AskID: id, Op: store.AskQueue,
		By: "c-001@" + box, Placement: placement, Class: "bug"}, box, at.Add(time.Second)); err != nil {
		t.Fatalf("queue %s: %v", summary, err)
	}
}

// scopes is the view's rows as "<state> <agent or scope> <workspace>".
func scopes(v lanesView) []string {
	out := []string{}
	for _, l := range v.Lanes {
		who := l.AgentID
		if l.State == "queued" {
			who = l.Scope
		}
		out = append(out, l.State+" "+who+" "+l.Workspace)
	}
	return out
}

// C40, C41, C42.
func TestLanesQueuedAsk(t *testing.T) {
	r := newWSLanesRig(t)
	now := time.Now()
	box := r.opBox.id
	queueAsk(t, r, "dispatch-"+r.t1[:8], "QUEUE w1 lane", "claude:c002-w1-lane", 30*time.Minute) // C40
	queueAsk(t, r, "gc-sat", "QUEUE no topic", "mistral:c001-gc", 20*time.Minute)                // C41
	queueAsk(t, r, r.t2, "QUEUE w2 lane", "agy:c002-w2-lane", 10*time.Minute)                    // C40 twin
	queueAsk(t, r, r.t1, "OPEN not queued", "", 5*time.Minute)                                   // an open ask is no row
	laneAt(t, r.fleetTokensRig, "c-521", box, r.t1, "SPL-2", now.Add(-1*time.Minute))            // C42: a w1 lane
	laneAt(t, r.fleetTokensRig, "c-522", box, "", "SPL-3", now.Add(-2*time.Minute))              // C42: no topic

	// C40: w1's admin sees its live lane, then the ask queued on dispatch-<w1 topic>.
	v, raw := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK)
	if got, want := scopes(v), []string{"live c-521 " + r.w1, "queued QUEUE w1 lane " + r.w1}; !slices.Equal(got, want) {
		t.Errorf("C40 w1 admin rows %v, want %v", got, want)
	}
	for _, l := range v.Lanes {
		if l.TopicID != r.t1 || l.TopicTitle != "W1 build" || l.AgentBox != "" || l.WorkspaceName == "" {
			t.Errorf("C40 row: %+v", l)
		}
		if l.State == "queued" && (l.AgentID != "" || l.Vendor != "claude" || l.Wait != "" || l.UpdatedAt == "") {
			t.Errorf("C40 queued row: %+v", l)
		}
	}
	for _, leak := range []string{"QUEUE no topic", "QUEUE w2 lane", "OPEN not queued", "c002-w1-lane", box} {
		if strings.Contains(raw, leak) {
			t.Errorf("C40: %q in w1's answer: %s", leak, raw)
		}
	}
	// C40 twin: w2's admin sees the w2 ask only.
	if v, _ := wsLanes(t, r, r.w2, r.w2Admin, http.StatusOK); !slices.Equal(scopes(v), []string{"queued QUEUE w2 lane " + r.w2}) {
		t.Errorf("C40 twin w2 admin rows %v", scopes(v))
	}

	// C41, C42: the operator sees the lanes, then every queued ask in queue
	// order; each row names the workspace holding its topic, else the operator's.
	op := getLanes(t, r.fleetTokensRig)
	want := []string{"live c-521 " + r.w1, "live c-522 " + r.op,
		"queued QUEUE w1 lane " + r.w1, "queued QUEUE no topic " + r.op, "queued QUEUE w2 lane " + r.w2}
	if got := scopes(op); !slices.Equal(got, want) {
		t.Errorf("C41/C42 operator rows %v, want %v", got, want)
	}
	for _, l := range op.Lanes {
		if l.WorkspaceName == "" || (l.State == "queued" && l.Vendor == "") {
			t.Errorf("C42 operator row: %+v", l)
		}
	}
	if got := issuesOf(t, op, "c-522"); len(got) != 1 || !strings.HasPrefix(got[0], "SPL-3") {
		t.Errorf("C42: the no-topic lane keeps its own key, got %v", got)
	}
}
