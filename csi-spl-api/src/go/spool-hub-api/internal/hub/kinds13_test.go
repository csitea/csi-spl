package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// kindsHello dials box b as agent with these hello features and returns once
// the welcome is read (the barrier TestV2HeldForV1OnlySession explains); recv
// frames of the hello's drain are left for readRecv.
func (e *env) kindsHello(tenant string, b *box, agent string, features []string) *websocket.Conn {
	e.t.Helper()
	ctx := context.Background()
	c, nonce := e.raw(tenant)
	h := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.MsgVersions, h.Features = []string{agent}, msg.Supported, features
	if err := wsjson.Write(ctx, c, h); err != nil {
		e.t.Fatal(err)
	}
	rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(rctx, c, &f); err != nil {
			e.t.Fatalf("no welcome after hello: %v", err)
		}
		if f.Type == wire.TWelcome {
			return c
		}
	}
}

// spec 033 K.4.3 (T023): a box whose hello lacks kinds13 runs a reader that
// refuses a kind beyond the first six and never commits the frame, so the
// hub's live push (ws.go push, a site K.4.3 does not list) keeps a bug
// message queued for it; a note still reaches it. CONTROL: the same box with
// the feature gets the held bug on its next hello.
func TestKinds13HeldForOldBoxLivePush(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	old := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, old)
	ctx := context.Background()

	c1 := e.kindsHello(tid, old, "CLE-07", nil) // no commit: a written frame is acked
	note := send(t, a, "GRK-03", "CLE-07", "note", "note ok", "box-b")
	if f := readRecv(t, c1, 3*time.Second); note.Delivery != wire.DeliverySent || f == nil || wire.InnerKind(f.Env) != "note" {
		t.Fatalf("note to a kinds13-less box: delivery %q frame %v", note.Delivery, f)
	}
	bug := send(t, a, "GRK-03", "CLE-07", "bug", "bug held", "box-b")
	if bug.Delivery != wire.DeliveryQueued {
		t.Fatalf("bug to a kinds13-less box: delivery %q, want queued", bug.Delivery)
	}
	if f := readRecv(t, c1, 500*time.Millisecond); f != nil {
		t.Fatalf("kinds13-less box was pushed %s", f.Env)
	}
	if st, err := e.st.DeliveryState(ctx, tid, bug.MsgID, "box-b"); err != nil || st != store.StateQueued {
		t.Fatalf("held bug state %q %v, want queued", st, err)
	}
	c1.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	c2 := e.kindsHello(tid, old, "CLE-07", []string{wire.FeatureKinds13})
	defer c2.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	f := readRecv(t, c2, 3*time.Second)
	if f == nil || wire.InnerMsgID(f.Env) != bug.MsgID || wire.InnerKind(f.Env) != "bug" {
		t.Fatalf("kinds13 box did not get the held bug: %v", f)
	}
	note2 := send(t, a, "GRK-03", "CLE-07", "note", "note new", "box-b")
	if f := readRecv(t, c2, 3*time.Second); note2.Delivery != wire.DeliverySent || f == nil || wire.InnerKind(f.Env) != "note" {
		t.Fatalf("note to a kinds13 box: delivery %q frame %v", note2.Delivery, f)
	}
}

// spec 033 K.4.3 (T023), the commit.go site: a bug sent to a kinds13 box and
// never committed stays unacked; a hello from the same box without kinds13
// (a rollback to an old binary) is not sent it again, and the next hello with
// the feature is.
func TestKinds13UnackedHeldForOldBox(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	both := []string{wire.FeatureCommit, wire.FeatureKinds13}

	c1 := e.kindsHello(tid, b, "CLE-07", both)
	bug := send(t, a, "GRK-03", "CLE-07", "bug", "never committed", "box-b")
	if f := readRecv(t, c1, 3*time.Second); f == nil || wire.InnerMsgID(f.Env) != bug.MsgID {
		t.Fatalf("kinds13 box did not get the bug: %v", f)
	}
	c1.CloseNow() //nolint:errcheck

	c2 := e.kindsHello(tid, b, "CLE-07", []string{wire.FeatureCommit})
	if f := readRecv(t, c2, 500*time.Millisecond); f != nil {
		t.Fatalf("kinds13-less hello was sent the unacked %s", f.Env)
	}
	c2.CloseNow() //nolint:errcheck

	c3 := e.kindsHello(tid, b, "CLE-07", both)
	defer c3.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	if f := readRecv(t, c3, 3*time.Second); f == nil || wire.InnerMsgID(f.Env) != bug.MsgID {
		t.Fatalf("kinds13 hello did not get the unacked bug again: %v", f)
	}
}
