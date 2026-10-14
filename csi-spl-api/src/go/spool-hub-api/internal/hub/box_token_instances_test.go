package hub_test

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-1826: with cnf max_instances 2 a box's socket and its REST calls are
// routed independently - the box client carries no session-affinity cookie,
// so its WS may sit on instance A while its 30 s probe (GET /v1/pins) or a
// desk put-file (POST /v1/files) lands on instance B of the SAME revision.
// Before the fix (box token in A's memory only) every one of those calls on
// B got 401 door: n = 15 dials, 15 probes, 15 put-files over 3 runs, and
// the hold loop redialled 3 of 3 runs. A retired revision still refuses it.

// split sends a WS upgrade to ws and every other request to *rest, and
// counts the upgrades: each one is a (re)dial of the box's session.
type split struct {
	ws    *http.Client
	rest  atomic.Pointer[http.Client]
	dials atomic.Int32
}

func newSplit(ws, rest *http.Client) *split {
	s := &split{ws: ws}
	s.rest.Store(rest)
	return s
}

func (s *split) client() *http.Client {
	return &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Upgrade") != "" {
			s.dials.Add(1)
			return s.ws.Transport.RoundTrip(r)
		}
		return s.rest.Load().Transport.RoundTrip(r)
	})}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func isDoor(err error) bool {
	var he *hubclient.HubError
	return errors.As(err, &he) && he.Status == http.StatusUnauthorized && he.Token == "door"
}

// two is instance A (e) of revision revA and B of revB on one store and
// one key: a live sibling when they match, the next deploy when not.
func two(t *testing.T, revA, revB string) (*env, *env) {
	a := newEnv(t, func(o *hub.Options) { o.UploadTokenKey, o.Revision = uploadKey, revA })
	return a, newUploadPeer(t, a, uploadKey, nil, func(o *hub.Options) { o.Revision = revB })
}

// The box's dial, probe and put-file with its socket on A and REST on B,
// against the control with REST on A too. n = 5 each.
func TestBoxTokenOnTheOtherLiveInstance(t *testing.T) {
	const n = 5
	for _, tc := range []struct {
		name   string
		restOn func(a, b *env) *http.Client
	}{
		{"control: REST on A", func(a, _ *env) *http.Client { return a.client }},
		{"REST on the sibling B", func(_, b *env) *http.Client { return b.client }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, b := two(t, "rev-1", "rev-1")
			tid, _ := a.tenant()
			bx := a.box(tid, "box-a", "GRK-03")
			a.pin(tid, bx)
			sp := newSplit(a.client, tc.restOn(a, b))
			bx.c.HTTP = sp.client()
			ctx := context.Background()
			for i := range n {
				sess, err := bx.c.Dial(ctx, wire.RoleBox)
				if err != nil {
					t.Errorf("dial %d (pin sync on REST): %v (false door=%v)", i, err, isDoor(err))
					continue
				}
				sess.Close()
			}
			// The socket on A whatever the case, then REST moves.
			sp.rest.Store(a.client)
			sess, err := bx.c.Dial(ctx, wire.RoleBox)
			if err != nil {
				t.Fatal(err)
			}
			defer sess.Close()
			sp.rest.Store(tc.restOn(a, b))
			src := filepath.Join(t.TempDir(), "f.txt")
			for i := range n {
				if err := sess.Probe(ctx); err != nil {
					t.Errorf("probe %d: %v (false door=%v)", i, err, isDoor(err))
				}
				os.WriteFile(src, []byte{'x', byte(i)}, 0o600) //nolint:errcheck
				att, err := files.PutFile(bx.cfg.FilesDir(), src)
				if err != nil {
					t.Fatal(err)
				}
				if err := sess.UploadFile(ctx, att.FileID); err != nil {
					t.Errorf("put-file %d: %v (false door=%v)", i, err, isDoor(err))
				}
			}
		})
	}
}

// The hold loop: the session dialled on A with REST on A, then REST moves
// to the sibling B; a probe every 50 ms for 1.5 s must not redial.
func TestBoxNoSpuriousRedialOnTheOtherLiveInstance(t *testing.T) {
	a, b := two(t, "rev-1", "rev-1")
	tid, _ := a.tenant()
	bx := a.box(tid, "box-a", "GRK-03")
	a.pin(tid, bx)
	sp := newSplit(a.client, a.client)
	bx.c.HTTP = sp.client()
	bx.cfg.SubmitSocket = "off"
	bx.c.SessionProbe = 50 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- bx.c.Run(ctx) }()
	eventually(t, "the first dial", func() bool { return sp.dials.Load() == 1 })
	time.Sleep(200 * time.Millisecond) // past the dial's pin sync
	sp.rest.Store(b.client)
	time.Sleep(1500 * time.Millisecond)
	cancel()
	<-done
	if d := sp.dials.Load(); d != 1 {
		t.Errorf("session dials: %d, want 1 (spurious redials %d)", d, d-1)
	}
}

// The strand detection holds: B runs the next revision, so the token A
// minted is refused there 401 door, and the hold loop redials (the new dial
// fails its pin sync on B too while the WS stays on A, so it keeps trying).
func TestBoxTokenRetiredRevisionStillStrands(t *testing.T) {
	a, b := two(t, "rev-1", "rev-2")
	tid, _ := a.tenant()
	bx := a.box(tid, "box-a", "GRK-03")
	a.pin(tid, bx)
	sp := newSplit(a.client, a.client)
	bx.c.HTTP = sp.client()
	ctx := context.Background()
	sess, err := bx.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	sp.rest.Store(b.client)
	for i := range 3 {
		if err := sess.Probe(ctx); !isDoor(err) {
			t.Errorf("probe %d on the next revision: %v, want 401 door", i, err)
		}
	}
	sess.Close()

	sp.rest.Store(a.client)
	bx.cfg.SubmitSocket = "off"
	bx.c.SessionProbe = 50 * time.Millisecond
	rctx, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	// base is read before Run starts: read after, a fast first dial was
	// already in it and the wait below looked for a second one that never
	// comes (CI flake, wf 10 run 38567360021, 5.43 s).
	base := sp.dials.Load()
	go func() { done <- bx.c.Run(rctx) }()
	eventually(t, "the hold loop's dial", func() bool { return sp.dials.Load() == base+1 })
	time.Sleep(200 * time.Millisecond)
	sp.rest.Store(b.client)
	eventually(t, "the strand redial", func() bool { return sp.dials.Load() > base+1 })
	cancel()
	<-done
}
