//go:build spike

package hub_test

// Spec 059 broker spike, the CONTROL: today's spool path (hub + box
// websocket + the inbox file) run through the same four tests as NATS
// JetStream, single-node Kafka and Postgres claims (csi-spl-doc/specs/
// 059-messaging-backbone/spike). Build tag `spike`: CI never compiles it.
//
//	SPOOL_TEST_PG_DSN=... SPIKE_OUT=<dir> go test -tags spike ./internal/hub -run Spike059 -v -count 1
//
// Each test prints one JSON line (the same fields as the broker runs) and
// writes it to $SPIKE_OUT/spool-t<N>.json.

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

type spikeResult struct {
	Backend     string  `json:"backend"`
	Test        int     `json:"test"`
	Consumers   string  `json:"consumers"`
	Want        int     `json:"want"`
	Got         int     `json:"got_unique"`
	Lost        int     `json:"lost"`
	Dup         int     `json:"dup_raw"`
	P50ms       float64 `json:"p50_ms"`
	P95ms       float64 `json:"p95_ms"`
	P99ms       float64 `json:"p99_ms"`
	MaxMs       float64 `json:"max_ms"`
	PubRetries  int     `json:"publish_retries"`
	RestartMs   float64 `json:"restart_ms,omitempty"`
	Redelivered *bool   `json:"redelivered,omitempty"`
	Pass        bool    `json:"pass"`
	Note        string  `json:"note,omitempty"`
}

func (r *spikeResult) emit(t *testing.T) {
	j, _ := json.Marshal(r)
	t.Log(string(j))
	if d := os.Getenv("SPIKE_OUT"); d != "" {
		os.WriteFile(filepath.Join(d, fmt.Sprintf("spool-t%d.json", r.Test)), append(j, '\n'), 0o644) //nolint:errcheck
	}
}

// spikeSender holds one role=cli socket and signs as box b. send re-dials and
// re-sends the SAME envelope (same msg id) on an error: the hub's insert is
// idempotent on msg id, so that is today's idempotent producer.
type spikeSender struct {
	t    *testing.T
	b    *box
	sess *hubclient.Session
	r    *spikeResult
}

func (s *spikeSender) send(toBox, to, body string) (string, time.Time) {
	s.t.Helper()
	priv, err := sign.LoadPrivate(s.b.cfg.KeysDir, s.b.id)
	if err != nil {
		s.t.Fatal(err)
	}
	m := &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(), TS: time.Now().UTC().Format(time.RFC3339),
		From: "GRK-03", To: to, Kind: "note", Body: body, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelope(priv, s.b.id, toBox, m)
	if err != nil {
		s.t.Fatal(err)
	}
	at := time.Now()
	deadline := at.Add(60 * time.Second)
	for {
		if s.sess != nil {
			if _, err := s.sess.Send(context.Background(), env); err == nil {
				return body, at // the inbox file name carries the body, not the full msg id
			}
			s.sess.Close()
			s.sess = nil
		}
		s.r.PubRetries++
		if time.Now().After(deadline) {
			s.t.Fatalf("send %s gave up", m.MsgID)
		}
		if sess, err := s.b.c.Dial(context.Background(), wire.RoleCLI); err == nil {
			s.sess = sess
		} else {
			time.Sleep(100 * time.Millisecond)
		}
	}
}

func newSender(t *testing.T, b *box, r *spikeResult) *spikeSender {
	s := &spikeSender{t: t, b: b, r: r}
	sess, err := b.c.Dial(context.Background(), wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	s.sess = sess
	return s
}

// arrivals reads the inbox files of agent `as` on box b: msg id -> mtime.
func arrivals(b *box, as string) map[string]time.Time {
	out := map[string]time.Time{}
	for _, d := range []string{"inbox", "archive"} {
		ents, _ := os.ReadDir(filepath.Join(b.cfg.SpoolRoot, as, d))
		for _, e := range ents {
			// msg.Filename: <ts>--<from>--<body slug>-<8 hex of the msg id>.json
			n := e.Name()
			parts := strings.SplitN(strings.TrimSuffix(n, ".json"), "--", 3)
			if fi, err := e.Info(); err == nil && len(parts) == 3 {
				slug := parts[2]
				if i := strings.LastIndex(slug, "-"); i > 0 {
					out[slug[:i]] = fi.ModTime()
				}
			}
		}
	}
	return out
}

func waitArrivals(b []*box, as []string, n int, d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		got := 0
		for i := range b {
			got += len(arrivals(b[i], as[i]))
		}
		if got >= n {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func scoreSpike(r *spikeResult, sent map[string]time.Time, got ...map[string]time.Time) {
	r.Want += len(sent)
	var lats []float64
	for id, at := range sent {
		n := 0
		var first time.Time
		for _, g := range got {
			if t, ok := g[id]; ok {
				n++
				if first.IsZero() || t.Before(first) {
					first = t
				}
			}
		}
		if n == 0 {
			r.Lost++
			continue
		}
		r.Got++
		r.Dup += n - 1
		lats = append(lats, float64(first.Sub(at).Microseconds())/1000)
	}
	sort.Float64s(lats)
	q := func(p float64) float64 {
		if len(lats) == 0 {
			return 0
		}
		return lats[min(len(lats)-1, int(p*float64(len(lats))))]
	}
	r.P50ms, r.P95ms, r.P99ms = max(r.P50ms, q(0.5)), max(r.P95ms, q(0.95)), max(r.P99ms, q(0.99))
	if len(lats) > 0 {
		r.MaxMs = max(r.MaxMs, lats[len(lats)-1])
	}
}

func pace(start time.Time, i, rate int) {
	if d := time.Until(start.Add(time.Duration(i) * time.Second / time.Duration(rate))); d > 0 {
		time.Sleep(d)
	}
}

// Test 1: 1,000 posts to each of two agents on two live boxes, 200 a second.
func TestSpike059Delivery(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	a := e.box(tid, "box-a", "CLE-11")
	b := e.box(tid, "box-b", "CLE-12")
	for _, x := range []*box{s, a, b} {
		e.pin(tid, x)
	}
	ctx := context.Background()
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sb.Close()
	r := &spikeResult{Backend: "spool", Test: 1, Consumers: "2 boxes x 1 agent"}
	snd := newSender(t, s, r)
	sentA, sentB := map[string]time.Time{}, map[string]time.Time{}
	start := time.Now()
	for i := 0; i < 1000; i++ {
		id, at := snd.send("box-a", "CLE-11", fmt.Sprintf("t1-%d", i))
		sentA[id] = at
		id, at = snd.send("box-b", "CLE-12", fmt.Sprintf("t1-%d", i))
		sentB[id] = at
		pace(start, i+1, 200)
	}
	waitArrivals([]*box{a, b}, []string{"CLE-11", "CLE-12"}, 2000, 60*time.Second)
	scoreSpike(r, sentA, arrivals(a, "CLE-11"))
	scoreSpike(r, sentB, arrivals(b, "CLE-12"))
	// The box writes <msg_id>.json and skips an id already there, so a
	// duplicate frame is invisible in the inbox; count frames instead.
	r.Dup = sa.Delivered() + sb.Delivered() - r.Got
	r.Pass = r.Lost == 0 && r.Dup == 0 && r.P95ms < 3000
	r.emit(t)
}

// Test 2: the dispatcher box is taken over halfway (058's model: the box id
// moves to a second machine). Today a "group" is one box id; the handover is
// the fleet lease (180 s in production, instant here).
func TestSpike059Failover(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	m1 := e.box(tid, "box-d", "CLE-14")
	m2 := e.machine2(m1, "CLE-14")
	e.pin(tid, s)
	e.pin(tid, m1)
	ctx := context.Background()
	s1, err := m1.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	r := &spikeResult{Backend: "spool", Test: 2, Consumers: "1 box id, 2 machines (takeover at 50 %)"}
	snd := newSender(t, s, r)
	sent := map[string]time.Time{}
	var s2 interface{ Close() }
	start := time.Now()
	for i := 0; i < 1000; i++ {
		if i == 500 {
			s1.Close()
			ss, err := m2.c.Dial(ctx, wire.RoleBox)
			if err != nil {
				t.Fatal(err)
			}
			s2 = ss
		}
		id, at := snd.send("box-d", "CLE-14", fmt.Sprintf("t2-%d", i))
		sent[id] = at
		pace(start, i+1, 200)
	}
	defer s2.Close()
	waitArrivals([]*box{m1, m2}, []string{"CLE-14", "CLE-14"}, 1000, 30*time.Second)
	scoreSpike(r, sent, arrivals(m1, "CLE-14"), arrivals(m2, "CLE-14"))
	r.Pass = r.Lost == 0 && r.Dup == 0
	r.emit(t)
}

// Test 3: the box reads 5 of 10 recv frames off its socket and dies before
// writing the 5th to the inbox (no ack exists to withhold). A fresh session
// of the same box then syncs: is the 5th delivered again?
func TestSpike059CrashBeforeAck(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	c := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, s)
	e.pin(tid, c)
	r := &spikeResult{Backend: "spool", Test: 3, Consumers: "1 box, crashed on #5, then a fresh session"}
	snd := newSender(t, s, r)
	raw := e.rawBoxNoDrain(tid, c, []string{"CLE-13"}, nil)
	raw.next(wire.TQueueEnd)
	var ids []string
	sent := map[string]time.Time{}
	for i := 0; i < 10; i++ {
		id, at := snd.send("box-c", "CLE-13", fmt.Sprintf("t3-%d", i))
		ids = append(ids, id)
		sent[id] = at
	}
	// The crashed box "processed" 1..4 (they would be in its inbox).
	processed := map[string]time.Time{}
	for i := 0; i < 5; i++ {
		f := raw.next(wire.TRecv)
		if env, err := wire.ParseEnvelope(f.Env); i < 4 && err == nil {
			if m, err := env.Inner(); err == nil {
				processed[m.Body] = time.Now()
			}
		}
	}
	raw.c.CloseNow() //nolint:errcheck // the crash
	time.Sleep(300 * time.Millisecond)
	// Control: what the hub still holds for the box after the crash.
	q, err := e.st.QueuedFor(context.Background(), tid, "box-c", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("after the crash the hub holds %d queued rows for box-c (10 sent, 4 processed)", len(q))
	if _, err := c.c.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := arrivals(c, "CLE-13")
	scoreSpike(r, sent, processed, got)
	red := false
	if _, ok := got[ids[4]]; ok {
		red = true
	}
	r.Redelivered = &red
	r.Pass = red && r.Lost == 0 && r.Dup == 0
	if !red {
		r.Note = "the hub marks a delivery sent when it writes the frame; a box that dies before its inbox write loses that message and every frame already in flight"
	}
	r.emit(t)
}

// Test 4: 1,000 posts at 100 a second to a live box running the production
// reconnect loop (hubclient.Run); the hub process is restarted at 40 % on the
// same store and port.
func TestSpike059HubRestart(t *testing.T) {
	st := newStore(t)
	blobs := t.TempDir()
	o := hub.Options{
		Store: st, Blob: blob.Dir{Root: blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test",
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	var mu sync.Mutex
	var srv *hub.Server
	var ts *httptest.Server
	up := func(l net.Listener) {
		s, err := hub.New(o)
		if err != nil {
			t.Fatal(err)
		}
		h := httptest.NewUnstartedServer(s.Handler())
		h.Listener.Close()
		h.Listener = l
		h.Start()
		mu.Lock()
		srv, ts = s, h
		mu.Unlock()
	}
	up(ln)
	t.Cleanup(func() { mu.Lock(); defer mu.Unlock(); srv.Shutdown(); ts.Close() })
	e := &env{t: t, st: st, srv: srv, ts: ts, blobs: blobs}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	e.client = &http.Client{Transport: tr}

	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	d := e.box(tid, "box-r", "CLE-15")
	e.pin(tid, s)
	e.pin(tid, d)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.c.Run(ctx) //nolint:errcheck // the production reconnect loop
	time.Sleep(500 * time.Millisecond)

	r := &spikeResult{Backend: "spool", Test: 4, Consumers: "1 box (hubclient.Run), hub restarted at 40 %"}
	snd := newSender(t, s, r)
	sent := map[string]time.Time{}
	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 1000; i++ {
		if i == 400 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				t0 := time.Now()
				mu.Lock()
				srv.Shutdown()
				ts.CloseClientConnections()
				ts.Close()
				mu.Unlock()
				time.Sleep(2 * time.Second) // a Cloud Run cold start is longer; 2 s keeps the gap visible
				var l net.Listener
				for {
					if l, err = net.Listen("tcp", addr); err == nil {
						break
					}
					time.Sleep(50 * time.Millisecond)
				}
				up(l)
				r.RestartMs = float64(time.Since(t0).Milliseconds())
			}()
		}
		id, at := snd.send("box-r", "CLE-15", fmt.Sprintf("t4-%d", i))
		sent[id] = at
		pace(start, i+1, 100)
	}
	wg.Wait()
	waitArrivals([]*box{d}, []string{"CLE-15"}, 1000, 90*time.Second)
	scoreSpike(r, sent, arrivals(d, "CLE-15"))
	r.Note = "a duplicate frame cannot show in the inbox: the box skips an id it already has (file name)"
	r.Pass = r.Lost == 0 && r.Dup == 0
	r.emit(t)
}
