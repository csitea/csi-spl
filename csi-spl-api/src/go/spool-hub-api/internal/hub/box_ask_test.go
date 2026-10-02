package hub_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
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
