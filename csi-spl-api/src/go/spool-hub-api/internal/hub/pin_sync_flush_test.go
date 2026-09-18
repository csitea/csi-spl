package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// T007/T008: sidecar GET /v1/pins writes box-<id>.pub; local≠hub → 78, no clobber.
func TestPinSyncWritesAndConflictNoClobber(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	pa := filepath.Join(b.cfg.PinsDir, "box-box-a.pub")
	pb := filepath.Join(b.cfg.PinsDir, "box-box-b.pub")
	if _, err := os.ReadFile(pa); err != nil {
		t.Fatalf("T007 box-a pin not written: %v", err)
	}
	if _, err := os.Stat(pb); err != nil {
		t.Fatalf("T007 box-b pin not written: %v", err)
	}
	if pub, err := sign.LoadPin(b.cfg.PinsDir, "box-a"); err != nil || base64.StdEncoding.EncodeToString(pub) != a.pub {
		t.Fatalf("synced pin: %v %v want %s", pub, err, a.pub)
	}

	otherPub, _, _ := ed25519.GenerateKey(nil)
	other := base64.StdEncoding.EncodeToString(otherPub)
	if err := os.WriteFile(pa, []byte(other+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := b.c.Sync(ctx)
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != "pin_conflict" {
		t.Fatalf("T008 want pin_conflict, got %v", err)
	}
	if action.ExitCode(err) != 78 {
		t.Fatalf("T008 exit %d, want 78", action.ExitCode(err))
	}
	after, _ := os.ReadFile(pa)
	if string(bytes.TrimSpace(after)) != other {
		t.Fatalf("T008 clobbered local pin: %q -> %q", other, after)
	}
	if pub, err := sign.LoadPin(b.cfg.PinsDir, "box-a"); err != nil || base64.StdEncoding.EncodeToString(pub) != other {
		t.Fatalf("T008 local pin was replaced: %v %v", pub, err)
	}
}

// T009: after pin sync, box B verifies A's envelope; missing pin → 78, nothing written.
func TestRecvVerifiesAfterPinSync(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	out := send(t, a, "GRK-03", "CLE-07", "task", "hello b", "")
	if out.Delivery != wire.DeliverySent {
		t.Fatalf("delivery %q", out.Delivery)
	}
	eventually(t, "verified recv", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })
	got := inbox(t, b, "CLE-07")
	if got[0].Body != "hello b" || got[0].MsgID != out.MsgID {
		t.Fatalf("recv %+v", got[0])
	}
}

// T011: hub down, same-box send still recvs locally; flush of a pending envelope
// is idempotent on msg_id (identical bytes replay as one hub row).
func TestHubDownSameBoxRecvAndFlushIdempotent(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	down := *a.cfg
	down.HubURL = "http://" + tid + ".unreachable.invalid"
	dc := hubclient.New(&down)
	dc.ReadyTimeout = 2 * time.Second

	loc, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "GRK-03", Kind: "note", Body: "self", Hub: dc})
	if err != nil || loc.Delivery != wire.DeliveryLocal {
		t.Fatalf("same-box hub down: %v %+v", err, loc)
	}
	got, err := action.Recv(&down, "GRK-03", false)
	if err != nil || len(got) != 1 || got[0].Body != "self" {
		t.Fatalf("T011 same-box recv: %v %+v", err, got)
	}

	pend, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "task", Body: "later", Hub: dc})
	if err != nil || pend.Delivery != wire.DeliveryPending {
		t.Fatalf("cross-box hub down: %v %+v", err, pend)
	}
	left, _ := a.c.Pending()
	if len(left) != 1 {
		t.Fatalf("pending %d", len(left))
	}
	before, _ := os.ReadFile(left[0])
	name := filepath.Base(left[0])

	r, err := a.c.Sync(ctx)
	if err != nil || r.Flushed != 1 || r.Pending != 0 {
		t.Fatalf("first flush: %+v %v", r, err)
	}
	if st, _ := e.st.DeliveryState(ctx, tid, pend.MsgID, "box-b"); st != store.StateQueued {
		t.Fatalf("state %q", st)
	}

	// Crash-window replay: the hub already has the envelope; put it back.
	dst := filepath.Join(a.cfg.SpoolRoot, ".hub", "pending", name)
	if err := os.MkdirAll(filepath.Dir(dst), 0o775); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, before, 0o664); err != nil {
		t.Fatal(err)
	}
	r, err = a.c.Sync(ctx)
	if err != nil || r.Flushed != 1 || r.Pending != 0 {
		t.Fatalf("idempotent flush: %+v %v", r, err)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, pend.TaskID)
	if len(envs) != 1 {
		t.Fatalf("T011 hub rows=%d, want 1", len(envs))
	}
	if string(envs[0]) != string(bytes.TrimSpace(before)) {
		t.Fatalf("T011 flush changed signed bytes")
	}
	if r, err := b.c.Sync(ctx); err != nil || r.Delivered != 1 {
		t.Fatalf("receiver: %+v %v", r, err)
	}
	if n := len(inbox(t, b, "CLE-07")); n != 1 {
		t.Fatalf("inbox %d after two flushes", n)
	}
}

// T012: hub 400/bad_sig on flush moves the file to rejected/ and stops with 78.
func TestFlushHTTP400StopsRetryWith78(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if _, err := b.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	down := *a.cfg
	down.HubURL = "http://" + tid + ".unreachable.invalid"
	dc := hubclient.New(&down)
	dc.ReadyTimeout = 2 * time.Second
	pend, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "task", Body: "later", Hub: dc})
	if err != nil || pend.Delivery != wire.DeliveryPending {
		t.Fatalf("pending: %v %+v", err, pend)
	}
	left, _ := a.c.Pending()
	if len(left) != 1 {
		t.Fatalf("pending files %d", len(left))
	}
	raw, _ := os.ReadFile(left[0])
	tampered := bytes.Replace(raw, []byte(`"later"`), []byte(`"TAMPER"`), 1)
	if bytes.Equal(raw, tampered) {
		t.Fatal("tamper did not change the pending envelope")
	}
	if err := os.WriteFile(left[0], tampered, 0o664); err != nil {
		t.Fatal(err)
	}

	r, err := a.c.Sync(ctx)
	if action.ExitCode(err) != 78 {
		t.Fatalf("T012 flush exit %d (%v), want 78; report %+v", action.ExitCode(err), err, r)
	}
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != "bad_sig" || he.Status != 400 {
		t.Fatalf("T012 want 400 bad_sig, got %v", err)
	}
	left, _ = a.c.Pending()
	if len(left) != 0 {
		t.Fatalf("T012 still pending: %v", left)
	}
	rejDir := filepath.Join(a.cfg.SpoolRoot, ".hub", "rejected")
	ents, _ := os.ReadDir(rejDir)
	if len(ents) != 1 {
		t.Fatalf("T012 rejected count %d", len(ents))
	}
	// A second flush must not retry the refused envelope.
	r2, err := a.c.Sync(ctx)
	if err != nil || r2.Flushed != 0 || r2.Pending != 0 {
		t.Fatalf("T012 retry: %+v %v", r2, err)
	}
	if st, err := e.st.DeliveryState(ctx, tid, pend.MsgID, "box-b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("T012 stored a refused envelope: %q %v", st, err)
	}
}

// T018a: $SPOOL_MIRROR_LOCAL=1 — a same-box send is delivered locally AND
// hub-sent; the result stays delivery=local; draining the mirrored copy back
// to the same box does not duplicate the inbox file; with the hub down the
// mirror copy waits pending-flush and the local delivery still succeeds.
func TestMirrorLocalSameBox(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03", "CLE-07")
	a.cfg.MirrorLocal = "1"
	e.pin(tid, a)
	ctx := context.Background()
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	out := send(t, a, "GRK-03", "CLE-07", "note", "mirrored", "box-a")
	if out.Delivery != wire.DeliveryLocal {
		t.Fatalf("mirror on: delivery %q, want local", out.Delivery)
	}
	if n := len(inbox(t, a, "CLE-07")); n != 1 {
		t.Fatalf("local inbox %d, want 1", n)
	}
	if envs, _ := e.st.TaskEnvelopes(ctx, tid, out.TaskID); len(envs) != 1 {
		t.Fatalf("hub rows %d, want 1 (mirrored)", len(envs))
	}
	if left, _ := a.c.Pending(); len(left) != 0 {
		t.Fatalf("pending %d after a reachable mirror", len(left))
	}
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(inbox(t, a, "CLE-07")); n != 1 {
		t.Fatalf("inbox %d after draining the mirror copy, want 1", n)
	}

	down := *a.cfg
	down.HubURL = "http://" + tid + ".unreachable.invalid"
	dc := hubclient.New(&down)
	dc.ReadyTimeout = 2 * time.Second
	loc, err := action.SendCtx(ctx, &down, action.SendArgs{From: "GRK-03", To: "CLE-07", Kind: "note", Body: "offline", ToBox: "box-a", Hub: dc})
	if err != nil || loc.Delivery != wire.DeliveryLocal {
		t.Fatalf("mirror on, hub down: %v %+v", err, loc)
	}
	if n := len(inbox(t, a, "CLE-07")); n != 2 {
		t.Fatalf("inbox %d, want 2", n)
	}
	if left, _ := a.c.Pending(); len(left) != 1 {
		t.Fatalf("pending %d, want the mirror copy kept for flush", len(left))
	}
}
