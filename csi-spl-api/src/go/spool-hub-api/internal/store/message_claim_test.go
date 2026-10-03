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
