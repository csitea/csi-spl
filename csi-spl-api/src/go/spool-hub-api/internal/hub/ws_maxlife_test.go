package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// closeOf reads c until it ends or wait passes; it returns the close status
// the hub sent (-1 = none) and the reason, or ok=false when c is still open.
func closeOf(c *websocket.Conn, wait time.Duration) (code websocket.StatusCode, reason string, ok bool) {
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	for {
		if _, _, err := c.Read(ctx); err != nil {
			if ctx.Err() != nil {
				return -1, "", false
			}
			var ce websocket.CloseError
			if errors.As(err, &ce) {
				return ce.Code, ce.Reason, true
			}
			return -1, err.Error(), true
		}
	}
}

func boxHello(t *testing.T, e *env, tenant string, b *box) *websocket.Conn {
	t.Helper()
	c, n := e.raw(tenant)
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{"CLE-07"}
	ctx := context.Background()
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("welcome %v %+v", err, wel)
	}
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return c
}

// SPL-1981: a box socket is closed by the hub at its max life with 1012
// max_life, so a retired Cloud Run instance does not hold a max_instances
// slot until the 3600 s request timeout. CONTROL: with no cap the same socket
// is still open after several times that life (the pre-fix hub).
func TestWSMaxLifeClosesBoxSocket(t *testing.T) {
	life := 300 * time.Millisecond
	off := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	to, _ := off.tenant()
	bo := off.box(to, "box-a", "CLE-07")
	off.pin(to, bo)
	if code, why, closed := closeOf(boxHello(t, off, to, bo), 4*life); closed {
		t.Fatalf("control: with no max life the box socket was closed (%d %q)", code, why)
	}

	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff; o.WSMaxLife = life })
	tn, _ := e.tenant()
	b := e.box(tn, "box-a", "CLE-07")
	e.pin(tn, b)
	start := time.Now()
	code, why, closed := closeOf(boxHello(t, e, tn, b), 10*life)
	if !closed {
		t.Fatalf("the box socket outlived its max life %s", life)
	}
	if code != websocket.StatusServiceRestart || why != hub.CloseMaxLife {
		t.Fatalf("close = %d %q, want 1012 %q", code, why, hub.CloseMaxLife)
	}
	if el := time.Since(start); el < life*4/5 {
		t.Fatalf("closed after %s, before the floor of its jittered life (%s)", el, life*4/5)
	}
	// A max-life close is a roll, not a disconnect: the box keeps reading
	// online while it redials (no left stamp, the shared stamp decides).
	time.Sleep(50 * time.Millisecond)
	if !rosterOnline(t, e, tn)["box-a"] {
		t.Fatal("box-a reads offline right after its max-life close: a planned redial flaps presence")
	}
}

// The browser socket gets the same cap: one long-lived tab pins a retired
// instance just as a box does (07:40:55Z, a 3601 s /v1/wui/ws on ...69f9cffe89).
func TestWSMaxLifeClosesWUISocket(t *testing.T) {
	life := 300 * time.Millisecond
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff; o.WSMaxLife = life })
	tn, _ := e.tenant()
	c, st := e.dialWS(tn, edge.PathWUIWS, nil)
	if st != http.StatusSwitchingProtocols {
		t.Fatalf("wui socket refused %d", st)
	}
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	if err := wsjson.Write(context.Background(), c, map[string]string{"type": "hello"}); err != nil {
		t.Fatal(err)
	}
	code, why, closed := closeOf(c, 10*life)
	if !closed || code != websocket.StatusServiceRestart || why != hub.CloseMaxLife {
		t.Fatalf("wui close = %v %d %q, want 1012 %q", closed, code, why, hub.CloseMaxLife)
	}
}
