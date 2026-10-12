package hub_test

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// Spec 134 P2 (rdb 0183, SPL-1569): the OD pool's ops through the real front
// end (action.Ask == `spool ask`) from two boxes: enqueue with dedupe, the
// pool row's kinds, lock-next from either box, the gen fence (409 ask_held
// naming the holder), the seat release, list --free, needs box:<box> from
// the session's box, the refusals, and the book's ack compare-and-set.

type odAnswer struct {
	Fleet   string       `json:"fleet"`
	Created bool         `json:"created"`
	Asks    []hub.AskRow `json:"asks"`
	Dead    []hub.AskRow `json:"dead"`
	Pool    *struct {
		ClaudeN int      `json:"claude_n"`
		Kinds   []string `json:"kinds"`
	} `json:"pool"`
}

func odCall(t *testing.T, b *box, in action.AskArgs) odAnswer {
	t.Helper()
	in.Hub = b.c
	raw, err := action.Ask(context.Background(), b.cfg, in)
	if err != nil {
		t.Fatalf("ask %+v: %v", in, err)
	}
	var out odAnswer
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

func odRefused(t *testing.T, b *box, in action.AskArgs, want string) {
	t.Helper()
	in.Hub = b.c
	_, err := action.Ask(context.Background(), b.cfg, in)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("%+v: want %q, got %v", in, want, err)
	}
}

func TestBoxOdPoolLockNext(t *testing.T) {
	_, _, _, _, home, sat := boxArchiveRig(t)
	const (
		j1   = "0d000000-0000-4000-8000-000000000001"
		j2   = "0d000000-0000-4000-8000-000000000002"
		j3   = "0d000000-0000-4000-8000-000000000003"
		book = "0e000000-0000-4000-8000-000000000001"
	)
	hs := action.AskArgs{Fleet: "main", Op: "lock-next", Seat: "c-901@box-b", Vendor: "claude"}
	ss := action.AskArgs{Fleet: "main", Op: "lock-next", Seat: "g-902@box-c", Vendor: "grok"}

	enq := action.AskArgs{Fleet: "main", Op: "enqueue", AskID: j1, Kind: "spawn", From: "c-002@box-b", Topic: "dispatch-e799211c",
		IssueKey: "SPL-1569", DedupeKey: "dispatch-e799211c:od-seat"}
	got := odCall(t, home, enq)
	if !got.Created || got.Asks[0].Role != "od" || got.Asks[0].State != "open" || got.Asks[0].LeaseS != 120 || got.Asks[0].IssueKey != "SPL-1569" {
		t.Fatalf("enqueue: %+v", got)
	}
	if got = odCall(t, sat, enq); got.Created {
		t.Fatalf("replay: %+v", got)
	}
	dup := enq
	dup.AskID = j2
	odRefused(t, sat, dup, j1)

	// kinds empty: nothing is locked
	if got = odCall(t, home, hs); len(got.Asks) != 0 {
		t.Fatalf("kinds empty: %+v", got)
	}
	got = odCall(t, home, action.AskArgs{Fleet: "main", Op: "pool", PoolSet: true, By: "c-002@box-b", Pool: map[string]any{"kinds": []string{"spawn"}}})
	if got.Pool == nil || !slices.Equal(got.Pool.Kinds, []string{"spawn"}) || got.Pool.ClaudeN != 2 {
		t.Fatalf("pool set: %+v", got.Pool)
	}
	if got = odCall(t, sat, action.AskArgs{Fleet: "main", Op: "pool"}); got.Pool == nil || !slices.Equal(got.Pool.Kinds, []string{"spawn"}) {
		t.Fatalf("pool read from the other box: %+v", got.Pool)
	}

	// lock from one box; the other box gets nothing; the free list is empty
	got = odCall(t, home, hs)
	if len(got.Asks) != 1 || got.Asks[0].AckedBy != "c-901@box-b" || got.Asks[0].Gen != 1 || got.Asks[0].LockUntil == "" {
		t.Fatalf("lock-next: %+v", got)
	}
	if got = odCall(t, sat, ss); len(got.Asks) != 0 {
		t.Fatalf("a locked job was locked again: %+v", got)
	}
	if got = odCall(t, sat, action.AskArgs{Fleet: "main", Role: "od", Free: true}); len(got.Asks) != 0 {
		t.Fatalf("free while locked: %+v", got)
	}
	// the gen fence: another seat, or the holder off its gen, is 409 naming the holder
	odRefused(t, sat, action.AskArgs{Fleet: "main", Op: "done", AskID: j1, By: "g-902@box-c", Gen: 1}, "c-901@box-b at gen 1")
	odRefused(t, home, action.AskArgs{Fleet: "main", Op: "renew", AskID: j1, By: "c-901@box-b", Gen: 7}, "ask_held")
	if got = odCall(t, home, action.AskArgs{Fleet: "main", Op: "renew", AskID: j1, By: "c-901@box-b", Gen: 1}); got.Asks[0].Gen != 1 {
		t.Fatalf("renew: %+v", got)
	}
	// the book's ops do not apply to an od job
	odRefused(t, sat, action.AskArgs{Fleet: "main", Op: "ack", AskID: j1, By: "g-902@box-c"}, "ask_op_refused")

	// the seat release (the kill): free again, gen 2; the old gen is fenced
	if got = odCall(t, home, action.AskArgs{Fleet: "main", Op: "release", By: "c-901@box-b"}); len(got.Asks) != 1 || got.Asks[0].State != "open" || got.Asks[0].Gen != 2 {
		t.Fatalf("release seat: %+v", got)
	}
	if got = odCall(t, sat, action.AskArgs{Fleet: "main", Role: "od", Free: true}); len(got.Asks) != 1 || got.Asks[0].AskID != j1 {
		t.Fatalf("free after release: %+v", got)
	}
	odRefused(t, home, action.AskArgs{Fleet: "main", Op: "renew", AskID: j1, By: "c-901@box-b", Gen: 1}, "the lock was lost")
	got = odCall(t, sat, ss)
	if len(got.Asks) != 1 || got.Asks[0].AckedBy != "g-902@box-c" || got.Asks[0].Gen != 3 {
		t.Fatalf("the other vendor locks it: %+v", got)
	}
	if got = odCall(t, sat, action.AskArgs{Fleet: "main", Op: "done", AskID: j1, By: "g-902@box-c", Gen: 3, Reason: "lane placed"}); got.Asks[0].State != "done" {
		t.Fatalf("done: %+v", got)
	}

	// needs box:<box> follows the session's box, not the caller's word
	odCall(t, home, action.AskArgs{Fleet: "main", Op: "enqueue", AskID: j3, Kind: "spawn", From: "c-002@box-b", Needs: "box:box-b"})
	if got = odCall(t, sat, ss); len(got.Asks) != 0 {
		t.Fatalf("needs box:box-b locked from box-c: %+v", got)
	}
	if _, err := sat.c.Ask(context.Background(), "lock-next", "main", json.RawMessage(`{"seat":"g-902@box-c","vendor":"grok","caps":["box:box-b"]}`)); err == nil {
		t.Fatal("hub accepted a box cap from the caller")
	}
	if got = odCall(t, home, hs); len(got.Asks) != 1 || got.Asks[0].AskID != j3 {
		t.Fatalf("needs box:box-b from box-b: %+v", got)
	}
	// a needs_owner job is never locked; reopen makes it lockable
	odCall(t, home, action.AskArgs{Fleet: "main", Op: "enqueue", AskID: j2, Kind: "spawn", From: "c-002@box-b", NeedsOwner: true})
	if got = odCall(t, sat, ss); len(got.Asks) != 0 {
		t.Fatalf("needs_owner locked: %+v", got)
	}
	odCall(t, home, action.AskArgs{Fleet: "main", Op: "reopen", AskID: j2, By: "c-002@box-b"})
	if got = odCall(t, sat, ss); len(got.Asks) != 1 || got.Asks[0].AskID != j2 {
		t.Fatalf("reopened: %+v", got)
	}

	// refusals: the client checks, and the hub checks a raw frame too
	for _, in := range []action.AskArgs{
		{Fleet: "main", Op: "enqueue", AskID: j2, Kind: "task", From: "c-002"},
		{Fleet: "main", Op: "enqueue", AskID: j2, Kind: "spawn", From: "c-002", Needs: "gpu"},
		{Fleet: "main", Op: "put", Role: "od", AskID: j2, Kind: "task", From: "c-002"},
		{Fleet: "main", Op: "lock-next", Seat: "c-901@box-b"},
		{Fleet: "main", Op: "lock-next", Seat: "c-901@box-b", Vendor: "claude", Caps: []string{"box:box-c"}},
		{Fleet: "main", Op: "list", Role: "orch", Free: true},
		{Fleet: "main", Op: "release"},
	} {
		in.Hub = home.c
		if _, err := action.Ask(context.Background(), home.cfg, in); err == nil {
			t.Fatalf("accepted %+v", in)
		}
	}
	for op, body := range map[string]string{
		"enqueue": `{"ask_id":"` + j2 + `","kind":"blocker","from":"c-002"}`,
		"put":     `{"ask_id":"` + j2 + `","role":"od","kind":"task","from":"c-002"}`,
		"pool":    `{"set":true,"by":"c-002","kinds":["task"]}`,
		"release": `{"ask_id":"` + j2 + `","by":"c-002","gen":1,"refuse":"Not A Harness"}`,
	} {
		if _, err := home.c.Ask(context.Background(), op, "main", json.RawMessage(body)); err == nil {
			t.Fatalf("hub accepted %s %s", op, body)
		}
	}

	// the book's ack compare-and-set: a second seat's ack is 409 naming the holder
	odCall(t, home, action.AskArgs{Fleet: "main", Op: "put", AskID: book, Kind: "task", From: "c-002@box-b"})
	odCall(t, home, action.AskArgs{Fleet: "main", Op: "ack", AskID: book, By: "c-001@box-b"})
	odRefused(t, sat, action.AskArgs{Fleet: "main", Op: "ack", AskID: book, By: "c-001@box-c"}, "held by c-001@box-b")
	if got = odCall(t, sat, action.AskArgs{Fleet: "main", Role: "orch"}); len(got.Asks) != 1 || got.Asks[0].AckedBy != "c-001@box-b" {
		t.Fatalf("the holder was replaced: %+v", got)
	}
}
