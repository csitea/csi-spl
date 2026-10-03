package store

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

var (
	_ AnswerOnce = (*Memory)(nil)
	_ AnswerOnce = (*Postgres)(nil)
)

// Spec 068 4.2 (rdb 0111): an answer is recorded only from the message's
// responsible seat on its current gen, and only once. Run on Memory and
// Postgres. Each step is a control: drop the seat / gen condition and the
// refusals are accepted; drop the key and the race stores more than one.
func TestAnswerOnceStore(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ao := st.(AnswerOnce)
			tid, other := newTenant(t, st), newTenant(t, st)
			// msgFor is to CLE-07: rdb 0110 makes CLE-07@box-c responsible at insert, gen 0.
			q := msgFor(tid, uuid4(), "box-c", now, now, `{"q":1}`)
			if _, err := st.InsertMessage(ctx, q); err != nil {
				t.Fatal(err)
			}
			const seat = "CLE-07@box-c"
			ans := func(seat string, gen int64) Answer {
				return Answer{Answers: q.MsgID, AnswerMsgID: uuid4(), Seat: seat, Gen: gen, AnsweredAt: now}
			}

			for what, a := range map[string]Answer{
				"another seat":               ans("CLE-08@box-c", 0),
				"the same id on another box": ans("CLE-07@box-d", 0),
				"a stale gen":                ans(seat, 1),
			} {
				got, err := ao.ClaimAnswer(ctx, tid, a)
				if !errors.Is(err, ErrNotResponsible) || got.Seat != seat || got.Gen != 0 {
					t.Fatalf("%s: %+v %v", what, got, err)
				}
			}
			if _, err := ao.ClaimAnswer(ctx, other, ans(seat, 0)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant: %v", err)
			}
			unknown := ans(seat, 0)
			unknown.Answers = uuid4()
			if _, err := ao.ClaimAnswer(ctx, tid, unknown); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown message: %v", err)
			}
			self := ans(seat, 0)
			self.AnswerMsgID = q.MsgID
			if _, err := ao.ClaimAnswer(ctx, tid, self); err == nil {
				t.Fatal("a message answered itself")
			}

			// eight answers race on the right seat and gen: exactly one is stored
			const n = 8
			var wg sync.WaitGroup
			var mu sync.Mutex
			var won []Answer
			var lost []Answer
			for range n {
				wg.Add(1)
				go func() {
					defer wg.Done()
					a := ans(seat, 0)
					got, err := ao.ClaimAnswer(ctx, tid, a)
					mu.Lock()
					defer mu.Unlock()
					switch {
					case err == nil:
						won = append(won, a)
					case errors.Is(err, ErrAnswered):
						lost = append(lost, got)
					default:
						t.Errorf("race: %v", err)
					}
				}()
			}
			wg.Wait()
			if len(won) != 1 || len(lost) != n-1 {
				t.Fatalf("race: %d won, %d lost", len(won), len(lost))
			}
			first := won[0]
			for _, l := range lost {
				if l.AnswerMsgID != first.AnswerMsgID || l.Seat != seat {
					t.Fatalf("a loser named %+v, not the first %+v", l, first)
				}
			}
			// once answered, even another seat hears who answered
			if got, err := ao.ClaimAnswer(ctx, tid, ans("CLE-08@box-c", 0)); !errors.Is(err, ErrAnswered) || got.AnswerMsgID != first.AnswerMsgID {
				t.Fatalf("after the answer: %+v %v", got, err)
			}
			// a resend of the winner is the winner
			if got, err := ao.ClaimAnswer(ctx, tid, first); err != nil || got.AnswerMsgID != first.AnswerMsgID {
				t.Fatalf("resend: %+v %v", got, err)
			}
			// a loser's release is a no-op; the winner's frees the message
			if err := ao.ReleaseAnswer(ctx, tid, q.MsgID, uuid4()); err != nil {
				t.Fatal(err)
			}
			if _, err := ao.ClaimAnswer(ctx, tid, ans(seat, 0)); !errors.Is(err, ErrAnswered) {
				t.Fatalf("a loser's release freed it: %v", err)
			}
			if err := ao.ReleaseAnswer(ctx, tid, q.MsgID, first.AnswerMsgID); err != nil {
				t.Fatal(err)
			}
			if _, err := ao.ClaimAnswer(ctx, tid, ans(seat, 0)); err != nil {
				t.Fatalf("after the release: %v", err)
			}

			// a peer message whose lock moved (rdb 0110): peer A claimed it on
			// gen 1, its lock ran out, peer B took it on gen 2. A still thinks it
			// holds it; its answer is refused naming B, and B's is stored.
			pm := msgFor(tid, uuid4(), "box-a", now, now, `{"peers":1}`)
			pm.FromID, pm.ToID = "c-009", PeersID
			if _, err := st.InsertMessage(ctx, pm); err != nil {
				t.Fatal(err)
			}
			mc := st.(MessageClaims)
			const seatA, seatB = "c-001@box-a", "c-002@box-b"
			for i, sb := range []string{seatA, seatB} {
				got, _, err := mc.PollMessageClaims(ctx, tid, ClaimPoll{Seat: sb, Harness: "claude", Max: 1, TTL: ClaimTTLMin},
					now.Add(time.Duration(i)*(ClaimTTLMin+time.Second)))
				if err != nil || len(got) != 1 || got[0].MsgID != pm.MsgID || got[0].ResponsibleGen != int64(i+1) {
					t.Fatalf("poll %s: %+v %v", sb, got, err)
				}
			}
			late := Answer{Answers: pm.MsgID, AnswerMsgID: uuid4(), Seat: seatA, Gen: 1, AnsweredAt: now}
			if got, err := ao.ClaimAnswer(ctx, tid, late); !errors.Is(err, ErrNotResponsible) || got.Seat != seatB || got.Gen != 2 {
				t.Fatalf("the lost lock answered: %+v %v", got, err)
			}
			if _, err := ao.ClaimAnswer(ctx, tid, Answer{Answers: pm.MsgID, AnswerMsgID: uuid4(), Seat: seatB, Gen: 2, AnsweredAt: now}); err != nil {
				t.Fatalf("the holder: %v", err)
			}
		})
	}
}
