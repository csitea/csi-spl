package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 068 L1: the claim frame through the real front end (action.Claim ==
// `spool claim`), two boxes (two machines) sharing one pool of peer
// messages:
//
//  1. both boxes' seats poll at once: every message is locked by exactly one
//     seat, the poll answer carries the v:1 message for the inbox
//  2. a seat on one box cannot close, release or claim for the other box's
//     seat: the close is refused naming the responsible seat
//  3. the holder's lock runs out (hub clock): the other box takes it, the
//     fence +1, and the old holder's close with the old fence is refused
//  4. a claude seat's harness refusal sends it to a grok seat only
//  5. four claims without a close: the next poll returns it dead, once
type claimOut struct {
	Seat string         `json:"seat"`
	Msgs []hub.ClaimRow `json:"msgs"`
	Dead []hub.ClaimRow `json:"dead"`
}

func claimCall(t *testing.T, b *box, in action.ClaimArgs) (claimOut, error) {
	t.Helper()
	in.Hub = b.c
	raw, err := action.Claim(context.Background(), b.cfg, in)
	if err != nil {
		return claimOut{}, err
	}
	var out claimOut
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out, nil
}

func mustClaim(t *testing.T, b *box, in action.ClaimArgs) claimOut {
	t.Helper()
	out, err := claimCall(t, b, in)
	if err != nil {
		t.Fatalf("claim %+v: %v", in, err)
	}
	return out
}

func refusedClaim(t *testing.T, b *box, in action.ClaimArgs, token, detail string) {
	t.Helper()
	_, err := claimCall(t, b, in)
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != token || !strings.Contains(he.Detail, detail) {
		t.Fatalf("claim %+v: want %s %q, got %v", in, token, detail, err)
	}
}

func TestBoxMessageClaim(t *testing.T) {
	var mu sync.Mutex
	now := time.Now().UTC().Truncate(time.Second)
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	advance := func(d time.Duration) { mu.Lock(); now = now.Add(d); mu.Unlock() }
	// the hub clock runs ahead of the boxes by several lock TTLs: widen the
	// hello skew so the clock, not the hello, is what the test moves
	e := newEnv(t, func(o *hub.Options) { o.Now, o.HelloSkew = clock, 24*time.Hour })
	tid, _ := e.tenant()
	sat := e.box(tid, "box-b", "c-001", "g-003")
	pc := e.box(tid, "box-c", "c-001", "g-004")
	e.pin(tid, sat)
	e.pin(tid, pc)
	ctx := context.Background()
	peerMsg := func() string {
		at := clock()
		id := uuidV4()
		m := store.Message{TenantID: tid, MsgID: id, TaskID: uuidV4(), TS: at, FromBox: "box-b", FromID: "c-120",
			ToBox: "box-b", ToID: store.PeersID, Kind: "note", Body: "report " + id,
			Files: []byte(`[]`), Msg: []byte(`{"v":1,"msg_id":"` + id + `"}`), Env: []byte(`{"id":"` + id + `"}`),
			ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
		if _, err := e.st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return id
	}

	// 1. two boxes poll at once: disjoint, all taken
	ids := map[string]bool{}
	for range 12 {
		ids[peerMsg()] = true
	}
	owner := map[string]string{}
	var wg sync.WaitGroup
	for _, p := range []struct {
		b    *box
		seat string
	}{{sat, "c-001"}, {sat, "g-003"}, {pc, "c-001"}, {pc, "g-004"}} {
		wg.Add(1)
		go func(b *box, seat string) {
			defer wg.Done()
			for {
				out, err := claimCall(t, b, action.ClaimArgs{Op: "poll", Seat: seat, Max: 2})
				if err != nil {
					t.Errorf("poll %s: %v", seat, err)
					return
				}
				if len(out.Msgs) == 0 {
					return
				}
				mu.Lock()
				for _, r := range out.Msgs {
					if prev := owner[r.MsgID]; prev != "" {
						t.Errorf("%s locked twice: %s and %s", r.MsgID, prev, out.Seat)
					}
					owner[r.MsgID] = out.Seat
					if r.Responsible != out.Seat || r.Gen != 1 || !strings.Contains(string(r.Msg), r.MsgID) || r.To != "peers@box-b" {
						t.Errorf("poll row: %+v", r)
					}
				}
				mu.Unlock()
			}
		}(p.b, p.seat)
	}
	wg.Wait()
	if len(owner) != len(ids) {
		t.Fatalf("locked %d of %d", len(owner), len(ids))
	}
	seats := map[string]bool{}
	for _, s := range owner {
		seats[s] = true
	}
	if len(seats) < 2 {
		t.Logf("only %v polled anything (a fast poller may drain the pool; disjointness is what counts)", seats)
	}
	// every lock is accounted for by the holders' renew
	held := 0
	for _, p := range []struct {
		b    *box
		seat string
	}{{sat, "c-001"}, {sat, "g-003"}, {pc, "c-001"}, {pc, "g-004"}} {
		out := mustClaim(t, p.b, action.ClaimArgs{Op: "renew", Seat: p.seat})
		held += len(out.Msgs)
	}
	if held != len(ids) {
		t.Fatalf("held %d, want %d", held, len(ids))
	}

	// 2. one box acts only for its own seats
	refusedClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001@box-c"}, "claim_seat_box", "its own seats")
	id := peerMsg()
	got := mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001@box-b"})
	if len(got.Msgs) != 1 || got.Msgs[0].MsgID != id || got.Seat != "c-001@box-b" {
		t.Fatalf("poll on sat: %+v", got)
	}
	refusedClaim(t, pc, action.ClaimArgs{Op: "done", Seat: "c-001", MsgID: id}, "claim_refused", "responsible is c-001@box-b")
	refusedClaim(t, pc, action.ClaimArgs{Op: "release", Seat: "g-004", MsgID: id, Reason: "send-failed"}, "claim_refused", "responsible is c-001@box-b")

	// 3. the lock runs out on the hub clock: the other box takes it, fence +1
	advance(store.ClaimTTLDefault + time.Second)
	got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "g-004", Max: 50})
	var moved *hub.ClaimRow
	for i := range got.Msgs {
		if got.Msgs[i].MsgID == id {
			moved = &got.Msgs[i]
		}
	}
	if moved == nil || moved.Responsible != "g-004@box-c" || moved.Gen != 2 || moved.ClaimN != 2 {
		t.Fatalf("expired lock: %+v", got)
	}
	refusedClaim(t, sat, action.ClaimArgs{Op: "done", Seat: "c-001", MsgID: id, Gen: 1}, "claim_refused", "responsible is g-004@box-c")
	refusedClaim(t, pc, action.ClaimArgs{Op: "done", Seat: "g-004", MsgID: id, Gen: 1, How: "handed:c-130"}, "claim_refused", "gen is 2")
	done := mustClaim(t, pc, action.ClaimArgs{Op: "done", Seat: "g-004", MsgID: id, Gen: 2, How: "handed:c-130"})
	if len(done.Msgs) != 1 || done.Msgs[0].HandledHow != "handed:c-130" || done.Msgs[0].HandledAt == "" {
		t.Fatalf("done: %+v", done)
	}
	refusedClaim(t, pc, action.ClaimArgs{Op: "done", Seat: "g-004", MsgID: id}, "claim_refused", "already closed handed:c-130")

	// 4. a claude refusal goes to grok only
	advance(store.ClaimTTLDefault + time.Second) // everything from step 1 is free again
	for range 3 {
		out := mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "g-003", Max: 50})
		for _, r := range out.Msgs {
			mustClaim(t, sat, action.ClaimArgs{Op: "done", Seat: "g-003", MsgID: r.MsgID, Gen: r.Gen, How: "no-reply:drill"})
		}
	}
	refused := peerMsg()
	if got = mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001"}); len(got.Msgs) != 1 || got.Msgs[0].MsgID != refused {
		t.Fatalf("poll refused-to-be: %+v", got)
	}
	rel := mustClaim(t, sat, action.ClaimArgs{Op: "release", Seat: "c-001", MsgID: refused, Reason: "harness-refused:prd-deploy"})
	if len(rel.Msgs) != 1 || rel.Msgs[0].Responsible != "" || len(rel.Msgs[0].NotBy) != 1 || rel.Msgs[0].NotBy[0] != "claude" {
		t.Fatalf("release: %+v", rel)
	}
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "c-001"}); len(got.Msgs) != 0 {
		t.Fatalf("a claude seat took a claude-refused message: %+v", got)
	}
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "g-004"}); len(got.Msgs) != 1 || got.Msgs[0].MsgID != refused {
		t.Fatalf("grok seat: %+v", got)
	}

	// 5. the fourth expiry: dead, once
	for i := 0; i < store.ClaimMax-2; i++ {
		advance(store.ClaimTTLDefault + time.Second)
		if got = mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "g-003"}); len(got.Msgs) != 1 {
			t.Fatalf("re-claim %d: %+v", i, got)
		}
	}
	advance(store.ClaimTTLDefault + time.Second)
	got = mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "g-003"})
	if len(got.Msgs) != 0 || len(got.Dead) != 1 || got.Dead[0].MsgID != refused || got.Dead[0].HandledHow != "dead" || len(got.Dead[0].Msg) == 0 {
		t.Fatalf("dead-letter: %+v", got)
	}
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "g-004"}); len(got.Msgs)+len(got.Dead) != 0 {
		t.Fatalf("dead twice: %+v", got)
	}

	// the client refuses what the hub would, before dialling
	if _, err := claimCall(t, sat, action.ClaimArgs{Op: "done", Seat: "c-001", MsgID: id, How: "maybe"}); err == nil || !strings.Contains(err.Error(), "--how") {
		t.Fatalf("bad how: %v", err)
	}
	if _, err := claimCall(t, sat, action.ClaimArgs{Op: "release", Seat: "c-001", MsgID: id}); err == nil || !strings.Contains(err.Error(), "--reason") {
		t.Fatalf("release without a reason: %v", err)
	}
}
