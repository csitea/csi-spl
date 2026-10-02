package hub_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// stampFake is the memory store with a change stamp the test moves by hand
// (rdb 0103's triggers move it on Postgres; store/change_stamp_test.go
// proves those). Embedding *store.Memory keeps every optional interface.
type stampFake struct {
	*store.Memory
	mu                sync.Mutex
	stamp             int64
	settled, expired  bool
	err               error
	calls             int
	lastSince, lastAt time.Time
}

func (f *stampFake) ChangeStamp(_ context.Context, _ string, since, now time.Time) (store.ChangeStamp, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastSince, f.lastAt = since, now
	return store.ChangeStamp{Stamp: f.stamp, Settled: f.settled, Expired: f.expired}, f.err
}

func (f *stampFake) set(fn func(f *stampFake)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *stampFake) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// R2-5: an unchanged repeat read of a stamped view answers 304 from the
// change stamp alone, without running the view's reads; any move of the
// stamp, an expiry, another request key, an unsettled stamp or a failed
// stamp read gives the full answer. A first read (no If-None-Match), a
// since= delta and the roster never read the stamp.
func TestViewStampRepeatRead(t *testing.T) {
	fs := &stampFake{stamp: 7, settled: true}
	r := newDoorRig(t, func(o *hub.Options) {
		if m, ok := o.Store.(*store.Memory); ok {
			fs.Memory = m
			o.Store = fs
		}
	})
	if fs.Memory == nil {
		t.Skip("the stamp fake wraps the memory store (Postgres: store/change_stamp_test.go)")
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

	const path = "/v1/view/topics?channel=feedback&per_topic=50"
	get := func(client *http.Client, p, inm string) (int, string, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("ETag"), string(b)
	}
	isStamp := func(tag string) bool { return strings.HasPrefix(tag, `W/"s`) }

	// A first read: the body hash, and the stamp is never read.
	code, bodyTag, first := get(r.browser, path, "")
	if code != http.StatusOK || bodyTag == "" || isStamp(bodyTag) || fs.count() != 0 {
		t.Fatalf("first read: %d tag %q, %d stamp reads", code, bodyTag, fs.count())
	}
	// A repeat read with the body tag: the same body, now with a stamp tag.
	code, tag, body := get(r.browser, path, bodyTag)
	if code != http.StatusOK || !isStamp(tag) || body != first || fs.count() != 1 {
		t.Fatalf("repeat with the body tag: %d tag %q, %d stamp reads, same body %v", code, tag, fs.count(), body == first)
	}
	// Unchanged: 304, no body, the same tag.
	if code, got, body := get(r.browser, path, tag); code != http.StatusNotModified || got != tag || body != "" {
		t.Fatalf("unchanged: %d tag %q body %q", code, got, body)
	}
	// The 304 ran none of the view's reads: a row written WITHOUT a stamp
	// bump (what a missing trigger would be) is not seen. This is why every
	// writer must bump.
	now := time.Now().UTC()
	hidden := store.Message{TenantID: tenant, MsgID: uuid4(), TaskID: task, TS: now, FromBox: "box-a", FromID: "CLE-07",
		ToBox: hub.WUIBox, ToID: "CLE-07", Kind: "note", Body: "written behind the stamp", Files: []byte(`[]`), Msg: []byte(`{"v":1}`),
		EnvSig: "sig", Env: []byte(`{"msg":{"body":"written behind the stamp"}}`), ReceivedAt: now, ExpiresAt: now.Add(time.Hour), Channel: "feedback"}
	if _, err := fs.InsertMessage(ctx, hidden); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := get(r.browser, path, tag); code != http.StatusNotModified {
		t.Fatalf("no bump: %d, want 304 (the gate must answer before the reads)", code)
	}
	// The bump: the full answer, the new row in it, a new tag.
	fs.set(func(f *stampFake) { f.stamp++ })
	code, tag2, body := get(r.browser, path, tag)
	if code != http.StatusOK || !strings.Contains(body, "written behind the stamp") || !isStamp(tag2) || tag2 == tag {
		t.Fatalf("after a bump: %d tag %q -> %q", code, tag, tag2)
	}
	// The gate asked for expiries since the tag's mint.
	if since, at := fs.lastSince, fs.lastAt; since.After(at) || at.Sub(since) > time.Minute {
		t.Fatalf("expiry window (%v, %v]", since, at)
	}
	// An expiry since the mint: the full answer.
	fs.set(func(f *stampFake) { f.expired = true })
	if code, _, _ := get(r.browser, path, tag2); code != http.StatusOK {
		t.Fatalf("an expiry: %d, want 200", code)
	}
	fs.set(func(f *stampFake) { f.expired = false })
	if code, _, _ := get(r.browser, path, tag2); code != http.StatusNotModified {
		t.Fatalf("control: %d, want 304", code)
	}
	// Another request key (query, path) never matches the tag.
	for _, p := range []string{path + "&limit=5", "/v1/view/channels", "/v1/view/topics/" + lobby} {
		if code, _, _ := get(r.browser, p, tag2); code != http.StatusOK {
			t.Fatalf("%s with the topics tag: %d, want 200", p, code)
		}
	}
	// The door before the gate: no session, no 304 for a held tag.
	if code, _, _ := get(&http.Client{Transport: r.browser.Transport}, path, tag2); code != http.StatusUnauthorized {
		t.Fatalf("anonymous with a valid tag: %d, want 401", code)
	}
	// Unsettled: the full answer and the body hash, never a stamp tag.
	fs.set(func(f *stampFake) { f.stamp++; f.settled = false })
	if code, got, _ := get(r.browser, path, tag2); code != http.StatusOK || got == "" || isStamp(got) {
		t.Fatalf("unsettled: %d tag %q, want 200 and the body hash", code, got)
	}
	// A failed stamp read: the full answer and the body hash.
	fs.set(func(f *stampFake) { f.settled = true; f.err = errors.New("db down") })
	if code, got, _ := get(r.browser, path, tag2); code != http.StatusOK || isStamp(got) {
		t.Fatalf("stamp error: %d tag %q", code, got)
	}
	fs.set(func(f *stampFake) { f.err = nil })
	// since= (R2-2's delta, its body carries the hub clock) and the roster
	// (process-memory presence) never read the stamp.
	n := fs.count()
	since := viewCursor(time.Now(), "x")
	if code, got, _ := get(r.browser, path+"&since="+url.QueryEscape(since), tag2); code != http.StatusOK || isStamp(got) {
		t.Fatalf("since=: %d tag %q", code, got)
	}
	if code, got, _ := get(r.browser, "/v1/view/roster", tag2); code != http.StatusOK || isStamp(got) {
		t.Fatalf("roster: %d tag %q", code, got)
	}
	if fs.count() != n {
		t.Fatalf("since= / roster read the stamp (%d -> %d)", n, fs.count())
	}
}

// TestViewStampRoundTrips (Postgres, the counting proxy of
// onsend_bench_test.go): an unchanged repeat read of a stamped view costs
// ONE DB round trip (the stamp) where the full read cost what
// TestRoundTripsPerRequest budgets, and the 304 carries no body. Logs the
// round trips and the hub time per request, full vs 304 (n per path).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run TestViewStampRoundTrips -v
func TestViewStampRoundTrips(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	proxy := newPGProxy(t, u.Host)
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
	w := &wuiClient{t: t, c: c}
	w.read("welcome")
	for i := 0; i < 5; i++ { // a lobby with history
		wsjson.Write(ctx, c, map[string]any{"type": "send", "task_id": "lobby", "body": fmt.Sprintf("seed %d", i)}) //nolint:errcheck
		w.read("ack")
	}
	for i := 0; i < 6; i++ { // a #tasks page: 6 topics of 3 messages
		task := uuid4()
		for j := 0; j < 3; j++ {
			channelFrame(t, c, uuid4(), task, "tasks", fmt.Sprintf("task %d line %d", i, j))
		}
	}
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	time.Sleep(100 * time.Millisecond)
	// Settle: age the tenant's last change past store.ChangeStampSettle (the
	// operator scope, as the sweeps run), instead of waiting it out.
	pool := r.e.st.(*store.Postgres).Pool()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err == nil {
		_, err = tx.Exec(ctx, `UPDATE tenant_change_stamps SET changed_at = changed_at - interval '1 minute' WHERE tenant_id = $1`, tenant)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	get := func(p, inm string) (int, string, int64, time.Duration) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		if inm != "" {
			req.Header.Set("If-None-Match", inm)
		}
		before, start := proxy.packets.Load(), time.Now()
		resp, err := r.browser.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
		took := time.Since(start)
		time.Sleep(20 * time.Millisecond)
		return resp.StatusCode, resp.Header.Get("ETag"), proxy.packets.Load() - before, took
	}
	const n = 20
	t.Logf("%-46s %-10s %-10s (n=%d, min round trips, median ms)", "request", "full", "304", n)
	for _, p := range []string{"/v1/view/topics?channel=tasks&limit=20&per_topic=50", "/v1/view/topics",
		"/v1/view/channels", "/v1/view/topics/" + lobby} {
		_, bodyTag, _, _ := get(p, "")
		code, tag, _, _ := get(p, bodyTag)
		if code != http.StatusOK || !strings.HasPrefix(tag, `W/"s`) {
			t.Fatalf("%s: no stamp tag minted (%d %q)", p, code, tag)
		}
		measure := func(inm string, want int) (int64, time.Duration) {
			lo, ds := int64(1<<62), make([]time.Duration, 0, n)
			for i := 0; i < n; i++ {
				code, _, rt, took := get(p, inm)
				if code != want {
					t.Fatalf("%s: %d, want %d", p, code, want)
				}
				lo, ds = min(lo, rt), append(ds, took)
			}
			sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
			return lo, ds[n/2]
		}
		fullRT, fullMS := measure("", http.StatusOK)
		hitRT, hitMS := measure(tag, http.StatusNotModified)
		t.Logf("%-46s %d / %-6.2f %d / %-6.2f", p, fullRT, float64(fullMS.Microseconds())/1000, hitRT, float64(hitMS.Microseconds())/1000)
		if hitRT > 1 {
			t.Errorf("%s: an unchanged repeat read took %d DB round trips, want 1", p, hitRT)
		}
	}
}
