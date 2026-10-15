package hubclient

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The paths below ran or not by timing, so internal/hubclient's coverage read
// 81.3..81.7 run to run on one tree and the coverage floor gate flaked by box
// load (c-001 task d6f1ab13). Each test reaches its path on its own, with no
// race left to lose.

// RSPCount on a session whose socket is already closed fails the write.
func TestRSPCountWriteOnClosedSession(t *testing.T) {
	_, s := dialOps(t, &opsHub{reply: func(wire.Frame) []wire.Frame { return nil }}, wire.RoleCLI)
	s.Close()
	<-s.Done()
	if _, err := s.RSPCount(context.Background(), "t"); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("got %v, want ErrUnreachable", err)
	}
}

// The socket closes, or the caller's ctx ends, after the rsp_count frame went
// out and before any reply: RSPCount returns on that, not on its reply
// timeout. (A ctx cancelled before the call fails the write or not by timing.)
func TestRSPCountEndsWhileWaiting(t *testing.T) {
	for _, tc := range []struct {
		name string
		end  func(*Session, context.CancelFunc)
		want func(error) bool
	}{
		{"socket closed", func(s *Session, _ context.CancelFunc) { s.Close() },
			func(err error) bool {
				return errors.Is(err, ErrUnreachable) && strings.Contains(err.Error(), "socket closed")
			}},
		{"ctx cancelled", func(_ *Session, cancel context.CancelFunc) { cancel() },
			func(err error) bool { return errors.Is(err, context.Canceled) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := &opsHub{reply: func(wire.Frame) []wire.Frame { return nil }}
			_, s := dialOps(t, h, wire.RoleCLI)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				for len(h.frames(wire.TTail)) == 0 {
					time.Sleep(5 * time.Millisecond)
				}
				tc.end(s, cancel)
			}()
			if _, err := s.RSPCount(ctx, "t"); !tc.want(err) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

// hold on an ended session returns its endErr from either select arm: the
// session's own Done, or the ended ctx with the session found ended too. With
// both ready, select picks one at random, so 64 calls reach each arm (a miss
// is 2^-64).
func TestHoldEndedSessionReturnsFromEitherArm(t *testing.T) {
	c, s := dialOps(t, &opsHub{}, wire.RoleCLI)
	s.Close()
	<-s.Done()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for i := 0; i < 64; i++ {
		if err := c.hold(ctx, s); err != nil {
			t.Fatalf("call %d: hold on a closed (not superseded) session: %v", i, err)
		}
	}
}

// sidecar listens on a fresh submit socket for c and runs serve on the first
// connection it accepts.
func sidecar(t *testing.T, c *Client, serve func(net.Conn)) {
	t.Helper()
	c.Cfg.SubmitSocket = shortSock(t)
	ln, err := net.Listen("unix", c.Cfg.SubmitPath())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		serve(conn)
	}()
}

// A sidecar that closes without reading: a request larger than the socket
// buffer cannot be written, so submit fails on the write.
func TestSubmitWriteToClosedSidecar(t *testing.T) {
	c := testClient(t)
	sidecar(t, c, func(net.Conn) {})
	raw, _ := json.Marshal(strings.Repeat("x", 8<<20))
	_, err := c.submit(context.Background(), raw, Claims{})
	if !errors.Is(err, ErrUnreachable) || !strings.Contains(err.Error(), "submit write") {
		t.Fatalf("got %v, want ErrUnreachable: submit write", err)
	}
}

// A sidecar that reads the request and closes without a reply.
func TestSubmitSidecarClosesWithoutReply(t *testing.T) {
	c := testClient(t)
	sidecar(t, c, func(conn net.Conn) { bufio.NewReader(conn).ReadBytes('\n') }) //nolint:errcheck
	_, err := c.submit(context.Background(), []byte(`{}`), Claims{})
	if !errors.Is(err, ErrUnreachable) || !strings.Contains(err.Error(), "submit reply") {
		t.Fatalf("got %v, want ErrUnreachable: submit reply", err)
	}
}

// The submit server answers a request line that is not JSON with an error
// line, and never touches the session.
func TestSubmitServerRefusesUnparsableRequest(t *testing.T) {
	c := testClient(t)
	c.Cfg.SubmitSocket = shortSock(t)
	srv, err := c.Listen()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.Serve(ctx, nil)
	conn, err := net.Dial("unix", c.Cfg.SubmitPath())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("not json\n")); err != nil {
		t.Fatal(err)
	}
	var resp submitResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil || resp.Error != "submit request does not parse" {
		t.Fatalf("reply %+v err %v", resp, err)
	}
}
