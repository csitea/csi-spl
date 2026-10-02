package hub_test

import (
	"context"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 061 3.3.1 (FR-015): every machine numbers c-004..c-999 on its own, so
// two machines each run a c-004. `spool send --to c-004@<box>` reaches that
// box's c-004 and only it; a bare c-004 is refused as ambiguous, never
// delivered to a guess.
func TestSendToAgentAtBoxReachesOnlyThatAgent(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	home := e.box(tid, "box-desk", "c-004", "c-005")
	sat := e.box(tid, "box-desk-sat", "c-004")
	e.pin(tid, home)
	e.pin(tid, sat)
	homeH := harness(t, home, "c-004", "c-005")
	satH := harness(t, sat, "c-004")
	ctx := context.Background()
	for _, b := range []*box{home, sat} {
		s, err := b.c.Dial(ctx, wire.RoleBox)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
	}
	eventually(t, "home sees the satellite's c-004 on the hub roster", func() bool {
		_, err := home.c.ResolveToBox("c-004", "")
		return err != nil && strings.Contains(err.Error(), "ambiguous_to_box")
	})

	if out := send(t, home, "c-005", "c-004@box-desk-sat", "note", "to sat", ""); out.Delivery != wire.DeliverySent {
		t.Fatalf("c-004@box-desk-sat delivery %q", out.Delivery)
	}
	send(t, home, "c-005", "c-004@box-desk", "note", "to home", "")
	eventually(t, "each c-004 holds only its own mail", func() bool {
		return strings.Join(harnessBodies(t, satH, "c-004"), ",") == "to sat" &&
			strings.Join(harnessBodies(t, homeH, "c-004"), ",") == "to home"
	})

	_, err := action.SendCtx(ctx, home.cfg, action.SendArgs{From: "c-005", To: "c-004", Kind: "note", Body: "guess", Hub: home.c})
	if err == nil || !strings.Contains(err.Error(), "ambiguous_to_box") {
		t.Fatalf("a bare c-004 on two boxes: %v, want ambiguous_to_box", err)
	}
}
