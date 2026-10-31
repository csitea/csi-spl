package hub_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// SPL-4522 (rows 4+5 of SPL-4420): Cloud Run kills an instance 10 s after
// SIGTERM, and Server.Shutdown runs first in that budget. A browser that does
// not answer the close frame holds its Close for the library's 5 s handshake
// wait; closed one after another, three such browsers held Shutdown for ~15 s,
// past the grace, and a live browser could get its 1001 only after them.
// Closed together, Shutdown returns in about one handshake wait, and every
// browser reads 1001.
func TestShutdownClosesSilentBrowsersTogether(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	var silent []*wuiClient
	for _, as := range []string{"HUM-1", "HUM-2", "HUM-3"} {
		silent = append(silent, dialWUI(t, e, tid, as)) // never reads again: no close reply
	}
	live := dialWUI(t, e, tid, "HUM-4")
	type closed struct {
		at  time.Time
		err error
	}
	liveClosed := make(chan closed, 1)
	go func() {
		for {
			if _, _, err := live.c.Read(context.Background()); err != nil {
				liveClosed <- closed{time.Now(), err}
				return
			}
		}
	}()

	start := time.Now()
	e.srv.Shutdown()
	took := time.Since(start)
	if took > 7*time.Second {
		t.Fatalf("Shutdown took %s with 3 silent browsers: want about one 5 s close wait, inside Cloud Run's 10 s grace", took)
	}
	select {
	case c := <-liveClosed:
		if d := c.at.Sub(start); d > 2*time.Second {
			t.Fatalf("the live browser got its close %s after Shutdown began: want it at once", d)
		}
		if code := websocket.CloseStatus(c.err); code != websocket.StatusGoingAway {
			t.Fatalf("live browser: want close 1001, got %v", c.err)
		}
	case <-time.After(time.Second):
		t.Fatal("the live browser was never closed")
	}
	for i, w := range silent {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		var err error
		for err == nil { // frames queued before the close come first
			_, _, err = w.c.Read(ctx)
		}
		cancel()
		var ce websocket.CloseError
		if !errors.As(err, &ce) || ce.Code != websocket.StatusGoingAway {
			t.Fatalf("silent browser %d: want close 1001, got %v", i, err)
		}
	}
	t.Logf("Shutdown with 3 silent + 1 live browser took %s", took.Round(10*time.Millisecond))
}
