package hub_test

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- US1: cross-box send/recv --------------------------------------------------

func TestCrossBoxSendRecvAndResult(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	// Both boxes hold sessions (the box daemon's role).
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)
	// box-a learns box-b's roster from the broadcast (to_box resolved locally).
	eventually(t, "roster with CLE-07@box-b on box-a", func() bool {
		tb, err := a.c.ResolveToBox("CLE-07", "")
		return err == nil && tb == "box-b"
	})

	out := send(t, a, "GRK-03", "CLE-07", "task", "build it", "")
	if out.Delivery != wire.DeliverySent {
		t.Fatalf("delivery = %q, want sent", out.Delivery)
	}
	eventually(t, "CLE-07 inbox on box-b", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })
	got := inbox(t, b, "CLE-07")[0]
	if got.MsgID != out.MsgID || got.From != "GRK-03" || got.Body != "build it" || got.Sig != "" {
		t.Fatalf("inner v:1 changed on the way: %+v", got)
	}
	if len(inbox(t, a, "CLE-07")) != 0 {
		t.Fatal("cross-box mail was also written to a local inbox on box-a")
	}

	// CLE-07 replies kind=result on the same task (an ordinary peer send).
	res, err := action.SendCtx(ctx, b.cfg, action.SendArgs{From: "CLE-07", To: "GRK-03", Kind: "result", Body: "done", TaskID: got.TaskID, Hub: b.c})
	if err != nil || res.Delivery != wire.DeliverySent {
		t.Fatalf("result: %v %+v", err, res)
	}
	eventually(t, "result in GRK-03 inbox", func() bool {
		m := inbox(t, a, "GRK-03")
		return len(m) == 1 && m[0].Kind == "result" && m[0].TaskID == got.TaskID
	})

	// Same-box stays local and never touches the hub.
	local := send(t, a, "GRK-03", "GRK-03", "note", "self", "")
	if local.Delivery != wire.DeliveryLocal {
		t.Fatalf("same-box delivery = %q", local.Delivery)
	}
	if st, err := e.st.DeliveryState(ctx, tid, local.MsgID, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("same-box message reached the hub: %q %v", st, err)
	}
}

func TestTamperedAndAmbiguousAndMissingPin(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	c := e.box(tid, "box-c", "CLE-07", "AGY-01")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()

	sb, err := b.c.Dial(ctx, wire.RoleBox) // box-b synced pins BEFORE box-c exists
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)

	// Tampered envelope: signed, then the body is changed → bad_sig → exit 78.
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli)
	m, _ := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "task", "real", nil)
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	env, _ := wire.NewEnvelope(priv, "box-a", "box-b", m)
	env.Msg = []byte(strings.Replace(string(env.Msg), `"real"`, `"fake"`, 1))
	_, err = cli.Send(ctx, env)
	if action.ExitCode(err) != 78 {
		t.Fatalf("tampered: exit %d (%v), want 78", action.ExitCode(err), err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, m.MsgID, "box-b"); st != "" {
		t.Fatal("tampered envelope was stored")
	}
	// from_box ≠ hello box is refused the same way.
	env2, _ := wire.NewEnvelope(priv, "box-b", "box-b", m)
	if _, err := cli.Send(ctx, env2); action.ExitCode(err) != 78 {
		t.Fatalf("spoofed from_box: %v", err)
	}

	// box-c joins; CLE-07 is now on box-b AND box-c.
	e.pin(tid, c)
	sc, err := c.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sc)
	a.c.Sync(ctx) //nolint:errcheck // refresh box-a's roster cache
	if _, err := a.c.ResolveToBox("CLE-07", ""); err == nil || !strings.Contains(err.Error(), "ambiguous_to_box") {
		t.Fatalf("CLI must refuse an ambiguous to before signing: %v", err)
	}
	// A hand-built envelope without to_box is refused by the hub (409), never filled.
	env3, _ := wire.NewEnvelope(priv, "box-a", "", m)
	var he *hubclient.HubError
	if _, err := cli.Send(ctx, env3); !errors.As(err, &he) || he.Token != "ambiguous_to_box" || he.Status != 409 {
		t.Fatalf("hub ambiguity: %v", err)
	}
	// With --to-box it goes through.
	if out := send(t, a, "GRK-03", "CLE-07", "task", "for c", "box-c"); out.Delivery != wire.DeliverySent {
		t.Fatalf("explicit to_box: %+v", out)
	}

	// Missing pin: box-c → box-b while box-b has NOT synced box-c's pubkey.
	// The hub stores and pushes it; box-b refuses locally (78), writes nothing.
	if out := send(t, c, "AGY-01", "CLE-07", "task", "from c", "box-b"); out.Delivery != wire.DeliverySent {
		t.Fatalf("c->b: %+v", out)
	}
	eventually(t, "box-b refusal", func() bool { return len(sb.RecvErrors()) == 1 })
	if code := action.ExitCode(sb.RecvErrors()[0]); code != 78 {
		t.Fatalf("missing pin: exit %d (%v), want 78", code, sb.RecvErrors()[0])
	}
	if n := len(inbox(t, b, "CLE-07")); n != 0 {
		t.Fatalf("refused frame was written: %d messages", n)
	}
}

// ---- US3: queued, pending, flush -------------------------------------------------

func TestOfflineQueueAndHubDownFlush(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil { // announce box-b's roster once
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	// box-b offline → queued (no receiver ack); drained on its next hello.
	out := send(t, a, "GRK-03", "CLE-07", "task", "while you were out", "")
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("offline: %q, want queued", out.Delivery)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, out.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("state %q, want queued", st)
	}
	r, err := b.c.Sync(ctx)
	if err != nil || r.Delivered != 1 {
		t.Fatalf("drain: %+v %v", r, err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, out.MsgID, "box-b"); st != store.StateSent {
		t.Fatalf("after drain: %q, want sent", st)
	}
	if n := len(inbox(t, b, "CLE-07")); n != 1 {
		t.Fatalf("inbox has %d", n)
	}
	// An idempotent replay of the same envelope does not deliver twice.
	if r, _ := b.c.Sync(ctx); r.Delivered != 0 {
		t.Fatalf("redelivered %d", r.Delivered)
	}

	// Hub unreachable → pending, exit 0; same-box still works.
	down := *a.cfg
	down.HubURL = "http://" + tid + ".unreachable.invalid"
	dc := hubclient.New(&down)
	dc.ReadyTimeout = 2 * time.Second
	pend, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "task", Body: "later", Hub: dc})
	if err != nil || pend.Delivery != wire.DeliveryPending {
		t.Fatalf("hub down: %v %+v", err, pend)
	}
	if loc, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "GRK-03", Kind: "note", Body: "self", Hub: dc}); err != nil || loc.Delivery != wire.DeliveryLocal {
		t.Fatalf("same-box with hub down: %v %+v", err, loc)
	}
	left, _ := a.c.Pending()
	if len(left) != 1 {
		t.Fatalf("pending files: %d", len(left))
	}
	before, _ := os.ReadFile(left[0])

	// Hub back: flush sends the SAME signed bytes (no re-sign, ts unchanged).
	r, err = a.c.Sync(ctx)
	if err != nil || r.Flushed != 1 || r.Pending != 0 {
		t.Fatalf("flush: %+v %v", r, err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, pend.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("flushed message state %q", st)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, pend.TaskID)
	if len(envs) != 1 || string(envs[0]) != strings.TrimSpace(string(before)) {
		t.Fatalf("flush changed the signed bytes:\n%s\n%s", before, envs)
	}
	if r, err := b.c.Sync(ctx); err != nil || r.Delivered != 1 {
		t.Fatalf("receiver after flush: %+v %v", r, err)
	}
}

// 006 T011b / FR-011: a ring of three pinned boxes (GRK, CLE, AGY). Every
// box commands the next; the agent prefix never changes authorisation.
func TestThreePeerMeshRing(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	c := e.box(tid, "box-c", "AGY-01")
	for _, x := range []*box{a, b, c} {
		e.pin(tid, x)
	}
	ctx := context.Background()
	ring := []struct {
		from       *box
		fromID     string
		to         *box
		toID, toBx string
	}{
		{a, "GRK-03", b, "CLE-07", "box-b"},
		{b, "CLE-07", c, "AGY-01", "box-c"},
		{c, "AGY-01", a, "GRK-03", "box-a"},
	}
	for _, r := range ring {
		out := send(t, r.from, r.fromID, r.toID, "task", r.fromID+" commands "+r.toID, r.toBx)
		if out.Delivery != wire.DeliveryQueued {
			t.Fatalf("%s -> %s: delivery %q, want queued", r.fromID, r.toID, out.Delivery)
		}
	}
	for _, r := range ring {
		if res, err := r.to.c.Sync(ctx); err != nil || res.Delivered != 1 {
			t.Fatalf("%s drain: %+v %v", r.toBx, res, err)
		}
		got := inbox(t, r.to, r.toID)
		if len(got) != 1 || got[0].Kind != "task" || got[0].From != r.fromID || got[0].Body != r.fromID+" commands "+r.toID {
			t.Fatalf("%s inbox: %+v", r.toID, got)
		}
	}
}
