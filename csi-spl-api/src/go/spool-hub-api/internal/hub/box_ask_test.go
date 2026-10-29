package hub_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// CLE-77929 (owner bug t1 2f7996aa): asks to the orchestrator survive the
// orchestrator. Two machines' boxes share one ask book through the real
// front end (action.Ask == `spool ask`):
//
//  1. a lane on the home box records a blocker (fire and forget)
//  2. the home orchestrator lists it - it HAS received it - and dies before
//     acking: no ack, no close, its inbox file is on a disk nobody reads
//  3. the successor on the other machine starts, lists the open asks and
//     gets it; the tick's re-raise counts; it acks and closes it with a reason
//  4. the dead holder's late close is refused with who closed it and why

type askOut struct {
	Fleet   string       `json:"fleet"`
	Created bool         `json:"created"`
	Asks    []hub.AskRow `json:"asks"`
}

func askCall(t *testing.T, b *box, in action.AskArgs) askOut {
	t.Helper()
	in.Hub = b.c
	raw, err := action.Ask(context.Background(), b.cfg, in)
	if err != nil {
		t.Fatalf("ask %+v: %v", in, err)
	}
	var out askOut
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

func TestBoxFleetAskSurvivesTheOrchestrator(t *testing.T) {
	e, tid, _, _, home, sat := boxArchiveRig(t)
	const id = "39451306-8830-4e8e-878c-eb29f2803839"

	if got := askCall(t, home, action.AskArgs{Fleet: "main"}); got.Fleet != "main" || len(got.Asks) != 0 {
		t.Fatalf("empty book: %+v", got)
	}
	// 1. fire and forget; a replay of the same msg id is a no-op
	put := action.AskArgs{Fleet: "main", Op: "put", AskID: id, Kind: "blocker", From: "CLE-002@box-b",
		Topic: "692aefe8", Summary: "t1 692aefe8 has had no lane for 6 h", Deadline: "2026-10-02T02:30:00Z"}
	got := askCall(t, home, put)
	if !got.Created || len(got.Asks) != 1 || got.Asks[0].State != "open" || got.Asks[0].Role != "orch" || got.Asks[0].WriterBox != "box-b" || got.Asks[0].DeadlineAt != "2026-10-02T02:30:00Z" {
		t.Fatalf("put: %+v", got)
	}
	if got = askCall(t, sat, put); got.Created || got.Asks[0].WriterBox != "box-b" {
		t.Fatalf("replay changed the ask: %+v", got)
	}

	// another role's topic stays out of the orchestrator's list
	askCall(t, home, action.AskArgs{Fleet: "main", Op: "put", Role: "dispatch", AskID: "22222222-2222-4222-8222-222222222222", Kind: "task", From: "CLE-001@box-b"})
	if got = askCall(t, sat, action.AskArgs{Fleet: "main", Role: "dispatch"}); len(got.Asks) != 1 || got.Asks[0].Role != "dispatch" {
		t.Fatalf("dispatch topic: %+v", got)
	}
	askCall(t, sat, action.AskArgs{Fleet: "main", Op: "done", AskID: "22222222-2222-4222-8222-222222222222", By: "CLE-002@box-c"})

	// 2. the home orchestrator receives it ... and dies before acking
	if got = askCall(t, home, action.AskArgs{Fleet: "main", Op: "list", Role: "orch"}); len(got.Asks) != 1 || got.Asks[0].AskID != id {
		t.Fatalf("home holder's list: %+v", got)
	}

	// 3. the successor on the other machine gets it on start
	got = askCall(t, sat, action.AskArgs{Fleet: "main", Role: "orch"})
	if len(got.Asks) != 1 || got.Asks[0].AskID != id || got.Asks[0].State != "open" || got.Asks[0].From != "CLE-002@box-b" {
		t.Fatalf("successor's list: %+v", got)
	}
	if got = askCall(t, sat, action.AskArgs{Fleet: "main", Op: "raise", AskID: id, By: "CLE-001@box-c"}); got.Asks[0].RaisedN != 1 || got.Asks[0].RaisedAt == "" {
		t.Fatalf("raise: %+v", got)
	}
	if got = askCall(t, sat, action.AskArgs{Fleet: "main", Op: "ack", AskID: id, By: "CLE-001@box-c"}); got.Asks[0].State != "acked" || got.Asks[0].AckedBy != "CLE-001@box-c" || got.Asks[0].WriterBox != "box-c" {
		t.Fatalf("ack: %+v", got)
	}
	if got = askCall(t, sat, action.AskArgs{Fleet: "main", Op: "done", AskID: id, By: "CLE-001@box-c", Reason: "given to CLE-77915"}); got.Asks[0].State != "done" {
		t.Fatalf("done: %+v", got)
	}
	if got = askCall(t, home, action.AskArgs{Fleet: "main"}); len(got.Asks) != 0 {
		t.Fatalf("a closed ask is still open: %+v", got)
	}
	if got = askCall(t, home, action.AskArgs{Fleet: "main", Role: "orch", All: true}); len(got.Asks) != 1 || got.Asks[0].ClosedBy != "CLE-001@box-c" {
		t.Fatalf("all: %+v", got)
	}

	// 4. the dead holder's late close is refused, naming the closer
	_, err := action.Ask(context.Background(), home.cfg, action.AskArgs{Fleet: "main", Op: "decline", AskID: id, By: "CLE-001@box-b", Reason: "late", Hub: home.c})
	if err == nil || !strings.Contains(err.Error(), "CLE-001@box-c") || !strings.Contains(err.Error(), "given to CLE-77915") {
		t.Fatalf("late close: %v", err)
	}

	// refusals: the client checks, and the hub checks a raw frame too
	for _, in := range []action.AskArgs{
		{Fleet: "Main"},
		{Fleet: "main", Op: "put", AskID: "x", Kind: "blocker", From: "CLE-1"},
		{Fleet: "main", Op: "put", AskID: id, Kind: "note", From: "CLE-1"},
		{Fleet: "main", Op: "put", AskID: id, Kind: "task", From: "CLE-1", Deadline: "tomorrow"},
		{Fleet: "main", Op: "decline", AskID: id, By: "CLE-001"},
		{Fleet: "main", Op: "ack", AskID: id, By: ""},
		{Fleet: "main", Op: "drop", AskID: id, By: "CLE-001"},
	} {
		in.Hub = home.c
		if _, err := action.Ask(context.Background(), home.cfg, in); err == nil {
			t.Fatalf("accepted %+v", in)
		}
	}
	for op, body := range map[string]string{
		"drop":    `{"ask_id":"` + id + `","by":"CLE-001"}`,
		"put":     `{"ask_id":"` + id + `","kind":"note","from":"CLE-1"}`,
		"ack":     `{"ask_id":"` + strings.Repeat("0", 36) + `","by":"CLE-001"}`,
		"decline": `"not an object"`,
	} {
		if _, err := home.c.Ask(context.Background(), op, "main", json.RawMessage(body)); err == nil {
			t.Fatalf("hub accepted %s %s", op, body)
		}
	}
	if _, err := home.c.Ask(context.Background(), "ack", "main", json.RawMessage(`{"ask_id":"00000000-0000-4000-8000-000000000000","by":"CLE-001"}`)); err == nil || !strings.Contains(err.Error(), "unknown_ask") {
		t.Fatalf("unknown ask: %v", err)
	}
	if as, _ := e.st.ListFleetAsks(context.Background(), tid, "main", "", true, time.Now()); len(as) != 2 {
		t.Fatalf("a refusal wrote: %+v", as)
	}
}

// CLE-77942: the share-group deltas through the real front end. The home
// holder acquires an ask and dies; the successor's tick on the other machine
// releases the expired lock (acked -> open, the last holder kept) and later
// dead-letters another ask with its reason; a dead-letter without a reason is
// refused by the client and by the hub; a late op on a dead ask names it.
func TestBoxFleetAskLockReleaseAndDeadLetter(t *testing.T) {
	_, _, _, _, home, sat := boxArchiveRig(t)
	const (
		id   = "5f0c6a2e-1d7b-4c8e-9a3f-2b6d8e1f4a70"
		dead = "6a1d7b3f-2e8c-4d9f-8b4a-3c7e9f2a5b81"
	)
	for _, a := range []string{id, dead} {
		askCall(t, home, action.AskArgs{Fleet: "main", Op: "put", AskID: a, Kind: "blocker", From: "CLE-002@box-b"})
	}
	askCall(t, home, action.AskArgs{Fleet: "main", Op: "ack", AskID: id, By: "CLE-001@box-b"})
	got := askCall(t, sat, action.AskArgs{Fleet: "main", Op: "release", AskID: id, By: "CLE-001@box-c"})
	if got.Asks[0].State != "open" || got.Asks[0].AckedBy != "CLE-001@box-b" || got.Asks[0].WriterBox != "box-c" {
		t.Fatalf("release: %+v", got)
	}
	if _, err := action.Ask(context.Background(), sat.cfg, action.AskArgs{Fleet: "main", Op: "dead", AskID: dead, By: "CLE-001@box-c", Hub: sat.c}); err == nil {
		t.Fatal("the client took a dead-letter without a reason")
	}
	if _, err := sat.c.Ask(context.Background(), "dead", "main", json.RawMessage(`{"ask_id":"`+dead+`","by":"CLE-001@box-c"}`)); err == nil {
		t.Fatal("the hub took a dead-letter without a reason")
	}
	const why = "max delivery count 4 reached; the owner was told"
	if got = askCall(t, sat, action.AskArgs{Fleet: "main", Op: "dead", AskID: dead, By: "CLE-001@box-c", Reason: why}); got.Asks[0].State != "dead" || got.Asks[0].Reason != why {
		t.Fatalf("dead: %+v", got)
	}
	_, err := action.Ask(context.Background(), home.cfg, action.AskArgs{Fleet: "main", Op: "ack", AskID: dead, By: "CLE-001@box-b", Hub: home.c})
	if err == nil || !strings.Contains(err.Error(), "already dead by CLE-001@box-c") {
		t.Fatalf("ack on a dead ask: %v", err)
	}
	if got = askCall(t, home, action.AskArgs{Fleet: "main", Role: "orch"}); len(got.Asks) != 1 || got.Asks[0].AskID != id {
		t.Fatalf("the open list: %+v", got)
	}
}

// rdb 0180 (owner HUM-10, t1 c9beaa77): the enqueue answer carries the
// position the sender is told ("position N of M"); the placer's ack of the
// head moves the next one up; a bad placement is refused before dialling.
func TestBoxFleetAskQueuePosition(t *testing.T) {
	_, _, _, _, home, sat := boxArchiveRig(t)
	const (
		a1 = "a1a1a1a1-0000-4000-8000-000000000001"
		a2 = "a2a2a2a2-0000-4000-8000-000000000002"
	)
	for _, id := range []string{a1, a2} {
		askCall(t, home, action.AskArgs{Fleet: "main", Op: "put", AskID: id, Kind: "task", From: "c-002@box-b", Summary: "SPAWN REQUEST " + id[:2]})
	}
	_, err := action.Ask(context.Background(), sat.cfg, action.AskArgs{Fleet: "main", Op: "queue", AskID: a1, By: "c-001@box-c", Hub: sat.c})
	if err == nil || !strings.Contains(err.Error(), "class") {
		t.Fatalf("a queue with no class (rdb 0195): %v", err)
	}
	got := askCall(t, sat, action.AskArgs{Fleet: "main", Op: "queue", AskID: a1, By: "c-001@box-c", Place: "claude:hub-pg-split", Class: "bug"})
	if r := got.Asks[0]; r.State != "queued" || r.Position != 1 || r.QueueLen != 1 || r.Placement != "claude:hub-pg-split" || r.EnqueuedAt == "" || r.Class != "bug" {
		t.Fatalf("queue a1: %+v", r)
	}
	if r := askCall(t, sat, action.AskArgs{Fleet: "main", Op: "queue", AskID: a2, By: "c-001@box-c", Class: "feature"}).Asks[0]; r.Position != 2 || r.QueueLen != 2 || r.Placement != "" {
		t.Fatalf("queue a2: %+v", r)
	}
	// SPL-1817: a later refactor row goes ahead of the older bug (FIFO would not)
	const a3 = "a3a3a3a3-0000-4000-8000-000000000003"
	askCall(t, home, action.AskArgs{Fleet: "main", Op: "put", AskID: a3, Kind: "task", From: "c-002@box-b", Summary: "SPAWN REQUEST a3"})
	if r := askCall(t, sat, action.AskArgs{Fleet: "main", Op: "queue", AskID: a3, By: "c-001@box-c", Class: "refactor"}).Asks[0]; r.Position != 1 || r.QueueLen != 3 {
		t.Fatalf("queue a3 refactor: %+v", r)
	}
	askCall(t, sat, action.AskArgs{Fleet: "main", Op: "ack", AskID: a3, By: "c-001@box-c"})
	askCall(t, sat, action.AskArgs{Fleet: "main", Op: "ack", AskID: a1, By: "c-001@box-c"})
	for _, r := range askCall(t, home, action.AskArgs{Fleet: "main", Role: "orch"}).Asks {
		if r.AskID == a2 && (r.Position != 1 || r.QueueLen != 1) || r.AskID == a1 && (r.State != "acked" || r.Position != 0) {
			t.Fatalf("after the head left: %+v", r)
		}
	}
	_, err = action.Ask(context.Background(), sat.cfg, action.AskArgs{Fleet: "main", Op: "queue", AskID: a2, By: "c-001@box-c", Place: "claude:x;rm", Hub: sat.c})
	if err == nil || !strings.Contains(err.Error(), "placement") {
		t.Fatalf("a bad placement: %v", err)
	}
}

// C404, spec 150 row B9 (rdb 0241, SPL-4193; panel F3): the hub sets an
// ask's discussion when it writes it. A topic dispatch-<topic8> that starts
// exactly one topic of the workspace resolves to it; two matches leave it
// empty (CONTROL: take the first match), as do no match and a topic of
// another shape. A discussion the caller sends wins over the resolve and is
// refused unless it is a uuid. The list carries the discussion's priority.
func TestBoxFleetAskDiscussionResolve(t *testing.T) {
	e, tid, _, _, home, _ := boxArchiveRig(t)
	ctx := context.Background()
	const (
		one   = "c4040001-0000-4000-8000-000000000001"
		twoA  = "c4040002-0000-4000-8000-00000000000a"
		twoB  = "c4040002-0000-4000-8000-00000000000b"
		other = "d4040003-0000-4000-8000-000000000003"
	)
	for _, task := range []string{one, twoA, twoB, other} {
		putCard(t, e, tid, task, "", "HUM-10", hub.WUIBox, 1, time.Now().UTC())
	}
	put := func(askID, topic string) hub.AskRow {
		t.Helper()
		got := askCall(t, home, action.AskArgs{Fleet: "main", Op: "put", AskID: askID, Kind: "task", From: "c-002@box-b", Topic: topic, Summary: "SPAWN REQUEST"})
		if len(got.Asks) != 1 {
			t.Fatalf("put %s: %+v", topic, got)
		}
		return got.Asks[0]
	}
	for topic, want := range map[string]string{
		"dispatch-c4040001": one, // one match
		"dispatch-c4040002": "",  // two matches: never guessed
		"dispatch-e4040004": "",  // no match
		"c4040001":          "",  // not dispatch-<topic8>
	} {
		id := uuidV4()
		if r := put(id, topic); r.Discussion != want {
			t.Errorf("topic %s: discussion %q, want %q", topic, r.Discussion, want)
		}
		if as, _ := e.st.ListFleetAsks(ctx, tid, "main", "orch", false, time.Now()); !hasAskDiscussion(as, id, want) {
			t.Errorf("topic %s: stored discussion is not %q", topic, want)
		}
	}

	// the caller's discussion wins over the topic's resolve
	raw := `{"ask_id":"` + uuidV4() + `","kind":"task","from":"c-002@box-b","topic":"dispatch-c4040001","discussion":"` + strings.ToUpper(other) + `"}`
	ans, err := home.c.Ask(ctx, "put", "main", json.RawMessage(raw))
	var out askOut
	if err != nil || json.Unmarshal(ans, &out) != nil || len(out.Asks) != 1 || out.Asks[0].Discussion != other {
		t.Fatalf("explicit discussion: %s %v", ans, err)
	}
	bad := `{"ask_id":"` + uuidV4() + `","kind":"task","from":"c-002@box-b","topic":"x","discussion":"c4040001"}`
	if _, err := home.c.Ask(ctx, "put", "main", json.RawMessage(bad)); err == nil || !strings.Contains(err.Error(), "discussion") {
		t.Fatalf("a short discussion id was accepted: %v", err)
	}

	// the list carries the discussion's priority, 5 without one
	if _, err := e.st.(store.TopicPriorityStore).SetTopicPriority(ctx, tid, one, 2, "HUM-10", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, r := range askCall(t, home, action.AskArgs{Fleet: "main", Role: "orch"}).Asks {
		want := 5
		if r.Discussion == one {
			want = 2
		}
		if r.Priority != want {
			t.Fatalf("priority of %s (discussion %q): %d, want %d", r.AskID, r.Discussion, r.Priority, want)
		}
	}
}

func hasAskDiscussion(as []store.FleetAsk, askID, want string) bool {
	for _, a := range as {
		if a.AskID == askID {
			return a.Discussion == want
		}
	}
	return false
}
