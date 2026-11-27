package hubclient

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-6700: a channel frame for THIS box that names its m.To among the agents
// wrote m.To's copy even when no such mailbox was hosted here, and so minted
// <root>/<m.To>/{inbox,outbox,archive}: on 2026-11-27 one move notice made 22
// csitea desk seats on one box for ids the hub still listed as channel
// invites, and
// the retired c-873's next holder then got the owner's channel posts. Run on
// the code before the fix, the c-873 dir exists and this goes red. CONTROL:
// the same frame to a hosted c-007 lands, and a plain DM to an id with no
// mailbox yet still makes one (a first DM is how a mailbox starts).
func TestChannelFrameToUnhostedAgentMakesNoMailbox(t *testing.T) {
	wui := newPeer(t, wuiBox)
	h := &opsHub{pins: []wire.PinEntry{wui.pin}}
	c := opsClient(t, h)
	pokeLog(t, c)

	ghost := note("HUM-10", "c-873", "note", "Moved: message x now lives in topic y")
	seated := note("HUM-10", "c-007", "note", "Moved: message x now lives in topic y")
	dm := note("HUM-10", "c-055", "task", "a first DM")
	h.push = []wire.Frame{
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "ops", ghost), Agents: []string{"c-873"}},
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "ops", seated), Agents: []string{"c-007"}},
		{Type: wire.TRecv, Env: envRaw(t, wui, "box-a", "", dm)},
	}
	r, err := c.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(c.Cfg.SpoolRoot, "c-873")); !os.IsNotExist(err) {
		t.Fatalf("a channel frame for the unhosted c-873 made its mailbox (lstat err %v)", err)
	}
	if n := inbox(t, c, "c-007"); n != 1 {
		t.Errorf("CONTROL: hosted c-007 got %d copies, want 1", n)
	}
	if n := inbox(t, c, "c-055"); n != 1 {
		t.Errorf("CONTROL: a DM to c-055 got %d copies, want 1", n)
	}
	if r.Delivered != 2 || r.Refused != 0 {
		t.Errorf("report %+v, want 2 delivered, 0 refused", r)
	}
}
