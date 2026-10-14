package hub_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/jackc/pgx/v5"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Perf round 5 P5-10 steps 1+2 (SPL-1740): GET /v1/view/channels gates on
// the stamp without deliveries (rdb 0190), the browser may send the ETag it
// holds (CORS), and every channels read logs what it held and what the gate
// did.

// TestViewStampChannelsNoDeliveries: a deliveries-only change leaves an
// unchanged channels read a 304 with no data read, while the topics view
// (which reads deliveries) answers in full; any other change, and an
// expiry, give the channels view in full.
func TestViewStampChannelsNoDeliveries(t *testing.T) {
	fs := &stampFake{stamp: 7, settled: true}
	var logs bytes.Buffer
	r := newDoorRig(t, func(o *hub.Options) {
		o.Log = zerolog.New(&syncWriter{w: &logs})
		if m, ok := o.Store.(*store.Memory); ok {
			fs.Memory = m
			o.Store = fs
		}
	})
	if fs.Memory == nil {
		t.Skip("the stamp fake wraps the memory store (Postgres: TestViewStampChannelsRoundTrips)")
	}
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	(&wuiClient{t: t, c: c}).read("welcome")
	task := uuid4()
	channelFrame(t, c, uuid4(), task, "feedback", "first line")

	get := func(p, inm string) (int, string, string, http.Header) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		resp, err := r.browser.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("ETag"), string(b), resp.Header
	}
	isStamp := stampTagRE.MatchString
	const channels, topics = "/v1/view/channels", "/v1/view/topics?channel=feedback"

	// First read, then the repeat with the body tag mints a stamp tag; the
	// WUI can read it (exposed to CORS).
	code, bodyTag, first, h := get(channels, "")
	if code != http.StatusOK || bodyTag == "" || isStamp(bodyTag) {
		t.Fatalf("first read: %d tag %q", code, bodyTag)
	}
	if got := h.Get("Access-Control-Expose-Headers"); !strings.Contains(got, "ETag") {
		t.Fatalf("Access-Control-Expose-Headers = %q: the WUI cannot read the tag it must send back", got)
	}
	code, tag, body, _ := get(channels, bodyTag)
	if code != http.StatusOK || !isStamp(tag) || body != first {
		t.Fatalf("repeat with the body tag: %d tag %q", code, tag)
	}
	_, ttag, _, _ := get(topics, "")
	_, ttag, _, _ = get(topics, ttag)
	if !isStamp(ttag) {
		t.Fatalf("topics stamp tag %q (control)", ttag)
	}
	// A row written behind the stamp is not seen: the 304 read no data.
	now := time.Now().UTC()
	hidden := store.Message{TenantID: tenant, MsgID: uuid4(), TaskID: uuid4(), TS: now, FromBox: "box-a", FromID: "CLE-07",
		ToBox: hub.WUIBox, ToID: "CLE-07", Kind: "note", Body: "behind the stamp", Files: []byte(`[]`), Msg: []byte(`{"v":1}`),
		EnvSig: "sig", Env: []byte(`{"msg":{"body":"behind the stamp"}}`), ReceivedAt: now, ExpiresAt: now.Add(time.Hour), Channel: "feedback"}
	if _, err := fs.InsertMessage(ctx, hidden); err != nil {
		t.Fatal(err)
	}
	if code, got, body, _ := get(channels, tag); code != http.StatusNotModified || got != tag || body != "" {
		t.Fatalf("unchanged: %d tag %q body %q", code, got, body)
	}
	// Deliveries-only changes, n=5, the last one not yet settled: channels
	// stays 304, topics (it reads deliveries) answers in full each time.
	for i := 1; i <= 5; i++ {
		fs.set(func(f *stampFake) { f.deliv++; f.delivFresh = i == 5 })
		if code, _, _, _ := get(channels, tag); code != http.StatusNotModified {
			t.Fatalf("deliveries change %d: channels %d, want 304", i, code)
		}
		if code, _, _, _ := get(topics, ttag); code != http.StatusOK {
			t.Fatalf("deliveries change %d: topics %d, want 200 (control: the 0103 stamp moved)", i, code)
		}
	}
	// Any other change: the full answer, the hidden row in it, a new tag.
	fs.set(func(f *stampFake) { f.stamp++; f.delivFresh = false })
	code, tag2, body, _ := get(channels, tag)
	if code != http.StatusOK || body == first || !isStamp(tag2) || tag2 == tag {
		t.Fatalf("after a channel change: %d tag %q -> %q, body changed %v", code, tag, tag2, body != first)
	}
	// An expiry: the full answer.
	fs.set(func(f *stampFake) { f.expired = true })
	if code, _, _, _ := get(channels, tag2); code != http.StatusOK {
		t.Fatalf("an expiry: %d, want 200", code)
	}
	fs.set(func(f *stampFake) { f.expired = false })

	// Step 1: one view_stamp_cond line per channels read, none for topics.
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	got := map[string]int{}
	for _, l := range lines {
		if !strings.Contains(l, `"message":"view_stamp_cond"`) {
			continue
		}
		if !strings.Contains(l, `"view":"channels"`) || !strings.Contains(l, `"tenant":"`+tenant+`"`) {
			t.Fatalf("log line %s", l)
		}
		for _, k := range []string{`"inm":"none","gate":"none"`, `"inm":"body","gate":"minted"`, `"inm":"stamp","gate":"304"`, `"inm":"stamp","gate":"minted"`} {
			if strings.Contains(l, k) {
				got[k]++
			}
		}
	}
	want := map[string]int{`"inm":"none","gate":"none"`: 1, `"inm":"body","gate":"minted"`: 1, `"inm":"stamp","gate":"304"`: 6, `"inm":"stamp","gate":"minted"`: 2}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("view_stamp_cond counts %v, want %v\n%s", got, want, logs.String())
	}
}

// TestViewChannelsPreflightIfNoneMatch: the WUI's conditional read sends
// If-None-Match itself, a non-safelisted header the preflight must allow.
func TestViewChannelsPreflightIfNoneMatch(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewCORSOrigins = []string{wuiOrigin} })
	tenant, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tenant)+"/v1/view/channels", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "GET")
	req.Header.Set("Access-Control-Request-Headers", "if-none-match")
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := strings.ToLower(resp.Header.Get("Access-Control-Allow-Headers")); !strings.Contains(got, "if-none-match") {
		t.Fatalf("preflight Allow-Headers %q: the browser would refuse the conditional read", got)
	}
}

// TestViewStampChannelsRoundTrips (Postgres, a statement-counting proxy):
// after a deliveries-only write, an unchanged channels read answers 304 with
// the stamp read alone (no data read), n per write; the topics view
// (control) answers 200. Uses no store field, so it also runs against the
// code before rdb 0190 (there each deliveries write turned the channels read
// into a full one).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run TestViewStampChannelsRoundTrips -v
func TestViewStampChannelsRoundTrips(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	// CI's hub-pg.tst.sh hands a unix-socket DSN (host=<dir>&port=<n>):
	// proxy that socket, and drop host/port so the hub dials the proxy.
	network, target := "tcp", u.Host
	if u.Host == "" {
		q := u.Query()
		port := q.Get("port")
		if port == "" {
			port = "5432"
		}
		network, target = "unix", filepath.Join(q.Get("host"), ".s.PGSQL."+port)
		q.Del("host")
		q.Del("port")
		u.RawQuery = q.Encode()
	}
	proxy := newStmtProxy(t, network, target)
	u.Host = proxy.ln.Addr().String()
	t.Setenv("SPOOL_TEST_PG_DSN", u.String())

	r := newDoorRig(t)
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	(&wuiClient{t: t, c: c}).read("welcome")
	w := &wuiClient{t: t, c: c}
	wsjson.Write(ctx, c, map[string]any{"type": "send", "task_id": "lobby", "body": "a line"}) //nolint:errcheck
	w.read("ack")
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	pool := r.e.st.(*store.Postgres).Pool()
	// inTenant runs fn in one committed transaction under the tenant scope.
	inTenant := func(fn func(tx pgx.Tx) error) {
		t.Helper()
		err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
				return err
			}
			return fn(tx)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	var msg string
	inTenant(func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT msg_id::text FROM messages WHERE tenant_id = $1 LIMIT 1`, tenant).Scan(&msg); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) VALUES ($1, $2, 'box-p510', now() + interval '1 hour')`, tenant, msg)
		return err
	})
	time.Sleep(store.ChangeStampSettle + time.Second) // settle every change so far

	get := func(p, inm string) (int, string, int64) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		time.Sleep(20 * time.Millisecond)
		before := proxy.statements.Load()
		resp, err := r.browser.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
		time.Sleep(20 * time.Millisecond)
		return resp.StatusCode, resp.Header.Get("ETag"), proxy.statements.Load() - before
	}
	tagOf := func(p string) string {
		t.Helper()
		_, body, _ := get(p, "")
		code, tag, _ := get(p, body)
		if code != http.StatusOK || !stampTagRE.MatchString(tag) {
			t.Fatalf("%s: no stamp tag minted (%d %q)", p, code, tag)
		}
		return tag
	}
	const channels, topics = "/v1/view/channels", "/v1/view/topics"
	ctag, ttag := tagOf(channels), tagOf(topics)
	_, _, full := get(channels, "")
	_, _, hit := get(channels, ctag)
	t.Logf("channels: full read %d statements, unchanged 304 %d statements", full, hit)
	if hit >= full {
		t.Fatalf("an unchanged read ran %d statements, a full one %d: the gate did not answer before the reads", hit, full)
	}
	const n = 5
	hits := 0
	for i := 0; i < n; i++ {
		inTenant(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE deliveries SET state = CASE state WHEN 'queued' THEN 'sent' ELSE 'queued' END
				WHERE tenant_id = $1 AND msg_id = $2`, tenant, msg)
			return err
		})
		code, _, st := get(channels, ctag)
		if code == http.StatusNotModified && st <= hit {
			hits++
		}
		t.Logf("deliveries write %d: channels %d, %d statements", i+1, code, st)
		if code, _, _ := get(topics, ttag); code != http.StatusOK {
			t.Fatalf("deliveries write %d: topics %d, want 200 (control: the 0103 stamp moved)", i+1, code)
		}
	}
	if hits != n {
		t.Fatalf("channels answered 304 with the stamp read alone after %d of %d deliveries-only writes, want %d", hits, n, n)
	}
}

// stmtProxy forwards to Postgres and counts the statements the hub sends:
// each Bind (extended protocol, pgx's default) or Query (simple protocol)
// message, batches included.
type stmtProxy struct {
	ln         net.Listener
	statements atomic.Int64
}

func newStmtProxy(t *testing.T, network, target string) *stmtProxy {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	p := &stmtProxy{ln: ln}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s, err := net.Dial(network, target)
			if err != nil {
				c.Close()
				continue
			}
			go func() { io.Copy(c, s); c.Close() }() //nolint:errcheck
			go p.count(c, s)
		}
	}()
	return p
}

// count copies client to server message by message: the startup message
// first (no type byte), then type + int32 length + body.
func (p *stmtProxy) count(c, s net.Conn) {
	defer s.Close()
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(c, hdr[:4]); err != nil {
		return
	}
	n := int(binary.BigEndian.Uint32(hdr[:4]))
	if _, err := s.Write(hdr[:4]); err != nil || n < 4 {
		return
	}
	if _, err := io.CopyN(s, c, int64(n-4)); err != nil {
		return
	}
	for {
		if _, err := io.ReadFull(c, hdr); err != nil {
			return
		}
		if hdr[0] == 'B' || hdr[0] == 'Q' {
			p.statements.Add(1)
		}
		n := int(binary.BigEndian.Uint32(hdr[1:]))
		if _, err := s.Write(hdr); err != nil || n < 4 {
			return
		}
		if _, err := io.CopyN(s, c, int64(n-4)); err != nil {
			return
		}
	}
}
