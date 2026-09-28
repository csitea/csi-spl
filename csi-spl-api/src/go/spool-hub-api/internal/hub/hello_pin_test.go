package hub_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of the hello refusals no other test drove, taken before hello was
// split into named steps (SPL-1029 round 2): each malformed hello closes
// with its code and reason, and nothing is seated for the box.
func TestHelloRefusalShapes(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	now := time.Now().UTC().Format(time.RFC3339)
	before, _ := e.st.Roster(context.Background(), tid)
	for _, c := range []struct {
		name string
		edit func(f *wire.Frame)
		code int
		why  string
	}{
		{"not a hello", func(f *wire.Frame) { f.Type = wire.TSend }, int(wire.CloseBadFrame), "bad_frame"},
		{"unknown role", func(f *wire.Frame) { f.Role = "wui" }, int(wire.CloseBadFrame), "bad_frame"},
		{"bad box id", func(f *wire.Frame) { f.BoxID = "Bad Box" }, int(wire.CloseBadFrame), "bad_frame"},
		{"box-wui", func(f *wire.Frame) { f.BoxID = hub.WUIBox }, int(wire.CloseUnauthorized), "unauthorized"},
		{"bad signature", func(f *wire.Frame) { f.Sig = f.Sig[:len(f.Sig)-4] + "AAAA" }, int(wire.CloseUnauthorized), "bad_sig"},
		{"duplicate roster", func(f *wire.Frame) { f.Agents = []string{"GRK-03", "GRK-03"} }, int(wire.CloseBadFrame), "roster_duplicate"},
	} {
		conn, nonce := e.raw(tid)
		f := helloFrame(a, nonce, now, wire.RoleBox)
		c.edit(&f)
		wsjson.Write(context.Background(), conn, f) //nolint:errcheck
		if code, why := closeReason(t, conn); int(code) != c.code || why != c.why {
			t.Errorf("%s: %d %q, want %d %q", c.name, code, why, c.code, c.why)
		}
	}
	if r, _ := e.st.Roster(context.Background(), tid); !reflect.DeepEqual(r["box-a"], before["box-a"]) {
		t.Fatalf("a refused hello changed the roster: %v -> %v", before["box-a"], r["box-a"])
	}
}
