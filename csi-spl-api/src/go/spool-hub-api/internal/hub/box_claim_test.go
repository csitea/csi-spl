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
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
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
//  6. spec 068 L3's calls: the fence, the hub-down adopt, the flat array
//  7. spec 093's two-phase claim (claimRounds): a round across both boxes,
//     the accept race, a park that lapses on a not-able holder, and the late
//     holder stopped by the fence and by answer-once (FR-009)
type claimOut struct {
	Seat    string         `json:"seat"`
	Msgs    []hub.ClaimRow `json:"msgs"`
	Dead    []hub.ClaimRow `json:"dead"`
	Held    bool           `json:"held"`
	Adopted bool           `json:"adopted"`
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
			Files: []byte(`[]`), Msg: []byte(`{"v":1,"msg_id":"` + id + `","task_id":"` + id + `","ts":"` + at.Format(time.RFC3339) +
				`","from":"c-120","to":"peers","kind":"note","body":"report ` + id + `","files":[]}`), Env: []byte(`{"id":"` + id + `"}`),
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

	// 6. L3's calls: the fence, the hub-down adopt, the flat array
	fresh := peerMsg()
	ad := mustClaim(t, pc, action.ClaimArgs{Op: "adopt", Seat: "c-001", MsgID: fresh})
	if !ad.Adopted || len(ad.Msgs) != 1 || ad.Msgs[0].Responsible != "c-001@box-c" || ad.Msgs[0].Gen != 1 {
		t.Fatalf("adopt: %+v", ad)
	}
	if ad = mustClaim(t, sat, action.ClaimArgs{Op: "adopt", Seat: "c-001", MsgID: fresh}); ad.Adopted || ad.Msgs[0].Responsible != "c-001@box-c" {
		t.Fatalf("adopt of a held message: %+v", ad)
	}
	if ck := mustClaim(t, pc, action.ClaimArgs{Op: "check", Seat: "c-001", MsgID: fresh, Gen: 1}); !ck.Held {
		t.Fatalf("check, held: %+v", ck)
	}
	for _, c := range []struct {
		b    *box
		seat string
		gen  int64
	}{{sat, "c-001", 1}, {pc, "c-001", 2}, {pc, "g-004", 1}} {
		if ck := mustClaim(t, c.b, action.ClaimArgs{Op: "check", Seat: c.seat, MsgID: fresh, Gen: c.gen}); ck.Held {
			t.Fatalf("check %s gen %d: %+v", c.seat, c.gen, ck)
		}
	}
	advance(store.ClaimTTLDefault + time.Second)
	if ck := mustClaim(t, pc, action.ClaimArgs{Op: "check", Seat: "c-001", MsgID: fresh, Gen: 1}); ck.Held {
		t.Fatalf("check after the lock ran out: %+v", ck)
	}
	raw, err := action.Claim(ctx, sat.cfg, action.ClaimArgs{Op: "poll", Seat: "c-001", Hub: sat.c})
	if err != nil {
		t.Fatal(err)
	}
	flat, err := action.ClaimFlat(raw)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err := json.Unmarshal(flat, &rows); err != nil || len(rows) != 1 {
		t.Fatalf("flat %s: %v", flat, err)
	}
	r := rows[0]
	if r["msg_id"] != fresh || r["responsible_gen"] != float64(2) || r["task_id"] != fresh || r["from"] != "c-120" ||
		r["to"] != "peers" || r["kind"] != "note" || r["body"] != "report "+fresh || r["ts"] == nil || r["files"] == nil {
		t.Fatalf("flat row for the poll loop: %v", r)
	}

	// 7. spec 093: close the last 068 claim so the pool is empty, then rounds
	mustClaim(t, sat, action.ClaimArgs{Op: "done", Seat: "c-001", MsgID: fresh, Gen: 2})
	claimRounds(t, roundEnv{e: e, tid: tid, sat: sat, pc: pc, advance: advance, peerMsg: peerMsg})

	// the client refuses what the hub would, before dialling
	if _, err := claimCall(t, sat, action.ClaimArgs{Op: "done", Seat: "c-001", MsgID: id, How: "maybe"}); err == nil || !strings.Contains(err.Error(), "--how") {
		t.Fatalf("bad how: %v", err)
	}
	if _, err := claimCall(t, sat, action.ClaimArgs{Op: "release", Seat: "c-001", MsgID: id}); err == nil || !strings.Contains(err.Error(), "--reason") {
		t.Fatalf("release without a reason: %v", err)
	}
}

type roundEnv struct {
	e       *env
	tid     string
	sat, pc *box
	advance func(time.Duration)
	peerMsg func() string
}

// claimRounds is TestBoxMessageClaim's step 7, spec 093 section 4 through
// the claim frame (task T009). Seats: c-001 and g-003 on box-b (sat),
// c-001 and g-004 on box-c (pc).
func claimRounds(t *testing.T, r roundEnv) {
	t.Helper()
	sat, pc := r.sat, r.pc
	ctx := context.Background()
	stub := func(out claimOut, id string) *hub.ClaimRow {
		for i := range out.Msgs {
			if out.Msgs[i].MsgID == id {
				return &out.Msgs[i]
			}
		}
		return nil
	}

	// 7a. a round: an idle seat opens it at once; a busy seat waits
	// BUSY_DELAY, a second claude seat waits for room for another harness;
	// an idle grok seat on the other box joins; then the round is full
	jobs := make([]string, 10)
	for i := range jobs {
		jobs[i] = r.peerMsg()
	}
	ready := []string{"g-003", "c-001@box-c", "g-004@box-c"}
	got := mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001", State: "idle", Ready: ready, Max: 10})
	if len(got.Msgs) != len(jobs) {
		t.Fatalf("idle poll opened %d rounds, want %d: %+v", len(got.Msgs), len(jobs), got)
	}
	for _, row := range got.Msgs {
		if row.State != store.ClaimOffered || row.Round != 1 || len(row.OfferSet) != 1 || row.OfferSet[0] != "c-001@box-b" ||
			row.Responsible != "" || len(row.Msg) != 0 || row.OfferUntil == "" {
			t.Fatalf("stub (no body, nobody owns it): %+v", row)
		}
	}
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "g-004", State: "busy", Max: 10}); len(got.Msgs) != 0 {
		t.Fatalf("a busy seat joined before BUSY_DELAY: %+v", got)
	}
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "c-001", State: "idle", Max: 10}); len(got.Msgs) != 0 {
		t.Fatalf("a second claude seat joined before HarnessDelay: %+v", got)
	}
	got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "g-004", State: "idle", Max: 10})
	if len(got.Msgs) != len(jobs) || len(got.Msgs[0].OfferSet) != store.OfferK {
		t.Fatalf("an idle grok seat on the other box did not join: %+v", got)
	}
	r.advance(store.HarnessDelay + time.Second)
	if got = mustClaim(t, pc, action.ClaimArgs{Op: "poll", Seat: "c-001", State: "idle", Max: 10}); len(got.Msgs) != 0 {
		t.Fatalf("a full round (OFFER_K) took a third seat: %+v", got)
	}

	// 7b. the accept race, once per job: exactly one wins the body and the
	// fence, the other is refused naming the winner; a stale round number
	// and a seat that was not told are refused first
	refusedClaim(t, sat, action.ClaimArgs{Op: "accept", Seat: "c-001", MsgID: jobs[0], Round: 2}, "claim_refused", "the round is 1")
	refusedClaim(t, sat, action.ClaimArgs{Op: "accept", Seat: "g-003", MsgID: jobs[0], Round: 1}, "claim_refused", "not offered to g-003@box-b")
	winner := map[string]string{}
	gens := map[string]int64{}
	for _, id := range jobs {
		var wg sync.WaitGroup
		outs, errs := make([]claimOut, 2), make([]error, 2)
		for i, c := range []struct {
			b    *box
			seat string
		}{{sat, "c-001"}, {pc, "g-004"}} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				outs[i], errs[i] = claimCall(t, c.b, action.ClaimArgs{Op: "accept", Seat: c.seat, MsgID: id, Round: 1})
			}()
		}
		wg.Wait()
		win, lose := 0, 1
		if errs[0] != nil {
			win, lose = 1, 0
		}
		if errs[win] != nil {
			t.Fatalf("%s: no accept won: %v / %v", id, errs[0], errs[1])
		}
		row := outs[win].Msgs[0]
		if row.State != store.ClaimOwned || row.Responsible != outs[win].Seat || row.Gen != 1 || row.ClaimN != 1 ||
			!strings.Contains(string(row.Msg), "report "+id) {
			t.Fatalf("%s: the winner's row: %+v", id, row)
		}
		var he *hubclient.HubError
		if !errors.As(errs[lose], &he) || he.Token != "claim_refused" || !strings.Contains(he.Detail, "responsible is "+row.Responsible) {
			t.Fatalf("%s: the loser: %v", id, errs[lose])
		}
		winner[id], gens[id] = row.Responsible, row.Gen
	}

	// 7c. park on a lane; renewed while the holder is able, free within
	// HB_FRESH once it is not, although parked_until is 30 min ahead
	job, holder := jobs[0], winner[jobs[0]]
	hb := sat
	hseat := "c-001"
	if holder == "g-004@box-c" {
		hb, hseat = pc, "g-004"
	}
	refusedClaim(t, hb, action.ClaimArgs{Op: "park", Seat: hseat, MsgID: job, Gen: gens[job], Until: "2h", Wait: "c-130", Reason: "waits on a lane"},
		"bad_frame", "at most 60 min")
	pk := mustClaim(t, hb, action.ClaimArgs{Op: "park", Seat: hseat, MsgID: job, Gen: gens[job], Until: "30m", Wait: "c-130", Reason: "waits on a lane"})
	if row := pk.Msgs[0]; row.State != store.ClaimParked || row.WaitToken != "c-130" || row.ParkedUntil == "" || len(row.Msg) != 0 {
		t.Fatalf("park: %+v", row)
	}
	mustClaim(t, hb, action.ClaimArgs{Op: "touch", Seat: hseat, MsgID: job, Gen: gens[job]})
	refusedClaim(t, hb, action.ClaimArgs{Op: "touch", Seat: hseat, MsgID: job, Gen: gens[job] + 1}, "claim_refused", "the fence moved")
	r.advance(time.Minute)
	rn := mustClaim(t, hb, action.ClaimArgs{Op: "renew", Seat: hseat, HB: "able"})
	if p := stub(rn, job); p == nil || p.State != store.ClaimParked {
		t.Fatalf("an able holder's park is renewed: %+v", rn)
	}
	r.advance(time.Minute)
	mustClaim(t, hb, action.ClaimArgs{Op: "renew", Seat: hseat, HB: "stale"}) // a dead login: no renew
	r.advance(store.HBFresh/2 + time.Second)
	got = mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "g-003", State: "idle", Max: 50})
	re := stub(got, job)
	if re == nil || re.State != store.ClaimOffered || re.Round != 2 || re.OfferSet[0] != "g-003@box-b" || re.WaitToken != "c-130" || re.Responsible != "" {
		t.Fatalf("the parked job of a not-able holder is in a new round, wait token inherited: %+v", got)
	}
	refusedClaim(t, hb, action.ClaimArgs{Op: "unpark", Seat: hseat, MsgID: job, Gen: gens[job]}, "claim_refused", "nobody holds it")

	// 7d. FR-009: the new owner accepts; the late holder's fence says lost
	// and its answer on the old generation is 409; the owner's first answer
	// stands and a second is 409
	acc := mustClaim(t, sat, action.ClaimArgs{Op: "accept", Seat: "g-003", MsgID: job, Round: 2})
	if acc.Msgs[0].Gen != gens[job]+1 || acc.Msgs[0].ClaimN != 2 {
		t.Fatalf("re-accept: %+v", acc.Msgs[0])
	}
	if ck := mustClaim(t, hb, action.ClaimArgs{Op: "check", Seat: hseat, MsgID: job, Gen: gens[job]}); ck.Held {
		t.Fatalf("the late holder's fence: %+v", ck)
	}
	if ck := mustClaim(t, sat, action.ClaimArgs{Op: "check", Seat: "g-003", MsgID: job, Gen: gens[job] + 1}); !ck.Held {
		t.Fatalf("the owner's fence: %+v", ck)
	}
	answer := func(b *box, from string, gen int64) error {
		s, err := b.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(s)
		env := signedIn(t, b, "box-b", "", "", &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(),
			TS: time.Now().UTC().Format(time.RFC3339), From: from, To: "c-120", Kind: "result", Body: "the answer", Files: []msg.Attachment{}})
		_, err = s.SendAnswer(ctx, env, job, gen)
		return err
	}
	var he *hubclient.HubError
	if err := answer(hb, hseat, gens[job]); !errors.As(err, &he) || he.Token != hub.TokenNotResponsible {
		t.Fatalf("the late holder's answer: %v", err)
	}
	if err := answer(sat, "g-003", gens[job]+1); err != nil {
		t.Fatalf("the owner's answer: %v", err)
	}
	if err := answer(sat, "g-003", gens[job]+1); !errors.As(err, &he) || he.Token != hub.TokenAnswered {
		t.Fatalf("a second answer: %v", err)
	}
	if d := mustClaim(t, sat, action.ClaimArgs{Op: "done", Seat: "g-003", MsgID: job, Gen: gens[job] + 1}); d.Msgs[0].State != store.ClaimDone {
		t.Fatalf("done: %+v", d.Msgs[0])
	}

	// the client refuses what the hub would, before dialling
	for _, in := range []action.ClaimArgs{
		{Op: "accept", Seat: "c-001", MsgID: job},
		{Op: "park", Seat: "c-001", MsgID: job, Gen: 1, Until: "30m"},
		{Op: "unpark", Seat: "c-001", MsgID: job},
		{Op: "poll", Seat: "c-001", State: "asleep"},
		{Op: "renew", Seat: "c-001", HB: "maybe"},
	} {
		if _, err := claimCall(t, sat, in); err == nil || errors.As(err, &he) {
			t.Fatalf("%+v: want a client refusal, got %v", in, err)
		}
	}
	// a fresh renew without its anchor is refused by the hub (FR-002)
	raw, _ := json.Marshal(map[string]any{"seat": "c-001", "fresh": true})
	if _, err := sat.c.Claim(ctx, "renew", raw); !errors.As(err, &he) || !strings.Contains(he.Detail, "anchor_age_s") {
		t.Fatalf("a fresh renew without anchor_age_s: %v", err)
	}
}
