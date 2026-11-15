package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-5594 (owner poll answer B on SPL-5514): the escalation waits for the
// take / ack deferral plus the grace. A zero deferral keeps the grace, a zero
// grace stays off.
func TestUnansweredAfterAddsTheDeferral(t *testing.T) {
	cases := []struct{ grace, deferral, want time.Duration }{
		{120 * time.Second, 300 * time.Second, 420 * time.Second},
		{120 * time.Second, 0, 120 * time.Second},
		{120 * time.Second, -time.Second, 120 * time.Second},
		{0, 300 * time.Second, 0},
	}
	for _, c := range cases {
		if got := hub.UnansweredAfter(c.grace, c.deferral); got != c.want {
			t.Errorf("UnansweredAfter(%v, %v) = %v, want %v", c.grace, c.deferral, got, c.want)
		}
	}
}

// SPL-5594: a human post with no reply is NOT escalated while the deferral
// runs, even past the bare grace, and IS once deferral + grace have passed.
// The rig of TestEscalateUnansweredReachesResponderDespiteOnlineAgent; the
// clock moves, no wall-clock sleep.
func TestEscalateUnansweredWaitsForTheDeferral(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	const grace, deferral = 2 * time.Second, 6 * time.Second
	var clockOffset atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		fallbackOpts(o, key, true)
		o.UnansweredGrace = hub.UnansweredAfter(grace, deferral)
		o.Now = func() time.Time { return time.Now().Add(time.Duration(clockOffset.Load())) }
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	e.pinKey(tid, hub.WUIBox, pub)
	if err := e.st.(store.Fallbacks).SetTenantResponders(ctx, tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	desk := e.box(tid, "box-desk", "CLE-001")
	pokes := pokeLog(t, desk)
	e.pin(tid, desk)
	sd, err := desk.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sd)
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "staffed",
		Name: "staffed", CreatedBy: human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "staffed", []string{human}, human, now); err != nil {
		t.Fatal(err)
	}
	b := e.box(tid, "box-b", "GRK-36")
	e.pin(tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sb)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/staffed/agents", human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	ws := dialMember(t, e, tid, "Owner", human)
	m1, task := "5d9eaf10-2b3c-4d4e-9f50-6b7c8d9e0f1a", "3b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e"
	threadFrame(t, ws, m1, task, "staffed", 1, "please pick this up")
	eventually(t, "GRK-36 got it the ordinary way", func() bool { return strings.Join(inboxIDs(t, b, "GRK-36"), ",") == m1 })
	// Past the bare grace, still inside the deferral: nothing is escalated.
	for _, at := range []time.Duration{grace + time.Second, deferral - time.Second} {
		clockOffset.Store(int64(at))
		e.srv.Relay(ctx)
		if n := len(inbox(t, desk, "CLE-001")); n != 0 || len(pokes()) != 0 {
			t.Fatalf("escalated at +%v, inside the %v deferral: CLE-001 inbox %d pokes %v", at, deferral, n, pokes())
		}
	}
	// Past deferral + grace with no reply: the sweep escalates it.
	clockOffset.Store(int64(deferral + grace + time.Second))
	e.srv.Relay(ctx)
	eventually(t, "CLE-001 got the escalation", func() bool { return strings.Join(inboxIDs(t, desk, "CLE-001"), ",") == m1 })
}
