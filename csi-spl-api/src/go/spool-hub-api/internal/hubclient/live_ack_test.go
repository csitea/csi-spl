package hubclient

// SPL-6517 (spec 053 S1, latency action 7): the box side of the shown ack.
// The hub-side proof (one row, none new on a second surfacing) is
// internal/hub/live_ack_shown_test.go; these hold the client and sidecar
// paths: the checks, no sidecar, no session, a written frame per id.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const (
	ackM1 = "11111111-2222-4333-8444-555555555555"
	ackM2 = "66666666-7777-4888-9999-aaaaaaaaaaaa"
)

func TestCheckLiveAck(t *testing.T) {
	many := make([]string, LiveAckMax+1)
	for i := range many {
		many[i] = fmt.Sprintf("%08x-0000-4000-8000-000000000000", i)
	}
	for _, c := range []struct {
		name, agent string
		ids         []string
		want        int
		bad         string
	}{
		{"two ids", "c-901", []string{ackM1, ackM2}, 2, ""},
		{"a repeat is sent once", "c-901", []string{ackM1, ackM1}, 1, ""},
		{"no ids", "c-901", nil, 0, "1..64"},
		{"not a uuid", "c-901", []string{"x"}, 0, "not a UUID"},
		{"not an agent", "box b", []string{ackM1}, 0, "not an agent id"},
		{"too many", "c-901", many, 0, "1..64"},
	} {
		got, err := checkLiveAck(c.agent, c.ids)
		switch {
		case c.bad == "" && (err != nil || len(got) != c.want):
			t.Errorf("%s: %v %v, want %d ids", c.name, got, err, c.want)
		case c.bad != "" && (err == nil || !strings.Contains(err.Error(), c.bad)):
			t.Errorf("%s: err %v, want %q", c.name, err, c.bad)
		}
	}
}

// No listener (submit off, or nothing on the socket): ErrNoSidecar, no dial.
func TestLiveAckShownNoSidecar(t *testing.T) {
	c := testClient(t)
	c.Cfg.HubURL = "http://127.0.0.1:1"
	c.Cfg.SubmitSocket = "off"
	if _, err := c.LiveAckShown(context.Background(), "c-901", []string{ackM1}); !errors.Is(err, ErrNoSidecar) {
		t.Fatalf("submit off: %v, want ErrNoSidecar", err)
	}
	c.Cfg.SubmitSocket = shortSock(t)
	if _, err := c.LiveAckShown(context.Background(), "c-901", []string{ackM1}); !errors.Is(err, ErrNoSidecar) {
		t.Fatalf("nothing listening: %v, want ErrNoSidecar", err)
	}
	if _, err := c.LiveAckShown(context.Background(), "c-901", nil); err == nil || errors.Is(err, ErrNoSidecar) {
		t.Fatalf("no ids: %v, want a refusal before the socket", err)
	}
}

// A sidecar with no session (the hub down) answers within submitWaitSession,
// acked 0: the ack is dropped, nothing waits on it longer.
func TestLiveAckShownSidecarWithoutSession(t *testing.T) {
	old := submitWaitSession
	submitWaitSession = 50 * time.Millisecond
	t.Cleanup(func() { submitWaitSession = old })
	c := testClient(t)
	c.Cfg.SubmitSocket = shortSock(t)
	srv, err := c.Listen()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer srv.Close()
	go srv.Serve(ctx, nil)
	waitSock(t, c.Cfg.SubmitPath())
	n, err := c.LiveAckShown(ctx, "c-901", []string{ackM1})
	if n != 0 || err == nil || !strings.Contains(err.Error(), "no hub session") {
		t.Fatalf("acked %d, err %v; want 0 and no hub session", n, err)
	}
}

// With a live session the sidecar writes one frame per id and says how many;
// on a session that has ended it writes none and says why.
func TestLiveAckShownOverTheSidecar(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sess, err := c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	srv, err := c.Listen()
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	go srv.Serve(ctx, sess)
	waitSock(t, c.Cfg.SubmitPath())
	if n, err := c.LiveAckShown(ctx, "c-901", []string{ackM1, ackM2, ackM1}); n != 2 || err != nil {
		t.Fatalf("acked %d, err %v; want 2, nil", n, err)
	}
	if err := sess.liveAck("c-901", ackM1, wire.AckShown); err != nil {
		t.Fatalf("a frame on the live session: %v", err)
	}
	sess.Close()
	<-sess.Done()
	if err := sess.liveAck("c-901", ackM1, wire.AckShown); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("a frame on an ended session: %v, want ErrUnreachable", err)
	}
}
