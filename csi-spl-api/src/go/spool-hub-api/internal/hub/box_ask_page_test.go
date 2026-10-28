package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4018: on prd `spool ask list --all` failed with "hub unreachable:
// socket closed": 1644 asks, ~1.56 MB in one frame, past the CLI's 1 MiB
// read limit, so every ask-book read fell back to a machine's journal. A
// week of closed asks well past 1 MiB now answers in full through the real
// socket: the hub pages it, the CLI follows every page. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). RED CONTROL (master): the
// list fails with "hub unreachable: socket closed".
func TestBoxFleetAskListAllPastTheFrameLimit(t *testing.T) {
	e, tid, _, _, home, _ := boxArchiveRig(t)
	ctx, now := context.Background(), time.Now().UTC()
	const n = 1400
	pad := strings.Repeat("x", 440)
	for i := 0; i < n; i++ {
		a := store.FleetAsk{Fleet: "main", AskID: fmt.Sprintf("%08x-0000-4000-8000-%012x", i, i), Role: "orch", Kind: "task",
			From: "c-002@box-b", Topic: "dispatch-5e7b15c9", Summary: fmt.Sprintf("ask %04d %s", i, pad)}
		at := now.Add(time.Duration(i-n) * time.Second)
		if _, _, err := e.st.PutFleetAsk(ctx, tid, a, "box-b", at); err != nil {
			t.Fatalf("put %d: %v", i, err)
		}
		if i%7 == 0 {
			continue // stays open
		}
		u := store.AskUpdate{Fleet: "main", AskID: a.AskID, Op: "done", By: "c-001@box-b", Reason: "closed " + pad}
		if _, err := e.st.UpdateFleetAsk(ctx, tid, u, "box-b", at); err != nil {
			t.Fatalf("done %d: %v", i, err)
		}
	}
	in := action.AskArgs{Fleet: "main", Role: "orch", All: true, Hub: home.c}
	raw, err := action.Ask(ctx, home.cfg, in)
	if err != nil {
		t.Fatalf("list --all: %v", err)
	}
	if len(raw) <= 1<<20 {
		t.Fatalf("the book is %d bytes: the test must cross the CLI's 1 MiB frame limit", len(raw))
	}
	got := askOut{}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("answer: %v", err)
	}
	seen, open, closedSeen := map[string]bool{}, 0, false
	for _, r := range got.Asks {
		if seen[r.AskID] {
			t.Fatalf("ask %s answered twice", r.AskID)
		}
		seen[r.AskID] = true
		isOpen := r.State == "open"
		if isOpen && closedSeen {
			t.Fatalf("open ask %s after a closed one: the store order is lost", r.AskID)
		}
		closedSeen = closedSeen || !isOpen
		if isOpen {
			open++
		}
	}
	if len(got.Asks) != n || open != (n+6)/7 || got.Fleet != "main" {
		t.Fatalf("list --all answered %d asks (%d open), want %d (%d open)", len(got.Asks), open, n, (n+6)/7)
	}
	if strings.Contains(string(raw), `"next"`) {
		t.Fatalf("the merged answer still carries a page cursor")
	}
	if got := askCall(t, home, action.AskArgs{Fleet: "main", Role: "orch"}); len(got.Asks) != (n+6)/7 {
		t.Fatalf("the open list: %d asks, want %d", len(got.Asks), (n+6)/7)
	}
}
