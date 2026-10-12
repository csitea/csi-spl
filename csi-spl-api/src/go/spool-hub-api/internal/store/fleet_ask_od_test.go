package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"
)

// Spec 134 T1 (rdb 0183): the OD pool's lock. Run on Memory and Postgres.

// TestFleetAskLockNextAckCAS is the defect 3.3 fixes in the ask book: a
// second seat's ack of an acked ask silently replaced the holder
// (fleet_ask.go applyAskOp). Now it is refused and the first holder stays;
// the holder may re-ack (renew), and after the tick's release another may
// take it. It uses the pre-0183 API only, so it runs red on the old code.
func TestFleetAskLockNextAckCAS(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 12, 21, 0, 0, 0, time.UTC)
	const a1 = "0b1c2d3e-4f50-4a61-8b72-9c8d7e6f5a41"
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			if _, _, err := st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: a1, Role: "orch", Kind: "task", From: "c-002@box-desk"}, "box-desk", t0); err != nil {
				t.Fatal(err)
			}
			upd := func(op, by string, at time.Time) (FleetAsk, error) {
				return st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: a1, Op: op, By: by}, "box-desk", at)
			}
			if got, err := upd(AskAck, "c-001@box-desk", t0.Add(time.Minute)); err != nil || got.AckedBy != "c-001@box-desk" {
				t.Fatalf("first ack: %+v %v", got, err)
			}
			got, err := upd(AskAck, "c-003@sat", t0.Add(2*time.Minute))
			if err == nil {
				t.Fatalf("a second seat's ack over a live ack was accepted: %+v", got)
			}
			if got.AckedBy != "c-001@box-desk" {
				t.Fatalf("the refusal names the holder: %+v %v", got, err)
			}
			as, _ := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0.Add(3*time.Minute))
			if len(as) != 1 || as[0].AckedBy != "c-001@box-desk" {
				t.Fatalf("the stored holder was replaced: %+v", as)
			}
			if got, err = upd(AskAck, "c-001@box-desk", t0.Add(4*time.Minute)); err != nil || got.Quiet != 0 {
				t.Fatalf("the holder's re-ack (renew): %+v %v", got, err)
			}
			if _, err = upd(AskRelease, "c-001@sat", t0.Add(64*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if got, err = upd(AskAck, "c-003@sat", t0.Add(65*time.Minute)); err != nil || got.AckedBy != "c-003@sat" {
				t.Fatalf("after the release another seat acks: %+v %v", got, err)
			}
		})
	}
}

func odJob(id, kind string) FleetAsk {
	return FleetAsk{Fleet: "main", AskID: id, Kind: kind, From: "c-002@box-desk", Topic: "dispatch-e799211c"}
}

func odID(i int) string { return fmt.Sprintf("0d000000-0000-4000-8000-%012d", i) }

// TestFleetAskLockNext: lock-next, expiry, gen fence, dedupe, needs_owner,
// not_by, needs, vendor_allow, the seat release, the role fence, and the
// races (spec 134 4.1: 4 seats on 1 row, n = 20 -> exactly one lock; 40 rows
// -> each locked exactly once).
func TestFleetAskLockNext(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 12, 21, 30, 0, 0, time.UTC)
	cl := OdLock{Fleet: "main", Seat: "c-901@box-desk", Vendor: "claude"}
	gr := OdLock{Fleet: "main", Seat: "g-902@sat", Vendor: "grok"}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			lock := func(q OdLock, box string, at time.Time) (FleetAsk, bool, []FleetAsk) {
				t.Helper()
				got, ok, dead, err := st.LockNextOdJob(ctx, tid, q, box, at)
				if err != nil {
					t.Fatalf("lock-next %s: %v", q.Seat, err)
				}
				return got, ok, dead
			}
			enq := func(a FleetAsk, owner bool, at time.Time) FleetAsk {
				t.Helper()
				got, created, err := st.EnqueueOdJob(ctx, tid, a, owner, "box-desk", at)
				if err != nil || !created {
					t.Fatalf("enqueue %s: %+v %v %v", a.AskID, got, created, err)
				}
				return got
			}
			upd := func(id, op, by string, gen int64, at time.Time) (FleetAsk, error) {
				return st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: id, Op: op, By: by, Gen: gen, Reason: "r"}, "box-desk", at)
			}

			// control: no pool row = kinds empty = nothing is locked
			j1 := odJob(odID(1), "lane_verify")
			j1.DedupeKey, j1.IssueKey = "SPL-1569", "SPL-1569"
			got := enq(j1, false, t0)
			if got.Role != OdRole || got.State != "open" || got.LeaseS != OdLeaseDefault || got.Gen != 0 || len(got.NotBy) != 0 {
				t.Fatalf("enqueued row: %+v", got)
			}
			if _, ok, _ := lock(cl, "box-desk", t0); ok {
				t.Fatal("kinds empty: a row was locked")
			}
			if p, err := st.GetOdPool(ctx, tid, "main"); err != nil || p.ClaudeN != 2 || p.GrokN != 2 || p.MinBoxes != 2 || len(p.Kinds) != 0 {
				t.Fatalf("default pool: %+v %v", p, err)
			}
			p, err := st.PutOdPool(ctx, tid, OdPool{Fleet: "main", ClaudeN: 2, GrokN: 2, MinBoxes: 2, Kinds: []string{"lane_verify", "spawn"}}, "c-002", "box-desk", t0)
			if err != nil || !slices.Equal(p.Kinds, []string{"lane_verify", "spawn"}) || p.UpdatedBy != "c-002@box-desk" || p.WriterBox != "box-desk" {
				t.Fatalf("put pool: %+v %v", p, err)
			}

			// dedupe: a second open job of the same kind and key conflicts and
			// names the open one; a replay of the same id is not a conflict
			dup := odJob(odID(2), "lane_verify")
			dup.DedupeKey = "SPL-1569"
			if got, created, err := st.EnqueueOdJob(ctx, tid, dup, false, "sat", t0); !errors.Is(err, ErrAskDuplicate) || created || got.AskID != j1.AskID {
				t.Fatalf("dedupe: %+v %v %v", got, created, err)
			}
			if got, created, err := st.EnqueueOdJob(ctx, tid, j1, false, "sat", t0); err != nil || created || got.WriterBox != "box-desk" {
				t.Fatalf("replay: %+v %v %v", got, created, err)
			}
			other := dup
			other.Kind = "spawn" // the key is per kind
			enq(other, false, t0.Add(time.Second))

			// lock: the oldest first, gen 1, lease on the hub clock
			got, ok, _ := lock(cl, "box-desk", t0.Add(10*time.Second))
			if !ok || got.AskID != j1.AskID || got.State != "acked" || got.AckedBy != "c-901@box-desk" || got.Gen != 1 ||
				!got.LockUntil.Equal(t0.Add(130*time.Second)) || got.RaisedN != 0 {
				t.Fatalf("lock: %+v %v", got, ok)
			}
			// a live lock is not offered again
			if got, ok, _ = lock(gr, "sat", t0.Add(20*time.Second)); !ok || got.AskID != other.AskID {
				t.Fatalf("second seat takes the other row: %+v %v", got, ok)
			}
			if _, ok, _ = lock(gr, "sat", t0.Add(30*time.Second)); ok {
				t.Fatal("a locked row was locked again")
			}
			// renew by the holder at its gen moves the lease
			if got, err = upd(j1.AskID, AskRenew, cl.Seat, 1, t0.Add(100*time.Second)); err != nil || !got.LockUntil.Equal(t0.Add(220*time.Second)) {
				t.Fatalf("renew: %+v %v", got, err)
			}
			if _, err = upd(other.AskID, AskRenew, gr.Seat, 1, t0.Add(100*time.Second)); err != nil {
				t.Fatalf("renew other: %v", err)
			}
			// expiry is lazy: past lock_until another seat locks it, gen 2,
			// raised_n counts the lost lock
			if _, ok, _ = lock(gr, "sat", t0.Add(219*time.Second)); ok {
				t.Fatal("locked before the lease ran out")
			}
			got, ok, _ = lock(gr, "sat", t0.Add(221*time.Second))
			if !ok || got.AskID != j1.AskID || got.AckedBy != "g-902@sat" || got.Gen != 2 || got.RaisedN != 1 {
				t.Fatalf("expired lock taken over: %+v %v", got, ok)
			}
			// the gen fence: the old holder's renew, done and release are 409
			for _, op := range []string{AskRenew, AskDone, AskRelease, AskDecline} {
				if got, err = upd(j1.AskID, op, cl.Seat, 1, t0.Add(222*time.Second)); !errors.Is(err, ErrAskHeld) || got.AckedBy != "g-902@sat" {
					t.Fatalf("stale %s: %+v %v", op, got, err)
				}
			}
			if _, err = upd(j1.AskID, AskDone, gr.Seat, 1, t0.Add(222*time.Second)); !errors.Is(err, ErrAskHeld) {
				t.Fatalf("the holder at a stale gen: %v", err)
			}
			// the role fence: the book's ops do not apply to an od job
			for _, op := range []string{AskAck, AskRaise, AskQueue, AskReopen} {
				if _, err = upd(j1.AskID, op, gr.Seat, 2, t0.Add(222*time.Second)); !errors.Is(err, ErrAskRole) {
					t.Fatalf("%s on an od job: %v", op, err)
				}
			}
			if got, err = upd(j1.AskID, AskDone, gr.Seat, 2, t0.Add(223*time.Second)); err != nil || got.State != "done" || got.ClosedBy != "g-902@sat" || !got.LockUntil.IsZero() {
				t.Fatalf("done: %+v %v", got, err)
			}
			// a closed job no longer blocks its key
			again := odJob(odID(3), "lane_verify")
			again.DedupeKey = "SPL-1569"
			enq(again, false, t0.Add(224*time.Second))
			if _, err = upd(again.AskID, AskDecline, "c-002@box-desk", 0, t0.Add(225*time.Second)); err != nil {
				t.Fatalf("decline of an open job (admin): %v", err)
			}

			// release with refuse: back to open, gen + 1, the harness joins not_by
			if got, err = upd(other.AskID, AskRelease, gr.Seat, 1, t0.Add(226*time.Second)); err != nil || got.State != "open" || got.Gen != 2 {
				t.Fatalf("release: %+v %v", got, err)
			}
			got, ok, _ = lock(gr, "sat", t0.Add(227*time.Second))
			if !ok || got.AskID != other.AskID || got.Gen != 3 || got.RaisedN != 0 {
				t.Fatalf("relock after release: %+v %v", got, ok)
			}
			if _, err = st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: other.AskID, Op: AskRelease, By: gr.Seat, Gen: 3, Refuse: "grok"}, "sat", t0.Add(228*time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, ok, _ = lock(gr, "sat", t0.Add(229*time.Second)); ok {
				t.Fatal("not_by: the refusing harness locked it again")
			}
			if got, ok, _ = lock(cl, "box-desk", t0.Add(230*time.Second)); !ok || got.AskID != other.AskID || !slices.Equal(got.NotBy, []string{"grok"}) {
				t.Fatalf("not_by: another harness locks it: %+v %v", got, ok)
			}
			if _, err = upd(other.AskID, AskDone, cl.Seat, got.Gen, t0.Add(231*time.Second)); err != nil {
				t.Fatal(err)
			}

			// needs_owner is never locked; a human reopens it
			no := enq(odJob(odID(4), "spawn"), true, t0.Add(232*time.Second))
			if no.State != "needs_owner" || !no.Open() {
				t.Fatalf("needs_owner row: %+v", no)
			}
			if _, ok, _ = lock(cl, "box-desk", t0.Add(233*time.Second)); ok {
				t.Fatal("a needs_owner row was locked")
			}
			if got, err = upd(no.AskID, AskReopen, "c-002@box-desk", 0, t0.Add(234*time.Second)); err != nil || got.State != "open" {
				t.Fatalf("reopen: %+v %v", got, err)
			}
			if _, err = upd(no.AskID, AskReopen, "c-002@box-desk", 0, t0.Add(234*time.Second)); !errors.Is(err, ErrAskRole) {
				t.Fatalf("reopen of an open row: %v", err)
			}
			if got, ok, _ = lock(cl, "box-desk", t0.Add(235*time.Second)); !ok || got.AskID != no.AskID {
				t.Fatalf("reopened row locked: %+v %v", got, ok)
			}
			if _, err = upd(no.AskID, AskDone, cl.Seat, got.Gen, t0.Add(236*time.Second)); err != nil {
				t.Fatal(err)
			}

			// vendor_allow and needs
			vg := odJob(odID(5), "spawn")
			vg.VendorAllow = "grok"
			enq(vg, false, t0.Add(237*time.Second))
			if _, ok, _ = lock(cl, "box-desk", t0.Add(238*time.Second)); ok {
				t.Fatal("vendor_allow grok: a claude seat locked it")
			}
			if got, ok, _ = lock(gr, "sat", t0.Add(239*time.Second)); !ok || got.AskID != vg.AskID {
				t.Fatalf("vendor_allow grok: %+v %v", got, ok)
			}
			bx := odJob(odID(6), "spawn")
			bx.Needs = "box:sat"
			enq(bx, false, t0.Add(240*time.Second))
			if _, ok, _ = lock(cl, "box-desk", t0.Add(241*time.Second)); ok {
				t.Fatal("needs box:sat: a box-desk seat locked it")
			}
			if got, ok, _ = lock(OdLock{Fleet: "main", Seat: "c-903@sat", Vendor: "claude"}, "sat", t0.Add(242*time.Second)); !ok || got.AskID != bx.AskID {
				t.Fatalf("needs box:sat on sat: %+v %v", got, ok)
			}
			pr := odJob(odID(7), "spawn")
			pr.Needs = "prd"
			enq(pr, false, t0.Add(243*time.Second))
			if _, ok, _ = lock(cl, "box-desk", t0.Add(244*time.Second)); ok {
				t.Fatal("needs prd: a seat without the cap locked it")
			}
			withPrd := cl
			withPrd.Caps = []string{"prd"}
			if got, ok, _ = lock(withPrd, "box-desk", t0.Add(245*time.Second)); !ok || got.AskID != pr.AskID {
				t.Fatalf("needs prd with the cap: %+v %v", got, ok)
			}
			if _, err = upd(pr.AskID, AskDone, cl.Seat, 1, t0.Add(245*time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, err = upd(bx.AskID, AskDone, "c-903@sat", 1, t0.Add(245*time.Second)); err != nil {
				t.Fatal(err)
			}
			// a kind the pool does not consume stays with the lease holder
			enq(odJob(odID(8), "box_op"), false, t0.Add(246*time.Second))
			if _, ok, _ = lock(cl, "box-desk", t0.Add(247*time.Second)); ok {
				t.Fatal("box_op is not in kinds: it was locked")
			}

			// the seat release (the kill): every row of the seat, gen + 1, and
			// the killed session's renew matches nothing
			rel, err := st.ReleaseOdSeat(ctx, tid, "main", "g-902", "sat", t0.Add(248*time.Second))
			if err != nil || len(rel) != 1 || rel[0].AskID != vg.AskID || rel[0].State != "open" || rel[0].Gen != 2 {
				t.Fatalf("release seat: %+v %v", rel, err)
			}
			if _, err = upd(vg.AskID, AskRenew, gr.Seat, 1, t0.Add(249*time.Second)); !errors.Is(err, ErrAskHeld) {
				t.Fatalf("the killed session's renew: %v", err)
			}

			// the 4th lost lock dead-letters the row (3.3): three expiries are
			// re-locked, the fourth is closed dead and reported once
			tick := t0.Add(300 * time.Second)
			for i := 1; i <= 4; i++ {
				got, ok, dead := lock(gr, "sat", tick)
				if !ok || got.AskID != vg.AskID || len(dead) != 0 || got.RaisedN != i-1 {
					t.Fatalf("lock %d: %+v %v %+v", i, got, ok, dead)
				}
				tick = tick.Add(121 * time.Second)
			}
			got, ok, dead := lock(gr, "sat", tick)
			if ok || len(dead) != 1 || dead[0].AskID != vg.AskID || dead[0].State != "dead" || dead[0].RaisedN != OdMaxLocks || dead[0].Reason == "" {
				t.Fatalf("dead-letter: %+v %v %+v", got, ok, dead)
			}
			if _, _, dead = lock(gr, "sat", tick.Add(time.Second)); len(dead) != 0 {
				t.Fatalf("a dead row is reported once: %+v", dead)
			}

			// the od ops do not apply to a book ask
			const book = "0e000000-0000-4000-8000-000000000001"
			if _, _, err = st.PutFleetAsk(ctx, tid, FleetAsk{Fleet: "main", AskID: book, Role: "orch", Kind: "task", From: "c-002"}, "box-desk", t0); err != nil {
				t.Fatal(err)
			}
			if _, err = upd(book, AskRenew, "c-001@box-desk", 0, t0); !errors.Is(err, ErrAskRole) {
				t.Fatalf("renew on a book ask: %v", err)
			}
			if as, _ := st.ListFleetAsks(ctx, tid, "main", "orch", false, t0); len(as) != 1 {
				t.Fatalf("the book's list holds no od row: %+v", as)
			}
		})
	}
}

// TestFleetAskLockNextRaces: 4 seats on 1 open row, n = 20 -> exactly one
// lock each round; 40 rows and 8 seats -> each row locked exactly once.
// Control: 2 rows, 2 seats -> both locked.
func TestFleetAskLockNextRaces(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 12, 22, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			if _, err := st.PutOdPool(ctx, tid, OdPool{Fleet: "main", ClaudeN: 2, GrokN: 2, MinBoxes: 2, Kinds: []string{"spawn"}}, "c-002", "box-desk", t0); err != nil {
				t.Fatal(err)
			}
			seats := []OdLock{
				{Fleet: "main", Seat: "c-901@box-desk", Vendor: "claude"}, {Fleet: "main", Seat: "c-902@sat", Vendor: "claude"},
				{Fleet: "main", Seat: "g-903@box-desk", Vendor: "grok"}, {Fleet: "main", Seat: "g-904@sat", Vendor: "grok"},
			}
			race := func(qs []OdLock, at time.Time, each int) map[string][]string {
				var mu sync.Mutex
				var wg sync.WaitGroup
				out := map[string][]string{}
				for _, q := range qs {
					wg.Add(1)
					go func(q OdLock) {
						defer wg.Done()
						for range each {
							got, ok, _, err := st.LockNextOdJob(ctx, tid, q, "box-desk", at)
							if err != nil {
								t.Errorf("lock-next: %v", err)
								return
							}
							if !ok {
								return
							}
							mu.Lock()
							out[got.AskID] = append(out[got.AskID], q.Seat)
							mu.Unlock()
						}
					}(q)
				}
				wg.Wait()
				return out
			}
			for i := range 20 {
				id := fmt.Sprintf("0f000000-0000-4000-8000-%012d", i)
				at := t0.Add(time.Duration(i) * time.Second)
				if _, _, err := st.EnqueueOdJob(ctx, tid, odJob(id, "spawn"), false, "box-desk", at); err != nil {
					t.Fatal(err)
				}
				got := race(seats, at, 1)
				if len(got) != 1 || len(got[id]) != 1 {
					t.Fatalf("round %d: 4 seats on 1 row: %v", i, got)
				}
				if _, err := st.UpdateFleetAsk(ctx, tid, AskUpdate{Fleet: "main", AskID: id, Op: AskDone, By: got[id][0], Gen: 1}, "box-desk", at); err != nil {
					t.Fatal(err)
				}
			}
			at := t0.Add(time.Hour)
			for i := range 40 {
				if _, _, err := st.EnqueueOdJob(ctx, tid, odJob(odID(100+i), "spawn"), false, "box-desk", at.Add(time.Duration(i)*time.Millisecond)); err != nil {
					t.Fatal(err)
				}
			}
			eight := append(append([]OdLock{}, seats...), seats...)
			for i := 4; i < 8; i++ {
				eight[i].Seat = fmt.Sprintf("c-91%d@sat", i)
			}
			got := race(eight, at.Add(time.Second), 40)
			if len(got) != 40 {
				t.Fatalf("40 rows: %d locked", len(got))
			}
			for id, by := range got {
				if len(by) != 1 {
					t.Fatalf("%s locked %d times: %v", id, len(by), by)
				}
			}
			// control: 2 rows, 2 seats -> both locked
			ctl := at.Add(2 * time.Second) // the 40 are still locked
			for i := range 2 {
				if _, _, err := st.EnqueueOdJob(ctx, tid, odJob(odID(200+i), "spawn"), false, "box-desk", ctl); err != nil {
					t.Fatal(err)
				}
			}
			if got = race(seats[:2], ctl, 1); len(got) != 2 {
				t.Fatalf("control: 2 rows 2 seats: %v", got)
			}
		})
	}
}

// The client and the hub refuse what 0183's CHECKs would.
func TestCheckOdJob(t *testing.T) {
	ok := odJob(odID(1), "route_post")
	ok.IssueKey, ok.DedupeKey, ok.VendorAllow, ok.Needs, ok.LeaseS = "SPL-1569", "msg-1", "grok", "box:sat", 180
	if why := CheckOdJob(ok); why != "" {
		t.Fatalf("refused a good job: %s", why)
	}
	for _, bad := range []func(*FleetAsk){
		func(a *FleetAsk) { a.Kind = "task" },
		func(a *FleetAsk) { a.IssueKey = "spl-1" },
		func(a *FleetAsk) { a.VendorAllow = "vibe" },
		func(a *FleetAsk) { a.Needs = "box:Sat" },
		func(a *FleetAsk) { a.Needs = "gpu" },
		func(a *FleetAsk) { a.LeaseS = 5 },
		func(a *FleetAsk) { a.DedupeKey = "a\nb" },
		func(a *FleetAsk) { a.AskID = "x" },
	} {
		a := ok
		bad(&a)
		if CheckOdJob(a) == "" {
			t.Fatalf("accepted %+v", a)
		}
	}
	if CheckFleetAsk(FleetAsk{Fleet: "main", AskID: odID(1), Role: OdRole, Kind: "task", From: "c-002"}) == "" {
		t.Fatal("put accepted role od")
	}
	if why := CheckOdLock(OdLock{Fleet: "main", Seat: "c-901@sat", Vendor: "claude", Caps: []string{"prd"}}); why != "" {
		t.Fatalf("refused a good lock: %s", why)
	}
	for _, q := range []OdLock{{Fleet: "main", Seat: "", Vendor: "claude"}, {Fleet: "main", Seat: "c-901", Vendor: ""},
		{Fleet: "main", Seat: "c-901", Vendor: "claude", Caps: []string{"box:sat"}}} {
		if CheckOdLock(q) == "" {
			t.Fatalf("accepted lock %+v", q)
		}
	}
	if CheckOdPool(OdPool{Fleet: "main", ClaudeN: 2, GrokN: 2, MinBoxes: 2, Kinds: []string{"spawn"}}) != "" {
		t.Fatal("refused a good pool")
	}
	for _, p := range []OdPool{{Fleet: "main", MinBoxes: 0}, {Fleet: "main", MinBoxes: 1, Kinds: []string{"task"}},
		{Fleet: "main", MinBoxes: 1, Kinds: []string{"spawn", "spawn"}}, {Fleet: "main", MinBoxes: 1, ClaudeN: 17}} {
		if CheckOdPool(p) == "" {
			t.Fatalf("accepted pool %+v", p)
		}
	}
}
