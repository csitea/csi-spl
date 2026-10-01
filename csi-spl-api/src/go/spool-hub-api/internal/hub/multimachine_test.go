package hub_test

// specs/058 (multi-machine fleet): the one-to-many cases, proven against one
// in-process hub. A "machine" here is a spool root of its own; a box id with
// its key is what the hub sees. Two models are exercised:
//
//   - one box id PER MACHINE (the target model): both machines stay seated in
//     one tenant at once and a message goes to exactly one of them;
//   - one box id MOVED between machines (a takeover): the key travels, the
//     last hello wins, and nothing sent before, during or after the move is
//     lost or delivered twice.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// machine2 is a second machine holding the SAME box id and key as b (the key
// was copied over, as a takeover does) but its own spool root and pins.
func (e *env) machine2(b *box, agents ...string) *box {
	e.t.Helper()
	root := e.t.TempDir()
	cfg := &config.Config{
		SpoolRoot: filepath.Join(root, "spool"), KeysDir: b.cfg.KeysDir,
		PinsDir: filepath.Join(root, "spool", "pins"), BoxID: b.id, HubURL: b.cfg.HubURL,
		LogLevel: "error", LogFormat: "console",
	}
	for _, a := range agents {
		os.MkdirAll(filepath.Join(cfg.SpoolRoot, a, "inbox"), 0o775) //nolint:errcheck
	}
	c := hubclient.New(cfg)
	c.HTTP = e.client
	c.ReadyTimeout = 5 * time.Second
	return &box{id: b.id, cfg: cfg, c: c, pub: b.pub}
}

func bodies(t *testing.T, b *box, as string) []string {
	t.Helper()
	var out []string
	for _, m := range inbox(t, b, as) {
		out = append(out, m.Body)
	}
	sort.Strings(out)
	return out
}

// Target model: the box machine and the satellite each seat their own box id
// in ONE tenant. Both sockets live side by side (no 4409), and a message to an
// agent on one machine lands there once and never on the other.
func TestTwoMachinesOneTenantOwnBoxIDs(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	home := e.box(tid, "box-desk", "CLE-77913")
	sat := e.box(tid, "box-desk-sat", "QWN-100000")
	e.pin(tid, home)
	e.pin(tid, sat)
	ctx := context.Background()

	st, err := home.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ss, err := sat.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer ss.Close()
	select {
	case <-st.Done():
		t.Fatalf("the satellite's hello evicted the box machine (close %d)", st.CloseCode())
	case <-ss.Done():
		t.Fatalf("the satellite's session closed (close %d)", ss.CloseCode())
	case <-time.After(300 * time.Millisecond):
	}
	eventually(t, "QWN-100000@box-desk-sat in the box machine's roster", func() bool {
		tb, err := home.c.ResolveToBox("QWN-100000", "")
		return err == nil && tb == "box-desk-sat"
	})

	out := send(t, home, "CLE-77913", "QWN-100000", "task", "on the satellite", "")
	if out.Delivery != wire.DeliverySent {
		t.Fatalf("delivery = %q, want sent", out.Delivery)
	}
	back := send(t, sat, "QWN-100000", "CLE-77913", "result", "from the satellite", "")
	if back.Delivery != wire.DeliverySent {
		t.Fatalf("reply delivery = %q, want sent", back.Delivery)
	}
	eventually(t, "one message each way", func() bool {
		return len(inbox(t, sat, "QWN-100000")) == 1 && len(inbox(t, home, "CLE-77913")) == 1
	})
	if n := len(inbox(t, home, "QWN-100000")); n != 0 {
		t.Fatalf("the satellite's message also landed on the box machine (%d)", n)
	}
	// A reconnect replays nothing already sent: routed once, delivered once.
	if r, err := sat.c.Sync(ctx); err != nil || r.Delivered != 0 {
		t.Fatalf("satellite re-sync delivered %d (%v), want 0", r.Delivered, err)
	}
	if n := len(inbox(t, sat, "QWN-100000")); n != 1 {
		t.Fatalf("satellite inbox has %d after re-sync, want 1", n)
	}
}

// A takeover: the satellite takes the box machine's box id (its key copied)
// while the box machine is still connected, then hands it back after going
// down. Every message reaches exactly one machine, once.
func TestBoxTakeoverMidMessageLosesNothing(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	peer := e.box(tid, "box-peer", "GRK-03")
	m1 := e.box(tid, "box-desk", "CLE-07")
	m2 := e.machine2(m1, "CLE-07")
	e.pin(tid, peer)
	e.pin(tid, m1)
	ctx := context.Background()
	if _, err := peer.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	s1, err := m1.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer s1.Close()
	if out := send(t, peer, "GRK-03", "CLE-07", "task", "1 before", "box-desk"); out.Delivery != wire.DeliverySent {
		t.Fatalf("msg 1: %q", out.Delivery)
	}
	eventually(t, "msg 1 on machine 1", func() bool { return len(inbox(t, m1, "CLE-07")) == 1 })

	// Machine 2 says hello as the same box: the last hello wins, machine 1
	// is told it was superseded (4409) and stops.
	s2, err := m2.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-s1.Done():
		if s1.CloseCode() != wire.CloseSuperseded {
			t.Fatalf("machine 1 closed with %d, want 4409", s1.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("machine 1 was not superseded by machine 2's hello")
	}
	if out := send(t, peer, "GRK-03", "CLE-07", "task", "2 during", "box-desk"); out.Delivery != wire.DeliverySent {
		t.Fatalf("msg 2: %q", out.Delivery)
	}
	eventually(t, "msg 2 on machine 2", func() bool { return len(inbox(t, m2, "CLE-07")) == 1 })

	// Machine 2 goes down: the next message queues for the box, not for a
	// machine, and drains to whichever machine says hello next.
	// Every probe sent while the socket closes is "in flight" across the
	// takeover window: each one must still reach a machine exactly once.
	s2.Close()
	want := map[string]int{"1 before": 1, "2 during": 1, "3 after": 1}
	probes := 0
	eventually(t, "box offline", func() bool {
		probes++
		body := fmt.Sprintf("probe %d", probes)
		want[body] = 1
		return send(t, peer, "GRK-03", "CLE-07", "note", body, "box-desk").Delivery == wire.DeliveryQueued
	})
	if out := send(t, peer, "GRK-03", "CLE-07", "task", "3 after", "box-desk"); out.Delivery != wire.DeliveryQueued {
		t.Fatalf("msg 3: %q, want queued", out.Delivery)
	}
	if _, err := m1.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	got := append(bodies(t, m1, "CLE-07"), bodies(t, m2, "CLE-07")...)
	seen := map[string]int{}
	for _, b := range got {
		seen[b]++
	}
	for b, n := range want {
		if seen[b] != n {
			t.Fatalf("%q delivered %d times across the two machines, want %d (all: %v)", b, seen[b], n, got)
		}
	}
	if len(seen) != len(want) {
		t.Fatalf("unexpected messages: got %v, want %v", seen, want)
	}
}
