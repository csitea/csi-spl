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

// specs/020 SC-003: a box writing v:1 and a box writing v:2 exchange mail
// both ways through one hub; each message arrives with the v its writer set.
func TestMixedFleetV1V2(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	a.cfg.MsgVersion, b.cfg.MsgVersion = msg.V1, msg.V2
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	for _, x := range []*box{a, b} {
		s, err := x.c.Dial(ctx, wire.RoleBox)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
	}

	if out := send(t, a, "GRK-03", "CLE-07", "task", "from v1", "box-b"); out.Delivery != wire.DeliverySent {
		t.Fatalf("v:1 -> v:2 box: delivery %q", out.Delivery)
	}
	eventually(t, "v:1 message on box-b", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })
	if m := inbox(t, b, "CLE-07")[0]; m.V != msg.V1 || m.Body != "from v1" {
		t.Fatalf("box-b got %+v", m)
	}

	if out := send(t, b, "CLE-07", "GRK-03", "result", "from v2", "box-a"); out.Delivery != wire.DeliverySent {
		t.Fatalf("v:2 -> v:1-writing box: delivery %q", out.Delivery)
	}
	eventually(t, "v:2 message on box-a", func() bool { return len(inbox(t, a, "GRK-03")) == 1 })
	if m := inbox(t, a, "GRK-03")[0]; m.V != msg.V2 || m.Body != "from v2" {
		t.Fatalf("box-a got %+v", m)
	}
}

// readRecv reads frames until a recv frame or the deadline; nil on deadline.
func readRecv(t *testing.T, c *websocket.Conn, within time.Duration) *wire.Frame {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), within)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(ctx, c, &f); err != nil {
			return nil
		}
		if f.Type == wire.TRecv {
			return &f
		}
	}
}

// specs/020 SC-004 / migration.md §3: a box that did not advertise v:2 in
// hello (every pre-020 binary) is never pushed a v:2 recv frame, because its
// reader would refuse it after the row is already sent: silent loss. The row
// stays queued and is delivered once the box says hello with msg_versions
// [1,2]. CONTROL: the same box, same hello, with msg_versions [1,2] gets it.
func TestV2HeldForV1OnlySession(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	old := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, old)
	ctx := context.Background()

	hello := func(versions []int) *websocket.Conn {
		c, nonce := e.raw(tid)
		h := helloFrame(old, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
		h.Agents, h.MsgVersions = []string{"CLE-07"}, versions
		if err := wsjson.Write(ctx, c, h); err != nil {
			t.Fatal(err)
		}
		// Barrier, not decoration: the hub registers the session BEFORE it
		// writes welcome (ws.go), so reading welcome is the only proof that
		// the next send() will see this box as live. Without it the send
		// races the registration and reads "queued" for a box that is in
		// fact connected -- run 35602240116 on 2026-09-21 failed exactly
		// there, with the recv frame present in the same assertion.
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		for {
			var wel wire.Frame
			if err := wsjson.Read(rctx, c, &wel); err != nil {
				t.Fatalf("no welcome after hello: %v", err)
			}
			if wel.Type == wire.TWelcome {
				break
			}
		}
		return c
	}

	// A pre-020 box: hello without msg_versions.
	c1 := hello(nil)
	a.cfg.MsgVersion = msg.V1
	v1 := send(t, a, "GRK-03", "CLE-07", "task", "v1 ok", "box-b")
	f := readRecv(t, c1, 3*time.Second)
	if v1.Delivery != wire.DeliverySent || f == nil || wire.InnerVersion(f.Env) != msg.V1 {
		t.Fatalf("v:1 to a pre-020 box: delivery %q frame %v", v1.Delivery, f)
	}

	a.cfg.MsgVersion = msg.V2
	v2 := send(t, a, "GRK-03", "CLE-07", "task", "v2 held", "box-b")
	if v2.Delivery != wire.DeliveryQueued {
		t.Fatalf("v:2 to a pre-020 box: delivery %q, want queued", v2.Delivery)
	}
	if f := readRecv(t, c1, 500*time.Millisecond); f != nil {
		t.Fatalf("pre-020 box was pushed %s", f.Env)
	}
	if st, err := e.st.DeliveryState(ctx, tid, v2.MsgID, "box-b"); err != nil || st != store.StateQueued {
		t.Fatalf("held row state %q %v, want queued", st, err)
	}
	c1.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	// CONTROL: the only change is msg_versions [1,2]; the drain now pushes it.
	c2 := hello(msg.Supported)
	defer c2.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	f = readRecv(t, c2, 3*time.Second)
	if f == nil || wire.InnerVersion(f.Env) != msg.V2 {
		t.Fatalf("upgraded box did not get the held v:2: %v", f)
	}
	env, err := wire.ParseEnvelope(f.Env)
	if err != nil {
		t.Fatal(err)
	}
	if m, err := env.Inner(); err != nil || m.MsgID != v2.MsgID {
		t.Fatalf("held message: %v %+v", err, m)
	}
}
