package hub_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 066 L2 (section 4.0): POST /v1/perf/samples is fire-and-forget. These
// tests run on the memory store, and on Postgres when SPOOL_TEST_PG_DSN is set.

// perfInsertFn replaces InsertPerfSamples; next is the real insert.
type perfInsertFn func(ctx context.Context, next func() error) error

// perfMem / perfPG swap the perf insert and keep every other interface of the
// concrete store.
type perfMem struct {
	*store.Memory
	fn perfInsertFn
}

func (p perfMem) InsertPerfSamples(ctx context.Context, tenant string, b []store.PerfSample) error {
	return p.fn(ctx, func() error { return p.Memory.InsertPerfSamples(ctx, tenant, b) })
}

type perfPG struct {
	*store.Postgres
	fn perfInsertFn
}

func (p perfPG) InsertPerfSamples(ctx context.Context, tenant string, b []store.PerfSample) error {
	return p.fn(ctx, func() error { return p.Postgres.InsertPerfSamples(ctx, tenant, b) })
}

// perfEnv is rbacEnv with the perf insert swapped (nil = the real one), a
// tenant and a seated member.
func perfEnv(t *testing.T, fn perfInsertFn) (*env, string, string) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) {
		if fn == nil {
			return
		}
		switch st := o.Store.(type) {
		case *store.Memory:
			o.Store = perfMem{st, fn}
		case *store.Postgres:
			o.Store = perfPG{st, fn}
		default:
			t.Fatalf("store %T", st)
		}
	})
	tid, _ := e.tenant()
	return e, tid, seat(t, e, tid, rbac.Developer)
}

func perfSession() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func perfOK(session string) map[string]any {
	return map[string]any{"session_id": session, "metric": "send_ack", "value_ms": 120,
		"device": "desktop", "view": "topic", "outcome": "ok", "build": "1.3.7"}
}

// postPerf POSTs body as text/plain (the beacon's type) and times the answer.
func postPerf(t *testing.T, e *env, tid, as string, body any) (int, map[string]any, time.Duration) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/perf/samples", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "text/plain;charset=UTF-8")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	start := time.Now()
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("post perf: %v", err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out, time.Since(start)
}

// perfRows waits for the writer to store want rows of tid (or fails).
func perfRows(t *testing.T, e *env, tid string, want int) []store.PerfSample {
	t.Helper()
	ps := e.st.(store.PerfSamples)
	deadline := time.Now().Add(5 * time.Second)
	for {
		rows, err := ps.ListPerfSamples(context.Background(), tid, time.Time{}, 0)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) >= want || time.Now().After(deadline) {
			if len(rows) != want {
				t.Fatalf("tenant %s: %d stored rows, want %d", tid, len(rows), want)
			}
			return rows
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// The tenant comes from the session and at from the hub: a body tenant_id or
// at (top level and per sample) is ignored. CONTROL: the other tenant named
// in the body stores nothing.
func TestPerfIngestTenantAndAtFromSession(t *testing.T) {
	e, tid, hum := perfEnv(t, nil)
	other, _ := e.tenant()
	s := perfOK(perfSession())
	s["tenant_id"], s["at"] = other, "2001-01-01T00:00:00Z"
	before := time.Now().Add(-time.Second)
	code, out, _ := postPerf(t, e, tid, hum, map[string]any{"samples": []any{s}, "tenant_id": other, "at": 0, "dropped": 2})
	after := time.Now().Add(time.Second)
	if code != http.StatusAccepted {
		t.Fatalf("post: %d %v", code, out)
	}
	if ms, _ := out["hub_ms"].(float64); ms < float64(before.UnixMilli()) || ms > float64(after.UnixMilli()) {
		t.Fatalf("hub_ms %v not the hub's clock", out["hub_ms"])
	}
	rows := perfRows(t, e, tid, 1)
	if at := rows[0].At; at.Before(before) || at.After(after) {
		t.Fatalf("at %v is not the receive time", at)
	}
	if rows[0].Metric != "send_ack" || rows[0].ValueMs != 120 || rows[0].View != "topic" {
		t.Fatalf("stored %+v", rows[0])
	}
	perfRows(t, e, other, 0)
}

// Section 4.2: an unknown metric, an out-of-set value and any field the
// contract does not name (PII-shaped) are refused 400; no member session is
// 403. CONTROL: the same body without the field is accepted.
func TestPerfIngestRefuses(t *testing.T) {
	e, tid, hum := perfEnv(t, nil)
	sess := perfSession()
	bad := map[string]func(map[string]any){
		"unknown metric": func(s map[string]any) { s["metric"] = "page_views" },
		"email build":    func(s map[string]any) { s["build"] = "a@b.example" },
		"bad session":    func(s map[string]any) { s["session_id"] = "HUM-10" },
	}
	for _, f := range []string{"user_id", "human_id", "email", "name", "ip", "user_agent", "url", "query", "topic", "channel", "msg_id", "issue_id", "text"} {
		bad["field "+f] = func(s map[string]any) { s[f] = "x" }
	}
	for name, mut := range bad {
		s := perfOK(sess)
		mut(s)
		if code, out, _ := postPerf(t, e, tid, hum, map[string]any{"samples": []any{s}}); code != http.StatusBadRequest {
			t.Fatalf("%s: %d %v", name, code, out)
		}
	}
	if code, out, _ := postPerf(t, e, tid, hum, map[string]any{"samples": []any{}, "email": "a@b.example"}); code != http.StatusBadRequest {
		t.Fatalf("top-level email: %d %v", code, out)
	}
	if code, _, _ := postPerf(t, e, tid, "", map[string]any{"samples": []any{perfOK(sess)}}); code != http.StatusForbidden {
		t.Fatalf("no session: %d", code)
	}
	perfRows(t, e, tid, 0)
	if code, out, _ := postPerf(t, e, tid, hum, map[string]any{"samples": []any{perfOK(sess)}}); code != http.StatusAccepted {
		t.Fatalf("CONTROL: %d %v", code, out)
	}
	perfRows(t, e, tid, 1)
}

// A failing or panicking store never reaches the answer: every POST is 2xx,
// fast, and the writer keeps serving the next batch.
func TestPerfIngestStoreFailingNo5xx(t *testing.T) {
	for name, fn := range map[string]perfInsertFn{
		"error": func(context.Context, func() error) error { return errors.New("db down") },
		"panic": func(context.Context, func() error) error { panic("driver bug") },
	} {
		t.Run(name, func(t *testing.T) {
			e, tid, hum := perfEnv(t, fn)
			for i := 0; i < 20; i++ {
				code, out, d := postPerf(t, e, tid, hum, map[string]any{"samples": []any{perfOK(perfSession())}})
				if code != http.StatusAccepted && code != http.StatusNoContent {
					t.Fatalf("post %d: %d %v", i, code, out)
				}
				if d > time.Second {
					t.Fatalf("post %d took %v", i, d)
				}
			}
			perfRows(t, e, tid, 0)
		})
	}
}

// A blocked store: the answers stay fast, the queue fills and then drops with
// 204 (never an error), and a member route answers as fast as before.
func TestPerfIngestStoreBlockedFullQueue(t *testing.T) {
	release := make(chan struct{})
	e, tid, hum := perfEnv(t, func(context.Context, func() error) error { <-release; return nil })
	t.Cleanup(func() { close(release) })

	member := func() time.Duration {
		ds := make([]time.Duration, 15)
		for i := range ds {
			start := time.Now()
			if code, out := call(t, e, tid, http.MethodGet, "/v1/view/me", hum, nil); code != http.StatusOK {
				t.Fatalf("view/me: %d %v", code, out)
			}
			ds[i] = time.Since(start)
		}
		sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
		return ds[len(ds)/2]
	}
	base := member()

	var mu sync.Mutex
	codes := map[int]int{}
	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				code, _, d := postPerf(t, e, tid, hum, map[string]any{"samples": []any{perfOK(perfSession())}})
				mu.Lock()
				codes[code]++
				if d > time.Second {
					codes[-1]++
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if codes[-1] > 0 || codes[http.StatusAccepted]+codes[http.StatusNoContent] != 400 {
		t.Fatalf("blocked store answers: %v (-1 = slower than 1 s)", codes)
	}
	if codes[http.StatusNoContent] == 0 {
		t.Fatalf("400 posts into a blocked store never filled the queue: %v", codes)
	}
	if busy := member(); busy > 3*base+100*time.Millisecond {
		t.Fatalf("member route median %v with ingest saturated, %v before", busy, base)
	}
}

// Spec 4 sampling: at most 300 samples per tab per hour; the rest is dropped
// (204), and CONTROL: another tab of the same member is not capped.
func TestPerfIngestSessionCap(t *testing.T) {
	e, tid, hum := perfEnv(t, nil)
	sess := perfSession()
	batch := func(s string, n int) []any {
		out := make([]any, n)
		for i := range out {
			out[i] = perfOK(s)
		}
		return out
	}
	for i := 0; i < 3; i++ {
		if code, out, _ := postPerf(t, e, tid, hum, map[string]any{"samples": batch(sess, 100)}); code != http.StatusAccepted {
			t.Fatalf("batch %d: %d %v", i, code, out)
		}
	}
	if code, _, _ := postPerf(t, e, tid, hum, map[string]any{"samples": batch(sess, 1)}); code != http.StatusNoContent {
		t.Fatalf("sample 301: %d, want 204", code)
	}
	if code, _, _ := postPerf(t, e, tid, hum, map[string]any{"samples": batch(perfSession(), 1)}); code != http.StatusAccepted {
		t.Fatalf("CONTROL another tab: %d", code)
	}
	perfRows(t, e, tid, 301)
}
