package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// stuckRosterStore never seats a roster: SetRoster waits for its ctx, as a
// pool acquire did on an exhausted pool (SPL-2238).
type stuckRosterStore struct{ *store.Memory }

func (stuckRosterStore) SetRoster(ctx context.Context, _, _ string, _ []string, _ time.Time) error {
	<-ctx.Done()
	return ctx.Err()
}

// SPL-2238: a hello whose store work is stuck ends at HelloStoreTimeout
// instead of waiting forever; the box sees the socket close, no welcome.
func TestHelloStoreDeadline(t *testing.T) {
	st := stuckRosterStore{store.NewMemory()}
	e := newEnv(t, func(o *hub.Options) { o.Store = st; o.HelloStoreTimeout = 300 * time.Millisecond })
	e.st = st
	tid, _ := e.tenant()
	b := e.box(tid, "box-a") // no agents: pin seats no roster
	e.pin(tid, b)
	c, nonce := e.raw(tid)
	h := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{"c-004"}
	if err := wsjson.Write(context.Background(), c, h); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	start := time.Now()
	var f wire.Frame
	err := wsjson.Read(ctx, c, &f)
	if err == nil {
		t.Fatalf("a hello with a stuck roster write was answered: %+v", f)
	}
	if ctx.Err() != nil {
		t.Fatalf("the hello was still open after %s: no store deadline", time.Since(start).Round(time.Millisecond))
	}
}
