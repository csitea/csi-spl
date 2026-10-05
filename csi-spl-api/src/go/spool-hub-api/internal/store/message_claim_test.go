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

// Spec 068 L1 (rdb 0110): the peer claim on a message, on Memory and
// Postgres. Four seats polling at once lock each of 100 peer messages exactly
// once; a lock past its TTL moves to the next poller with the fence +1; a
// renew keeps it; only the responsible seat may close (a stale fence and a
// second close are refused with the current row); a harness that refused a
// message never gets it back (not_by); the CLAIM_MAX-th expiry closes it
// dead exactly once; a message to one agent is that agent's from insert and
// no peer polls it; a human room post needs a peer only once the workspace
// is seated.
func TestMessageClaimPoll(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 3, 14, 0, 0, 0, time.UTC)
	ttl := ClaimTTLDefault
	seats := []string{"c-001@box-a", "c-002@box-a", "g-003@box-a", "g-004@box-a"}
	harness := map[string]string{"c-001@box-a": "claude", "c-002@box-a": "claude", "g-003@box-a": "grok", "g-004@box-a": "grok"}
	poll := func(t *testing.T, st Store, tid, seat string, max int, now time.Time) ([]Message, []Message) {
		t.Helper()
		got, dead, err := st.PollMessageClaims(ctx, tid, ClaimPoll{Seat: seat, Harness: harness[seat], Max: max, TTL: ttl}, now)
		if err != nil {
			t.Fatalf("poll %s: %v", seat, err)
		}
		return got, dead
	}
	peerMsgs := func(t *testing.T, st Store, tid string, n int) []string {
		t.Helper()
		ids := make([]string, n)
		for i := range ids {
			m := msgFor(tid, uuid4(), "box-a", t0.Add(time.Duration(i)*time.Millisecond), t0, fmt.Sprint("env-", i))
			m.FromID, m.ToID = "c-009", PeersID
			if _, err := st.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			ids[i] = m.MsgID
		}
		return ids
	}

	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			t.Run("four pollers, 100 messages, each locked once", func(t *testing.T) {
				tid := newTenant(t, st)
				ids := peerMsgs(t, st, tid, 100)
				var mu sync.Mutex
				owner := map[string]string{}
				dup := []string{}
				var wg sync.WaitGroup
				for _, seat := range seats {
					wg.Add(1)
					go func(seat string) {
						defer wg.Done()
						for {
							got, _, err := st.PollMessageClaims(ctx, tid, ClaimPoll{Seat: seat, Harness: harness[seat], Max: 3, TTL: ttl}, t0.Add(time.Second))
							if err != nil {
								t.Errorf("poll %s: %v", seat, err)
								return
							}
							if len(got) == 0 {
								return
							}
							mu.Lock()
							for _, m := range got {
								if prev, ok := owner[m.MsgID]; ok {
									dup = append(dup, m.MsgID+" "+prev+" "+seat)
								}
								owner[m.MsgID] = seat
								if m.Responsible != seat || m.ResponsibleGen != 1 || m.ClaimN != 1 || !m.LockedUntil.Equal(t0.Add(time.Second+ttl)) {
									t.Errorf("claimed row: %+v", m)
								}
							}
							mu.Unlock()
						}
					}(seat)
				}
				wg.Wait()
				if len(dup) != 0 || len(owner) != 100 {
					t.Fatalf("locked %d of 100, duplicates %v", len(owner), dup)
				}
				for _, id := range ids {
					if owner[id] == "" {
						t.Fatalf("%s never locked", id)
					}
				}
				// every lock is live: nobody gets anything until it runs out
				if got, _ := poll(t, st, tid, seats[0], 50, t0.Add(ttl)); len(got) != 0 {
					t.Fatalf("live locks re-claimed: %d", len(got))
				}
				// the holders' views agree with the claims
				n := 0
				for _, seat := range seats {
					held, err := st.RenewMessageClaims(ctx, tid, seat, ttl, t0.Add(2*time.Second))
					if err != nil {
						t.Fatal(err)
					}
					for _, m := range held {
						if owner[m.MsgID] != seat {
							t.Fatalf("%s holds %s, claimed by %s", seat, m.MsgID, owner[m.MsgID])
						}
					}
					n += len(held)
				}
				if n != 100 {
					t.Fatalf("held %d, want 100", n)
				}
				// another tenant sees none of it
				if got, _ := poll(t, st, newTenant(t, st), seats[0], 50, t0.Add(time.Hour)); len(got) != 0 {
					t.Fatalf("cross-tenant claim: %+v", got)
				}
			})

			t.Run("expiry, renew, close by the responsible seat only", func(t *testing.T) {
				tid := newTenant(t, st)
				id := peerMsgs(t, st, tid, 1)[0]
				got, _ := poll(t, st, tid, seats[0], 3, t0)
				if len(got) != 1 || got[0].MsgID != id || string(got[0].Msg) == "" || got[0].ToID != PeersID {
					t.Fatalf("first claim: %+v", got)
				}
				// a renew with more than ttl/2 left keeps the lock as it is
				held, err := st.RenewMessageClaims(ctx, tid, seats[0], ttl, t0.Add(30*time.Second))
				if err != nil || len(held) != 1 || !held[0].LockedUntil.Equal(t0.Add(ttl)) {
					t.Fatalf("early renew: %+v %v", held, err)
				}
				// past half of it, the renew extends it from now
				held, err = st.RenewMessageClaims(ctx, tid, seats[0], ttl, t0.Add(90*time.Second))
				if err != nil || len(held) != 1 || !held[0].LockedUntil.Equal(t0.Add(90*time.Second+ttl)) {
					t.Fatalf("renew: %+v %v", held, err)
				}
				if got, _ := poll(t, st, tid, seats[1], 3, t0.Add(ttl+time.Second)); len(got) != 0 {
					t.Fatalf("renewed lock taken: %+v", got)
				}
				// the holder stops renewing: past the lock, the next poller takes it, fence +1
				got, _ = poll(t, st, tid, seats[1], 3, t0.Add(90*time.Second+ttl+time.Second))
				if len(got) != 1 || got[0].Responsible != seats[1] || got[0].ResponsibleGen != 2 || got[0].ClaimN != 2 {
					t.Fatalf("expired lock: %+v", got)
				}
				now := t0.Add(4 * time.Minute)
				// the old holder may not close it, and learns who holds it
				m, err := st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[0], How: "answered"}, now)
				if !errors.Is(err, ErrConflict) || m.Responsible != seats[1] {
					t.Fatalf("non-responsible close: %+v %v", m, err)
				}
				if _, err = st.ReleaseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[0], Reason: "send-failed"}, now); !errors.Is(err, ErrConflict) {
					t.Fatalf("non-responsible release: %v", err)
				}
				// a stale fence loses the compare-and-set
				if m, err = st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[1], How: "handed:c-120", Gen: 1}, now); !errors.Is(err, ErrConflict) || m.ResponsibleGen != 2 {
					t.Fatalf("stale gen: %+v %v", m, err)
				}
				m, err = st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[1], How: "handed:c-120", Gen: 2}, now)
				if err != nil || m.HandledHow != "handed:c-120" || !m.HandledAt.Equal(now) || !m.LockedUntil.IsZero() {
					t.Fatalf("close: %+v %v", m, err)
				}
				// closed once: a second close names the first
				if m, err = st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[1], How: "answered"}, now); !errors.Is(err, ErrConflict) || m.HandledHow != "handed:c-120" {
					t.Fatalf("second close: %+v %v", m, err)
				}
				if got, _ := poll(t, st, tid, seats[2], 3, now.Add(time.Hour)); len(got) != 0 {
					t.Fatalf("closed message claimed: %+v", got)
				}
				if held, _ := st.RenewMessageClaims(ctx, tid, seats[1], ttl, now); len(held) != 0 {
					t.Fatalf("closed message still held: %+v", held)
				}
				if _, err = st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: uuid4(), Seat: seats[1], How: "answered"}, now); !errors.Is(err, ErrNotFound) {
					t.Fatalf("unknown message: %v", err)
				}
			})

			t.Run("not_by: a refused harness never gets it back", func(t *testing.T) {
				tid := newTenant(t, st)
				id := peerMsgs(t, st, tid, 1)[0]
				if got, _ := poll(t, st, tid, seats[0], 3, t0); len(got) != 1 {
					t.Fatalf("claim: %+v", got)
				}
				m, err := st.ReleaseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[0], Harness: "claude", Reason: "harness-refused:prd-deploy"}, t0)
				if err != nil || m.Responsible != "" || !slices.Equal(m.NotBy, []string{"claude"}) {
					t.Fatalf("release: %+v %v", m, err)
				}
				// released: free at once, but not for a claude seat
				if got, _ := poll(t, st, tid, seats[1], 3, t0.Add(time.Second)); len(got) != 0 {
					t.Fatalf("claude seat took a claude-refused message: %+v", got)
				}
				got, _ := poll(t, st, tid, seats[2], 3, t0.Add(time.Second))
				if len(got) != 1 || got[0].Responsible != seats[2] || got[0].ResponsibleGen != 2 {
					t.Fatalf("grok seat: %+v", got)
				}
				// a plain release frees it without touching not_by
				m, err = st.ReleaseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[2], Harness: "grok", Reason: "send-failed"}, t0)
				if err != nil || !slices.Equal(m.NotBy, []string{"claude"}) {
					t.Fatalf("plain release: %+v %v", m, err)
				}
				if got, _ := poll(t, st, tid, seats[3], 3, t0.Add(2*time.Second)); len(got) != 1 {
					t.Fatalf("after a plain release: %+v", got)
				}
			})

			t.Run("dead-letter at the fourth claim", func(t *testing.T) {
				tid := newTenant(t, st)
				id := peerMsgs(t, st, tid, 1)[0]
				now := t0
				for i := 1; i <= ClaimMax; i++ {
					got, dead := poll(t, st, tid, seats[i%4], 3, now)
					if len(got) != 1 || got[0].ClaimN != i || len(dead) != 0 {
						t.Fatalf("claim %d: %+v dead %+v", i, got, dead)
					}
					now = now.Add(ttl + time.Second)
				}
				// four claims ran out without a close: the next poll closes it dead, once
				got, dead := poll(t, st, tid, seats[0], 3, now)
				if len(got) != 0 || len(dead) != 1 || dead[0].MsgID != id || dead[0].HandledHow != "dead" || dead[0].ClaimN != ClaimMax {
					t.Fatalf("dead-letter: %+v dead %+v", got, dead)
				}
				if got, dead := poll(t, st, tid, seats[1], 3, now.Add(time.Hour)); len(got)+len(dead) != 0 {
					t.Fatalf("dead twice: %+v %+v", got, dead)
				}
				if m, err := st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: id, Seat: seats[3], How: "answered"}, now); !errors.Is(err, ErrConflict) || m.HandledHow != "dead" {
					t.Fatalf("close after dead: %+v %v", m, err)
				}
			})

			t.Run("one agent's message, and the seated room", func(t *testing.T) {
				tid := newTenant(t, st)
				dm := msgFor(tid, uuid4(), "box-b", t0, t0, "dm")
				dm.ToID = "c-120"
				if _, err := st.InsertMessage(ctx, dm); err != nil {
					t.Fatal(err)
				}
				room := func(env string) Message {
					m := msgFor(tid, uuid4(), "box-wui", t0.Add(time.Second), t0, env)
					m.FromBox, m.FromID, m.ToID, m.Channel = "box-wui", "HUM-1", "ALL-0", "lobby"
					if _, err := st.InsertMessage(ctx, m); err != nil {
						t.Fatal(err)
					}
					return m
				}
				room("before-seats") // no peer seat yet: nobody polls it
				if got, _ := poll(t, st, tid, seats[0], 50, t0.Add(time.Hour)); len(got) != 0 {
					t.Fatalf("unseated: %+v", got)
				}
				// responsible from insert: the addressee may close it, a peer may not release it
				if m, err := st.ReleaseMessageClaim(ctx, tid, ClaimClose{MsgID: dm.MsgID, Seat: "c-120@box-b", Reason: "send-failed"}, t0); !errors.Is(err, ErrNotPeerMessage) || m.Responsible != "c-120@box-b" {
					t.Fatalf("release of a dm: %+v %v", m, err)
				}
				if m, err := st.CloseMessageClaim(ctx, tid, ClaimClose{MsgID: dm.MsgID, Seat: "c-120@box-b", How: "no-reply:fyi"}, t0); err != nil || m.HandledHow != "no-reply:fyi" {
					t.Fatalf("close of a dm: %+v %v", m, err)
				}
				if err := st.PutPin(ctx, tid, "box-a", pubkey(), false, t0, t0); err != nil {
					t.Fatal(err)
				}
				if err := st.SetRoster(ctx, tid, "box-a", []string{"c-001", "c-120"}, t0); err != nil {
					t.Fatal(err)
				}
				seated := room("after-seats")
				got, _ := poll(t, st, tid, seats[0], 50, t0.Add(time.Hour))
				if len(got) != 1 || got[0].MsgID != seated.MsgID || got[0].FromID != "HUM-1" || got[0].Channel != "lobby" {
					t.Fatalf("seated room post: %+v", got)
				}
			})
		})
	}
}

// The fence read and the hub-down adopt (spec 068 4.2, section 7): a seat
// still holds a message only while it is responsible at the same fence with
// a live lock; adopt takes a free peer message as a claim would, and leaves
// one another seat holds untouched (insert-if-absent).
func TestMessageClaimAdopt(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 3, 15, 0, 0, 0, time.UTC)
	ttl := ClaimTTLDefault
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, st)
			ins := func(to string) string {
				m := msgFor(tid, uuid4(), "box-a", t0, t0, "env-"+uuid4())
				m.FromID, m.ToID = "c-009", to
				if _, err := st.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m.MsgID
			}
			a, b := ins(PeersID), ins(PeersID)
			m, adopted, err := st.AdoptMessageClaim(ctx, tid, ClaimClose{MsgID: a, Seat: "c-001@box-a"}, ttl, t0)
			if err != nil || !adopted || m.Responsible != "c-001@box-a" || m.ResponsibleGen != 1 || m.ClaimN != 1 || !m.LockedUntil.Equal(t0.Add(ttl)) {
				t.Fatalf("adopt: %+v %v %v", m, adopted, err)
			}
			// insert-if-absent: the other machine's seat leaves it alone
			if m, adopted, err = st.AdoptMessageClaim(ctx, tid, ClaimClose{MsgID: a, Seat: "c-001@box-b"}, ttl, t0); err != nil || adopted || m.Responsible != "c-001@box-a" {
				t.Fatalf("second adopt: %+v %v %v", m, adopted, err)
			}
			// an adopted message is held: a poll does not take it
			if got, _, _ := st.PollMessageClaims(ctx, tid, ClaimPoll{Seat: "g-003@box-a", Harness: "grok", Max: 5, TTL: ttl}, t0); len(got) != 1 || got[0].MsgID != b {
				t.Fatalf("poll after adopt: %+v", got)
			}
			if m, err = st.GetMessageClaim(ctx, tid, a); err != nil || !ClaimHeld(m, "c-001@box-a", 1, t0.Add(ttl)) {
				t.Fatalf("held: %+v %v", m, err)
			}
			for _, c := range []struct {
				seat string
				gen  int64
				at   time.Time
			}{{"c-001@box-b", 1, t0}, {"c-001@box-a", 2, t0}, {"c-001@box-a", 1, t0.Add(ttl + time.Second)}} {
				if ClaimHeld(m, c.seat, c.gen, c.at) {
					t.Fatalf("held by %s gen %d at %s", c.seat, c.gen, c.at)
				}
			}
			if _, _, err = st.AdoptMessageClaim(ctx, tid, ClaimClose{MsgID: ins("c-120"), Seat: "c-001@box-a"}, ttl, t0); !errors.Is(err, ErrNotPeerMessage) {
				t.Fatalf("adopt a dm: %v", err)
			}
			if _, err = st.GetMessageClaim(ctx, tid, uuid4()); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown: %v", err)
			}
		})
	}
}

// Spec 093 section 4 (rdb 0132, T008): the two-phase claim on Memory and
// Postgres. Each case drives the transitions T1..T10 with the hub clock in
// the test's hands, checks every row it touched is in exactly one
// claim_state (ClaimStateProblem), and carries a control: the same input
// with one thing flipped, which DOES move the row (spec FR-011), so no case
// passes because nothing happened.

var (
	rA1, rA2 = "c-001@box-a", "g-003@box-a"
	rB1, rB2 = "c-001@box-b", "g-002@box-b"
	rReady   = []string{rA1, rA2, rB1, rB2}
)

type roundFix struct {
	t   *testing.T
	st  Store
	tid string
	t0  time.Time
	ids []string
}

func newRoundFix(t *testing.T, st Store) *roundFix {
	return &roundFix{t: t, st: st, tid: newTenant(t, st), t0: time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)}
}

// job inserts a message to the peers at t0 + at.
func (f *roundFix) job(at time.Duration) string {
	f.t.Helper()
	m := msgFor(f.tid, uuid4(), "box-a", f.t0.Add(at), f.t0, "env-"+uuid4())
	m.FromID, m.ToID = "c-120", PeersID
	if _, err := f.st.InsertMessage(context.Background(), m); err != nil {
		f.t.Fatal(err)
	}
	f.ids = append(f.ids, m.MsgID)
	return m.MsgID
}

func (f *roundFix) poll(seat string, busy bool, ready []string, at time.Duration) (offered, dead []Message) {
	f.t.Helper()
	offered, dead, err := f.st.PollMessageRounds(context.Background(), f.tid, RoundPoll{Seat: seat, Busy: busy, Ready: ready, Max: 3}, f.t0.Add(at))
	if err != nil {
		f.t.Fatalf("poll %s: %v", seat, err)
	}
	f.states()
	return offered, dead
}

// offeredTo reports whether seat's poll at `at` returns id.
func (f *roundFix) offeredTo(id, seat string, busy bool, at time.Duration) bool {
	f.t.Helper()
	got, _ := f.poll(seat, busy, rReady, at)
	return slices.ContainsFunc(got, func(m Message) bool { return m.MsgID == id })
}

func (f *roundFix) get(id string) Message {
	f.t.Helper()
	m, err := f.st.GetMessageClaim(context.Background(), f.tid, id)
	if err != nil {
		f.t.Fatal(err)
	}
	return m
}

// states fails on any job whose claim columns disagree with its claim_state.
func (f *roundFix) states() {
	f.t.Helper()
	for _, id := range f.ids {
		if p := ClaimStateProblem(f.get(id)); p != "" {
			f.t.Fatalf("%s: %s: %+v", id, p, f.get(id))
		}
	}
}

// accept is T2 by seat on the round the row is in now.
func (f *roundFix) accept(id, seat string, at time.Duration) (Message, error) {
	f.t.Helper()
	m, err := f.st.AcceptMessageClaim(context.Background(), f.tid, ClaimAct{MsgID: id, Seat: seat, Round: f.get(id).Round.OfferN}, f.t0.Add(at))
	f.states()
	return m, err
}

func (f *roundFix) renew(seat string, fresh, able bool, age, at time.Duration) []Message {
	f.t.Helper()
	held, err := f.st.RenewMessageRounds(context.Background(), f.tid, ClaimRenew{Seat: seat, Fresh: fresh, Able: able, AnchorAge: age}, f.t0.Add(at))
	if err != nil {
		f.t.Fatal(err)
	}
	f.states()
	return held
}

// owned opens a round for seat on a new job at `at` and accepts it.
func (f *roundFix) owned(seat string, at time.Duration) Message {
	f.t.Helper()
	id := f.job(at - time.Second)
	if !f.offeredTo(id, seat, false, at) {
		f.t.Fatalf("no round for %s", seat)
	}
	m, err := f.accept(id, seat, at)
	if err != nil || m.Round.State != ClaimOwned || m.Responsible != seat || m.ClaimN != 1 || string(m.Msg) == "" {
		f.t.Fatalf("accept: %+v %v", m, err)
	}
	return m
}

// FR-004: two accepts of one round, n = 100: exactly one gets the row and
// the body, the other is refused with the winner's row. Control: an accept
// of the right round by a seat that was told wins; one naming a stale round
// or by a seat never told is refused.
func TestMessageRoundAcceptRace(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			for i := range 100 {
				at := time.Duration(i) * time.Minute
				id := f.job(at)
				if !f.offeredTo(id, rA1, false, at) || !f.offeredTo(id, rB2, false, at) {
					t.Fatalf("round %d: %+v", i, f.get(id))
				}
				m := f.get(id)
				if m.Round.State != ClaimOffered || !slices.Equal(m.Round.OfferSet, []string{rA1, rB2}) || m.Round.OfferN != 1 {
					t.Fatalf("round %d: %+v", i, m.Round)
				}
				if i == 0 { // the control: a stale round and a seat never told
					for _, a := range []ClaimAct{{MsgID: id, Seat: rA1, Round: 2}, {MsgID: id, Seat: rA2, Round: 1}} {
						if _, err := st.AcceptMessageClaim(ctx, f.tid, a, f.t0.Add(at)); !errors.Is(err, ErrConflict) {
							t.Fatalf("control accept %+v: %v", a, err)
						}
					}
				}
				var wg sync.WaitGroup
				var start sync.WaitGroup
				start.Add(1)
				res := make([]Message, 2)
				errs := make([]error, 2)
				for k, seat := range []string{rA1, rB2} {
					wg.Add(1)
					go func() {
						defer wg.Done()
						start.Wait()
						res[k], errs[k] = st.AcceptMessageClaim(ctx, f.tid, ClaimAct{MsgID: id, Seat: seat, Round: 1}, f.t0.Add(at+time.Second))
					}()
				}
				start.Done()
				wg.Wait()
				win := slices.IndexFunc(errs, func(e error) bool { return e == nil })
				if win < 0 || !errors.Is(errs[1-win], ErrConflict) {
					t.Fatalf("race %d: %v", i, errs)
				}
				w, l := res[win], res[1-win]
				if string(w.Msg) == "" || w.ResponsibleGen != 1 || w.ClaimN != 1 || w.Round.State != ClaimOwned || l.Responsible != w.Responsible {
					t.Fatalf("race %d: winner %+v loser %+v", i, w, l)
				}
				if _, err := st.CloseMessageClaim(ctx, f.tid, ClaimClose{MsgID: id, Seat: w.Responsible, How: "answered", Gen: 1}, f.t0.Add(at+2*time.Second)); err != nil {
					t.Fatalf("close %d: %v", i, err)
				}
				f.states()
				f.ids = nil // closed: keep the state check on the open jobs
			}
		})
	}
}

// FR-003: a round not accepted in OfferWindow lapses; the next round skips
// the lapsed seats; once every ready seat has lapsed the skip list clears;
// claim_n never moves on a lapse; OfferMax rounds close the job dead, once.
func TestMessageRoundLapse(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			id := f.job(0)
			f.offeredTo(id, rA1, false, time.Second)
			f.offeredTo(id, rA2, false, time.Second)
			// control: inside the window the round stands, and it is full
			if f.offeredTo(id, rB1, false, 20*time.Second) || f.get(id).Round.OfferN != 1 {
				t.Fatalf("round 1 moved inside its window: %+v", f.get(id).Round)
			}
			// past it: round 1 lapses, b1 opens round 2 in the same poll
			if !f.offeredTo(id, rB1, false, 22*time.Second) {
				t.Fatalf("no round 2: %+v", f.get(id).Round)
			}
			if r := f.get(id); r.Round.OfferN != 2 || r.ClaimN != 0 || !slices.Equal(r.Round.Lapsed, []string{rA1, rA2}) {
				t.Fatalf("lapse: %+v claim_n %d", r.Round, r.ClaimN)
			}
			if f.offeredTo(id, rA1, false, 23*time.Second) || !f.offeredTo(id, rB2, false, 23*time.Second) {
				t.Fatalf("skip list: %+v", f.get(id).Round)
			}
			// round 2 lapses: everyone has lapsed but a fifth ready seat (control) ...
			if got, _ := f.poll(rA1, false, append(slices.Clone(rReady), "c-004@box-b"), 45*time.Second); len(got) != 0 {
				t.Fatalf("skip list cleared with a ready seat untried: %+v", got)
			}
			// ... and once every ready seat has, the list clears and a1 opens round 3
			if !f.offeredTo(id, rA1, false, 46*time.Second) || f.get(id).Round.OfferN != 3 || len(f.get(id).Round.Lapsed) != 0 {
				t.Fatalf("round 3: %+v", f.get(id).Round)
			}
			at := 46 * time.Second
			for n := 4; n <= OfferMax; n++ {
				at += OfferWindow + time.Second
				if got, dead := f.poll(rB1, false, []string{rB1}, at); len(got) != 1 || len(dead) != 0 || got[0].Round.OfferN != n {
					t.Fatalf("round %d: %+v dead %+v", n, got, dead)
				}
			}
			at += OfferWindow + time.Second
			got, dead := f.poll(rB2, false, rReady, at)
			if len(got) != 0 || len(dead) != 1 || dead[0].HandledHow != "dead" || dead[0].ClaimN != 0 || dead[0].Round.State != ClaimDone {
				t.Fatalf("dead: %+v %+v", got, dead)
			}
			if got, dead := f.poll(rA1, false, rReady, at+time.Hour); len(got)+len(dead) != 0 {
				t.Fatalf("dead twice: %+v %+v", got, dead)
			}
		})
	}
}

// FR-002: a renew writes anchor + HBFresh on the hub clock, never now +
// HBFresh (n = 20 anchors); a renew that is not fresh writes nothing
// (control); past the anchor's lock the next poll frees the job (T5) and
// opens a round, claim_n unmoved, a second before it does not.
func TestMessageRoundRenewAnchor(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			id := f.owned(rA1, 0).MsgID
			var at, age time.Duration
			for i := range 20 {
				at, age = time.Duration(i+1)*5*time.Second, time.Duration(i%7)*9*time.Second
				held := f.renew(rA1, true, true, age, at)
				if len(held) != 1 || !held[0].LockedUntil.Equal(f.t0.Add(at-age+HBFresh)) {
					t.Fatalf("renew %d (age %s): %+v", i, age, held)
				}
				if before := f.get(id).LockedUntil; !f.renew(rA1, false, true, 0, at+time.Second)[0].LockedUntil.Equal(before) {
					t.Fatalf("a stale renew moved the lock")
				}
			}
			end := at - age + HBFresh
			if f.offeredTo(id, rB1, false, end-time.Second) || f.get(id).Round.State != ClaimOwned {
				t.Fatalf("taken before the lock ran out: %+v", f.get(id))
			}
			if !f.offeredTo(id, rB1, false, end+time.Second) {
				t.Fatalf("not re-offered after the lock: %+v", f.get(id))
			}
			if m := f.get(id); m.Responsible != "" || m.ClaimN != 1 || m.ResponsibleGen != 1 {
				t.Fatalf("expiry: %+v", m)
			}
			// a renew after the lock ran out never takes it back
			if held := f.renew(rA1, true, true, 0, end+2*time.Second); len(held) != 0 {
				t.Fatalf("expired job renewed: %+v", held)
			}
		})
	}
}

// FR-006, n = 5 each: a parked job whose holder stays able is renewed for
// its whole park; one whose holder stops being able goes free HBFresh after
// its last renew while parked_until is still ahead, a second before it does
// not, and the next owner inherits wait_token and park_reason. A park past
// ParkMax or at a stale fence is refused.
func TestMessageRoundPark(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			for i := range 5 {
				m := f.owned(rA1, time.Duration(i)*3*time.Hour)
				at := m.Round.AcceptedAt.Sub(f.t0)
				park := ClaimAct{MsgID: m.MsgID, Seat: rA1, Gen: m.ResponsibleGen, Until: f.t0.Add(at + time.Hour), Wait: "c-120", Reason: "lane c-120 builds it"}
				bad := park
				bad.Until = park.Until.Add(time.Minute)
				if _, err := st.ParkMessageClaim(ctx, f.tid, bad, f.t0.Add(at)); !errors.Is(err, ErrClaimArg) {
					t.Fatalf("park past ParkMax: %v", err)
				}
				bad = park
				bad.Gen++
				if _, err := st.ParkMessageClaim(ctx, f.tid, bad, f.t0.Add(at)); !errors.Is(err, ErrConflict) {
					t.Fatalf("park at a stale fence: %v", err)
				}
				if p, err := st.ParkMessageClaim(ctx, f.tid, park, f.t0.Add(at)); err != nil || p.Round.State != ClaimParked || p.Round.WaitToken != "c-120" {
					t.Fatalf("park: %+v %v", p, err)
				}
				f.states()
				// able for the first half hour: renewed every minute, never taken
				last := at
				for ; last < at+30*time.Minute; last += time.Minute {
					if held := f.renew(rA1, false, true, 0, last); len(held) != 1 || !held[0].LockedUntil.Equal(f.t0.Add(last+HBFresh)) {
						t.Fatalf("able renew at %s: %+v", last, held)
					}
					if f.offeredTo(m.MsgID, rB1, false, last+30*time.Second) {
						t.Fatalf("an able holder's park was taken at %s", last)
					}
				}
				last -= time.Minute
				// not able (a dead login): renews write nothing, the job goes free at the lock
				f.renew(rA1, false, false, 0, last+time.Minute)
				if f.offeredTo(m.MsgID, rB1, false, last+HBFresh-time.Second) {
					t.Fatalf("taken before its lock")
				}
				if !f.offeredTo(m.MsgID, rB1, false, last+HBFresh+time.Second) {
					t.Fatalf("not able, not re-offered: %+v", f.get(m.MsgID))
				}
				n, err := f.accept(m.MsgID, rB1, last+HBFresh+2*time.Second)
				if err != nil || n.Round.WaitToken != "c-120" || n.Round.ParkReason != park.Reason || n.ClaimN != 2 || n.ResponsibleGen != 2 {
					t.Fatalf("next owner: %+v %v", n, err)
				}
			}
		})
	}
}

// T7a and T7b: the holder unparks at its fence and owns again; a parked job
// whose wait has arrived is re-offered to the holder alone, who accepts it
// again. Control: a non-holder's unpark and re-offer are refused.
func TestMessageRoundUnpark(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			m := f.owned(rA1, 0)
			act := ClaimAct{MsgID: m.MsgID, Seat: rA1, Gen: 1, Until: f.t0.Add(time.Hour), Wait: "c-120", Reason: "lane"}
			step := func(call func(context.Context, string, ClaimAct, time.Time) (Message, error), a ClaimAct, at time.Duration) (Message, error) {
				r, err := call(ctx, f.tid, a, f.t0.Add(at))
				f.states()
				return r, err
			}
			if _, err := step(st.ParkMessageClaim, act, time.Second); err != nil {
				t.Fatal(err)
			}
			other := act
			other.Seat = rB1
			for _, call := range []func(context.Context, string, ClaimAct, time.Time) (Message, error){st.UnparkMessageClaim, st.ReofferMessageClaim} {
				if _, err := step(call, other, 2*time.Second); !errors.Is(err, ErrConflict) {
					t.Fatalf("non-holder: %v", err)
				}
			}
			if r, err := step(st.UnparkMessageClaim, act, 3*time.Second); err != nil || r.Round.State != ClaimOwned || !r.LockedUntil.Equal(f.t0.Add(3*time.Second+HBFresh)) {
				t.Fatalf("unpark: %+v %v", r, err)
			}
			act.Until = f.t0.Add(time.Hour)
			if _, err := step(st.ParkMessageClaim, act, 4*time.Second); err != nil {
				t.Fatal(err)
			}
			r, err := step(st.ReofferMessageClaim, act, 5*time.Second)
			if err != nil || r.Round.State != ClaimOffered || !slices.Equal(r.Round.OfferSet, []string{rA1}) || r.Responsible != "" {
				t.Fatalf("re-offer: %+v %v", r, err)
			}
			if f.offeredTo(m.MsgID, rB1, false, 6*time.Second) {
				t.Fatalf("a re-offer to the holder alone was joined at once")
			}
			if r, err = f.accept(m.MsgID, rA1, 7*time.Second); err != nil || r.ResponsibleGen != 2 || r.Responsible != rA1 {
				t.Fatalf("accept again: %+v %v", r, err)
			}
		})
	}
}

// FR-007: a fresh seat that works one job and does not touch another for
// JobIdleMax loses the other and keeps the one it touches (the control).
func TestMessageRoundTouch(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			kept, idle := f.owned(rA1, 0), f.owned(rA1, time.Second)
			at := time.Second
			for ; at <= JobIdleMax+3*time.Minute; at += time.Minute {
				if _, err := st.TouchMessageClaim(ctx, f.tid, ClaimAct{MsgID: kept.MsgID, Seat: rA1, Gen: 1}, f.t0.Add(at)); err != nil {
					t.Fatalf("touch at %s: %v", at, err)
				}
				f.renew(rA1, true, true, 0, at)
				f.poll(rB1, false, rReady, at+time.Second)
			}
			if m := f.get(kept.MsgID); m.Round.State != ClaimOwned || m.Responsible != rA1 {
				t.Fatalf("touched job lost: %+v", m)
			}
			m := f.get(idle.MsgID)
			if m.Responsible == rA1 || m.ResponsibleGen != 1 {
				t.Fatalf("untouched job still held: %+v", m)
			}
			// it went free within HBFresh of its last renewal: idle since t0+1s, last renew at < JobIdleMax+1s
			if !slices.Contains(m.Round.OfferSet, rB1) && m.Round.State != ClaimOffered && !slices.Contains(m.Round.Lapsed, rB1) {
				t.Fatalf("untouched job not re-offered: %+v", m)
			}
			if _, err := st.TouchMessageClaim(ctx, f.tid, ClaimAct{MsgID: idle.MsgID, Seat: rA1, Gen: 1}, f.t0.Add(at)); !errors.Is(err, ErrConflict) {
				t.Fatalf("touch of a lost job: %v", err)
			}
		})
	}
}

// FR-005 on the store: an idle seat opens a round at once, a busy one only
// BusyDelay after the job went free (control: the idle seat at the same
// instant); a busy join waits BusyDelay and a same-harness join HarnessDelay
// after the round opened, another harness joins at once. A release (T8)
// frees the job as of now; a harness never polls a job it refused.
func TestMessageRoundIdleFirst(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newRoundFix(t, st)
			id := f.job(0)
			if f.offeredTo(id, rB2, true, BusyDelay-time.Second) {
				t.Fatalf("busy seat opened inside BusyDelay")
			}
			if !f.offeredTo(id, rA1, false, BusyDelay-time.Second) {
				t.Fatalf("idle seat did not open")
			}
			opened := BusyDelay - time.Second
			if f.offeredTo(id, rB1, false, opened+HarnessDelay-time.Second) {
				t.Fatalf("same harness joined inside HarnessDelay")
			}
			if f.offeredTo(id, rB2, true, opened+BusyDelay-time.Second) {
				t.Fatalf("busy seat joined inside BusyDelay")
			}
			if !f.offeredTo(id, rB2, true, opened+BusyDelay) {
				t.Fatalf("busy seat did not join after BusyDelay: %+v", f.get(id).Round)
			}
			m, err := f.accept(id, rB2, opened+BusyDelay+time.Second)
			if err != nil {
				t.Fatal(err)
			}
			rel := opened + 2*BusyDelay
			if m, err = st.ReleaseMessageClaim(ctx, f.tid, ClaimClose{MsgID: id, Seat: rB2, Harness: "grok", Reason: "harness-refused:prd", Gen: m.ResponsibleGen}, f.t0.Add(rel)); err != nil || m.Round.State != ClaimFree || !m.Round.OfferUntil.Equal(f.t0.Add(rel)) {
				t.Fatalf("release: %+v %v", m, err)
			}
			f.states()
			if f.offeredTo(id, rA2, false, rel+time.Second) {
				t.Fatalf("grok seat polled a grok-refused job")
			}
			if f.offeredTo(id, rA1, true, rel+BusyDelay-time.Second) || !f.offeredTo(id, rA1, true, rel+BusyDelay) {
				t.Fatalf("busy open after a release: %+v", f.get(id).Round)
			}
		})
	}
}
