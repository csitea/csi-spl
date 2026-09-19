package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// 009 T003 (spec D-3, D-5): a bot seat over the M4 cap. announce growing
// past the cap → error quota/402 with the roster unchanged; shrinking → ok;
// a hello over cap keeps the already-seated agents and stays up.
func TestBotSeatCapAnnounceAndHello(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	a := e.box(tid, "box-a")
	e.pin(tid, a)
	if err := e.st.SetSeatCaps(ctx, tid, 0, 2); err != nil {
		t.Fatal(err)
	}
	roster := func() string {
		r, _ := e.st.Roster(ctx, tid)
		return strings.Join(r["box-a"], ",")
	}
	hello := func(agents ...string) *websocket.Conn {
		c, n := e.raw(tid)
		h := helloFrame(a, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
		h.Agents = agents
		wsjson.Write(ctx, c, h) //nolint:errcheck
		var w wire.Frame
		if err := wsjson.Read(ctx, c, &w); err != nil || w.Type != wire.TWelcome {
			t.Fatalf("welcome: %v %+v", err, w)
		}
		return c
	}
	// next reads frames until a non-roster/presence one, or none within d.
	next := func(c *websocket.Conn, d time.Duration) (wire.Frame, bool) {
		for {
			rctx, cancel := context.WithTimeout(ctx, d)
			var f wire.Frame
			err := wsjson.Read(rctx, c, &f)
			cancel()
			if err != nil {
				return f, false
			}
			if f.Type == wire.TError {
				return f, true
			}
		}
	}

	c := hello("CLE-1", "CLE-2")
	if roster() != "CLE-1,CLE-2" {
		t.Fatalf("hello at cap: %q", roster())
	}
	// CONTROL: re-announce growing past cap → 402 quota, roster unchanged.
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"CLE-1", "CLE-2", "CLE-3"}}) //nolint:errcheck
	f, ok := next(c, 2*time.Second)
	if !ok || f.Error != "quota" || f.Status != http.StatusPaymentRequired {
		t.Fatalf("grow past cap: %v %+v", ok, f)
	}
	if roster() != "CLE-1,CLE-2" {
		t.Fatalf("refused announce changed the roster: %q", roster())
	}
	// CONTROL: shrinking → ok, no error frame.
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"CLE-1"}}) //nolint:errcheck
	if f, ok := next(c, 500*time.Millisecond); ok {
		t.Fatalf("shrink answered an error: %+v", f)
	}
	if roster() != "CLE-1" {
		t.Fatalf("shrink: %q", roster())
	}
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	// Hello over cap (1 seated + 2 new > 2): keeps CLE-1, drops the additions,
	// socket stays up (existing peers keep working).
	c2 := hello("CLE-1", "CLE-8", "CLE-9")
	defer c2.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	if roster() != "CLE-1" {
		t.Fatalf("hello over cap: %q", roster())
	}
	wsjson.Write(ctx, c2, wire.Frame{Type: wire.TToken}) //nolint:errcheck
	var tok wire.Frame
	for tok.Type != wire.TToken {
		if err := wsjson.Read(ctx, c2, &tok); err != nil {
			t.Fatalf("socket after over-cap hello: %v", err)
		}
	}
}
