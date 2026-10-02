package hub_test

// (spec 027 P2): Postgres round trips per hot request, over the
// real session door (fake IdP sign-in, store-backed membership) against a real
// Postgres behind the counting TCP proxy of onsend_bench_test.go. A round trip
// is one client-to-server packet: pgx writes one buffer per round trip, and a
// batch is one. Production pays one Cloud Run -> Cloud SQL RTT per packet, so
// this number is the part of a request's latency the code controls,
// independent of the box it is measured on.
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run TestRoundTripsPerRequest -v
//
// Skipped without SPOOL_TEST_PG_DSN (the memory store has no wire).

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

func TestRoundTripsPerRequest(t *testing.T) {
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
	dmTask := uuid4()
	send := func(body string) wuiFrame {
		wsjson.Write(ctx, c, map[string]any{"type": "send", "task_id": "lobby", "body": body}) //nolint:errcheck
		return w.read("ack")
	}
	for i := 0; i < 5; i++ { // a lobby with history, and a warm statement cache
		send(fmt.Sprintf("seed %d", i))
	}
	for i := 0; i < 6; i++ { // a #tasks page: 6 topics of 3 messages
		task := uuid4()
		for j := 0; j < 3; j++ {
			channelFrame(t, c, uuid4(), task, "tasks", fmt.Sprintf("task %d line %d", i, j))
		}
	}
	r.e.pin(tenant, r.e.box(tenant, "box-a", "CLE-07"))
	for i := 0; i < 3; i++ { // a DM topic of 3 lines, for the DM seed
		wsjson.Write(ctx, c, map[string]any{"type": "send", "task_id": dmTask, "to": "CLE-07", "body": fmt.Sprintf("dm %d", i)}) //nolint:errcheck
		w.read("ack")
	}

	get := func(path string) func() error {
		return func() error {
			if code, _, body := r.get(t, tenant, path); code != 200 {
				return fmt.Errorf("%s: %d %s", path, code, body)
			}
			return nil
		}
	}
	// budget is the fewest round trips a request may take (the minimum over
	// n: a background write - presence, last-seen - can land inside one
	// sample, never inside all of them). Tree bbe04d26 read 3 10 5 5 11 28 5;
	// raising a budget needs a reason in the commit.
	// SPL-1115: the read door's channel list rides the membership batch, one
	// round trip off channels, topics, topics/{id}, search and a channel page.
	probes := []struct {
		name   string
		budget int64
		run    func() error
	}{
		{"GET /v1/view/me", 1, get("/v1/view/me")},
		// SPL-1100: one humans read for every setting (it read the row 9 times: 14).
		// db-payload audit cut 6: the tenant list is one batch, not
		// BEGIN..COMMIT (it was 6, measured 6/8 -> 3/5, n=3).
		{"GET /api/v1/auth/session", 3, get("/api/v1/auth/session")},
		{"GET /v1/view/channels", 2, get("/v1/view/channels")},
		// SPL-1111: boxes, avatars and members in one batch (it was 3: 4).
		{"GET /v1/view/roster", 2, get("/v1/view/roster")},
		{"GET /v1/view/topics", 2, get("/v1/view/topics")},
		{"GET /v1/view/topics/{lobby}", 4, // SPL-1121: reactions ride the deliveries batch
			get("/v1/view/topics/" + lobby)},
		{"GET /v1/view/search?q=seed", 7, get("/v1/view/search?q=seed")},
		// SPL-1206: the grammar is built once (sync.Once), so operators is only
		// the view door's one membership read — it must never grow a read of its
		// own (measured 1/1 against Postgres).
		{"GET /v1/view/search/operators", 1, get("/v1/view/search/operators")},
		// A channel page in ONE read (per_topic, 6 topics x 3 messages); the
		// WUI used to add one topics/{id} read (6 round trips) per topic.
		{"GET topics?channel&per_topic=30", 2, get("/v1/view/topics?channel=tasks&limit=20&per_topic=30")},
		// DB payload cut 1: the DM seed counts per-peer unread/total in the hub
		// from a thin read; per_topic=50 inlined the envelopes and read their
		// deliveries and reactions too (measured 5/9 -> 4/5 here, n=3).
		{"GET topics?dm&dm_counts", 4, get("/v1/view/topics?dm=true&limit=50&dm_counts=true&dm_read=CLE-07%40box-a~2026-10-01T00%3A00%3A00Z~")},
		// DB payload cut 7: the message and its box-wui delivery (sent) in one
		// statement; insert + enqueue + claim took three (it was 5).
		{"WS wui send (lobby) -> ack", 3, func() error { send("probe"); return nil }},
	}
	const n = 5
	t.Logf("%-30s DB round trips (n=%d, min/max, budget)", "request", n)
	for _, p := range probes {
		lo, hi := int64(1<<62), int64(0)
		for i := 0; i < n; i++ {
			time.Sleep(20 * time.Millisecond) // let background writes (last-seen, fan-out) settle
			if os.Getenv("RT_MARK") != "" {   // a marker line in a log_statement=all server log
				r.e.st.(*store.Postgres).Pool().Exec(ctx, "SELECT $1::text", "MARK "+p.name) //nolint:errcheck
			}
			before := proxy.packets.Load()
			if err := p.run(); err != nil {
				t.Fatal(err)
			}
			time.Sleep(20 * time.Millisecond)
			d := proxy.packets.Load() - before
			lo, hi = min(lo, d), max(hi, d)
		}
		t.Logf("%-30s %d/%d  %d", p.name, lo, hi, p.budget)
		if lo > p.budget {
			t.Errorf("%s: %d DB round trips, budget %d", p.name, lo, p.budget)
		}
	}
}
