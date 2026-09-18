package hub_test

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// slowRoster stalls the next Roster read once armed: it holds a registered
// session between register and its welcome, the window of the race.
type slowRoster struct {
	store.Store
	armed atomic.Bool
	delay time.Duration
}

func (s *slowRoster) Roster(ctx context.Context, tenantID string) (map[string][]string, error) {
	if s.armed.CompareAndSwap(true, false) {
		time.Sleep(s.delay)
	}
	return s.Store.Roster(ctx, tenantID)
}

// A roster broadcast (another box's hello) must not reach a session before
// that session's own welcome: the box reads welcome first, always.
func TestWelcomeIsFirstFrameDespiteConcurrentRoster(t *testing.T) {
	var slow *slowRoster
	e := newEnv(t, func(o *hub.Options) {
		slow = &slowRoster{Store: o.Store, delay: 400 * time.Millisecond}
		o.Store = slow
	})
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	now := func() string { return time.Now().UTC().Format(time.RFC3339) }

	cb, nb := e.raw(tid)
	hb := helloFrame(b, nb, now(), wire.RoleBox)
	hb.Agents = []string{"CLE-07"}
	slow.armed.Store(true)
	wsjson.Write(ctx, cb, hb)          //nolint:errcheck
	time.Sleep(100 * time.Millisecond) // b is registered, its welcome is stalled

	ca, na := e.raw(tid)
	ha := helloFrame(a, na, now(), wire.RoleBox)
	ha.Agents = []string{"GRK-03"}
	defer ca.CloseNow()       //nolint:errcheck
	wsjson.Write(ctx, ca, ha) //nolint:errcheck
	var wa wire.Frame
	if err := wsjson.Read(ctx, ca, &wa); err != nil || wa.Type != wire.TWelcome {
		t.Fatalf("box-a: %v %+v", err, wa)
	}

	var first wire.Frame
	if err := wsjson.Read(ctx, cb, &first); err != nil || first.Type != wire.TWelcome {
		t.Fatalf("box-b first frame %q (err %v), want welcome", first.Type, err)
	}
	var next wire.Frame
	rctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	for next.Type != wire.TRoster {
		if err := wsjson.Read(rctx, cb, &next); err != nil {
			t.Fatalf("box-b never got the roster broadcast after welcome: %v", err)
		}
	}
	if len(next.Roster["box-a"]) != 1 {
		t.Fatalf("roster after welcome: %+v", next.Roster)
	}
}
