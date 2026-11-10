package hubclient

// Refactor round 30 row 05: sendFrame's revive of a sender the run report
// marked not running, which every other test survives without, and the now
// and timeout defaults of a zero Client. Non-test code unchanged.

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// rdStopped reports whether c holds a "not running since" clock for id.
func rdStopped(c *Client, id string) bool {
	c.dropMu.Lock()
	defer c.dropMu.Unlock()
	_, ok := c.stopSince[id]
	return ok
}

// An agent the run report marked not running sends a line the hub refuses as
// unannounced: sending is living, so its clock is gone after the resend.
func TestRDSendFrameRevivesStoppedSender(t *testing.T) {
	h := newUBHub(t)
	c := ubClient(t, h)
	c.DropAfter = time.Hour
	c.dropDead([]string{ubAgent}, map[string]bool{ubAgent: false})
	if !rdStopped(c, ubAgent) {
		t.Fatalf("setup: %s has no not-running clock", ubAgent)
	}
	m, env, _ := srPending(t, c, "first line")
	s := srSession(t, c, wire.RoleBox)
	f, err := s.sendFrame(context.Background(), env, wire.Frame{})
	if err != nil || f.Type != wire.TSent || f.MsgID != m.MsgID {
		t.Fatalf("frame %+v err %v, want the sent frame of %s", f, err, m.MsgID)
	}
	if rdStopped(c, ubAgent) {
		t.Fatalf("%s still has a not-running clock after its line was sent", ubAgent)
	}
}

func TestRDZeroClientNowIsWallClock(t *testing.T) {
	if d := time.Since((&Client{}).now()); d < -time.Second || d > time.Second {
		t.Fatalf("Client{}.now() is %v off the wall clock", d)
	}
}

func TestRDZeroClientTimeoutIsDefault(t *testing.T) {
	if got := (&Client{}).timeout(); got != defaultReadyTimeout {
		t.Fatalf("Client{}.timeout() = %v, want %v", got, defaultReadyTimeout)
	}
}
