package hub_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestChannelPostRoleGroup is spec 059 S5: the dispatcher c-002 is seated on
// two machines (box-desk and sat), and a channel post reaches only the box
// holding the dispatch fleet lease. A lane member (c-007, c-008) keeps its
// normal delivery; the next post after a lease move goes to the new holder;
// a stalled lease fans out as before; a row queued before a move is still
// delivered. Runs on memory and, with SPOOL_TEST_PG_DSN, on Postgres.
func TestChannelPostRoleGroup(t *testing.T) {
	trace, withLog := traceOnFailure(t)
	e := newEnv(t, withLog)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "GRK-03")
	desk := e.box(tid, "box-desk", "c-002", "c-008")
	sat := e.box(tid, "sat", "c-002")
	lane := e.box(tid, "box-l", "c-007")
	for _, b := range []*box{a, desk, sat, lane} {
		e.pin(tid, b)
	}
	seat := func(b, id string) {
		t.Helper()
		if err := e.st.InviteChannelAgent(ctx, tid, "feedback", b, id, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	seat("box-a", "GRK-03")
	seat("box-desk", "c-002")
	seat("sat", "c-002")
	seat("box-l", "c-007")
	rd := e.rawBox(tid, desk, []string{"c-002", "c-008"}, []string{"feedback"})
	rd.trace = trace
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	task := uuidV4()
	post := func(body string) string {
		t.Helper()
		m := chanMsg(task, "ALL-0", "note", body)
		if _, err := cli.Send(ctx, signedIn(t, a, hub.WUIBox, "feedback", "", m)); err != nil {
			t.Fatalf("post %q: %v", body, err)
		}
		trace("posted %s %q", m.MsgID, body)
		return m.MsgID
	}
	routed := func(id, box string) bool {
		t.Helper()
		_, err := e.st.DeliveryState(ctx, tid, id, box)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			t.Fatal(err)
		}
		return err == nil
	}
	// deskRecv reads box-desk's next recv frame: it must be post id, for agents.
	deskRecv := func(id string, agents ...string) {
		t.Helper()
		f := rd.next(wire.TRecv)
		env, err := wire.ParseEnvelope(f.Env)
		if err != nil {
			t.Fatal(err)
		}
		in, err := env.Inner()
		if err != nil {
			t.Fatal(err)
		}
		if in.MsgID != id || strings.Join(f.Agents, ",") != strings.Join(agents, ",") {
			t.Fatalf("box-desk recv %s agents %v, want %s agents %v", in.MsgID, f.Agents, id, agents)
		}
	}
	gen := int64(0)
	lease := func(holder, box string, at time.Time) {
		t.Helper()
		l, err := e.st.CASFleetLease(ctx, tid, "fleet-a", "dispatch", holder, box, gen, at)
		if err != nil {
			t.Fatalf("lease %s: %v", holder, err)
		}
		gen = l.Gen
	}

	// CONTROL, before S5's lease: every seated box gets the post - the
	// double dispatch (spec 058 H7) this step exists to remove.
	p0 := post("no lease yet")
	deskRecv(p0, "c-002")
	if !routed(p0, "sat") || !routed(p0, "box-l") {
		t.Fatal("no lease: the post must fan out to every member box")
	}

	// 1. Two seated role boxes, the lease on box-desk: exactly one delivery
	// for the role, to the holder; the lane member on box-l still receives.
	lease("c-002@box-desk", "box-desk", time.Now())
	p1 := post("held on box-desk")
	deskRecv(p1, "c-002")
	if routed(p1, "sat") {
		t.Fatal("sat got the post while box-desk holds the dispatch lease")
	}
	if !routed(p1, "box-l") {
		t.Fatal("the non-role member c-007@box-l lost its delivery")
	}

	// 2. The lease moves to sat: the next post goes to the new holder only.
	lease("c-002@sat", "sat", time.Now())
	p2 := post("held on sat")
	if !routed(p2, "sat") || routed(p2, "box-desk") || !routed(p2, "box-l") {
		t.Fatalf("after the move: sat %v box-desk %v box-l %v", routed(p2, "sat"), routed(p2, "box-desk"), routed(p2, "box-l"))
	}

	// 3. A lane member on the non-holder's box still receives, and the
	// frame leaves the role agent out (box-desk's c-002 is on standby).
	seat("box-desk", "c-008")
	p3 := post("lane member on the standby box")
	deskRecv(p3, "c-008")
	if !routed(p3, "sat") {
		t.Fatal("the holder sat lost the post")
	}

	// 4. A stalled holder (not renewed for longer than RoleLeaseStale) no
	// longer narrows the post: it fans out, so a dead holder loses nothing.
	lease("c-002@sat", "sat", time.Now().Add(-hub.DefaultRoleLeaseStale-time.Minute))
	p4 := post("holder stalled")
	deskRecv(p4, "c-002", "c-008")
	if !routed(p4, "sat") {
		t.Fatal("stalled lease: sat lost the post")
	}

	// 5. In flight: a row queued for sat before the lease moves back to
	// box-desk is still delivered to sat when it drains (never dropped);
	// the post after the move reaches box-desk's c-002 only.
	lease("c-002@sat", "sat", time.Now())
	p5 := post("queued for sat")
	deskRecv(p5, "c-008")
	lease("c-002@box-desk", "box-desk", time.Now())
	p6 := post("back on box-desk")
	deskRecv(p6, "c-002", "c-008")
	if routed(p6, "sat") {
		t.Fatal("sat got the post after the lease moved back to box-desk")
	}
	rs := e.rawBoxNoDrain(tid, sat, []string{"c-002"}, []string{"feedback"})
	rs.trace = trace
	var got []string
	for range 20 { // p0, p2, p3, p4, p5, then queue_end
		var f wire.Frame
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := wsjson.Read(rctx, rs.c, &f)
		cancel()
		if err != nil {
			t.Fatalf("sat drain after %v: %v", got, err)
		}
		if f.Type == wire.TQueueEnd {
			break
		}
		if f.Type != wire.TRecv {
			continue
		}
		env, _ := wire.ParseEnvelope(f.Env)
		in, _ := env.Inner()
		if strings.Join(f.Agents, ",") != "c-002" {
			t.Fatalf("sat drained %s for %v, want c-002", in.MsgID, f.Agents)
		}
		got = append(got, in.MsgID)
	}
	if want := []string{p0, p2, p3, p4, p5}; strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("sat drained %v, want p0 p2 p3 p4 p5 = %v", got, want)
	}
}
