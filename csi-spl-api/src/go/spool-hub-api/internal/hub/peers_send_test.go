package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 068 4.1, through the real front end (action.SendCtx == `spool send`):
// a lane's report `--to peers` is accepted, stored with needs_peer and no
// responsible, pushed to no box, and locked by exactly one of two seats on
// two boxes polling at once. A message to the peers signed to a real box is
// refused, and local mode (no hub to claim on) refuses it before writing.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestSendToPeers(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	sat := e.box(tid, "box-b", "c-120", "c-001")
	pc := e.box(tid, "box-c", "g-004")
	e.pin(tid, sat)
	e.pin(tid, pc)

	for range 5 {
		out := send(t, sat, "c-120", msg.PeersID, "result", "lane report", "")
		row, err := e.st.(store.MessageClaims).GetMessageClaim(ctx, tid, out.MsgID)
		if err != nil {
			t.Fatal(err)
		}
		if !row.NeedsPeer || row.Responsible != "" || row.ToID != msg.PeersID || row.ToBox != msg.PeersToBox {
			t.Fatalf("stored row: needs_peer=%v responsible=%q to=%s@%s", row.NeedsPeer, row.Responsible, row.ToID, row.ToBox)
		}
		// two seats on two boxes poll at once: one locks it, once
		got := make([][]string, 2)
		var wg sync.WaitGroup
		for i, p := range []struct {
			b    *box
			seat string
		}{{sat, "c-001"}, {pc, "g-004"}} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				c, err := claimCall(t, p.b, action.ClaimArgs{Op: "poll", Seat: p.seat, Max: 3})
				if err != nil {
					t.Errorf("poll %s: %v", p.seat, err)
					return
				}
				for _, r := range c.Msgs {
					got[i] = append(got[i], r.MsgID)
				}
			}()
		}
		wg.Wait()
		if n := len(got[0]) + len(got[1]); n != 1 || append(got[0], got[1]...)[0] != out.MsgID {
			t.Fatalf("polls took %v / %v, want %s exactly once", got[0], got[1], out.MsgID)
		}
		// close it, so the next round's poll sees only the next report
		seat, b := "c-001", sat
		if len(got[1]) == 1 {
			seat, b = "g-004", pc
		}
		mustClaim(t, b, action.ClaimArgs{Op: "done", Seat: seat, MsgID: out.MsgID})
	}
	// no box received it: the sender's box has no peers inbox
	if _, err := os.Stat(filepath.Join(sat.cfg.SpoolRoot, msg.PeersID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a peers inbox appeared on the box: %v", err)
	}

	// signed to a real box: refused, not stored
	s, err := sat.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	env := signedIn(t, sat, "box-c", "", "", &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(),
		TS: time.Now().UTC().Format(time.RFC3339), From: "c-120", To: msg.PeersID, Kind: "note", Body: "x", Files: []msg.Attachment{}})
	var he *hubclient.HubError
	if _, err := s.Send(ctx, env); !errors.As(err, &he) || he.Status != http.StatusBadRequest {
		t.Fatalf("peers to box-c: %v", err)
	}
	if m, _ := env.Inner(); func() bool { ok, _ := e.st.HasMessage(ctx, tid, m.MsgID); return ok }() {
		t.Fatal("a refused peers message was stored")
	}
	// --to-box elsewhere, and local mode, refuse before anything is written
	if _, err := action.SendCtx(ctx, sat.cfg, action.SendArgs{From: "c-120", To: msg.PeersID, Kind: "note", Body: "x", ToBox: "box-c", Hub: sat.c}); err == nil {
		t.Fatal("--to peers --to-box box-c was accepted")
	}
	local := *sat.cfg
	local.HubURL = ""
	if _, err := action.SendCtx(ctx, &local, action.SendArgs{From: "c-120", To: msg.PeersID, Kind: "note", Body: "x"}); err == nil {
		t.Fatal("--to peers in local mode was accepted")
	}
}

// Spec 068 4.2 through `spool send --answers <msg_id> --if-gen <n>`
// (action.SendCtx): the seat that polled a peer message answers it once; the
// same send again exits ExitAnswered, a seat that does not hold the message
// ExitNotResponsible, and neither refused answer reaches the outbox or the
// hub. --if-gen without --answers is refused before dialling.
func TestSendAnswers(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	sat := e.box(tid, "box-b", "c-120", "c-001")
	pc := e.box(tid, "box-c", "g-004")
	e.pin(tid, sat)
	e.pin(tid, pc)
	answer := func(b *box, from, q string, gen int64) (action.SendResult, error) {
		return action.SendCtx(ctx, b.cfg, action.SendArgs{From: from, To: "c-120", ToBox: "box-b", Kind: "result",
			Body: "the answer", Answers: q, IfGen: gen, Hub: b.c})
	}
	outbox := func(b *box, from string) int {
		ents, _ := os.ReadDir(filepath.Join(b.cfg.SpoolRoot, from, "outbox"))
		return len(ents)
	}

	q := send(t, sat, "c-120", msg.PeersID, "task", "who takes this", "").MsgID
	c := mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001", Max: 1})
	if len(c.Msgs) != 1 || c.Msgs[0].MsgID != q {
		t.Fatalf("poll: %+v", c.Msgs)
	}
	gen := c.Msgs[0].Gen
	first, err := answer(sat, "c-001", q, gen)
	if err != nil {
		t.Fatalf("first answer: %v", err)
	}
	if ok, _ := e.st.HasMessage(ctx, tid, first.MsgID); !ok || outbox(sat, "c-001") != 1 {
		t.Fatalf("first answer stored %v, outbox %d", ok, outbox(sat, "c-001"))
	}
	second, err := answer(sat, "c-001", q, gen)
	if code := action.ExitCode(err); code != action.ExitAnswered {
		t.Fatalf("second answer: exit %d (%v), want %d answered", code, err, action.ExitAnswered)
	}
	if second.MsgID != "" || outbox(sat, "c-001") != 1 {
		t.Fatalf("a refused answer reached the outbox: %+v, %d", second, outbox(sat, "c-001"))
	}

	q2 := send(t, sat, "c-120", msg.PeersID, "task", "and this", "").MsgID
	c = mustClaim(t, sat, action.ClaimArgs{Op: "poll", Seat: "c-001", Max: 1})
	if len(c.Msgs) != 1 || c.Msgs[0].MsgID != q2 {
		t.Fatalf("poll 2: %+v", c.Msgs)
	}
	_, err = answer(pc, "g-004", q2, c.Msgs[0].Gen)
	if code := action.ExitCode(err); code != action.ExitNotResponsible {
		t.Fatalf("answer by a seat that does not hold it: exit %d (%v), want %d not_responsible", code, err, action.ExitNotResponsible)
	}
	if outbox(pc, "g-004") != 0 {
		t.Fatal("a refused answer reached the outbox")
	}
	if _, err := answer(sat, "c-001", q2, c.Msgs[0].Gen); err != nil {
		t.Fatalf("the holder: %v", err)
	}

	if _, err := action.SendCtx(ctx, sat.cfg, action.SendArgs{From: "c-001", To: "c-120", Kind: "note", Body: "x", IfGen: 1, Hub: sat.c}); err == nil {
		t.Fatal("--if-gen without --answers was accepted")
	}
}
