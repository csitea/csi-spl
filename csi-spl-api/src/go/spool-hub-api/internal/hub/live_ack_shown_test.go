package hub_test

import (
	"context"
	"errors"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-6517 (spec 053 S1, latency action 7): the shown ack, end to end. box-b
// runs its real sidecar (hubclient Run, as `spool hub-run`); the agent hook's
// `spool live-ack` is a second client on box-b's config that only talks to the
// sidecar's submit socket. Memory store, and Postgres with SPOOL_TEST_PG_DSN.

type shownRig struct {
	e      *env
	tid    string
	a, b   *box
	verb   *hubclient.Client // the `spool live-ack` process: never dials
	cancel func()
}

func newShownRig(t *testing.T) *shownRig {
	t.Helper()
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	b.cfg.SubmitSocket = shortSocket(t)
	b.c.SessionProbe = -1
	b.c.RotateAfter = -1
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- b.c.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	eventually(t, "box-b's submit listener", func() bool { _, err := os.Stat(b.cfg.SubmitPath()); return err == nil })
	// the verb's config points at no hub: any dial of its own would fail, so
	// a stored ack proves it rode the sidecar's socket
	vc := *b.cfg
	vc.HubURL = "http://127.0.0.1:1"
	verb := hubclient.New(&vc)
	return &shownRig{e: e, tid: tid, a: a, b: b, verb: verb, cancel: cancel}
}

// deliver sends one note GRK-03 -> CLE-07 and waits until box-b's inbox
// holds it (the hub's delivery row is then sent).
func (r *shownRig) deliver(t *testing.T, body string) string {
	t.Helper()
	id := send(t, r.a, "GRK-03", "CLE-07", "note", body, "box-b").MsgID
	eventually(t, "CLE-07's inbox has "+body, func() bool { return slices.Contains(inboxIDs(t, r.b, "CLE-07"), id) })
	return id
}

func (r *shownRig) acks(t *testing.T, m string) []store.LiveAck {
	t.Helper()
	got, err := r.e.st.(store.LiveAcks).LiveAcksOf(context.Background(), r.tid, m)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func (r *shownRig) shown(t *testing.T, ids ...string) {
	t.Helper()
	n, err := r.verb.LiveAckShown(context.Background(), "CLE-07", ids)
	if err != nil || n != len(ids) {
		t.Fatalf("live-ack %v: acked %d, err %v; want %d, nil", ids, n, err, len(ids))
	}
}

// A message the hook surfaced leaves exactly one shown row; a second
// surfacing records nothing new (the first acked_at stands).
func TestLiveAckShownRecordedOnce(t *testing.T) {
	r := newShownRig(t)
	m := r.deliver(t, "first")
	r.shown(t, m)
	eventually(t, "one shown ack of CLE-07 on box-b", func() bool {
		got := r.acks(t, m)
		return len(got) == 1 && got[0].Agent == "CLE-07" && got[0].Box == "box-b" && got[0].Outcome == wire.AckShown
	})
	first := r.acks(t, m)[0].AckedAt

	r.shown(t, m)
	// The hub handles one socket's frames in order: once the ack of a later
	// message is stored, the second ack of m has been handled.
	m2 := r.deliver(t, "second")
	r.shown(t, m2)
	eventually(t, "the ack of the later message", func() bool { return len(r.acks(t, m2)) == 1 })
	got := r.acks(t, m)
	if len(got) != 1 || !got[0].AckedAt.Equal(first) || got[0].Outcome != wire.AckShown {
		t.Fatalf("after a second surfacing: %+v, want the one row acked at %v", got, first)
	}
}

// CONTROL: an id the hub never sent box-b records nothing, and a bad id or
// agent is refused before the socket.
func TestLiveAckShownRefusesWhatTheBoxNeverGot(t *testing.T) {
	r := newShownRig(t)
	stray := "7f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b3c"
	r.shown(t, stray)
	m := r.deliver(t, "marker")
	r.shown(t, m)
	eventually(t, "the marker's ack", func() bool { return len(r.acks(t, m)) == 1 })
	if got := r.acks(t, stray); len(got) != 0 {
		t.Fatalf("acks %+v for a message box-b never got, want none", got)
	}
	for _, c := range []struct{ agent, id string }{{"CLE-07", "not-a-uuid"}, {"box b", m}} {
		if _, err := r.verb.LiveAckShown(context.Background(), c.agent, []string{c.id}); err == nil {
			t.Errorf("live-ack %q %q: want a refusal", c.agent, c.id)
		}
	}
}

// Hub down = no sidecar on the box: the verb returns ErrNoSidecar at once and
// never dials the hub itself (its role=box hello would supersede the sidecar).
func TestLiveAckShownNoSidecarReturnsAtOnce(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	b := e.box(tid, "box-b", "CLE-07")
	b.cfg.SubmitSocket = shortSocket(t)
	start := time.Now()
	_, err := hubclient.New(b.cfg).LiveAckShown(context.Background(), "CLE-07", []string{"7f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b3c"})
	if !errors.Is(err, hubclient.ErrNoSidecar) {
		t.Fatalf("err %v, want ErrNoSidecar", err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("took %v with no sidecar, want under 1 s", d)
	}
}
