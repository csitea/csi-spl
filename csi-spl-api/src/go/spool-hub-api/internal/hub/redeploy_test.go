package hub_test

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// redeploy is a Cloud Run revision swap in miniature: two hub processes that
// share one store, behind one URL. flip() sends every NEW request to the second
// process while a socket already upgraded on the first stays there and keeps
// ponging - which is exactly what a redeploy does to a box's WS, because a WS
// is an in-flight request and the old revision lives until the request timeout.
// nextClient reaches the second process directly, whatever flip() says: a
// sender that already lands there while the box is still held by the first.
type redeploy struct {
	cur        atomic.Pointer[http.Handler]
	next       http.Handler
	client     *http.Client
	nextClient *http.Client
}

// dialOnly is a client whose every Host resolves to addr.
func dialOnly(addr string) *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	return &http.Client{Transport: tr}
}

func newRedeploy(t *testing.T, e *env) *redeploy {
	t.Helper()
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-next",
	}
	next, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	r := &redeploy{next: next.Handler()}
	first := e.srv.Handler()
	r.cur.Store(&first)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		(*r.cur.Load()).ServeHTTP(w, q)
	}))
	nts := httptest.NewServer(r.next)
	t.Cleanup(func() { next.Shutdown(); ts.Close(); nts.Close() })
	r.client = dialOnly(ts.Listener.Addr().String())
	r.nextClient = dialOnly(nts.Listener.Addr().String())
	return r
}

func (r *redeploy) flip() { r.cur.Store(&r.next) }

// The box-desk strand of 2026-09-25: after a dev hub redeploy the
// sidecar logged `hub session up` and then nothing, the hub said the box was
// offline, and for ~50 min every accepted message queued for a box that never
// came back - the 030 ping kept passing, because the OLD process answered it.
//
// With the session probe the box notices that the process answering REST does
// not know its upload token (401 door), redials onto the new process, and that
// hello drains the queue: the message sent during the strand arrives. Without
// it (SessionProbe < 0, the pre-fix binary) the box stays on the old process
// and the message never arrives.
func TestBoxRedialsAfterHubRedeploy(t *testing.T) {
	for _, tc := range []struct {
		name  string
		probe time.Duration
		want  bool
	}{
		{"old binary stays stranded", -1, false},
		{"probe redials and drains", 200 * time.Millisecond, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			tid, _ := e.tenant()
			rd := newRedeploy(t, e)
			a := e.box(tid, "box-a", "GRK-03")
			b := e.box(tid, "box-b", "CLE-07")
			a.c.HTTP, b.c.HTTP = rd.client, rd.client
			a.cfg.SubmitSocket, b.cfg.SubmitSocket = "off", "off"
			e.pin(tid, a)
			e.pin(tid, b)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if _, err := a.c.Sync(ctx); err != nil {
				t.Fatal(err)
			}

			b.c.SessionProbe = tc.probe
			done := make(chan error, 1)
			go func() { done <- b.c.Run(ctx) }()
			send(t, a, "GRK-03", "CLE-07", "task", "before the redeploy", "box-b")
			eventually(t, "the pre-redeploy message", func() bool { return len(inbox(t, b, "CLE-07")) == 1 })

			// The strand message goes to the new process BEFORE the flip.
			// Sent after it, a probe tick (every 200 ms) could already have
			// redialled box-b onto the new process, and the send then came
			// back "sent" instead of "queued" (wf10 run 37578242459, -race on
			// Postgres). Before the flip box-b's probes still reach the old
			// process, which knows its token, so it cannot have moved yet.
			a.c.HTTP = rd.nextClient
			out := send(t, a, "GRK-03", "CLE-07", "task", "during the strand", "box-b")
			if out.Delivery != "queued" {
				t.Fatalf("the new hub process should not know box-b yet: delivery %q, want queued", out.Delivery)
			}
			rd.flip()
			start := time.Now()
			// The redial drains in ~1 s (max 1.04 s over 360 runs at up to
			// 48-way parallel load), yet a lane saw it trip a flat 3 s inside
			// the full -race suite under fleet load (CLE-77797). The
			// window only bounds how long a PASS may take - the loop exits on
			// delivery - so the redial case waits 15 s. The stranded case keeps
			// 3 s: three redial periods of silence are its proof.
			window := 3 * time.Second
			if tc.want {
				window = 15 * time.Second
			}
			got := false
			for deadline := time.Now().Add(window); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
				if len(inbox(t, b, "CLE-07")) == 2 {
					got = true
					break
				}
			}
			if got != tc.want {
				t.Fatalf("message sent during the strand delivered=%v, want %v", got, tc.want)
			}
			if got {
				t.Logf("redialled and drained %v after the redeploy", time.Since(start).Round(time.Millisecond))
			}
			cancel()
			<-done
		})
	}
}
